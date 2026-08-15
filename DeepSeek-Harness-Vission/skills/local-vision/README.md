# local-vision：本地识图补全（Ollama qwen3-vl:8b）

弥补 `deepseek-v4-flash`（及其他纯文本模型）不能识图的缺点：

- **上传图片后后台静默识图**：`local-vision` profile 插件把本地 Ollama
  `qwen3-vl:8b` 注册为 deepseek 适配器的"识图桥"。每次请求发给模型前，适配器
  在序列化阶段把图片块替换为识别文本——**识别结果不写入会话、界面零痕迹**，
  聊天里只显示提问与图片缩略图，模型直接基于识别结果回答。
- **定向识图**：本 skill（`SKILL.md`）指导模型在需要更精确结果时用
  `scripts/ollama_vision.ps1` 对指定图片/指定问题再次调用 Ollama。
- **仅按需触发**：无图片时不调用 Ollama，零开销；同一图片识别结果进程内缓存。

## 组成

| 路径 | 作用 |
|---|---|
| `~/.dsh/profiles/web/plugins/local-vision.mjs` | 识图桥插件（注册 Ollama 识别函数，含缓存） |
| `~/.dsh/profiles/web/cordis.patch.yml` | profile 补丁层，装载插件 |
| `~/.dsh/skills/local-vision/SKILL.md` | 模型技能（定向识图指令） |
| `~/.dsh/skills/local-vision/scripts/ollama_vision.ps1` | 定向识图辅助脚本 |

## 前置条件

- Ollama 已启动（应用或 `ollama serve`），`localhost:11434` 可达；
- 模型已拉取：`ollama pull qwen3-vl:8b`。
- 检查：`ollama list`

## dsh 包补丁（升级后需重打）

`dsh-llm-deepseek`（npx 缓存内）有两处小补丁，`dsh` 包升级会还原：

1. `assertTextOnly` 由"含图片即抛错"改为"剥离图片块"（deepseek 适配器不再因
   图片历史而失败）。
2. `inputModalities` 由 `["text"]` 改为 `["text", "image"]`（放行图片上传与
   `read_image` 能力检查）。

重打：运行 `pwsh ~/.dsh/profiles/web/plugins/reapply-dsh-patches.ps1`（幂等）。

## 验证

1. 重启 harness（结束 3080 端口进程 → 重新运行启动脚本）。
2. 新会话上传图片并提问 → 聊天只显示提问与缩略图，模型基于后台识图结果回答。
3. 纯文字消息 → 行为不变、无识别调用。
4. 视觉服务不可用（Ollama 关闭 / API 不可达）→ 不崩溃，模型会收到"识别失败"
   提示并向用户说明如何修复。

## 切换视觉服务（不用 Ollama / 改用其它识图 API）

无需改插件代码，只需编辑 `~/.dsh/profiles/web/cordis.patch.yml` 中 `local-vision`
条目的 `config`（改后重启 harness）：

```yaml
config:
  provider: openai          # ollama（默认） | openai（OpenAI 兼容接口）
  baseUrl: https://dashscope.aliyuncs.com/compatible-mode/v1   # API 根地址
  model: qwen-vl-max        # 对方模型名
  apiKey: sk-xxxx           # 密钥；无鉴权可留空
```

- `openai` 模式兼容绝大多数视觉 API（GPT-4o、通义千问 Qwen-VL、GLM-4V、Kimi、
  OpenAI 兼容代理等），图片以 data URL 发送；
- 支持 `ollama` 与 `openai` 两种模式；`baseUrl` 末尾自动补 `/chat/completions`；
- 识别结果文本中会标注所用模型名与图片对象路径。

## 已知限制

- 仅处理新消息中的图片；已含图片的历史会话请开新会话。
- 首次识别受 Ollama 冷启动影响，可能较慢（10–60s）。
- 识别为文本描述，精确数字/代码可能存在误差，需人工核对。
