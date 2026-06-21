#requires -Version 7.0
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('sync-grok', 'sync-codex', 'sync-claude', 'project', 'verify', 'context', 'decide', 'task')]
    [string]$Command,

    [string]$WorkspaceRoot,
    [string]$GrokSessionId,
    [string]$CodexSessionPath,
    [string]$ClaudeSessionPath,
    [ValidateSet('normal', 'compact')]
    [string]$Mode = 'normal',

    [int]$LockTimeoutSeconds = 30,

    [string]$ContextAgent,
    [int]$ContextLast = 0,
    [string]$ContextBefore,
    [string]$ContextAround,
    [int]$ContextWindow = 1,
    [string]$ContextTopic,
    [switch]$ContextJson,

    [string]$DecisionText,
    [string]$DecisionRationale,
    [string]$DecisionAgent = 'codex',
    [string]$DecisionSource,

    [ValidateSet('create', 'update', 'close')]
    [string]$TaskAction,
    [string]$TaskId,
    [string]$TaskTitle,
    [string]$TaskStatus,
    [string]$TaskNextStep,
    [string]$TaskEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PipelineLockPath = $null
$script:PipelineLockOwned = $false

function Get-PipelineLockPath {
    param([string]$WorkspaceRoot)
    Join-Path (Join-Path (Join-Path $WorkspaceRoot '.conversation-esaa') 'run') 'conversation-esaa.lock'
}

function Test-PipelineLockStale {
    param($LockData)
    if (-not $LockData -or -not $LockData.pid) { return $true }
    return -not (Get-Process -Id ([int]$LockData.pid) -ErrorAction SilentlyContinue)
}

