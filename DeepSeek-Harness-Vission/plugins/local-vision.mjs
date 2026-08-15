/**
 * local-vision —— 视觉识别桥接插件（DeepSeek Harness / Cordis）
 *
 * 把视觉模型注册为 deepseek 适配器的"识图桥"（globalThis[Symbol.for('dsh.localVision.bridge')]）：
 * 每次模型请求时，适配器在序列化阶段把消息中的图片块交给本桥识别，用识别文本
 * 替换图片块发给模型；会话里仍只保留图片块（聊天缩略图可见），识别结果【不写入
 * 会话】→ 界面零痕迹，完全后台进行。无图片时零开销；同一图片（attachmentId）
 * 结果按进程缓存。
 *
 * 视觉服务支持两种模式（config.provider）：
 *   - 'ollama'（默认）：本机 Ollama 原生接口。baseUrl 默认 http://localhost:11434，
 *     model 默认 qwen3-vl:8b，无需 apiKey。
 *   - 'openai'：OpenAI 兼容接口（/chat/completions，图片用 data URL）。适用于
 *     GPT-4o、通义千问 Qwen-VL、GLM-4V、Kimi、各种 OpenAI 兼容代理等。
 *     baseUrl 填接口根地址（如 https://api.openai.com/v1 或
 *     https://dashscope.aliyuncs.com/compatible-mode/v1），脚本自动补 /chat/completions；
 *     model 填对方模型名（如 gpt-4o-mini、qwen-vl-max）；apiKey 填密钥（无鉴权可留空）。
 *
 * 配置（cordis.patch.yml 的 config 示例）：
 *   使用 Ollama：
 *     baseUrl: http://localhost:11434
 *     model: qwen3-vl:8b
 *   改用 OpenAI 兼容 API：
 *     provider: openai
 *     baseUrl: https://dashscope.aliyuncs.com/compatible-mode/v1
 *     model: qwen-vl-max
 *     apiKey: sk-xxxx
 *   其它可选：
 *     timeoutMs: 120000
 *     promptTemplate: 含 {userText} 占位符的识别提示模板
 */
import os from 'node:os';
import path from 'node:path';

export const name = 'local-vision';

const BRIDGE_KEY = Symbol.for('dsh.localVision.bridge');

const DEFAULT_PROMPT_TEMPLATE =
  '你是图像识别助手。请详细、准确地描述这张图片的内容：' +
  '包括所有可见的文字（尽量逐字转录）、界面元素、物体、场景、人物、图表、颜色等。' +
  '如果用户提出了与图片相关的问题，请结合图片内容直接回答，或提供回答所需的关键信息。\n\n' +
  '用户的原始消息：\n{userText}';

