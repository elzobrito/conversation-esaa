#requires -Version 7.0
<#
.SYNOPSIS
    Public v1.1 CLI for Conversation ESAA.
#>
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [string]$Workspace,
    [string]$Agent,
    [string]$GrokSessionId,
    [string]$CodexSessionPath,
    [string]$ClaudeSessionPath,
    [ValidateSet('normal', 'compact')]
    [string]$Mode = 'normal',
    [switch]$Trust,
    [switch]$Watcher,
    [int]$Last = 0,
    [string]$Before,
    [string]$Around,
    [int]$Window = 1,
    [string]$Topic,
    [switch]$Json,
    [string]$Rationale,
    [string]$Decision,
    [string]$SourceEvent,
    [string]$TaskId,
    [string]$Status,
    [string]$NextStep,
    [string]$Evidence,
    [string]$Title,
    [Alias('topic-id')]
    [string]$TopicId,
    [Alias('EventId', 'Events')]
    [string[]]$TopicEventId,
    [string]$TopicTitle,
    [Alias('Summary')]
    [string]$TopicSummary,
    [parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binDir = $PSScriptRoot
$convCli = Join-Path $binDir 'conversation-esaa.ps1'
$convSync = Join-Path $binDir 'conv-sync.ps1'
$convBootstrap = Join-Path $binDir 'conv-bootstrap.ps1'
$codexWatch = Join-Path $binDir 'codex-watch.ps1'

function Resolve-WorkspacePath {
    if ($Workspace) { return (Resolve-Path -LiteralPath $Workspace).Path }
    if ($env:GROK_WORKSPACE_ROOT) { return $env:GROK_WORKSPACE_ROOT }
    $parent = Split-Path -Parent (Split-Path -Parent $binDir)
    return (Resolve-Path -LiteralPath $parent).Path
}

function Invoke-ConvSyncCli {
    param(
        [string]$SyncCommand,
        [string[]]$Extra = @()
    )
    $ws = Resolve-WorkspacePath
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $convSync,
        $SyncCommand, '-WorkspaceRoot', $ws
    ) + $Extra
    & pwsh @args
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Show-Help {
    @'
Conversation ESAA v1.1

Usage:
  conversation-esaa init --workspace <path>
  conversation-esaa enable-hooks --agent <grok|claude|codex> --workspace <path> [--trust] [--watcher]
  conversation-esaa sync --agent <grok|claude|codex> --workspace <path>
  conversation-esaa project --workspace <path>
  conversation-esaa verify --workspace <path>
  conversation-esaa context --workspace <path> [--agent <id>] [--last N] [--before <event_id>] [--around <event_id>] [--window N] [--topic <text>] [--topic-id TOP-001] [--json]
  conversation-esaa decide "<text>" --workspace <path> [--rationale <text>] [--agent <id>] [--source <event_id>]
  conversation-esaa task create "<title>" --workspace <path>
  conversation-esaa task update <task_id> --workspace <path> [--status <status>] [--next-step <text>]
  conversation-esaa task close <task_id> --workspace <path> [--evidence <text>]
  conversation-esaa topics create "<title>" --workspace <path> [--summary "..."]
  conversation-esaa topics list --workspace <path>
  conversation-esaa topics show TOP-001 --workspace <path>
  conversation-esaa context --topic-id TOP-001 --workspace <path>
'@ | Write-Output
}

$sub = if ($Rest -and $Rest.Count -ge 1) { $Rest[0] } else { $null }

function Get-RestOptionValues {
    param([string[]]$Names)
    $values = @()
    if (-not $Rest) { return $values }
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        if ($Rest[$i] -in $Names -and ($i + 1) -lt $Rest.Count) {
            $values += $Rest[$i + 1]
            $i++
        }
    }
    return $values
}