function Acquire-PipelineLock {
    param(
        [string]$WorkspaceRoot,
        [string]$CommandName,
        [int]$TimeoutSeconds
    )
    $runDir = Join-Path (Join-Path $WorkspaceRoot '.conversation-esaa') 'run'
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $lockPath = Get-PipelineLockPath $WorkspaceRoot
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([datetime]::UtcNow -lt $deadline) {
        if (-not (Test-Path -LiteralPath $lockPath)) {
            try {
                $lock = [ordered]@{
                    pid = $PID
                    command = $CommandName
                    started_at = (Get-IsoTimestamp)
                    workspace_root = $WorkspaceRoot
                }
                $json = (($lock | ConvertTo-Json -Compress) + "`n")
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $fs = [System.IO.FileStream]::new(
                    $lockPath,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None
                )
                try {
                    $fs.Write($bytes, 0, $bytes.Length)
                } finally {
                    $fs.Close()
                }
                $script:PipelineLockPath = $lockPath
                $script:PipelineLockOwned = $true
                return
            } catch [System.IO.IOException] {
                # Another process created the lock; retry.
            }
        } else {
            try {
                $existing = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (Test-PipelineLockStale $existing) {
                    Write-Warning "removing stale pipeline lock (pid=$($existing.pid))"
                    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                    continue
                }
            } catch {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                continue
            }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Pipeline lock timeout after ${TimeoutSeconds}s: $lockPath"
}

function Release-PipelineLock {
    param([string]$WorkspaceRoot)
    if (-not $script:PipelineLockOwned) { return }
    $lockPath = if ($script:PipelineLockPath) { $script:PipelineLockPath } else { Get-PipelineLockPath $WorkspaceRoot }
    if (Test-Path -LiteralPath $lockPath) {
        try {
            $existing = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$existing.pid -eq $PID) {
                Remove-Item -LiteralPath $lockPath -Force
            }
        } catch {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
    $script:PipelineLockPath = $null
    $script:PipelineLockOwned = $false
}

function Invoke-WithPipelineLock {
    param(
        [string]$WorkspaceRoot,
        [string]$CommandName,
        [int]$TimeoutSeconds,
        [scriptblock]$Body
    )
    try {
        Acquire-PipelineLock -WorkspaceRoot $WorkspaceRoot -CommandName $CommandName -TimeoutSeconds $TimeoutSeconds
        & $Body
    } finally {
        Release-PipelineLock -WorkspaceRoot $WorkspaceRoot
    }
}

function Get-ConvPaths {
    param([string]$Root)
    @{
        Root = $Root
        Esaa = Join-Path $Root '.conversation-esaa'
        Activity = Join-Path $Root '.conversation-esaa\activity.jsonl'
        SyncState = Join-Path $Root '.conversation-esaa\sync-state.json'
        State = Join-Path $Root '.conversation-esaa\state.md'
        Handoff = Join-Path $Root '.conversation-esaa\handoff.md'
        Tasks = Join-Path $Root '.conversation-esaa\tasks.json'
        Decisions = Join-Path $Root '.conversation-esaa\decisions.md'
    }
}

function Resolve-WorkspaceRoot {
    if ($WorkspaceRoot) { return (Resolve-Path -LiteralPath $WorkspaceRoot).Path }
    if ($env:GROK_WORKSPACE_ROOT) { return $env:GROK_WORKSPACE_ROOT }
    $scriptDir = Split-Path -Parent $PSScriptRoot
    return (Resolve-Path -LiteralPath (Split-Path -Parent $scriptDir)).Path
}

function Encode-GrokCwd {
    param([string]$Path)
    $normalized = $Path.TrimEnd('\')
    return [uri]::EscapeDataString($normalized)
}

function Encode-ClaudeCwd {
    param([string]$Path)
    # Claude Code names its project dir by replacing path separators, ':',
    # spaces and dots in the cwd with '-'. e.g. C:\xampp\htdocs\foo -> C--xampp-htdocs-foo
    $normalized = $Path.TrimEnd('\', '/')
    return ($normalized -replace '[:\\/ .]', '-')
}

function Get-IsoTimestamp {
    param([Nullable[datetimeoffset]]$SourceOffset = $null)
    $offset = [TimeSpan]::FromHours(-3)
    $dto = if ($SourceOffset) {
        $SourceOffset.Value.ToOffset($offset)
    } else {
        [DateTimeOffset]::new((Get-Date), $offset)
    }
    return $dto.ToString("yyyy-MM-dd'T'HH:mm:ssK")
}

function Parse-SourceTimestamp {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try {
        return [datetimeoffset]::Parse($Raw)
    } catch {
        return $null
    }
}

function Normalize-Whitespace {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return ([regex]::Replace($Text.Trim(), '\s+', ' '))
}

function Make-Summary {
    param([string]$Text)
    $normalized = Normalize-Whitespace $Text
    if ($normalized.Length -le 200) { return $normalized }
    return $normalized.Substring(0, 200)
}

function Compute-EventId {
    param(
        [string]$Source,
        [string]$SessionId,
        [int]$SourceIndex,
        [string]$Actor,
        [string]$Text
    )
    $payload = "$Source|$SessionId|$SourceIndex|$Actor|$Text"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
}

function Test-ActivityNeedsRepair {
    param([string]$ActivityPath)
    if (-not (Test-Path -LiteralPath $ActivityPath)) { return $false }
    foreach ($line in [System.IO.File]::ReadLines($ActivityPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json
        } catch {
            continue
        }
        if (('source' -in $event.PSObject.Properties.Name) -and $event.source) {
            if ('agent_id' -notin $event.PSObject.Properties.Name) { return $true }
            if ($event.actor -eq 'user' -and ($null -ne $event.agent_id) -and [string]$event.agent_id -eq '') { return $true }
            if (-not (('workspace_root' -in $event.PSObject.Properties.Name) -and $event.workspace_root)) { return $true }
        }
    }
    return $false
}

function Repair-ActivityContract {
    param([string]$ActivityPath)
    if (-not (Test-ActivityNeedsRepair $ActivityPath)) { return }

    $esaaDir = Split-Path -Parent $ActivityPath
    $workspaceRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $esaaDir)).Path

    $lines = [System.IO.File]::ReadAllLines($ActivityPath)
    $fixed = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $fixed.Add($line)
            continue
        }
        try {
            $event = $line | ConvertFrom-Json
        } catch {
            $fixed.Add($line)
            continue
        }

        if (('source' -in $event.PSObject.Properties.Name) -and $event.source) {
            $needsFix = $false
            if ('agent_id' -notin $event.PSObject.Properties.Name) {
                $event | Add-Member -NotePropertyName agent_id -NotePropertyValue $null -Force
                $needsFix = $true
            } elseif ($event.actor -eq 'user' -and ($null -ne $event.agent_id) -and [string]$event.agent_id -eq '') {
                $event.agent_id = $null
                $needsFix = $true
            }
            if (-not (('workspace_root' -in $event.PSObject.Properties.Name) -and $event.workspace_root)) {
                $event | Add-Member -NotePropertyName workspace_root -NotePropertyValue $workspaceRoot -Force
                $needsFix = $true
            }
            if ($needsFix) {
                $fixed.Add(($event | ConvertTo-Json -Compress -Depth 8))
                continue
            }
        }
        $fixed.Add($line)
    }

    $text = ($fixed -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    [System.IO.File]::WriteAllText($ActivityPath, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Output 'repair-activity: normalized agent_id and workspace_root on synced events'
}

function Get-ActivityEventIds {
    param([string]$ActivityPath)
    $ids = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $ActivityPath)) { return @($ids) }
    foreach ($line in [System.IO.File]::ReadLines($ActivityPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json
        } catch {
            continue
        }
        if (($event.PSObject.Properties.Name -contains 'event_id') -and $event.event_id) {
            $ids.Add([string]$event.event_id)
        }
    }
    return @($ids)
}

function Load-SyncState {
    param([string]$Path, [string]$ActivityPath)
    # activity.jsonl is the source of truth for processed event ids (CONV-006).
    $ids = Get-ActivityEventIds $ActivityPath
    return @{
        schema_version = 'conversation-esaa.sync-state.v0.1'
        processed_event_ids = $ids
    }
}

function Save-SyncState {
    param($State, [string]$Path)
    $json = $State | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Append-ActivityEvent {
    param($Event, [string]$Path)
    $line = ($Event | ConvertTo-Json -Compress -Depth 8)
    [System.IO.File]::AppendAllText($Path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Read-JsonlLines {
    param([string]$Path)
    $lines = @()
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.UTF8Encoding]::new($false))
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lines += $line
            }
        }
        $reader.Close()
    } finally {
        $stream.Close()
    }
    return $lines
}

function Extract-UserQueryText {
    param([string]$Text)
    if ($Text -match '(?s)<user_query>\s*(.*?)\s*</user_query>') {
        return $Matches[1].Trim()
    }
    return $null
}

function Should-SkipCodexText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $trim = $Text.Trim()
    if ($trim.StartsWith('<environment_context>')) { return $true }
    if ($trim.StartsWith('<permissions instructions>')) { return $true }
    return $false
}

function Get-GrokTextFromEntry {
    param($Entry)
    switch ($Entry.type) {
        'user' {
            $parts = @()
            foreach ($item in @($Entry.content)) {
                if ($item.type -eq 'text' -and $item.text) {
                    $parts += $item.text
                }
            }
            $raw = ($parts -join "`n").Trim()
            $query = Extract-UserQueryText $raw
            if ($query) { return @{ Actor = 'user'; Text = $query; AgentId = $null } }
            return $null
        }
        'assistant' {
            $text = ''
            if ($Entry.content -is [string]) {
                $text = $Entry.content.Trim()
            }
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return @{ Actor = 'assistant'; Text = $text; AgentId = 'grok' }
        }
    }
    return $null
}