export function apply(ctx, config = {}) {
  const provider = String(config.provider ?? 'ollama').toLowerCase();
  if (provider !== 'ollama' && provider !== 'openai') {
    throw new Error(`local-vision: unknown provider "${provider}" (supported: ollama, openai)`);
  }
  const baseUrl = String(
    config.baseUrl ?? (provider === 'openai' ? 'https://api.openai.com/v1' : 'http://localhost:11434'),
  ).replace(/\/+$/, '');
  const model = String(config.model ?? (provider === 'openai' ? 'gpt-4o-mini' : 'qwen3-vl:8b'));
  const apiKey = String(config.apiKey ?? '');
  const timeoutMs = Number(config.timeoutMs ?? 120000);
  const promptTemplate = String(config.promptTemplate ?? DEFAULT_PROMPT_TEMPLATE);
  const dshHome = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');

  /** 成功识别结果的进程内缓存（attachmentId -> 文本）。失败不缓存，下次请求重试。 */
  const cache = new Map();

  /** attachmentId 即内容寻址 sha256，还原对象文件路径（供 skill 定向重识别）。 */
  function attachmentPath(attachment) {
    const sha = String(attachment.attachmentId).replace(/^sha256:/, '');
    return path.join(dshHome, 'attachments', 'v1', 'objects', sha.slice(0, 2), sha);
  }

  /** 读附件字节 → base64 → 调视觉服务 → 识别文本（含对象路径提示）。 */
  async function recognize(attachment, userText, signal) {
    const id = String(attachment.attachmentId);
    const cached = cache.get(id);
    if (cached !== void 0) return cached;

    const attachments = ctx.get('attachments');
    if (!attachments) throw new Error('attachment service is not mounted');
    const stored = await attachments.readImage(attachment, signal);
    const b64 = Buffer.from(stored.data).toString('base64');
    const prompt = promptTemplate.replace('{userText}', (userText || '').trim());

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error(`timeout after ${timeoutMs}ms`)), timeoutMs);
    const onOuterAbort = () => {
      if (signal?.aborted) controller.abort(signal.reason ?? new Error('aborted'));
    };
    signal?.addEventListener('abort', onOuterAbort, { once: true });
    let text;
    try {
      if (provider === 'openai') {
        const endpoint = baseUrl.endsWith('/chat/completions') ? baseUrl : `${baseUrl}/chat/completions`;
        const response = await fetch(endpoint, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
          },
          body: JSON.stringify({
            model,
            messages: [{
              role: 'user',
              content: [
                { type: 'text', text: prompt },
                { type: 'image_url', image_url: { url: `data:${attachment.mediaType};base64,${b64}` } },
              ],
            }],
            stream: false,
          }),
          signal: controller.signal,
        });
        if (!response.ok) {
          const detail = (await response.text()).slice(0, 300);
          throw new Error(`vision API HTTP ${response.status}: ${detail}`);
        }
        const json = await response.json();
        const content = json?.choices?.[0]?.message?.content;
        if (typeof content !== 'string' || content.trim().length === 0) {
          throw new Error('vision API returned an empty recognition result');
        }
        text = content.trim();
      } else {
        // Ollama 原生接口
        const response = await fetch(`${baseUrl}/api/chat`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            model,
            messages: [{ role: 'user', content: prompt, images: [b64] }],
            stream: false,
          }),
          signal: controller.signal,
        });
        if (!response.ok) {
          const detail = (await response.text()).slice(0, 300);
          throw new Error(`Ollama HTTP ${response.status}: ${detail}`);
        }
        const json = await response.json();
        const content = json?.message?.content;
        if (typeof content !== 'string' || content.trim().length === 0) {
          throw new Error('Ollama returned an empty recognition result');
        }
        text = content.trim();
      }
    } catch (error) {
      const detail = error?.message ?? String(error);
      let hint;
      if (/connect|fetch|network|ECONNREFUSED|ENOTFOUND/i.test(detail)) {
        hint = provider === 'ollama'
          ? `无法连接本地 Ollama（${baseUrl}）。请启动 Ollama 并确认已拉取模型 ${model}（ollama pull ${model}），然后重试。`
          : `无法连接视觉模型 API（${baseUrl}）。请检查网络与 baseUrl 配置，然后重试。`;
      } else if (/401|403|api[ _-]?key|unauthorized/i.test(detail)) {
        hint = `视觉模型 API 鉴权失败：请检查 apiKey（provider=${provider}）。`;
      } else {
        hint = detail;
      }
      throw new Error(hint);
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onOuterAbort);
    }
    cache.set(id, text);
    ctx.logger.info(`[local-vision] recognized ${id} (${provider}/${model})`);
    return `[识图 ${model}；图片对象路径：${attachmentPath(attachment)}]\n${text}`;
  }

  globalThis[BRIDGE_KEY] = recognize;
  ctx.logger.info(`[local-vision] bridge active: provider=${provider} model=${model} baseUrl=${baseUrl}`);

  return () => {
    if (globalThis[BRIDGE_KEY] === recognize) delete globalThis[BRIDGE_KEY];
  };
}
