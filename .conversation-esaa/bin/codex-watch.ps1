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
        $selection = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $syncScript find-codex-rollout -WorkspaceRoot $root)
        if ($LASTEXITCODE -ne 0) { throw "rollout selection failed ($LASTEXITCODE)" }
        $rollout = if ($selection.Count -gt 0) { [string]$selection[-1] } else { $null }
        if ($rollout -and (Test-Path -LiteralPath $rollout)) {
            $item = Get-Item -LiteralPath $rollout
            $changed = ($rollout -ne $lastPath) -or ($item.LastWriteTime -ne $lastWrite) -or ($item.Length -ne $lastLength)
            if ($changed) {
                & pwsh -NoProfile -ExecutionPolicy Bypass -File $syncScript sync-codex -WorkspaceRoot $root -CodexSessionPath $rollout |
                    Out-File -LiteralPath $logPath -Encoding utf8 -Append
                if ($LASTEXITCODE -ne 0) { throw "sync failed ($LASTEXITCODE)" }
                $lastPath = $rollout
                $lastWrite = $item.LastWriteTime
                $lastLength = $item.Length
            }
        }
    } catch {
        "$(Get-Date -Format o) ERROR $($_.Exception.Message)" |
            Out-File -LiteralPath $logPath -Encoding utf8 -Append
    }

    Start-Sleep -Seconds $PollSeconds
}