function Get-CodexTextFromEntry {
    param($Entry, [int]$Index)
    if ($Entry.type -ne 'response_item') { return $null }
    $payload = $Entry.payload
    if (-not $payload -or $payload.type -ne 'message') { return $null }
    $role = $payload.role
    if ($role -notin @('user', 'assistant')) { return $null }

    $text = ''
    if ($payload.content) {
        foreach ($item in @($payload.content)) {
            if (-not $item) { continue }
            if ($item.type -eq 'input_text' -and $item.text) { $text = $item.text }
            if ($item.type -eq 'output_text' -and $item.text) { $text = $item.text }
        }
    }
    if (Should-SkipCodexText $text) { return $null }

    $timestamp = $null
    if ($Entry.PSObject.Properties.Name -contains 'timestamp') {
        $timestamp = [string]$Entry.timestamp
    }

    if ($role -eq 'user') {
        return @{ Actor = 'user'; Text = $text.Trim(); AgentId = $null; Timestamp = $timestamp }
    }
    return @{ Actor = 'assistant'; Text = $text.Trim(); AgentId = 'codex'; Timestamp = $timestamp }
}

function Get-ClaudeTextFromEntry {
    param($Entry)
    if ($Entry.type -notin @('user', 'assistant')) { return $null }
    # Skip subagent sidechain turns; keep only the main conversation.
    if (($Entry.PSObject.Properties.Name -contains 'isSidechain') -and $Entry.isSidechain) { return $null }
    $message = $Entry.message
    if (-not $message) { return $null }

    switch ($Entry.type) {
        'user' {
            # Real user prompts carry a string content; array content is tool_result payload.
            if ($message.content -is [string]) {
                $text = $message.content.Trim()
                if ([string]::IsNullOrWhiteSpace($text)) { return $null }
                $timestamp = $null
                if ($Entry.PSObject.Properties.Name -contains 'timestamp') {
                    $timestamp = [string]$Entry.timestamp
                }
                return @{ Actor = 'user'; Text = $text; AgentId = $null; Timestamp = $timestamp }
            }
            return $null
        }
        'assistant' {
            # Assistant content is a block array: keep only visible text, skip
            # thinking (reasoning) and tool_use blocks.
            if ($message.content -is [string]) { return $null }
            $parts = @()
            foreach ($block in @($message.content)) {
                if ($block -and $block.type -eq 'text' -and $block.text) {
                    $parts += $block.text
                }
            }
            $text = ($parts -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            $timestamp = $null
            if ($Entry.PSObject.Properties.Name -contains 'timestamp') {
                $timestamp = [string]$Entry.timestamp
            }
            return @{ Actor = 'assistant'; Text = $text; AgentId = 'claude'; Timestamp = $timestamp }
        }
    }
    return $null
}

function Import-Message {
    param(
        $Paths,
        $SyncState,
        [string]$Source,
        [string]$SessionId,
        [string]$SourcePath,
        [int]$SourceIndex,
        [string]$Actor,
        [string]$Text,
        [string]$AgentId = $null,
        [string]$SourceTimestamp = $null,
        [string]$EventName = 'conversation_turn'
    )

    $eventId = Compute-EventId $Source $SessionId $SourceIndex $Actor $Text
    if ($SyncState.processed_event_ids -contains $eventId) {
        return $false
    }

    $parsedTs = Parse-SourceTimestamp $SourceTimestamp
    $record = [ordered]@{
        event_id = $eventId
        ts = if ($parsedTs) { Get-IsoTimestamp -SourceOffset $parsedTs } else { Get-IsoTimestamp }
        event = $EventName
        actor = $Actor
        agent_id = if ($Actor -eq 'assistant' -and $AgentId) { $AgentId } else { $null }
        source = $Source
        source_session_id = $SessionId
        source_path = $SourcePath
        source_index = $SourceIndex
        workspace_root = $Paths.Root
        summary = Make-Summary $Text
        text = $Text
    }

    Append-ActivityEvent $record $Paths.Activity
    $SyncState.processed_event_ids += $eventId
    return $true
}

function Find-GrokChatHistory {
    param([string]$WorkspaceRoot)
    $grokHome = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $HOME '.grok' }
    $encoded = Encode-GrokCwd $WorkspaceRoot
    $projectSessionsDir = Join-Path (Join-Path $grokHome 'sessions') $encoded
    if (-not (Test-Path -LiteralPath $projectSessionsDir)) { return $null }

    $latest = $null
    $latestTime = [datetime]::MinValue
    Get-ChildItem -Path $projectSessionsDir -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $chatHistory = Join-Path $_.FullName 'chat_history.jsonl'
            if (Test-Path -LiteralPath $chatHistory) {
                $mtime = (Get-Item -LiteralPath $chatHistory).LastWriteTime
                if ($mtime -gt $latestTime) {
                    $latest = @{
                        SessionId = $_.Name
                        ChatHistory = $chatHistory
                    }
                    $latestTime = $mtime
                }
            }
        }
    return $latest
}

