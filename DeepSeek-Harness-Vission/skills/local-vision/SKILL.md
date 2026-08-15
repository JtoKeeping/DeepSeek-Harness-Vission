---
name: local-vision
description: 本地识图（Ollama qwen3-vl:8b）。仅在用户上传了图片、引用图片文件、或消息中出现"图片对象路径"且需要识别/描述/OCR 图片内容时使用；无图片或无需识图时不要调用。
whenToUse: 用户上传图片或引用图片文件并需要理解图片内容时；识别结果不足或需要定向识别（逐字 OCR、按问题追问细节）时；插件自动识别失败后的兜底。
metadata:
  engine: local-ollama
  model: qwen3-vl:8b
---

# local-vision：本地识图

当前会话模型（deepseek-v4-flash）不能直接查看图片。本技能通过本机 Ollama 的
`qwen3-vl:8b` 完成识图，推理仍由当前模型完成。

## 自动识别（后台静默，已由插件完成）

用户上传的图片会被 `local-vision` 插件在**后台**自动识别：每次请求发给模型前，
适配器把图片替换为识别文本——**识别结果不会出现在聊天界面里**，界面只保留
用户的提问和图片缩略图，然后模型直接基于识别结果回答。

模型侧收到的图片内容通常形如：

```
[用户上传的图片（本地识图结果）]
[本地识图 qwen3-vl:8b；图片对象路径：<路径>]
<识别内容>
```

**直接使用该文本**，不要重复识别，除非需要更精确的结果。

## 定向/补充识别

需要更精确的识别时（例如逐字转录文字、追问图片细节、或图片未能自动识别），
使用本技能目录下的辅助脚本（先以资源基目录为基准解析路径）：

```
scripts\ollama_vision.ps1 -ImagePath "<图片对象路径>" -Prompt "<你的定向问题>"
```

- `<图片对象路径>` 来自模型收到的识图文本中"图片对象路径"一行；也可以是工作区内的图片文件路径。
- 用 `pwsh` 工具运行；脚本会 base64 编码图片并调用本地 Ollama，输出识别结果。
- **注意**：若 `local-vision` 插件已切换为 `provider: openai`（调用云端 API 而非
  Ollama），本脚本不适用；此时以插件自动识图结果为准，如需更精确识别请提示
  用户手动检查图片。
- 若 `pwsh` 沙箱无法联网，改用等价的 `curl.exe`：
  ```powershell
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("<路径>"))
  curl.exe -s http://localhost:11434/api/chat -H "Content-Type: application/json" -d ("{`"model`":`"qwen3-vl:8b`",`"messages`":[{`"role`":`"user`",`"content`":`"<提示>`",`"images`":[`"" + $b64 + "`"]}],`"stream`":false}")
  ```
  响应 JSON 中取 `message.content` 即为识别文本。

## 视觉服务不可用时的处置

如果模型收到的图片内容为"本地识图失败"提示（如"无法连接视觉模型 API"、
"无法连接本地 Ollama"、"鉴权失败"），或调用脚本时报连接错误：

1. 告诉用户按 `local-vision` 插件的配置（`~/.dsh/profiles/web/cordis.patch.yml`
   里的 `provider`）检查对应的视觉服务：
   - `provider: ollama`：启动本机 Ollama（托盘应用或 `ollama serve`），并确认
     已拉取模型（`ollama pull <model>`）；
   - `provider: openai`：检查 `baseUrl`、`apiKey` 是否正确、网络是否可达。
2. 提醒用户修复后重新发送图片即可自动识别。

## 约束

- 本技能**只在涉及图片且需要识图时**使用；普通纯文本对话不得调用。
- 识别结果只是文本描述，存在误差；涉及精确数据（数字、代码、证件号等）时
  提示用户该结果来自本地视觉模型，可能不准确，需要人工核对。
