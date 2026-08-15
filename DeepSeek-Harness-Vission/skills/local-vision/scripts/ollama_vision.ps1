# ollama_vision.ps1 - recognize one image with the local Ollama vision model.
# Usage:
#   powershell -File ollama_vision.ps1 -ImagePath "C:\path\to\image" -Prompt "What text is in this image?"
# Params:
#   ImagePath  required. Image file path (PNG/JPEG/WebP/GIF; no extension needed, Ollama sniffs the format).
#   Prompt     required. Recognition / question prompt.
#   Model      optional. Default qwen3-vl:8b
#   BaseUrl    optional. Default http://localhost:11434
# Output: recognition text on stdout.
param(
  [Parameter(Mandatory = $true)][string]$ImagePath,
  [Parameter(Mandatory = $true)][string]$Prompt,
  [string]$Model = 'qwen3-vl:8b',
  [string]$BaseUrl = 'http://localhost:11434'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ImagePath)) {
  Write-Error "ImagePath not found: $ImagePath"
}

$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ImagePath).Path)
$b64 = [Convert]::ToBase64String($bytes)

$body = @{
  model    = $Model
  messages = @(
    @{
      role    = 'user'
      content = $Prompt
      images  = @($b64)
    }
  )
  stream   = $false
} | ConvertTo-Json -Depth 6 -Compress

$resp = Invoke-RestMethod -Uri "$BaseUrl/api/chat" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300
if ($null -eq $resp -or $null -eq $resp.message -or [string]::IsNullOrWhiteSpace($resp.message.content)) {
  Write-Error 'Ollama returned an empty recognition result.'
}
$resp.message.content