function Invoke-SyncGrok {
    param($Paths, $SyncState)

    $sessionId = $GrokSessionId
    if (-not $sessionId) { $sessionId = $env:GROK_SESSION_ID }

    $chatHistory = $null
    if ($sessionId) {
        $grokHome = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $HOME '.grok' }
        $encoded = Encode-GrokCwd $Paths.Root
        $sessionDir = Join-Path (Join-Path (Join-Path $grokHome 'sessions') $encoded) $sessionId
        $candidate = Join-Path $sessionDir 'chat_history.jsonl'
        if (Test-Path -LiteralPath $candidate) {
            $chatHistory = $candidate
        }
    }

    if (-not $chatHistory) {
        $found = Find-GrokChatHistory -WorkspaceRoot $Paths.Root
        if ($found) {
            $sessionId = $found.SessionId
            $chatHistory = $found.ChatHistory
        }
    }

    if (-not $chatHistory -or -not (Test-Path -LiteralPath $chatHistory)) {
        throw 'Grok chat history not found. Pass -GrokSessionId, set GROK_SESSION_ID, or ensure a session exists for this workspace.'
    }

    $imported = 0
    $index = 0
    foreach ($line in (Read-JsonlLines $chatHistory)) {
        if ([string]::IsNullOrWhiteSpace($line)) { $index++; continue }
        $entry = $line | ConvertFrom-Json
        $parsed = Get-GrokTextFromEntry $entry
        if ($parsed) {
            $added = Import-Message `
                -Paths $Paths `
                -SyncState $SyncState `
                -Source 'grok' `
                -SessionId $sessionId `
                -SourcePath $chatHistory `
                -SourceIndex $index `
                -Actor $parsed.Actor `
                -Text $parsed.Text `
                -AgentId $parsed.AgentId `
                -SourceTimestamp $(if ($parsed.ContainsKey('Timestamp')) { $parsed.Timestamp } else { $null }) `
                -EventName $(if ($Mode -eq 'compact') { 'pre_compact_sync' } else { 'conversation_turn' })
            if ($added) { $imported++ }
        }
        $index++
    }

    Write-Output "sync-grok: imported $imported new event(s) from $sessionId"
    return $imported
}

function Find-LatestCodexRollout {
    param([string]$WorkspaceRoot)
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
                $head = @(Get-Content -LiteralPath $_.FullName -TotalCount 5 -Encoding UTF8)
                $joined = ($head -join "`n")
                if ($joined -match [regex]::Escape($WorkspaceRoot)) {
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

function Invoke-SyncCodex {
    param($Paths, $SyncState)

    $rollout = $CodexSessionPath
    if (-not $rollout) {
        $rollout = Find-LatestCodexRollout -WorkspaceRoot $Paths.Root
    }
    if (-not $rollout -or -not (Test-Path -LiteralPath $rollout)) {
        throw 'Codex rollout JSONL not found.'
    }

    $sessionId = 'unknown'
    $first = Get-Content -LiteralPath $rollout -TotalCount 1 -Encoding UTF8
    if ($first) {
        $meta = $first | ConvertFrom-Json
        if ($meta.payload.id) { $sessionId = $meta.payload.id }
    }

    $imported = 0
    $index = 0
    foreach ($line in (Read-JsonlLines $rollout)) {
        if ([string]::IsNullOrWhiteSpace($line)) { $index++; continue }
        $entry = $line | ConvertFrom-Json
        $parsed = Get-CodexTextFromEntry $entry $index
        if ($parsed) {
            $added = Import-Message `
                -Paths $Paths `
                -SyncState $SyncState `
                -Source 'codex' `
                -SessionId $sessionId `
                -SourcePath $rollout `
                -SourceIndex $index `
                -Actor $parsed.Actor `
                -Text $parsed.Text `
                -AgentId $parsed.AgentId `
                -SourceTimestamp $(if ($parsed.ContainsKey('Timestamp')) { $parsed.Timestamp } else { $null })
            if ($added) { $imported++ }
        }
        $index++
    }

    Write-Output "sync-codex: imported $imported new event(s) from $rollout"
    return $imported
}

function Find-ClaudeTranscript {
    param([string]$WorkspaceRoot)
    $claudeHome = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $HOME '.claude' }
    $projectsDir = Join-Path $claudeHome 'projects'
    if (-not (Test-Path -LiteralPath $projectsDir)) { return $null }

    # Primary: deterministic encoded project dir, newest transcript.
    $encoded = Encode-ClaudeCwd $WorkspaceRoot
    $projectDir = Join-Path $projectsDir $encoded
    if (Test-Path -LiteralPath $projectDir) {
        $latest = Get-ChildItem -Path $projectDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { return $latest.FullName }
    }

    # Fallback: scan all transcripts and match the recorded cwd to the workspace.
    $needle = [regex]::Escape($WorkspaceRoot)
    $preferred = $null
    $preferredTime = [datetime]::MinValue
    Get-ChildItem -Path $projectsDir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $head = (@(Get-Content -LiteralPath $_.FullName -TotalCount 5 -Encoding UTF8) -join "`n")
                $head = $head -replace '\\\\', '\'
                if (($head -match $needle) -and ($_.LastWriteTime -gt $preferredTime)) {
                    $preferred = $_.FullName
                    $preferredTime = $_.LastWriteTime
                }
            } catch { }
        }
    return $preferred
}