switch ($Command) {
    'help' { Show-Help }
    'init' {
        $ws = Resolve-WorkspacePath
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $convBootstrap -WorkspaceRoot $ws
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    'sync' {
        if (-not $Agent) { throw 'sync requires --agent grok|claude|codex' }
        $map = @{ grok = 'sync-grok'; codex = 'sync-codex'; claude = 'sync-claude' }
        if ($Agent -notin $map.Keys) { throw "Unknown agent: $Agent" }
        $extra = @()
        if ($Mode -eq 'compact') { $extra += '-Mode', 'compact' }
        if ($GrokSessionId) { $extra += '-GrokSessionId', $GrokSessionId }
        if ($CodexSessionPath) { $extra += '-CodexSessionPath', $CodexSessionPath }
        if ($ClaudeSessionPath) { $extra += '-ClaudeSessionPath', $ClaudeSessionPath }
        Invoke-ConvSyncCli -SyncCommand $map[$Agent] -Extra $extra
    }
    'project' { Invoke-ConvSyncCli -SyncCommand 'project' }
    'verify' { Invoke-ConvSyncCli -SyncCommand 'verify' }
    'enable-hooks' {
        if (-not $Agent) { throw 'enable-hooks requires --agent grok|claude|codex' }
        $ws = Resolve-WorkspacePath
        $grokDir = Join-Path $ws '.grok\hooks'
        $claudeDir = Join-Path $ws '.claude'
        New-Item -ItemType Directory -Force -Path $grokDir, $claudeDir | Out-Null
        $cmdGrok = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$convCli`" sync --agent grok --workspace `"$ws`""
        $cmdGrokCompact = "$cmdGrok --Mode compact"
        $cmdClaude = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$convCli`" sync --agent claude --workspace `"$ws`""
        $cmdClaudeCompact = "$cmdClaude --Mode compact"
        if ($Agent -eq 'grok') {
            $grokCfg = [ordered]@{
                hooks = [ordered]@{
                    UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = $cmdGrok; timeout = 15 }) })
                    Stop             = @(@{ hooks = @(@{ type = 'command'; command = $cmdGrok; timeout = 20 }) })
                    PreCompact       = @(@{ hooks = @(@{ type = 'command'; command = $cmdGrokCompact; timeout = 25 }) })
                }
            }
            [System.IO.File]::WriteAllText(
                (Join-Path $grokDir 'conversation-esaa.json'),
                (($grokCfg | ConvertTo-Json -Depth 8) + "`n"),
                [System.Text.UTF8Encoding]::new($false)
            )
            Write-Output 'enable-hooks: wrote .grok/hooks/conversation-esaa.json'
        }
        if ($Agent -eq 'claude') {
            $claudeCfg = [ordered]@{
                hooks = [ordered]@{
                    UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = $cmdClaude; timeout = 20 }) })
                    Stop             = @(@{ hooks = @(@{ type = 'command'; command = $cmdClaude; timeout = 30 }) })
                    PreCompact       = @(@{ hooks = @(@{ type = 'command'; command = $cmdClaudeCompact; timeout = 30 }) })
                }
            }
            [System.IO.File]::WriteAllText(
                (Join-Path $claudeDir 'settings.json'),
                (($claudeCfg | ConvertTo-Json -Depth 8) + "`n"),
                [System.Text.UTF8Encoding]::new($false)
            )
            Write-Output 'enable-hooks: wrote .claude/settings.json'
        }
        if ($Agent -eq 'grok' -and $Trust) {
            $grokHome = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $HOME '.grok' }
            $trusted = Join-Path $grokHome 'trusted-hook-projects'
            try {
                New-Item -ItemType Directory -Force -Path $grokHome | Out-Null
                $lines = @()
                if (Test-Path -LiteralPath $trusted) {
                    $lines = @([System.IO.File]::ReadAllLines($trusted))
                }
                if ($lines -notcontains $ws) {
                    $lines += $ws
                    [System.IO.File]::WriteAllLines($trusted, $lines, [System.Text.UTF8Encoding]::new($false))
                    Write-Output "enable-hooks: added trusted project $ws"
                } else {
                    Write-Output "enable-hooks: trusted project already registered"
                }
            } catch {
                Write-Output "enable-hooks: trusted project not updated ($($_.Exception.Message))"
            }
        }
        if ($Agent -eq 'claude') {
            Write-Output 'enable-hooks: claude settings written; approval_required until Claude Code approves project hooks'
        }
        if ($Agent -eq 'codex') {
            if ($Watcher) {
                Write-Output "enable-hooks: start watcher: pwsh -File `"$codexWatch`" -WorkspaceRoot `"$ws`""
            } else {
                Write-Output 'enable-hooks: codex has no native hooks; use --watcher or run codex-watch.ps1 manually'
            }
        }
        Invoke-ConvSyncCli -SyncCommand 'verify'
    }
    'context' {
        $extra = @()
        if (-not $TopicId) {
            $restTopicIds = @(Get-RestOptionValues @('--topic-id', '-topic-id'))
            if ($restTopicIds.Count -gt 0) { $TopicId = $restTopicIds[0] }
        }
        if ($Agent) { $extra += '-ContextAgent', $Agent }
        if ($Last -gt 0) { $extra += '-ContextLast', "$Last" }
        if ($Before) { $extra += '-ContextBefore', $Before }
        if ($TopicId) { $extra += '-ContextTopicId', $TopicId }
        if ($Topic) { $extra += '-ContextTopic', $Topic }
        if ($Around) { $extra += '-ContextAround', $Around }
        if ($Window -gt 0) { $extra += '-ContextWindow', "$Window" }
        if ($Json) { $extra += '-ContextJson' }
        Invoke-ConvSyncCli -SyncCommand 'context' -Extra $extra
    }
    'decide' {
        $text = if ($Decision) { $Decision } elseif ($Rest -and $Rest.Count -ge 1) { $Rest -join ' ' } elseif ($Title) { $Title } else { $null }
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'decide requires decision text (-Decision)' }
        $extra = @('-DecisionText', $text)
        if ($Rationale) { $extra += '-DecisionRationale', $Rationale }
        if ($Agent) { $extra += '-DecisionAgent', $Agent }
        if ($SourceEvent) { $extra += '-DecisionSource', $SourceEvent }
        Invoke-ConvSyncCli -SyncCommand 'decide' -Extra $extra
    }
    'task' {
        if (-not $sub) { throw 'task requires create|update|close' }
        $extra = @('-TaskAction', $sub)
        switch ($sub) {
            'create' {
                $text = if ($Rest.Count -ge 2) { ($Rest[1..($Rest.Count - 1)] -join ' ') } else { $Title }
                if ([string]::IsNullOrWhiteSpace($text)) { throw 'task create requires title' }
                $extra += '-TaskTitle', $text
            }
            'update' {
                if (-not $TaskId -and $Rest.Count -ge 2) { $TaskId = $Rest[1] }
                if (-not $TaskId) { throw 'task update requires task_id' }
                $extra += '-TaskId', $TaskId
                if ($Status) { $extra += '-TaskStatus', $Status }
                if ($NextStep) { $extra += '-TaskNextStep', $NextStep }
            }
            'close' {
                if (-not $TaskId -and $Rest.Count -ge 2) { $TaskId = $Rest[1] }
                if (-not $TaskId) { throw 'task close requires task_id' }
                $extra += '-TaskId', $TaskId
                if ($Evidence) { $extra += '-TaskEvidence', $Evidence }
            }
            default { throw "Unknown task action: $sub" }
        }
        Invoke-ConvSyncCli -SyncCommand 'task' -Extra $extra
    }
    { $_ -in @('topic', 'topics') } {
        if (-not $sub) { throw 'topics requires list|show|create|update|link|close' }
        $extra = @('-TopicAction', $sub)
        switch ($sub) {
            'list' {
                if ($Status) { $extra += '-TopicStatus', $Status }
                if ($Json) { $extra += '-TopicJson' }
            }
            'show' {
                if (-not $TopicId -and $Rest.Count -ge 2) { $TopicId = $Rest[1] }
                if (-not $TopicId) { throw 'topics show requires topic id' }
                $extra += '-TopicId', $TopicId
                if ($Json) { $extra += '-TopicJson' }
            }
            'create' {
                $text = if ($Rest.Count -ge 2) { ($Rest[1..($Rest.Count-1)] -join ' ') } else { $TopicTitle }
                if ([string]::IsNullOrWhiteSpace($text)) { throw 'topics create requires title' }
                $extra += '-TopicTitle', $text
                if ($TopicSummary) { $extra += '-TopicSummary', $TopicSummary }
            }
            'update' {
                if (-not $TopicId -and $Rest.Count -ge 2) { $TopicId = $Rest[1] }
                if (-not $TopicId) { throw 'topics update requires topic id' }
                $extra += '-TopicId', $TopicId
                if ($TopicTitle) { $extra += '-TopicTitle', $TopicTitle }
                if ($TopicSummary) { $extra += '-TopicSummary', $TopicSummary }
            }
            'link' {
                if (-not $TopicId -and $Rest.Count -ge 2) { $TopicId = $Rest[1] }
                if (-not $TopicId) { throw 'topics link requires topic id' }
                $extra += '-TopicId', $TopicId
                if (-not $TopicEventId) {
                    $restEventIds = @(Get-RestOptionValues @('--event-id', '-event-id', '--events', '-events'))
                    if ($restEventIds.Count -gt 0) { $TopicEventId = $restEventIds }
                }
                if ($TopicEventId) { $extra += '-TopicEventIds', ($TopicEventId -join ',') }
            }
            'close' {
                if (-not $TopicId -and $Rest.Count -ge 2) { $TopicId = $Rest[1] }
                if (-not $TopicId) { throw 'topics close requires topic id' }
                $extra += '-TopicId', $TopicId
                if ($Evidence) { $extra += '-TopicEvidence', $Evidence }
            }
            default { throw "Unknown topics action: $sub" }
        }
        Invoke-ConvSyncCli -SyncCommand 'topic' -Extra $extra
    }
    default { throw "Unknown command: $Command" }
}
