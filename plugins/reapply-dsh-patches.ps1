# reapply-dsh-patches.ps1 - idempotently re-apply the dsh-llm-deepseek local-vision patches.
# Supports both the old multi-package layout (0.1.0-rc.x, package under npm-cache) and the
# new bundled-profile layout (0.1.1-rc.x, package under ~/.dsh/profiles/*/node_modules).
# Patches are reverted whenever the dsh package is upgraded - re-run this script (or the
# installer) after every upgrade.
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
  # old layout: npm-cache npx installs
  $npxRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
  if (Test-Path $npxRoot) {
    $candidates += Get-ChildItem $npxRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh-llm-deepseek\lib\index.js' } |
      Where-Object { Test-Path -LiteralPath $_ }
  }
  # new layout: profile installs under the dsh home
  $dshHome = $env:DSH_HOME; if (-not $dshHome) { $dshHome = Join-Path $HOME '.dsh' }
  $profilesRoot = Join-Path $dshHome 'profiles'
  if (Test-Path $profilesRoot) {
    # profiles-level node_modules (new layout: ~/.dsh/profiles/node_modules/...)
    $candidates += Join-Path $profilesRoot 'node_modules\@deepseek-ai\dsh-llm-deepseek\lib\index.js'
    # per-profile node_modules (fallback)
    $candidates += Get-ChildItem $profilesRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh-llm-deepseek\lib\index.js' } |
      Where-Object { Test-Path -LiteralPath $_ }
  }
  # global npm root (e.g. D:\develop\NodeJs\node_modules)
  $globalRoot = & npm root -g 2>$null
  if ($globalRoot -and (Test-Path $globalRoot)) {
    $g = Join-Path $globalRoot '@deepseek-ai\dsh-llm-deepseek\lib\index.js'
    if (Test-Path -LiteralPath $g) { $candidates += $g }
  }
}
$candidates = @($candidates | Select-Object -Unique)

if ($candidates.Count -eq 0) { Write-Error 'dsh-llm-deepseek/lib/index.js not found. Install dsh first, then re-run.' }

foreach ($target in $candidates) {
  Write-Host "Target: $target"
  $content = [System.IO.File]::ReadAllText($target)
  $changed = $false

  if ($content.Contains('serializeMessagesWithImages')) {
    # ---------- NEW layout (0.1.1-rc.x) ----------
    Write-Host 'Layout: new (0.1.1-rc.x).'
    if (-not $content.Contains('dsh.localVision.bridge')) {
      $anchor = '/** Resolve one durable image into its transient DeepSeek data-URL part. */'
      $index = $content.IndexOf($anchor)
      if ($index -lt 0) { Write-Host '  new patch 1: anchor not found; skipping.' }
      else {
        $bridgeBlock = @'
/** Read the optional local-vision bridge registered by a plugin on this process. */
function localVisionBridge() {
	return globalThis[Symbol.for("dsh.localVision.bridge")];
}
/**
* Replace image blocks with recognition text (via the optional local-vision
* bridge) before serialization, so a text-only model still "sees" uploaded
* images while the session keeps its thumbnails. Returns the same array when
* no bridge is registered or no images are present.
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
        Write-Host '  new patch 1 (vision bridge functions) applied.'
      }
    } else {
      Write-Host '  new patch 1 (vision bridge functions) already applied.'
    }

    if (-not $content.Contains('await prepareImages(options.messages, options.signal)')) {
      $oldH = "`t`t`tconst hasImages = options.messages.some((message) => contentHasImage(message.content));"
      $newH = "`t`t`tconst messages = await prepareImages(options.messages, options.signal);`n`t`t`tconst preparedOptions = messages === options.messages ? options : { ...options, messages };`n`t`t`tconst hasImages = preparedOptions.messages.some((message) => contentHasImage(message.content));"
      $ok1 = $false; $ok2 = $false
      if ($content.Contains($oldH)) { $content = $content.Replace($oldH, $newH); $ok1 = $true }
      if ($content.Contains('this.request(options, watchdog.signal, connection, apiKey, userId, attachments,')) {
        $content = $content.Replace('this.request(options, watchdog.signal, connection, apiKey, userId, attachments,', 'this.request(preparedOptions, watchdog.signal, connection, apiKey, userId, attachments,')
        $ok2 = $true
      }
      if ($ok1 -and $ok2) { $changed = $true; Write-Host '  new patch 2 (stream-time image resolution) applied.' }
      else { Write-Host '  new patch 2: call site not found; skipping (manual check needed).' }
    } else {
      Write-Host '  new patch 2 (stream-time image resolution) already applied.'
    }
  } elseif ($content.Contains('assertTextOnly')) {
    # ---------- OLD layout (0.1.0-rc.x) ----------
    Write-Host 'Layout: old (0.1.0-rc.x).'
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
      Write-Host '  old patch 1 (strip images) applied.'
    } else { Write-Host '  old patch 1 (strip images) already applied.' }
    if ($content.Contains('inputModalities: ["text"]')) {
      $content = $content.Replace('inputModalities: ["text"]', 'inputModalities: ["text", "image"]')
      $changed = $true; Write-Host '  old patch 2 (inputModalities) applied.'
    } else { Write-Host '  old patch 2 (inputModalities) already applied.' }
    if (-not $content.Contains('dsh.localVision.bridge')) {
      $anchor = '/** Serialize one assistant message'
      $index = $content.IndexOf($anchor)
      if ($index -lt 0) { Write-Host '  old patch 3: anchor not found; skipping.' }
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
        $changed = $true; Write-Host '  old patch 3 (vision bridge functions) applied.'
      }
    } else { Write-Host '  old patch 3 (vision bridge functions) already applied.' }
    if (-not $content.Contains('await prepareImages(options.messages, signal)')) {
      $old4 = "const body = serializeRequest(options, connection.defaults);"
      $new4 = "const messages = await prepareImages(options.messages, signal);`n`t`tconst body = serializeRequest({ ...options, messages }, connection.defaults);"
      if ($content.Contains($old4)) { $content = $content.Replace($old4, $new4); $changed = $true; Write-Host '  old patch 4 (request-time image resolution) applied.' }
      else { Write-Host '  old patch 4: call site not found; skipping (manual check needed).' }
    } else { Write-Host '  old patch 4 (request-time image resolution) already applied.' }
  } else {
    Write-Host 'Layout: unrecognized; skipping (manual check needed).'
  }

  if ($changed) {
    [System.IO.File]::WriteAllText($target, $content)
    Write-Host 'Patches written. Restart the harness to take effect.'
  } else {
    Write-Host 'No changes needed.'
  }
}