function Invoke-SyncClaude {
    param($Paths, $SyncState)

    $transcript = $ClaudeSessionPath
    if (-not $transcript) {
        $transcript = Find-ClaudeTranscript -WorkspaceRoot $Paths.Root
    }
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) {
        throw 'Claude Code transcript JSONL not found.'
    }

    $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($transcript)

    $imported = 0
    $index = 0
    foreach ($line in (Read-JsonlLines $transcript)) {
        if ([string]::IsNullOrWhiteSpace($line)) { $index++; continue }
        try { $entry = $line | ConvertFrom-Json } catch { $index++; continue }
        $parsed = Get-ClaudeTextFromEntry $entry
        if ($parsed) {
            $added = Import-Message `
                -Paths $Paths `
                -SyncState $SyncState `
                -Source 'claude' `
                -SessionId $sessionId `
                -SourcePath $transcript `
                -SourceIndex $index `
                -Actor $parsed.Actor `
                -Text $parsed.Text `
                -AgentId $parsed.AgentId `
                -SourceTimestamp $(if ($parsed.ContainsKey('Timestamp')) { $parsed.Timestamp } else { $null }) `
                -EventName $(if ($Mode -eq 'compact') { 'pre_compact_sync' } else { 'conversation_turn' })
            if ($added) { $imported++ }
        }
        $index++
    }

    Write-Output "sync-claude: imported $imported new event(s) from $sessionId"
    return $imported
}

function Read-ActivityEvents {
    param([string]$Path)
    $events = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $events }
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $events += ($line | ConvertFrom-Json)
    }
    return $events
}

function Get-WorkspaceEvents {
    param($Paths)
    $expectedRoot = (Resolve-Path -LiteralPath $Paths.Root).Path
    $events = @(Read-ActivityEvents $Paths.Activity)
    return @($events | Where-Object {
        if (('workspace_root' -in $_.PSObject.Properties.Name) -and $_.workspace_root) {
            try {
                return ((Resolve-Path -LiteralPath $_.workspace_root).Path -eq $expectedRoot)
            } catch {
                return $false
            }
        }
        # Legacy events without workspace_root belong to the lab workspace only.
        return $true
    })
}

function New-CuratedEventId {
    param([string]$Payload)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
}

function Append-CuratedEvent {
    param($Paths, $Record)
    $hasId = ($Record -is [System.Collections.IDictionary] -and $Record.Contains('event_id')) -or
        (('event_id' -in $Record.PSObject.Properties.Name) -and $Record.event_id)
    if (-not $hasId) {
        $payload = "$($Record.event)|$($Paths.Root)|$($Record.ts)|$($Record | ConvertTo-Json -Compress -Depth 6)"
        if ($Record -is [System.Collections.IDictionary]) {
            $Record['event_id'] = New-CuratedEventId $payload
        } else {
            $Record | Add-Member -NotePropertyName event_id -NotePropertyValue (New-CuratedEventId $payload) -Force
        }
    }
    Append-ActivityEvent $Record $Paths.Activity
}

function Get-NextConversationTaskId {
    param([hashtable]$TaskMap)
    $max = 0
    foreach ($id in $TaskMap.Keys) {
        if ($id -match '^CONV-(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ('CONV-{0:D3}' -f ($max + 1))
}

function Get-EventField {
    param($Event, [string]$Name)
    if ($Name -in $Event.PSObject.Properties.Name) { return $Event.$Name }
    return $null
}

function Project-TasksFromEvents {
    param($Events)
    $map = @{}
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Events) {
        switch ($e.event) {
            'task.created' {
                $taskId = Get-EventField $e 'task_id'
                if (-not $taskId) { continue }
                $map[$taskId] = [ordered]@{
                    id = $taskId
                    title = Get-EventField $e 'title'
                    status = if (Get-EventField $e 'status') { Get-EventField $e 'status' } else { 'open' }
                    description = Get-EventField $e 'description'
                    next_step = Get-EventField $e 'next_step'
                    completed_at = $null
                    evidence = $null
                }
                if ($order -notcontains $taskId) { $order.Add($taskId) }
            }
            'task.updated' {
                $taskId = Get-EventField $e 'task_id'
                if (-not $taskId -or -not $map.ContainsKey($taskId)) { continue }
                $status = Get-EventField $e 'status'
                if ($status) { $map[$taskId].status = $status }
                $next = Get-EventField $e 'next_step'
                if ($next) { $map[$taskId].next_step = $next }
                $title = Get-EventField $e 'title'
                if ($title) { $map[$taskId].title = $title }
            }
            'task.closed' {
                $taskId = Get-EventField $e 'task_id'
                if (-not $taskId -or -not $map.ContainsKey($taskId)) { continue }
                $map[$taskId].status = if (Get-EventField $e 'status') { Get-EventField $e 'status' } else { 'completed' }
                $map[$taskId].completed_at = Get-EventField $e 'ts'
                $evidence = Get-EventField $e 'evidence'
                if ($evidence) { $map[$taskId].evidence = $evidence }
            }
        }
    }
    $tasks = @($order | ForEach-Object { $map[$_] })
    return [ordered]@{
        schema_version = 'conversation-esaa.tasks.v0.1'
        tasks = $tasks
    }
}

function Project-DecisionsMarkdown {
    param($Events)
    $decisions = @($Events | Where-Object { $_.event -eq 'decision.recorded' })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Decisions')
    $lines.Add('')
    $lines.Add('> Generated by conversation-esaa project. Do not edit manually.')
    $lines.Add('')
    $lines.Add('## Active Decisions')
    $lines.Add('')
    if ($decisions.Count -eq 0) {
        $lines.Add('_No decision.recorded events yet._')
    } else {
        $i = 1
        foreach ($d in $decisions) {
            $lines.Add("### DEC-$('{0:D4}' -f $i) — $($d.decision)")
            $lines.Add('')
            $lines.Add("- ts: $($d.ts)")
            $lines.Add("- actor: $($d.actor)")
            if ($d.agent_id) { $lines.Add("- agent_id: $($d.agent_id)") }
            if ($d.rationale) { $lines.Add("- rationale: $($d.rationale)") }
            if ($d.related_turns) { $lines.Add("- related_turns: $($d.related_turns -join ', ')") }
            $lines.Add('')
            $i++
        }
    }
    return ($lines -join [Environment]::NewLine).TrimEnd() + "`n"
}

function Get-ContextSearchFields {
    param($Event)
    $fields = @()
    foreach ($name in @('summary', 'text', 'decision', 'rationale', 'title', 'next_step')) {
        if (($name -in $Event.PSObject.Properties.Name) -and $Event.$name) {
            $fields += [string]$Event.$name
        }
    }
    return $fields
}

function Get-ContextEventId {
    param($Event)
    if (('event_id' -in $Event.PSObject.Properties.Name) -and $Event.event_id) {
        return [string]$Event.event_id
    }
    return ''
}

function Get-ContextEventValue {
    param($Event, [string]$Name, [string]$Default = '')
    if (($Name -in $Event.PSObject.Properties.Name) -and $Event.$Name) {
        return [string]$Event.$Name
    }
    return $Default
}

function Invoke-Context {
    param($Paths)
    $events = @(Get-WorkspaceEvents $Paths)
    if ($ContextAgent) {
        $events = @($events | Where-Object {
            (('agent_id' -in $_.PSObject.Properties.Name) -and ($_.agent_id -eq $ContextAgent)) -or
            (('source' -in $_.PSObject.Properties.Name) -and ($_.source -eq $ContextAgent))
        })
    }
    if ($ContextTopic) {
        $needle = $ContextTopic.ToLowerInvariant()
        $events = @($events | ForEach-Object {
            $hay = (Get-ContextSearchFields $_) -join ' ' | ForEach-Object { $_.ToLowerInvariant() }
            $count = 0
            $idx = 0
            while (($idx = $hay.IndexOf($needle, $idx)) -ge 0) {
                $count++
                $idx += $needle.Length
            }
            [pscustomobject]@{ Event = $_; MatchCount = $count }
        } | Where-Object { $_.MatchCount -gt 0 } |
            Sort-Object -Property @{ Expression = 'MatchCount'; Descending = $true }, @{ Expression = { $_.Event.ts }; Descending = $true }, @{ Expression = { Get-ContextEventId $_.Event } } |
            ForEach-Object { $_.Event })
    }
    if ($ContextBefore) {
        $idx = [array]::IndexOf(@($events | ForEach-Object { Get-ContextEventId $_ }), $ContextBefore)
        if ($idx -lt 0) { throw "Context target event not found: $ContextBefore" }
        $take = if ($ContextLast -gt 0) { $ContextLast } else { 2 }
        $start = [Math]::Max(0, $idx - $take)
        $events = @($events[$start..($idx - 1)])
    } elseif ($ContextAround) {
        $idx = [array]::IndexOf(@($events | ForEach-Object { Get-ContextEventId $_ }), $ContextAround)
        if ($idx -lt 0) { throw "Context target event not found: $ContextAround" }
        $start = [Math]::Max(0, $idx - $ContextWindow)
        $end = [Math]::Min($events.Count - 1, $idx + $ContextWindow)
        $events = @($events[$start..$end])
    } elseif ($ContextLast -gt 0) {
        $events = @($events | Select-Object -Last $ContextLast)
    }
    if ($ContextJson) {
        $events | ConvertTo-Json -Depth 8
        return
    }
    $filter = @()
    if ($ContextAgent) { $filter += "agent=$ContextAgent" }
    if ($ContextTopic) { $filter += "topic=$ContextTopic" }
    if ($ContextBefore) { $filter += "before=$ContextBefore" }
    if ($ContextAround) { $filter += "around=$ContextAround" }
    if ($ContextLast -gt 0 -and -not $ContextBefore) { $filter += "last=$ContextLast" }
    $filterText = if ($filter.Count -gt 0) { $filter -join ', ' } else { 'none' }
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('# Context Window')
    $out.Add('')
    $out.Add("workspace: $($Paths.Root)")
    $out.Add("filter: $filterText")
    $out.Add("count: $($events.Count)")
    $out.Add('')
    $out.Add('## Events')
    $out.Add('')
    foreach ($e in $events) {
        $actor = Get-ContextEventValue $e 'actor' 'unknown'
        $agent = Get-ContextEventValue $e 'agent_id'
        $who = if ($agent) { "$actor/$agent" } else { $actor }
        $eventId = Get-ContextEventId $e
        $eid = if ($eventId) { $eventId } else { '(legacy)' }
        $ts = Get-ContextEventValue $e 'ts' '(no-ts)'
        $summary = Get-ContextEventValue $e 'summary'
        $out.Add("- [$ts] $who $eid")
        if ($summary) { $out.Add("  $summary") }
        $out.Add('')
    }
    Write-Output ($out -join [Environment]::NewLine).TrimEnd()
}

function Invoke-Decide {
    param($Paths)
    if ([string]::IsNullOrWhiteSpace($DecisionText)) { throw 'decide requires decision text' }
    $related = @()
    if ($DecisionSource) { $related = @($DecisionSource) }
    $record = [ordered]@{
        ts = Get-IsoTimestamp
        event = 'decision.recorded'
        actor = 'assistant'
        agent_id = $DecisionAgent
        workspace_root = $Paths.Root
        decision = $DecisionText
        rationale = if ($DecisionRationale) { $DecisionRationale } else { '' }
        related_turns = $related
        summary = Make-Summary $DecisionText
        text = $DecisionText
    }
    Append-CuratedEvent -Paths $Paths -Record $record
    Write-Output "decide: recorded $($record.event_id)"
}

function Invoke-TaskCommand {
    param($Paths)
    switch ($TaskAction) {
        'create' {
            if ([string]::IsNullOrWhiteSpace($TaskTitle)) { throw 'task create requires title' }
            $events = @(Get-WorkspaceEvents $Paths)
            $existing = Project-TasksFromEvents $events
            $map = @{}
            foreach ($t in $existing.tasks) { $map[$t.id] = $true }
            $newId = Get-NextConversationTaskId $map
            $record = [ordered]@{
                ts = Get-IsoTimestamp
                event = 'task.created'
                actor = 'assistant'
                agent_id = 'codex'
                workspace_root = $Paths.Root
                task_id = $newId
                title = $TaskTitle
                status = 'open'
                summary = Make-Summary $TaskTitle
                text = $TaskTitle
            }
            Append-CuratedEvent -Paths $Paths -Record $record
            Write-Output "task: created $newId"
        }
        'update' {
            if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'task update requires task_id' }
            $record = [ordered]@{
                ts = Get-IsoTimestamp
                event = 'task.updated'
                actor = 'assistant'
                agent_id = 'codex'
                workspace_root = $Paths.Root
                task_id = $TaskId
                summary = "task.updated $TaskId"
                text = "task.updated $TaskId"
            }
            if ($TaskStatus) { $record.status = $TaskStatus }
            if ($TaskNextStep) { $record.next_step = $TaskNextStep }
            Append-CuratedEvent -Paths $Paths -Record $record
            Write-Output "task: updated $TaskId"
        }
        'close' {
            if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'task close requires task_id' }
            $record = [ordered]@{
                ts = Get-IsoTimestamp
                event = 'task.closed'
                actor = 'assistant'
                agent_id = 'codex'
                workspace_root = $Paths.Root
                task_id = $TaskId
                status = 'completed'
                evidence = if ($TaskEvidence) { $TaskEvidence } else { '' }
                summary = "task.closed $TaskId"
                text = "task.closed $TaskId"
            }
            Append-CuratedEvent -Paths $Paths -Record $record
            Write-Output "task: closed $TaskId"
        }
        default { throw "Unknown task action: $TaskAction" }
    }
}

