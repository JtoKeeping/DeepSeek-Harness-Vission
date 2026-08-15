# reapply-dsh-patches.ps1 - idempotently re-apply the dsh-llm-deepseek patches
# (they are reverted whenever the dsh package is upgraded).
# Usage: pwsh reapply-dsh-patches.ps1
# Optional: -Target <path> to patch a specific index.js (used for testing).
param(
  [string]$Target = ''
)
$ErrorActionPreference = 'Stop'

$candidates = @()
if ($Target) {
  $candidates += $Target
} else {
  $known = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx\xxx\node_modules\@deepseek-ai\dsh-llm-deepseek\lib\index.js'
  if (Test-Path -LiteralPath $known) { $candidates += $known }
  $candidates += Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx') -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh-llm-deepseek\lib\index.js' } |
    Where-Object { Test-Path -LiteralPath $_ }
}

$target = $candidates | Select-Object -First 1
if (-not $target) { Write-Error 'dsh-llm-deepseek/lib/index.js not found under npm-cache.' }
Write-Host "Target: $target"

$content = [System.IO.File]::ReadAllText($target)
$changed = $false

# --- Patch 1: assertTextOnly strips images instead of throwing ---
if ($content.Contains('throw new LlmError("The DeepSeek chat-completions adapter does not support image content.')) {
  $old1 = 'if (contentHasImage(blocks)) throw new LlmError("The DeepSeek chat-completions adapter does not support image content.", "UNSUPPORTED_CONTENT");'
  $new1 = @'
return blocks.flatMap((block) => {
	if (block.type === "image") return [];
	if (block.type === "tool-result" && contentHasImage(block.content)) {
		return [{ ...block, content: assertTextOnly(block.content) }];
	}
	return [block];
});
'@
  $content = $content.Replace($old1, $new1)
  $content = $content.Replace('assertTextOnly(message.content);', 'const content = assertTextOnly(message.content);')
  $content = $content.Replace('content: flattenText(message.content)', 'content: flattenText(content)')
  $content = $content.Replace('const toolResults = message.content.filter((block) => block.type === "tool-result");', 'const toolResults = content.filter((block) => block.type === "tool-result");')
  $content = $content.Replace('const text = flattenText(message.content);', 'const text = flattenText(content);')
  $changed = $true
  Write-Host 'Patch 1 (strip images) applied.'
} elseif (-not $content.Contains('return blocks.flatMap((block) => {')) {
  Write-Host 'Patch 1: unexpected adapter layout; skipping (manual check needed).'
} else {
  Write-Host 'Patch 1 (strip images) already applied.'
}

# --- Patch 2: deepseek declares image input ---
if ($content.Contains('inputModalities: ["text"]')) {
  $content = $content.Replace('inputModalities: ["text"]', 'inputModalities: ["text", "image"]')
  $changed = $true
  Write-Host 'Patch 2 (inputModalities) applied.'
} else {
  Write-Host 'Patch 2 (inputModalities) already applied.'
}

# --- Patch 3: local-vision bridge functions (inserted before the assistant serializer) ---
if (-not $content.Contains('dsh.localVision.bridge')) {
  $anchor = '/** Serialize one assistant message'
  $index = $content.IndexOf($anchor)
  if ($index -lt 0) { Write-Host 'Patch 3: anchor not found; skipping.' }
  else {
    $bridgeBlock = @'
/** Read the optional local-vision bridge registered by a plugin on this process. */
function localVisionBridge() {
	return globalThis[Symbol.for("dsh.localVision.bridge")];
}
/**
* Replace image blocks with recognition text (via the optional local-vision
* bridge) before serialization, so the wire stays text-only while the session
* keeps its thumbnails. Falls back to stripping when no bridge is registered.
*/
async function prepareImages(messages, signal) {
	if (!messages.some((message) => contentHasImage(message.content))) return messages;
	const bridge = localVisionBridge();
	if (bridge === void 0) return messages;
	const prepared = [];
	for (const message of messages) {
		if (!contentHasImage(message.content)) {
			prepared.push(message);
			continue;
		}
		const userText = message.content.filter((block) => block.type === "text").map((block) => block.text).join("\n");
		prepared.push({ ...message, content: await replaceImageBlocks(message.content, userText, signal) });
	}
	return prepared;
}
async function replaceImageBlocks(blocks, userText, signal) {
	const bridge = localVisionBridge();
	const replaced = [];
	for (const block of blocks) {
		if (block.type === "image") {
			try {
				const text = await bridge(block.attachment, userText, signal);
				replaced.push({ type: "text", text: `[用户上传的图片（本地识图结果）]\n${text}` });
			} catch (error) {
				replaced.push({ type: "text", text: `[用户上传了一张图片，但本地识图失败：${error?.message ?? String(error)}]` });
			}
			continue;
		}
		if (block.type === "tool-result" && contentHasImage(block.content)) {
			replaced.push({ ...block, content: await replaceImageBlocks(block.content, userText, signal) });
			continue;
		}
		replaced.push(block);
	}
	return replaced;
}
/**
'@
    $content = $content.Substring(0, $index) + $bridgeBlock + $content.Substring($index + '/**'.Length)
    $changed = $true
    Write-Host 'Patch 3 (vision bridge functions) applied.'
  }
} else {
  Write-Host 'Patch 3 (vision bridge functions) already applied.'
}

# --- Patch 4: request() resolves images before serialization ---
if (-not $content.Contains('await prepareImages(options.messages, signal)')) {
  $old4 = "const body = serializeRequest(options, connection.defaults);"
  $new4 = "const messages = await prepareImages(options.messages, signal);`n`t`tconst body = serializeRequest({ ...options, messages }, connection.defaults);"
  if ($content.Contains($old4)) {
    $content = $content.Replace($old4, $new4)
    $changed = $true
    Write-Host 'Patch 4 (request-time image resolution) applied.'
  } else {
    Write-Host 'Patch 4: call site not found; skipping (manual check needed).'
  }
} else {
  Write-Host 'Patch 4 (request-time image resolution) already applied.'
}

if ($changed) {
  [System.IO.File]::WriteAllText($target, $content)
  Write-Host 'Patches written. Restart the harness to take effect.'
} else {
  Write-Host 'No changes needed.'
}
