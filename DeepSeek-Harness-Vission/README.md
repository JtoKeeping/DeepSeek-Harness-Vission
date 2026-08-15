# DeepSeek-Harness-Vission — DSH 本地识图补全（Local Vision Bridge for DeepSeek Harness）

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh web`）的纯文本模型（如 `deepseek-v4-flash`）补上"识图"能力：

> 上传图片并提问 → 视觉模型在**后台**自动识别 → 当前模型结合识别结果回答。
> 聊天界面只显示你的提问、图片缩略图和模型回答——识别过程完全不可见。

## 特性

- **后台静默识图**：识别结果不写入会话、界面零痕迹，模型直接基于识别内容推理；
- **保留缩略图**：聊天记录里图片照常显示；
- **仅按需触发**：无图片时零开销；同一图片结果进程内缓存；
- **视觉服务可切换**：内置 `ollama`（本机 Ollama）与 `openai`（OpenAI 兼容 API）两种模式，
  无需改代码即可切换 GPT-4o、通义千问 Qwen-VL、GLM-4V、Kimi 等；
- **附带技能**：`local-vision` 技能自动出现在模型技能目录，支持定向/补充识别。

## 原理

三层结构，全部本地/可配置：

```
┌─ 插件 plugins/local-vision.mjs
│    注册"识图桥"（globalThis[Symbol.for('dsh.localVision.bridge')]）：
│    读附件字节 → base64 → 调视觉服务（Ollama / OpenAI 兼容 API）→ 识别文本
│
┌─ 适配器补丁 dsh-llm-deepseek（安装脚本自动打）
│    1) inputModalities 声明 image → 放行图片上传与 read_image 能力检查
│    2) 每次请求序列化时，把图片块临时替换为识图桥返回的文本发给模型
│       （会话里仍只存图片块 → 缩略图可见、识别文本不可见）
│
┌─ 技能 skills/local-vision/SKILL.md
│    出现在模型技能目录；指导模型使用识别结果、做定向识别（scripts/ollama_vision.ps1）
```

## 快速开始

### 1. 前置条件

- 已安装 DeepSeek Harness 并能运行 `dsh web`，会话模型为 **DeepSeek** 系列；
- 视觉服务二选一：
  - **Ollama**（默认）：安装并启动 Ollama，拉取视觉模型：`ollama pull qwen3-vl:8b`；
  - 或一个 OpenAI 兼容视觉 API（见下文"切换视觉服务"）。

### 2. 安装

克隆本仓库后在任意位置运行（或右键 `install-local-vision.ps1` → "使用 PowerShell 运行"）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install-local-vision.ps1
```

脚本自动完成 4 件事（可重复运行，幂等）：

1. 把插件装到 `~/.dsh/profiles/web/plugins/`；
2. 在 `~/.dsh/profiles/web/cordis.patch.yml` 注册插件入口；
3. 把技能装到 `~/.dsh/skills/local-vision/`；
4. 给 `dsh-llm-deepseek` 适配器打补丁（自动定位安装位置）。

### 3. 重启并验证

1. 重启 harness（结束占用 3080 端口的进程 → 重新运行你的启动脚本）；
2. **开一个新会话**，上传图片并提问 → 聊天只显示提问与缩略图，模型基于识别结果回答；
3. 纯文字消息 → 行为不变、无识别调用。

## 切换视觉服务（不用 Ollama / 改用其它识图 API）

无需改代码，编辑 `~/.dsh/profiles/web/cordis.patch.yml` 中 `local-vision` 条目的 `config`，重启生效：

```yaml
config:
  provider: openai          # ollama（默认） | openai（OpenAI 兼容接口）
  baseUrl: https://dashscope.aliyuncs.com/compatible-mode/v1   # API 根地址
  model: qwen-vl-max        # 对方模型名
  apiKey: sk-xxx            # 密钥；无鉴权可留空
```

常用服务示例（`baseUrl` 末尾自动补 `/chat/completions`）：

| 服务 | baseUrl | model 示例 |
|---|---|---|
| Ollama（默认） | `http://localhost:11434` | `qwen3-vl:8b` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| 通义千问 Qwen-VL | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-vl-max` |
| 智谱 GLM-4V | `https://open.bigmodel.cn/api/paas/v4` | `glm-4v-plus` |
| Moonshot Kimi | `https://api.moonshot.cn/v1` | `moonshot-v1-vision`（以官方文档为准） |

> 非 OpenAI 兼容格式（如 Claude / Gemini 原生接口）需自行修改 `plugins/local-vision.mjs`
> 中 `recognize()` 的请求与响应解析部分。

## 手动安装（不使用安装脚本）

```
~/.dsh/profiles/web/plugins/local-vision.mjs      ← 插件
~/.dsh/profiles/web/cordis.patch.yml              ← 追加：
    - insert:
        - id: local-vision
          name: ./plugins/local-vision.mjs
          config:
            baseUrl: http://localhost:11434
            model: qwen3-vl:8b
~/.dsh/skills/local-vision/SKILL.md               ← 技能
~/.dsh/skills/local-vision/scripts/ollama_vision.ps1
```

适配器补丁：运行 `plugins/reapply-dsh-patches.ps1`（自动定位 `dsh-llm-deepseek`，幂等）。

## 卸载

1. 从 `cordis.patch.yml` 删除 `local-vision` 条目；
2. 删除 `~/.dsh/profiles/web/plugins/local-vision.mjs` 与 `~/.dsh/skills/local-vision`；
3. 重启 harness。适配器补丁无害可保留；如需彻底还原，重装对应版本 dsh 包即可。

## 隐私与安全

- **Ollama 模式下图片不出本机**（本地识别）；
- 云端 API 模式：图片 base64 后发送给所配置的服务，`apiKey` 仅存于本地 `cordis.patch.yml`，
  不会写入会话或发送给模型；
- 识别结果文本会标注所用模型名与图片对象路径；涉及精确数字/代码/证件号时模型会提示人工核对。

## 常见问题

- **上传图片仍提示不支持**：确认已重启 harness、补丁已应用（`reapply-dsh-patches.ps1` 显示
  全部 already applied）、当前模型为 DeepSeek。
- **识别失败/超时**：Ollama 模式下确认 `ollama serve` 在运行且已 `ollama pull qwen3-vl:8b`；
  API 模式下检查 `baseUrl`/`apiKey`/网络。首次识别受模型冷启动影响可能较慢（10–60s）。
- **升级 dsh 后失效**：补丁会被还原，重跑 `reapply-dsh-patches.ps1` 即可（或重跑安装脚本）。
- **版本兼容**：补丁按 `@deepseek-ai/dsh` 0.1.0-rc.x 制作；版本差异过大时重打脚本会提示
  需人工核对。

## License

[MIT](LICENSE)