function Invoke-Project {
    param($Paths)

    $events = @(Get-WorkspaceEvents $Paths)
    $tasksPayload = Project-TasksFromEvents $events
    [System.IO.File]::WriteAllText(
        $Paths.Tasks,
        (($tasksPayload | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    $tasks = $tasksPayload

    $decisionsMd = Project-DecisionsMarkdown $events
    [System.IO.File]::WriteAllText($Paths.Decisions, $decisionsMd, [System.Text.UTF8Encoding]::new($false))

    $objective = 'Evoluir o ESAA conversacional para gravacao automatica e handoff entre agentes sem gastar tokens na sincronizacao mecanica.'
    $recordedDecisions = @($events | Where-Object { $_.event -eq 'decision.recorded' } | Select-Object -Last 5)
    $decisions = @($recordedDecisions | ForEach-Object { $_.decision })
    if ($decisions.Count -eq 0) {
        $decisions = @(
            'Usar estrutura separada do ESAA formal para nao poluir .roadmap.',
            'Incluir agent_id nos eventos sincronizados (grok, codex, claude em assistant; null em user).',
            'activity.jsonl e fonte de verdade; read models sao projetados via conversation-esaa.'
        )
    }

    $recent = $events |
        Where-Object { $_.summary } |
        Select-Object -Last 5

    $openTasks = @()
    $doneTasks = @()
    if ($tasks -and $tasks.tasks) {
        $openTasks = @($tasks.tasks | Where-Object { $_.status -in @('open', 'in_progress') })
        $doneTasks = @($tasks.tasks | Where-Object { $_.status -eq 'completed' })
    }

    $nextAction = if (@($openTasks).Count -ge 1) {
        $t = $openTasks[0]
        $step = Get-EventField $t 'next_step'
        if ($step) { $step } else { "Trabalhar em $($t.id): $($t.title)" }
    } else {
        'Continuar a conversa; sync automatico mantem .conversation-esaa/ atualizado.'
    }

    $recentLines = @(foreach ($e in $recent) {
        $who = if ($e.actor) { $e.actor } else { 'system' }
        $hasAgent = ($e.PSObject.Properties.Name -contains 'agent_id') -and $e.agent_id
        $id = if ($hasAgent) { " ($($e.agent_id))" } else { '' }
        "- [$($e.ts)] $who$id — $($e.summary)"
    })

    $openLines = @(foreach ($t in $openTasks) {
        "- **$($t.id)** — $($t.title)"
    })
    if ($openLines.Count -eq 0) { $openLines = @('- Nenhuma tarefa aberta.') }

    $decisionBlock = ($decisions | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    $recentBlock = $recentLines -join [Environment]::NewLine
    $openBlock = $openLines -join [Environment]::NewLine

    $state = @(
        '# Estado da Conversa'
        ''
        '> Gerado automaticamente por conv-sync.ps1 project. Nao edite manualmente.'
        ''
        '## Objetivo Atual'
        ''
        $objective
        ''
        '## Decisoes'
        ''
        $decisionBlock
        ''
        '## Estado Atual'
        ''
        "- Eventos em activity.jsonl: $($events.Count)"
        "- Tarefas abertas: $($openTasks.Count)"
        "- Tarefas concluidas: $($doneTasks.Count)"
        '- Sync v1 ativo via conv-sync.ps1'
        ''
        '## Ultimos Eventos'
        ''
        $recentBlock
        ''
        '## Proxima Acao Recomendada'
        ''
        $nextAction
    ) -join [Environment]::NewLine

    $handoff = @(
        '# Handoff para o Proximo Agente'
        ''
        '> Gerado automaticamente por conv-sync.ps1 project. Contrato fixo abaixo.'
        ''
        'Este diretorio usa um ESAA conversacional, nao o ESAA runtime formal.'
        ''
        '## Ordem de leitura'
        ''
        '1. state.md — objetivo, decisoes e estado atual (projetado).'
        '2. tasks.json — tarefas abertas, concluidas e bloqueadas.'
        '3. activity.jsonl — historico cronologico com event_id e source.'
        '4. plans/v1-conversation-esaa-sync.md — plano de implementacao da sync v1.'
        ''
        '## Contrato operacional'
        ''
        '- Nao edite activity.jsonl, state.md ou handoff.md manualmente durante sync v1.'
        '- Grok: hooks em .grok/hooks/conversation-esaa.json disparam sync-grok automaticamente.'
        '- Codex: rode bin/codex-watch.ps1 (auto-sync) ou sync-codex manualmente apos cada sessao.'
        '- Claude Code: hooks em .claude/settings.json disparam sync-claude automaticamente.'
        '- Eventos sincronizados incluem agent_id em assistant (grok/codex/claude) e agent_id null em user.'
        '- Nao trate .conversation-esaa como .roadmap.'
        '- PRIVACIDADE: activity.jsonl/state.md/handoff.md contem texto bruto das conversas. Nao commite dados reais em repo publico. Ver PRIVACY.md e .gitignore.'
        ''
        '## Comandos de sync'
        ''
        '```powershell'
        'pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-sync.ps1 verify -WorkspaceRoot C:\xampp\htdocs\esaa-conversational-lab'
        'pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-sync.ps1 sync-grok -WorkspaceRoot C:\xampp\htdocs\esaa-conversational-lab -GrokSessionId <session-id>'
        'pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-sync.ps1 sync-codex -WorkspaceRoot C:\xampp\htdocs\esaa-conversational-lab'
        'pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-sync.ps1 sync-claude -WorkspaceRoot C:\xampp\htdocs\esaa-conversational-lab'
        'pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-sync.ps1 project -WorkspaceRoot C:\xampp\htdocs\esaa-conversational-lab'
        '```'
        ''
        '## Trust Grok hooks'
        ''
        'Adicione o projeto em ~/.grok/trusted-hook-projects e recarregue com /hooks → r.'
        ''
        '## Tarefas abertas'
        ''
        $openBlock
        ''
        '## Proxima acao recomendada'
        ''
        $nextAction
    ) -join [Environment]::NewLine

    [System.IO.File]::WriteAllText($Paths.State, $state.TrimEnd() + "`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($Paths.Handoff, $handoff.TrimEnd() + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Output 'project: regenerated state.md, handoff.md, tasks.json, and decisions.md'
}

function Invoke-Verify {
    param($Paths)

    if (-not (Test-Path -LiteralPath $Paths.Activity)) {
        throw 'activity.jsonl not found'
    }

    $tasks = Get-Content -LiteralPath $Paths.Tasks -Raw -Encoding UTF8 | ConvertFrom-Json
    # An empty tasks array (fresh/bootstrapped workspace) is valid; only the
    # absence of the property is an error.
    if (-not ($tasks.PSObject.Properties.Name -contains 'tasks')) { throw 'tasks.json has no tasks array' }

    $expectedRoot = (Resolve-Path -LiteralPath $Paths.Root).Path
    $seen = @{}
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($Paths.Activity)) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json
        } catch {
            throw "Invalid JSON at activity.jsonl line $lineNo"
        }

        if ('source' -in $event.PSObject.Properties.Name -and $event.source) {
            foreach ($field in @('event_id', 'ts', 'event', 'actor', 'source', 'summary', 'text')) {
                if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                    throw "Synced event missing '$field' at line $lineNo"
                }
            }
            if ('agent_id' -notin $event.PSObject.Properties.Name) {
                throw "Synced event missing agent_id property at line $lineNo"
            }
            if ($event.actor -eq 'assistant' -and $event.source -in @('grok', 'codex', 'claude')) {
                if (-not $event.agent_id) {
                    throw "Assistant synced event missing agent_id at line $lineNo"
                }
            }
            if (-not (('workspace_root' -in $event.PSObject.Properties.Name) -and $event.workspace_root)) {
                throw "Synced event missing 'workspace_root' at line $lineNo"
            }
            try {
                $eventRoot = (Resolve-Path -LiteralPath $event.workspace_root).Path
            } catch {
                throw "Synced event has invalid workspace_root at line $lineNo"
            }
            if ($eventRoot -ne $expectedRoot) {
                throw "Event $($event.event_id) belongs to another workspace: $($event.workspace_root)"
            }
            if ($seen.ContainsKey($event.event_id)) {
                throw "Duplicate event_id '$($event.event_id)' at line $lineNo"
            }
            $seen[$event.event_id] = $true
        }

        if ($event.event -eq 'decision.recorded') {
            foreach ($field in @('event_id', 'ts', 'event', 'actor', 'agent_id', 'workspace_root', 'decision', 'rationale')) {
                if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                    throw "Decision event missing '$field' at line $lineNo"
                }
            }
            $eventRoot = (Resolve-Path -LiteralPath $event.workspace_root).Path
            if ($eventRoot -ne $expectedRoot) {
                throw "Event $($event.event_id) belongs to another workspace: $($event.workspace_root)"
            }
            if ($seen.ContainsKey($event.event_id)) {
                throw "Duplicate event_id '$($event.event_id)' at line $lineNo"
            }
            $seen[$event.event_id] = $true
        }

        if ($event.event -in @('task.created', 'task.updated', 'task.closed')) {
            foreach ($field in @('event_id', 'ts', 'event', 'actor', 'workspace_root', 'task_id')) {
                if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                    throw "Task event missing '$field' at line $lineNo"
                }
            }
            if ($event.event -eq 'task.created') {
                foreach ($field in @('title', 'status')) {
                    if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                        throw "Task created event missing '$field' at line $lineNo"
                    }
                }
            }
            $eventRoot = (Resolve-Path -LiteralPath $event.workspace_root).Path
            if ($eventRoot -ne $expectedRoot) {
                throw "Event $($event.event_id) belongs to another workspace: $($event.workspace_root)"
            }
            if ($event.event -in @('task.updated', 'task.closed')) {
                $priorCreated = $false
                foreach ($line2 in [System.IO.File]::ReadLines($Paths.Activity)) {
                    if ([string]::IsNullOrWhiteSpace($line2)) { continue }
                    try {
                        $e2 = $line2 | ConvertFrom-Json
                    } catch { continue }
                    if ($e2.event -eq 'task.created' -and $e2.task_id -eq $event.task_id) {
                        $priorCreated = $true
                        break
                    }
                }
                if (-not $priorCreated) {
                    throw "Task event for unknown task_id '$($event.task_id)' at line $lineNo"
                }
            }
            if ($seen.ContainsKey($event.event_id)) {
                throw "Duplicate event_id '$($event.event_id)' at line $lineNo"
            }
            $seen[$event.event_id] = $true
        }
    }

    Write-Output 'verify: ok'
}

