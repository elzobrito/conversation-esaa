#requires -Version 7.0
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HookResult {
    param([hashtable]$Result = @{})
    [Console]::Out.WriteLine(($Result | ConvertTo-Json -Compress -Depth 4))
}

function Write-HookLog {
    param([string]$Message)
    try {
        $logPath = Join-Path $WorkspaceRoot '.conversation-esaa\antigravity-hook.log'
        $line = "{0} {1}`n" -f ([DateTimeOffset]::Now.ToString('o')), $Message
        [System.IO.File]::AppendAllText($logPath, $line, [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'hook payload is empty' }
    $payload = $raw | ConvertFrom-Json
    $workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

    $payloadWorkspaces = @($payload.workspacePaths | Where-Object { $_ })
    if ($payloadWorkspaces.Count -gt 0) {
        $matches = @($payloadWorkspaces | Where-Object {
            try { (Resolve-Path -LiteralPath $_).Path -eq $workspace } catch { $false }
        })
        if ($matches.Count -eq 0) {
            Write-HookLog "skip workspace_mismatch conversationId=$($payload.conversationId)"
            Write-HookResult
            exit 0
        }
    }

    $conversationId = [string]$payload.conversationId
    $transcript = [string]$payload.transcriptPath
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) {
        if (-not $conversationId) { throw 'payload lacks conversationId and readable transcriptPath' }
        $transcript = Join-Path $HOME ".gemini\antigravity-cli\brain\$conversationId\.system_generated\logs\transcript.jsonl"
    }
    if (-not (Test-Path -LiteralPath $transcript)) {
        throw "transcript not found: $transcript"
    }

    $cli = Join-Path $workspace '.conversation-esaa\bin\conversation-esaa.ps1'
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
        'sync', '--agent', 'antigravity', '--workspace', $workspace,
        '-AntigravityTranscriptPath', $transcript
    )
    if ($conversationId) { $args += '-AntigravityConversationId', $conversationId }
    $syncOutput = (& pwsh @args 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "sync exit=$LASTEXITCODE output=$syncOutput"
    }
    Write-HookLog "success conversationId=$conversationId transcript=$transcript output=$syncOutput"
} catch {
    Write-HookLog "fail_open error=$($_.Exception.Message)"
}

Write-HookResult
exit 0
