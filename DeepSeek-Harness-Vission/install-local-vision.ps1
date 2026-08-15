# install-local-vision.ps1 - one-click installer for the local-vision skill (local image recognition via Ollama)
# Usage:
#   Right-click "Run with PowerShell", or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-local-vision.ps1
# Optional: -ProfileName <name>  (default: web, i.e. ~/.dsh/profiles/web)
# Optional: -DshHome <path>      (default: $env:DSH_HOME or ~/.dsh)
param(
  [string]$ProfileName = 'web',
  [string]$DshHome = ''
)
$ErrorActionPreference = 'Stop'

if (-not $DshHome) {
  $DshHome = $env:DSH_HOME
  if (-not $DshHome) { $DshHome = Join-Path $HOME '.dsh' }
}
$profileDir = Join-Path $DshHome (Join-Path 'profiles' $ProfileName)
$pluginDir = Join-Path $profileDir 'plugins'

Write-Host "== 1/4 install plugin files =="
New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'plugins\local-vision.mjs') (Join-Path $pluginDir 'local-vision.mjs')
Copy-Item -Force (Join-Path $PSScriptRoot 'plugins\reapply-dsh-patches.ps1') (Join-Path $pluginDir 'reapply-dsh-patches.ps1')
Write-Host "plugin -> $pluginDir\local-vision.mjs"

Write-Host "== 2/4 register plugin in the profile patch layer =="
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
$patchFile = Join-Path $profileDir 'cordis.patch.yml'
if (-not (Test-Path -LiteralPath $patchFile)) {
  Set-Content -LiteralPath $patchFile -Value "# dsh profile patch layer" -Encoding UTF8
}
$patch = Get-Content -LiteralPath $patchFile -Raw
if ($patch -match 'local-vision') {
  Write-Host 'entry already present; skipped.'
} elseif ($patch -match '\[\s*\]') {
  # default template contains an empty flow array -> replace it with the entry list
  $entry = @'
- insert:
    - id: local-vision
      name: ./plugins/local-vision.mjs
      config:
        baseUrl: http://localhost:11434
        model: qwen3-vl:8b
'@
  $newPatch = [regex]::Replace($patch, '\[\s*\]', $entry)
  Set-Content -LiteralPath $patchFile -Value $newPatch -Encoding UTF8
  Write-Host "entry written to $patchFile"
} else {
  # block-sequence file -> append another top-level item
  Add-Content -LiteralPath $patchFile -Value @'

- insert:
    - id: local-vision
      name: ./plugins/local-vision.mjs
      config:
        baseUrl: http://localhost:11434
        model: qwen3-vl:8b
'@ -Encoding UTF8
  Write-Host "entry appended to $patchFile"
}

Write-Host "== 3/4 install the skill =="
$skillRoot = Join-Path $DshHome 'skills'
New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
$skillSrc = Join-Path $PSScriptRoot 'skills\local-vision'
Copy-Item -Recurse -Force $skillSrc (Join-Path $skillRoot 'local-vision')
Write-Host "skill -> $skillRoot\local-vision"

Write-Host "== 4/4 apply the dsh-llm-deepseek adapter patches =="
& (Join-Path $pluginDir 'reapply-dsh-patches.ps1')

Write-Host ''
Write-Host '===================================================================='
Write-Host 'Installation finished. Next steps:'
Write-Host '  1) Make sure Ollama is installed and running, and the model is pulled:'
Write-Host '       ollama pull qwen3-vl:8b'
Write-Host '  2) Restart the harness (stop the process on port 3080, then run your'
Write-Host '     launcher again, e.g. "dsh web" or your start script).'
Write-Host '  3) Open a NEW session, upload an image and ask - recognition runs in'
Write-Host '     the background; the chat only shows your question + thumbnail + answer.'
Write-Host '===================================================================='