$root = Resolve-WorkspaceRoot
$paths = Get-ConvPaths $root
if (-not (Test-Path -LiteralPath $paths.Esaa)) {
    throw "Missing .conversation-esaa at $($paths.Esaa)"
}

switch ($Command) {
    'sync-grok' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Repair-ActivityContract $paths.Activity
            $state = Load-SyncState $paths.SyncState $paths.Activity
            $null = Invoke-SyncGrok -Paths $paths -SyncState $state
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
            Save-SyncState $state $paths.SyncState
        }
    }
    'sync-codex' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Repair-ActivityContract $paths.Activity
            $state = Load-SyncState $paths.SyncState $paths.Activity
            $null = Invoke-SyncCodex -Paths $paths -SyncState $state
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
            Save-SyncState $state $paths.SyncState
        }
    }
    'sync-claude' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Repair-ActivityContract $paths.Activity
            $state = Load-SyncState $paths.SyncState $paths.Activity
            $null = Invoke-SyncClaude -Paths $paths -SyncState $state
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
            Save-SyncState $state $paths.SyncState
        }
    }
    'project' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Invoke-Project -Paths $paths
        }
    }
    'verify' {
        Repair-ActivityContract $paths.Activity
        Invoke-Verify -Paths $paths
    }
    'context' {
        Invoke-Context -Paths $paths
    }
    'decide' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Invoke-Decide -Paths $paths
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        }
    }
    'task' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Invoke-TaskCommand -Paths $paths
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        }
    }
}
