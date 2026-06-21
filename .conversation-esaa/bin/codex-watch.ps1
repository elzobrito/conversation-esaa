#requires -Version 7.0
param(
    [string]$WorkspaceRoot,
    [int]$PollSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-WorkspaceRoot {
    if ($WorkspaceRoot) { return (Resolve-Path -LiteralPath $WorkspaceRoot).Path }
    $scriptDir = Split-Path -Parent $PSScriptRoot
    return (Resolve-Path -LiteralPath (Split-Path -Parent $scriptDir)).Path
}

function Find-LatestCodexRollout {
    param([string]$Root)
    $base = Join-Path $HOME '.codex\sessions'
    if (-not (Test-Path -LiteralPath $base)) { return $null }

    $preferred = $null
    $preferredTime = [datetime]::MinValue
    $fallback = $null
    $fallbackTime = [datetime]::MinValue

    Get-ChildItem -Path $base -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            $matchesWorkspace = $false
            try {
                $head = @(Get-Content -LiteralPath $_.FullName -TotalCount 8 -Encoding UTF8)
                if (($head -join "`n") -match [regex]::Escape($Root)) {
                    $matchesWorkspace = $true
                }
            } catch {
                $matchesWorkspace = $false
            }

            if ($matchesWorkspace -and $_.LastWriteTime -gt $preferredTime) {
                $preferred = $_.FullName
                $preferredTime = $_.LastWriteTime
            }
            if ($_.LastWriteTime -gt $fallbackTime) {
                $fallback = $_.FullName
                $fallbackTime = $_.LastWriteTime
            }
        }

    if ($preferred) { return $preferred }
    return $fallback
}

$root = Resolve-WorkspaceRoot
$syncScript = Join-Path $root '.conversation-esaa\bin\conv-sync.ps1'
$logPath = Join-Path $root '.conversation-esaa\codex-watch.log'

if (-not (Test-Path -LiteralPath $syncScript)) {
    throw "conv-sync.ps1 not found at $syncScript"
}

$lastPath = $null
$lastWrite = [datetime]::MinValue
$lastLength = -1L

"$(Get-Date -Format o) codex-watch started workspace=$root poll=${PollSeconds}s" |
    Out-File -LiteralPath $logPath -Encoding utf8 -Append

while ($true) {
    try {
        $rollout = Find-LatestCodexRollout -Root $root
        if ($rollout -and (Test-Path -LiteralPath $rollout)) {
            $item = Get-Item -LiteralPath $rollout
            $changed = ($rollout -ne $lastPath) -or ($item.LastWriteTime -ne $lastWrite) -or ($item.Length -ne $lastLength)
            if ($changed) {
                $lastPath = $rollout
                $lastWrite = $item.LastWriteTime
                $lastLength = $item.Length

                & pwsh -NoProfile -ExecutionPolicy Bypass -File $syncScript sync-codex -WorkspaceRoot $root |
                    Out-File -LiteralPath $logPath -Encoding utf8 -Append
            }
        }
    } catch {
        "$(Get-Date -Format o) ERROR $($_.Exception.Message)" |
            Out-File -LiteralPath $logPath -Encoding utf8 -Append
    }

    Start-Sleep -Seconds $PollSeconds
}
