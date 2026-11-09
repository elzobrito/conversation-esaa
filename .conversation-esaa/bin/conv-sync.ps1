#requires -Version 7.0
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('sync-grok', 'sync-codex', 'sync-claude', 'sync-antigravity', 'sync-cursor', 'project', 'verify', 'context', 'decide', 'task', 'topic', 'pack', 'memory-accept', 'memory-rollback')]
    [string]$Command,

    [string]$WorkspaceRoot,
    [string]$GrokSessionId,
    [string]$CodexSessionPath,
    [string]$ClaudeSessionPath,
    [string]$AntigravityTranscriptPath,
    [string]$AntigravityConversationId,
    [string]$CursorSessionId,
    [string]$CursorTranscriptPath,
    [string]$CursorPrompt,
    [ValidateSet('user', 'assistant')]
    [string]$CursorRole,
    [int]$CursorSourceIndex = -1,
    [int]$BudgetTokens = 0,
    [int]$BudgetChars = 0,
    [ValidateSet('normal', 'compact')]
    [string]$Mode = 'normal',

    [int]$LockTimeoutSeconds = 30,
    [switch]$SkipIfLocked,

    [string]$ContextAgent,
    [int]$ContextLast = 0,
    [string]$ContextBefore,
    [string]$ContextAround,
    [int]$ContextWindow = 1,
    [string]$ContextTopic,
    [string]$ContextTopicId,
    [switch]$ContextJson,

    [string]$DecisionText,
    [string]$DecisionRationale,
    [string]$DecisionAgent = 'unknown',
    [string]$CuratorAgent = 'unknown',
    [string]$DecisionSource,
    [string]$DecisionSupersedes,
    [string]$DecisionSupersededBy,

    [ValidateSet('create', 'update', 'close')]
    [string]$TaskAction,
    [string]$TaskId,
    [string]$TaskTitle,
    [string]$TaskStatus,
    [string]$TaskNextStep,
    [string]$TaskEvidence,

    # Topic params for ADR-009 (schema/events support)
    [ValidateSet('list', 'show', 'create', 'update', 'link', 'close')]
    [string]$TopicAction,
    [string]$TopicId,
    [string]$TopicTitle,
    [string]$TopicSummary,
    [string]$TopicEventIds,
    [string]$TopicEvidence,
    [string]$TopicStatus,
    [switch]$TopicJson,

    # Memory-TCG / RRR governance params (ADR-013)
    [string]$MemoryProposalId,
    [string]$MemoryGenerationId,
    [string]$MemoryReason,
    [switch]$MemoryJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PipelineSkipIfLocked = [bool]$SkipIfLocked
$script:PipelineLockPath = $null
$script:PipelineLockOwned = $false
$script:PipelineLockStream = $null

function Get-PipelineLockPath {
    param([string]$WorkspaceRoot)
    Join-Path (Join-Path (Join-Path $WorkspaceRoot '.conversation-esaa') 'run') 'conversation-esaa.lock'
}

function Write-PipelineLockMetadata {
    param(
        [System.IO.FileStream]$Stream,
        [string]$CommandName,
        [string]$WorkspaceRoot
    )
    $lock = [ordered]@{
        pid = $PID
        command = $CommandName
        started_at = (Get-IsoTimestamp)
        workspace_root = $WorkspaceRoot
    }
    $json = (($lock | ConvertTo-Json -Compress) + "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Stream.SetLength(0)
    $Stream.Position = 0
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Try-OpenExclusiveLockFile {
    param(
        [string]$LockPath,
        [System.IO.FileMode]$Mode
    )
    try {
        return [System.IO.FileStream]::new(
            $LockPath,
            $Mode,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch [System.IO.IOException] {
        return $null
    }
}

function Acquire-PipelineLock {
    param(
        [string]$WorkspaceRoot,
        [string]$CommandName,
        [int]$TimeoutSeconds,
        [switch]$SkipIfLocked
    )
    $runDir = Join-Path (Join-Path $WorkspaceRoot '.conversation-esaa') 'run'
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $lockPath = Get-PipelineLockPath $WorkspaceRoot
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([datetime]::UtcNow -lt $deadline) {
        if ($SkipIfLocked -and (Test-Path -LiteralPath $lockPath)) {
            return $false
        }
        $created = Try-OpenExclusiveLockFile -LockPath $lockPath -Mode ([System.IO.FileMode]::CreateNew)
        if ($created) {
            try {
                Write-PipelineLockMetadata -Stream $created -CommandName $CommandName -WorkspaceRoot $WorkspaceRoot
                $script:PipelineLockStream = $created
                $script:PipelineLockPath = $lockPath
                $script:PipelineLockOwned = $true
                return $true
            } catch {
                $created.Dispose()
                throw
            }
        }

        # Exclusive Open succeeds only when no process holds the stream
        # (crash leftover or old metadata-only lock). Never delete a lock we
        # cannot open exclusively: that file is held by a live writer.
        $existingStream = Try-OpenExclusiveLockFile -LockPath $lockPath -Mode ([System.IO.FileMode]::Open)
        if ($existingStream) {
            $existingPid = $null
            try {
                $existingStream.Position = 0
                $reader = New-Object System.IO.StreamReader($existingStream, [System.Text.UTF8Encoding]::new($false), $false, 1024, $true)
                $raw = $reader.ReadToEnd()
                $reader.Dispose()
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = $raw | ConvertFrom-Json
                    if ($parsed.pid) { $existingPid = [int]$parsed.pid }
                }
            } catch {
                $existingPid = $null
            }
            Write-Warning "reclaiming unheld pipeline lock (pid=$existingPid)"
            try {
                Write-PipelineLockMetadata -Stream $existingStream -CommandName $CommandName -WorkspaceRoot $WorkspaceRoot
                $script:PipelineLockStream = $existingStream
                $script:PipelineLockPath = $lockPath
                $script:PipelineLockOwned = $true
                return $true
            } catch {
                $existingStream.Dispose()
                throw
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
    if ($script:PipelineLockStream) {
        try { $script:PipelineLockStream.Dispose() } catch { }
        $script:PipelineLockStream = $null
    }
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
    $acquired = Acquire-PipelineLock -WorkspaceRoot $WorkspaceRoot -CommandName $CommandName -TimeoutSeconds $TimeoutSeconds -SkipIfLocked:$script:PipelineSkipIfLocked
    if ($acquired -ne $true) {
        if ($script:PipelineSkipIfLocked) {
            Write-Output "pipeline lock busy; skip $CommandName"
        }
        return
    }
    try {
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
        Topics = Join-Path $Root '.conversation-esaa\topics.json'
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
    param($SourceOffset = $null)
    $offset = [TimeSpan]::FromHours(-3)
    $dto = if ($null -ne $SourceOffset) {
        if ($SourceOffset -is [datetimeoffset]) {
            $SourceOffset.ToOffset($offset)
        } else {
            ([datetimeoffset]$SourceOffset).ToOffset($offset)
        }
    } else {
        [DateTimeOffset]::Now.ToOffset($offset)
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
    $line = ($Event | ConvertTo-Json -Compress -Depth 20)
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

function Get-AntigravityTextFromEntry {
    param($Entry)
    if (-not $Entry) { return $null }
    if ('status' -notin $Entry.PSObject.Properties.Name) { return $null }
    if ('type' -notin $Entry.PSObject.Properties.Name) { return $null }
    if ($Entry.status -ne 'DONE') { return $null }
    if ($Entry.type -notin @('USER_INPUT', 'PLANNER_RESPONSE')) { return $null }
    if ('content' -notin $Entry.PSObject.Properties.Name) { return $null }
    if ($Entry.content -isnot [string]) { return $null }

    $text = $Entry.content.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $timestamp = if ($Entry.PSObject.Properties.Name -contains 'created_at') {
        [string]$Entry.created_at
    } else { $null }

    if ($Entry.type -eq 'USER_INPUT') {
        $identityText = $text
        if ($text -match '(?s)<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>') {
            $text = $Matches[1].Trim()
        }
        return @{ Actor = 'user'; Text = $text; IdentityText = $identityText; AgentId = $null; Timestamp = $timestamp }
    }
    return @{ Actor = 'assistant'; Text = $text; AgentId = 'antigravity'; Timestamp = $timestamp }
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
        [string]$EventIdText = $null,
        [string]$AgentId = $null,
        [string]$SourceTimestamp = $null,
        [string]$EventName = 'conversation_turn'
    )

    $identityText = if (-not [string]::IsNullOrEmpty($EventIdText)) { $EventIdText } else { $Text }
    $eventId = Compute-EventId $Source $SessionId $SourceIndex $Actor $identityText
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

function Find-AntigravityTranscript {
    $brain = Join-Path $HOME '.gemini\antigravity-cli\brain'
    if (-not (Test-Path -LiteralPath $brain)) { return $null }
    $latest = Get-ChildItem -Path $brain -Recurse -Filter 'transcript.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]\.system_generated[\\/]logs[\\/]transcript\.jsonl$' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latest) { return $latest.FullName }
    return $null
}

function Get-AntigravityConversationIdFromPath {
    param([string]$TranscriptPath)
    $logsDir = Split-Path -Parent $TranscriptPath
    $systemDir = Split-Path -Parent $logsDir
    $conversationDir = Split-Path -Parent $systemDir
    return Split-Path -Leaf $conversationDir
}

function Invoke-SyncAntigravity {
    param($Paths, $SyncState)

    $transcript = $AntigravityTranscriptPath
    if (-not $transcript) { $transcript = Find-AntigravityTranscript }
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) {
        throw 'Antigravity transcript JSONL not found. Pass -AntigravityTranscriptPath or run inside an Antigravity hook.'
    }
    $transcript = (Resolve-Path -LiteralPath $transcript).Path
    $sessionId = if ($AntigravityConversationId) {
        $AntigravityConversationId
    } else {
        Get-AntigravityConversationIdFromPath $transcript
    }

    $imported = 0
    $lineIndex = 0
    foreach ($line in (Read-JsonlLines $transcript)) {
        if ([string]::IsNullOrWhiteSpace($line)) { $lineIndex++; continue }
        try { $entry = $line | ConvertFrom-Json } catch { $lineIndex++; continue }
        $parsed = Get-AntigravityTextFromEntry $entry
        if ($parsed) {
            $sourceIndex = if (($entry.PSObject.Properties.Name -contains 'step_index') -and ($null -ne $entry.step_index)) {
                [int]$entry.step_index
            } else { $lineIndex }
            $added = Import-Message `
                -Paths $Paths `
                -SyncState $SyncState `
                -Source 'antigravity' `
                -SessionId $sessionId `
                -SourcePath $transcript `
                -SourceIndex $sourceIndex `
                -Actor $parsed.Actor `
                -Text $parsed.Text `
                -EventIdText $(if ($parsed.ContainsKey('IdentityText')) { $parsed.IdentityText } else { $null }) `
                -AgentId $parsed.AgentId `
                -SourceTimestamp $parsed.Timestamp `
                -EventName $(if ($Mode -eq 'compact') { 'pre_compact_sync' } else { 'conversation_turn' })
            if ($added) { $imported++ }
        }
        $lineIndex++
    }

    Write-Output "sync-antigravity: imported $imported new event(s) from $sessionId"
    return $imported
}

function Get-CursorTextFromEntry {
    param($Entry)
    if (-not $Entry) { return $null }
    $role = $null
    $text = $null
    if (($Entry.PSObject.Properties.Name -contains 'role') -and $Entry.role) {
        $role = [string]$Entry.role
    } elseif (($Entry.PSObject.Properties.Name -contains 'type') -and $Entry.type) {
        $role = [string]$Entry.type
    }
    if ($role -notin @('user', 'assistant')) { return $null }
    if (($Entry.PSObject.Properties.Name -contains 'text') -and $Entry.text -is [string]) {
        $text = $Entry.text
    } elseif (($Entry.PSObject.Properties.Name -contains 'prompt') -and $Entry.prompt -is [string]) {
        $text = $Entry.prompt
    } elseif (($Entry.PSObject.Properties.Name -contains 'message') -and $Entry.message) {
        if ($Entry.message -is [string]) {
            $text = $Entry.message
        } elseif (($Entry.message.PSObject.Properties.Name -contains 'content') -and $Entry.message.content -is [string]) {
            $text = $Entry.message.content
        }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $timestamp = $null
    if ($Entry.PSObject.Properties.Name -contains 'timestamp') {
        $timestamp = [string]$Entry.timestamp
    }
    if ($role -eq 'user') {
        return @{ Actor = 'user'; Text = $text.Trim(); AgentId = $null; Timestamp = $timestamp }
    }
    return @{ Actor = 'assistant'; Text = $text.Trim(); AgentId = 'cursor'; Timestamp = $timestamp }
}

function Invoke-SyncCursor {
    param($Paths, $SyncState)

    $imported = 0
    $sessionId = if ($CursorSessionId) { $CursorSessionId } else { 'cursor-session' }

    if ($CursorRole -and -not [string]::IsNullOrWhiteSpace($CursorPrompt)) {
        $sourceIndex = if ($CursorSourceIndex -ge 0) { $CursorSourceIndex } else {
            if ($CursorRole -eq 'user') { 0 } else { 1 }
        }
        $added = Import-Message `
            -Paths $Paths `
            -SyncState $SyncState `
            -Source 'cursor' `
            -SessionId $sessionId `
            -SourcePath 'cursor-hook' `
            -SourceIndex $sourceIndex `
            -Actor $(if ($CursorRole -eq 'user') { 'user' } else { 'assistant' }) `
            -Text $CursorPrompt.Trim() `
            -AgentId $(if ($CursorRole -eq 'assistant') { 'cursor' } else { $null }) `
            -EventName $(if ($Mode -eq 'compact') { 'pre_compact_sync' } else { 'conversation_turn' })
        if ($added) { $imported++ }
        Write-Output "sync-cursor: imported $imported new event(s) from $sessionId"
        return $imported
    }

    $transcript = $CursorTranscriptPath
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) {
        throw 'Cursor transcript or prompt not found. Pass -CursorPrompt/-CursorRole from the hook or -CursorTranscriptPath.'
    }
    $transcript = (Resolve-Path -LiteralPath $transcript).Path
    $index = 0
    foreach ($line in (Read-JsonlLines $transcript)) {
        if ([string]::IsNullOrWhiteSpace($line)) { $index++; continue }
        try { $entry = $line | ConvertFrom-Json } catch { $index++; continue }
        $parsed = Get-CursorTextFromEntry $entry
        if ($parsed) {
            $added = Import-Message `
                -Paths $Paths `
                -SyncState $SyncState `
                -Source 'cursor' `
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

    Write-Output "sync-cursor: imported $imported new event(s) from $sessionId"
    return $imported
}

function Get-Utf8CharCount {
    param([string]$Text)
    if ($null -eq $Text) { return 0 }
    return [System.Text.Encoding]::UTF8.GetByteCount($Text)
}

function Get-EstimatedTokenCount {
    param([string]$Text)
    $chars = Get-Utf8CharCount $Text
    if ($chars -le 0) { return 0 }
    return [int][Math]::Ceiling($chars / 4.0)
}

function Test-PackFitsBudget {
    param(
        [string]$Text,
        [int]$TokenBudget,
        [int]$CharBudget
    )
    $chars = Get-Utf8CharCount $Text
    $tokens = Get-EstimatedTokenCount $Text
    if ($CharBudget -gt 0 -and $chars -gt $CharBudget) { return $false }
    if ($TokenBudget -gt 0 -and $tokens -gt $TokenBudget) { return $false }
    return $true
}

function Invoke-Pack {
    param($Paths)

    $tokenBudget = $BudgetTokens
    $charBudget = $BudgetChars
    if ($tokenBudget -le 0 -and $charBudget -le 0) { $tokenBudget = 4000 }

    $handoffBody = '_Handoff missing. Run verify._'
    if (Test-Path -LiteralPath $Paths.Handoff) {
        $rawHandoff = Get-Content -LiteralPath $Paths.Handoff -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($rawHandoff)) { $handoffBody = $rawHandoff.Trim() }
    }

    $decisionLines = [System.Collections.Generic.List[string]]::new()
    $activeMemPath = Join-Path (Join-Path $Paths.Esaa 'memory') 'active.json'
    if (Test-Path -LiteralPath $activeMemPath) {
        $cliScript = Resolve-MemoryCliScriptForSync
        $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
        if ($cliScript -and $nodeCmd) {
            $effCharBudget = if ($charBudget -gt 0) { $charBudget } elseif ($tokenBudget -gt 0) { $tokenBudget * 4 } else { 4000 }
            $rawMemCtx = & $nodeCmd.Source $cliScript 'context' '--workspace' $Paths.Root '--budget-chars' "$effCharBudget" '--json' 2>$null
            if ($LASTEXITCODE -eq 0 -and $rawMemCtx) {
                try {
                    $memCtx = ($rawMemCtx -join "`n") | ConvertFrom-Json
                    if ($memCtx.status -eq 'OK') {
                        foreach ($d in @($memCtx.retained_decisions)) {
                            $evIds = @($d.evidence_event_ids) -join ', '
                            [void]$decisionLines.Add("- **[ACTIVE]** ($($d.memory_id)) $($d.summary) *(evidence: $evIds)*")
                        }
                        foreach ($u in @($memCtx.unresolved_conflicts)) {
                            $evIds = @($u.evidence_event_ids) -join ', '
                            [void]$decisionLines.Add("- **[UNRESOLVED CONFLICT]** ($($u.conflict_id): $($u.reason_code)) *(evidence: $evIds)*")
                        }
                        foreach ($h in @($memCtx.historical_decisions)) {
                            $evIds = @($h.evidence_event_ids) -join ', '
                            $supBy = if ($h.superseded_by_id) { " -> superseded by $($h.superseded_by_id)" } else { '' }
                            [void]$decisionLines.Add("- **[HISTORICAL / SUPERSEDED]** ($($h.memory_id)) $($h.summary)$supBy *(evidence: $evIds)*")
                        }
                        foreach ($s in @($memCtx.consolidated_subjects)) {
                            $evIds = @($s.evidence_event_ids) -join ', '
                            $topicTag = if ($s.topic_id) { " [$($s.topic_id)]" } else { '' }
                            [void]$decisionLines.Add("- **[SUBJECT / ASSUNTO]**$topicTag ($($s.memory_id)) $($s.summary) *(evidence: $evIds)*")
                        }
                        foreach ($g in @($memCtx.grouped_duplicates)) {
                            $evIds = @($g.evidence_event_ids) -join ', '
                            [void]$decisionLines.Add("- **[RECURRING SUBJECT]** ($($g.memory_id), $($g.duplicate_count) turns) $($g.summary) *(evidence: $evIds)*")
                        }
                        if (@($memCtx.omitted_memory_ids).Count -gt 0) {
                            [void]$decisionLines.Add("- *(budget omitted: $(@($memCtx.omitted_memory_ids) -join ', '))*")
                        }
                    } elseif ($memCtx.status -eq 'FALLBACK_LEGACY') {
                        [void]$decisionLines.Add("- [MEMORY-FALLBACK: active.json integrity check failed ($($memCtx.error_code)); using legacy decisions projection]")
                    }
                } catch { }
            }
        }
    }
    if ($decisionLines.Count -eq 0 -or ($decisionLines.Count -eq 1 -and $decisionLines[0].StartsWith('- [MEMORY-FALLBACK:'))) {
        if (Test-Path -LiteralPath $Paths.Decisions) {
            foreach ($line in [System.IO.File]::ReadLines($Paths.Decisions)) {
                if ($line -match '^\s*-\s+\S') { [void]$decisionLines.Add($line.Trim()) }
            }
        }
    }
    if ($decisionLines.Count -eq 0) { [void]$decisionLines.Add('- None recorded.') }

    $taskLines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Paths.Tasks) {
        try {
            $tasksPayload = Get-Content -LiteralPath $Paths.Tasks -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($task in @($tasksPayload.tasks)) {
                if ($task.status -in @('open', 'in_progress')) {
                    [void]$taskLines.Add("- **$($task.id)** — $($task.title)")
                }
            }
        } catch { }
    }
    if ($taskLines.Count -eq 0) { [void]$taskLines.Add('- Nenhuma tarefa aberta.') }

    $topicId = 'none'
    $recentLines = [System.Collections.Generic.List[string]]::new()
    $keyIds = @()
    if (Test-Path -LiteralPath $Paths.Topics) {
        try {
            $topicsPayload = Get-Content -LiteralPath $Paths.Topics -Raw -Encoding UTF8 | ConvertFrom-Json
            $active = @($topicsPayload.topics | Where-Object { $_.status -eq 'active' })
            if ($active.Count -ge 1) {
                $topicId = [string]$active[0].id
                $keyIds = @($active[0].key_event_ids)
            }
        } catch { }
    }
    $events = @(Get-WorkspaceEvents $Paths)
    $selected = @()
    if ($keyIds.Count -gt 0) {
        $idSet = @{}
        foreach ($id in $keyIds) { $idSet[[string]$id] = $true }
        $selected = @($events | Where-Object {
            $eid = Get-ContextEventId $_
            $eid -and $idSet.ContainsKey($eid)
        } | Select-Object -Last 8)
    }
    if ($selected.Count -eq 0) {
        $selected = @($events |
            Where-Object { $_.event -eq 'conversation_turn' -and $_.summary } |
            Select-Object -Last 8)
    }
    foreach ($event in $selected) {
        $who = if ($event.actor) { $event.actor } else { 'system' }
        $summary = if ($event.summary) { $event.summary } else { $event.event }
        [void]$recentLines.Add("- [$($event.ts)] $who — $summary")
    }
    if ($recentLines.Count -eq 0) { [void]$recentLines.Add('- Nenhum evento recente.') }

    function Build-Pack([string]$Handoff, [string[]]$Decisions, [string[]]$Tasks, [string[]]$Recent) {
        @(
            '# cold-start v1 — mechanical, no LLM'
            '## Handoff'
            $Handoff
            '## Decisions (active)'
            ($Decisions -join [Environment]::NewLine)
            '## Open tasks'
            ($Tasks -join [Environment]::NewLine)
            "## Recent events (topic=$topicId)"
            ($Recent -join [Environment]::NewLine)
        ) -join [Environment]::NewLine
    }

    $pack = Build-Pack $handoffBody @($decisionLines) @($taskLines) @($recentLines)
    if (-not (Test-PackFitsBudget $pack $tokenBudget $charBudget)) {
        $pack = Build-Pack $handoffBody @($decisionLines) @($taskLines) @('- (omitted to fit budget)')
    }
    if (-not (Test-PackFitsBudget $pack $tokenBudget $charBudget)) {
        $pack = Build-Pack $handoffBody @($decisionLines) @('- (omitted to fit budget)') @('- (omitted to fit budget)')
    }
    if (-not (Test-PackFitsBudget $pack $tokenBudget $charBudget)) {
        $pack = Build-Pack $handoffBody @('- (omitted to fit budget)') @('- (omitted to fit budget)') @('- (omitted to fit budget)')
    }
    if (-not (Test-PackFitsBudget $pack $tokenBudget $charBudget)) {
        $prefix = "# cold-start v1 — mechanical, no LLM`n## Handoff`n"
        $suffix = "`n…[truncated to budget]"
        $limitChars = if ($charBudget -gt 0) { $charBudget } else { $tokenBudget * 4 }
        $overhead = (Get-Utf8CharCount $prefix) + (Get-Utf8CharCount $suffix)
        $available = $limitChars - $overhead
        if ($available -lt 1) { $available = 1 }
        $trimmed = $handoffBody
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($trimmed)
        if ($bytes.Length -gt $available) {
            $trimmed = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $available)
        }
        $pack = $prefix + $trimmed + $suffix
        while (-not (Test-PackFitsBudget $pack $tokenBudget $charBudget) -and $trimmed.Length -gt 0) {
            $cut = [Math]::Max(1, [int][Math]::Ceiling($trimmed.Length * 0.15))
            $trimmed = $trimmed.Substring(0, [Math]::Max(0, $trimmed.Length - $cut))
            $pack = $prefix + $trimmed + $suffix
        }
    }

    Write-Output $pack
}

function Test-CursorAdapter {
    param($Paths)

    $manifestPath = Join-Path $Paths.Esaa 'install-manifest.json'
    $hooksPath = Join-Path $Paths.Root '.cursor\hooks.json'
    $wrapperPath = Join-Path $Paths.Esaa 'bin\cursor-hook.ps1'
    $expectCursor = $false
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@($manifest.agents) -contains 'cursor') { $expectCursor = $true }
        } catch { }
    }
    if (Test-Path -LiteralPath $hooksPath) { $expectCursor = $true }
    if (-not $expectCursor) { return }

    if (-not (Test-Path -LiteralPath $wrapperPath)) {
        throw "Cursor adapter wrapper missing ($wrapperPath). Repair: install --agent cursor / repair."
    }
    if (-not (Test-Path -LiteralPath $hooksPath)) {
        throw 'Cursor hooks missing (.cursor/hooks.json). Repair: install --agent cursor.'
    }
    try {
        $hooks = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw 'Cursor hooks JSON is invalid (.cursor/hooks.json). Repair: install --agent cursor.'
    }

    function Get-CursorHookCommands([string]$EventName) {
        if (-not $hooks.hooks) { return @() }
        $entry = $hooks.hooks.$EventName
        $commands = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($entry)) {
            if ($item -and ($item.PSObject.Properties.Name -contains 'command')) {
                [void]$commands.Add([string]$item.command)
            } elseif ($item -and ($item.PSObject.Properties.Name -contains 'hooks')) {
                foreach ($nested in @($item.hooks)) {
                    if ($nested.command) { [void]$commands.Add([string]$nested.command) }
                }
            }
        }
        return @($commands)
    }

    $submit = @(Get-CursorHookCommands 'beforeSubmitPrompt' | Where-Object { $_ -match 'cursor-hook\.ps1' })
    $assistant = @(Get-CursorHookCommands 'afterAgentResponse' | Where-Object { $_ -match 'cursor-hook\.ps1' })
    $session = @(Get-CursorHookCommands 'sessionStart' | Where-Object { $_ -match 'cursor-hook\.ps1' })
    if ($submit.Count -eq 0) {
        throw 'Cursor capture hook missing (beforeSubmitPrompt in .cursor/hooks.json). Repair: install --agent cursor.'
    }
    if ($assistant.Count -eq 0) {
        throw 'Cursor capture hook missing (afterAgentResponse in .cursor/hooks.json). Repair: install --agent cursor.'
    }
    if ($session.Count -eq 0 -and $submit.Count -eq 0) {
        throw 'Cursor inject hook missing (sessionStart or beforeSubmitPrompt in .cursor/hooks.json). Repair: install --agent cursor.'
    }
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
    $workspaceEvents = @($events | Where-Object {
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

    # Keep the append-only log intact while making read models resilient to
    # repeated imports of the same native transcript step.
    $seenSourceTurns = @{}
    $deduped = [System.Collections.Generic.List[object]]::new()
    foreach ($event in $workspaceEvents) {
        $hasSourceIdentity =
            ('source' -in $event.PSObject.Properties.Name) -and $event.source -and
            ('source_session_id' -in $event.PSObject.Properties.Name) -and $event.source_session_id -and
            ('source_index' -in $event.PSObject.Properties.Name) -and ($null -ne $event.source_index) -and
            ('actor' -in $event.PSObject.Properties.Name) -and $event.actor
        if ($hasSourceIdentity) {
            $key = "$($event.source)|$($event.source_session_id)|$($event.source_index)|$($event.actor)"
            if ($seenSourceTurns.ContainsKey($key)) { continue }
            $seenSourceTurns[$key] = $true
        }
        $deduped.Add($event)
    }
    return @($deduped)
}

function New-CuratedEventId {
    param([string]$Payload)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
}

function Append-CuratedEvent {
    param($Paths, $Record)
    if ($Record -is [System.Collections.IDictionary]) {
        $Record['agent_id_source'] = if ($Record.agent_id -and $Record.agent_id -ne 'unknown') { 'declared' } else { 'unknown' }
    }
    $hasId = ($Record -is [System.Collections.IDictionary] -and $Record.Contains('event_id')) -or
        (('event_id' -in $Record.PSObject.Properties.Name) -and $Record.event_id)
    if (-not $hasId) {
        $payload = "$($Record.event)|$($Paths.Root)|$($Record.ts)|$($Record | ConvertTo-Json -Compress -Depth 20)"
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

function Get-NextTopicId {
    param($Topics)
    $max = 0
    try {
        $t = if ($Topics) { $Topics } else { $null }
        if ($t -and $t.topics) {
            foreach ($item in $t.topics) {
                if ($item.id -match '^TOP-(\d+)$') {
                    $n = [int]$Matches[1]
                    if ($n -gt $max) { $max = $n }
                }
            }
        }
    } catch {}
    return ('TOP-{0:D3}' -f ($max + 1))
}

# conversation-esaa.topics.v0.1 schema (see ADR-009)
# {
#   "schema_version": "conversation-esaa.topics.v0.1",
#   "updated": "...",
#   "workspace_root": "...",
#   "topics": [ { "id": "TOP-001", "title": "...", "summary": "...", "status": "active|paused|completed|archived", "created_ts": "...", "last_ts": "...", "keywords": [], "key_event_ids": [], "event_count": 0, "first_event_id": null, "last_event_id": null, "related_decisions": [], "related_tasks": [], "source": "curated" } ]
# }

function Get-EventField {
    param($Event, [string]$Name)
    if ($Event -is [System.Collections.IDictionary]) {
        if ($Event.Contains($Name)) { return $Event[$Name] }
        return $null
    }
    if ($Name -in $Event.PSObject.Properties.Name) { return $Event.$Name }
    return $null
}

function Split-TopicEventIds {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-TopicExists {
    param($TopicsPayload, [string]$Id)
    if (-not $TopicsPayload -or -not $TopicsPayload.topics) { return $false }
    return [bool](@($TopicsPayload.topics | Where-Object { $_.id -eq $Id } | Select-Object -First 1).Count)
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
    $events = @(Get-WorkspaceEvents $Paths | Where-Object { $_.event -notlike 'memory.*' })
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
    if ($ContextTopicId) {
        $topics = Get-Content $Paths.Topics -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        $t = if ($topics -and $topics.topics) { $topics.topics | Where-Object { $_.id -eq $ContextTopicId } | Select-Object -First 1 } else { $null }
        if (-not $t) { throw "Unknown topic_id '$ContextTopicId'" }
        $linked = @($t.key_event_ids)
        $events = @($events | Where-Object { (Get-ContextEventId $_) -in $linked })
    }
    if ($ContextBefore) {
        $idx = [array]::IndexOf(@($events | ForEach-Object { Get-ContextEventId $_ }), $ContextBefore)
        if ($idx -lt 0) { throw "Context target event not found: $ContextBefore" }
        $take = if ($ContextLast -gt 0) { $ContextLast } else { 2 }
        $start = [Math]::Max(0, $idx - $take)
        if ($idx -eq 0) { $events = @() } else { $events = @($events[$start..($idx - 1)]) }
    } elseif ($ContextAround) {
        $idx = [array]::IndexOf(@($events | ForEach-Object { Get-ContextEventId $_ }), $ContextAround)
        if ($idx -lt 0) { throw "Context target event not found: $ContextAround" }
        $start = [Math]::Max(0, $idx - $ContextWindow)
        $end = [Math]::Min($events.Count - 1, $idx + $ContextWindow)
        $events = @($events[$start..$end])
    } elseif ($ContextLast -gt 0) {
        $events = @($events | Select-Object -Last $ContextLast)
    }
    foreach ($e in $events) {
        if ($e.event -match '^(decision|task|topic)\.' -and 'agent_id_source' -notin $e.PSObject.Properties.Name) {
            $e | Add-Member -NotePropertyName agent_id_source -NotePropertyValue 'legacy_unverified' -Force
        }
    }
    if ($ContextJson) {
        if (@($events).Count -eq 0) { Write-Output '[]' } else { $events | ConvertTo-Json -Depth 8 }
        return
    }
    $filter = @()
    if ($ContextAgent) { $filter += "agent=$ContextAgent" }
    if ($ContextTopic) { $filter += "topic=$ContextTopic" }
    if ($ContextTopicId) { $filter += "topic_id=$ContextTopicId" }
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
        $origin = Get-ContextEventValue $e 'agent_id_source'
        if ($origin) { $who += " [agent_id_source=$origin]" }
        $eventId = Get-ContextEventId $e
        $eid = if ($eventId) { $eventId } else { '(legacy)' }
        $ts = Get-ContextEventValue $e 'ts' '(no-ts)'
        $summary = Get-ContextEventValue $e 'summary'
        $out.Add("- [$ts] $who $eid")
        if ($summary) { $out.Add("  $summary") }
        $out.Add('')
    }
    $activeMemPath = Join-Path (Join-Path $Paths.Esaa 'memory') 'active.json'
    if ((Test-Path -LiteralPath $activeMemPath) -and -not $ContextBefore -and -not $ContextAround -and $ContextLast -le 0 -and -not $ContextAgent) {
        $cliScript = Resolve-MemoryCliScriptForSync
        $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
        if ($cliScript -and $nodeCmd) {
            $ctxArgs = @($cliScript, 'context', '--workspace', $Paths.Root, '--json')
            if ($ContextTopicId) { $ctxArgs += @('--topic-id', $ContextTopicId) }
            $rawMemCtx = & $nodeCmd.Source @ctxArgs 2>$null
            if ($LASTEXITCODE -eq 0 -and $rawMemCtx) {
                try {
                    $memCtx = ($rawMemCtx -join "`n") | ConvertFrom-Json
                    if ($memCtx.status -eq 'OK' -and $memCtx.markdown) {
                        $out.Add($memCtx.markdown)
                    } elseif ($memCtx.status -eq 'FALLBACK_LEGACY') {
                        $out.Add("> [MEMORY-FALLBACK: active.json integrity check failed ($($memCtx.error_code)); showing legacy ledger projection]")
                    }
                } catch { }
            }
        }
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
    if ($DecisionSupersedes -and $DecisionSupersededBy) {
        $record['link_only'] = $true
        $record['supersedes_links'] = @(
            [ordered]@{
                source = $DecisionSupersededBy
                target = $DecisionSupersedes
            }
        )
    } elseif ($DecisionSupersedes) {
        $record['supersedes'] = $DecisionSupersedes
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
                agent_id = $CuratorAgent
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
                agent_id = $CuratorAgent
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
                agent_id = $CuratorAgent
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

function Invoke-TopicCommand {
    param($Paths)
    if (-not $TopicAction) { $TopicAction = 'create' }
    switch ($TopicAction) {
        'list' {
            $topicsPayload = if (Test-Path -LiteralPath $Paths.Topics) {
                Get-Content -LiteralPath $Paths.Topics -Raw -Encoding UTF8 | ConvertFrom-Json
            } else {
                Project-TopicsFromEvents @(Get-WorkspaceEvents $Paths)
            }
            $items = @($topicsPayload.topics)
            if ($TopicStatus -and $TopicStatus -ne 'all') {
                $items = @($items | Where-Object { $_.status -eq $TopicStatus })
            }
            if ($TopicJson) {
                $items | ConvertTo-Json -Depth 8
                return
            }
            if ($items.Count -eq 0) {
                Write-Output 'topics: none'
                return
            }
            foreach ($topic in $items) {
                Write-Output "$($topic.id) [$($topic.status)] $($topic.title)"
            }
            return
        }
        'show' {
            if ([string]::IsNullOrWhiteSpace($TopicId)) { throw 'topics show requires --topic-id' }
            $topicsPayload = if (Test-Path -LiteralPath $Paths.Topics) {
                Get-Content -LiteralPath $Paths.Topics -Raw -Encoding UTF8 | ConvertFrom-Json
            } else {
                Project-TopicsFromEvents @(Get-WorkspaceEvents $Paths)
            }
            $topic = @($topicsPayload.topics | Where-Object { $_.id -eq $TopicId } | Select-Object -First 1)
            if ($topic.Count -eq 0) { throw "Unknown topic_id '$TopicId'" }
            if ($TopicJson) {
                $topic[0] | ConvertTo-Json -Depth 8
                return
            }
            Write-Output "$($topic[0].id) [$($topic[0].status)] $($topic[0].title)"
            if ($topic[0].summary) { Write-Output $topic[0].summary }
            if ($topic[0].key_event_ids -and $topic[0].key_event_ids.Count -gt 0) {
                Write-Output "key_event_ids: $($topic[0].key_event_ids -join ', ')"
            }
            return
        }
        'create' {
            if ([string]::IsNullOrWhiteSpace($TopicTitle)) { throw 'topic create requires --title' }
            $topicId = if ($TopicId) { $TopicId } else { Get-NextTopicId (Get-Content $Paths.Topics -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue) }
            if ($topicId -notmatch '^TOP-\d{3,}$') { throw "Invalid topic_id '$topicId'" }
            $record = [ordered]@{
                ts = Get-IsoTimestamp
                event = 'topic.created'
                actor = 'assistant'
                agent_id = $CuratorAgent
                workspace_root = $Paths.Root
                topic_id = $topicId
                title = $TopicTitle
                summary = if ($TopicSummary) { $TopicSummary } else { $TopicTitle }
                status = 'active'
                keywords = @()
                event_ids = @()
                source = 'curated'
                text = if ($TopicSummary) { $TopicSummary } else { $TopicTitle }
            }
            Append-CuratedEvent -Paths $Paths -Record $record
            Write-Output "topic: created $topicId"
        }
        'update' {
            if ([string]::IsNullOrWhiteSpace($TopicId)) { throw 'topic update requires --topic-id' }
            $current = Project-TopicsFromEvents @(Get-WorkspaceEvents $Paths)
            if (-not (Test-TopicExists $current $TopicId)) { throw "Unknown topic_id '$TopicId'" }
            $record = [ordered]@{
                ts = Get-IsoTimestamp
                event = 'topic.updated'
                actor = 'assistant'
                agent_id = $CuratorAgent
                workspace_root = $Paths.Root
                topic_id = $TopicId
            }
            if ($TopicTitle) { $record.title = $TopicTitle }
            if ($TopicSummary) { $record.summary = $TopicSummary }
            if ($TopicStatus) { $record.status = $TopicStatus }
            $record.summary = if ($record.Contains('summary')) { $record.summary } else { "topic.updated $TopicId" }
            $record.text = $record.summary
            Append-CuratedEvent -Paths $Paths -Record $record
            Write-Output "topic: updated $TopicId"
        }
        'link' {
            if ([string]::IsNullOrWhiteSpace($TopicId)) { throw 'topic link requires --topic-id' }
            $current = Project-TopicsFromEvents @(Get-WorkspaceEvents $Paths)
            if (-not (Test-TopicExists $current $TopicId)) { throw "Unknown topic_id '$TopicId'" }
            $ids = @(Split-TopicEventIds $TopicEventIds)
            if ($ids.Count -eq 0) { throw 'topic link requires --event-id/--events' }
            $known = @{}
            foreach ($event in @(Get-WorkspaceEvents $Paths)) {
                $eventId = Get-ContextEventId $event
                if ($eventId) { $known[$eventId] = $true }
            }
            foreach ($id in $ids) {
                if (-not $known.ContainsKey($id)) { throw "Unknown event_id '$id'" }
            }
            $record = [ordered]@{
                ts = Get-IsoTimestamp
                event = 'topic.event.linked'
                actor = 'assistant'
                agent_id = $CuratorAgent
                workspace_root = $Paths.Root
                topic_id = $TopicId
                event_ids = $ids
                summary = "topic.event.linked $TopicId"
                text = "topic.event.linked $TopicId"
            }
            Append-CuratedEvent -Paths $Paths -Record $record
            Write-Output "topic: linked event to $TopicId"
        }
        'close' {
            if ([string]::IsNullOrWhiteSpace($TopicId)) { throw 'topic close requires --topic-id' }
            $current = Project-TopicsFromEvents @(Get-WorkspaceEvents $Paths)
            if (-not (Test-TopicExists $current $TopicId)) { throw "Unknown topic_id '$TopicId'" }
            $record = [ordered]@{
                ts = Get-IsoTimestamp
                event = 'topic.closed'
                actor = 'assistant'
                agent_id = $CuratorAgent
                workspace_root = $Paths.Root
                topic_id = $TopicId
                status = 'completed'
                evidence = if ($TopicEvidence) { $TopicEvidence } else { '' }
                summary = if ($TopicEvidence) { $TopicEvidence } else { "topic.closed $TopicId" }
                text = if ($TopicEvidence) { $TopicEvidence } else { "topic.closed $TopicId" }
            }
            Append-CuratedEvent -Paths $Paths -Record $record
            Write-Output "topic: closed $TopicId"
        }
        default { throw "Unknown topic action: $TopicAction" }
    }
}

function Project-TopicsFromEvents {
    param($Events)
    $topicMap = @{}
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Events) {
        switch ($e.event) {
            'topic.created' {
                $tid = Get-EventField $e 'topic_id'
                if (-not $tid) { continue }
                $initialIds = @()
                $createdEventIds = Get-EventField $e 'event_ids'
                if ($createdEventIds) { $initialIds = @($createdEventIds) }
                $topicMap[$tid] = [ordered]@{
                    id = $tid
                    title = Get-EventField $e 'title'
                    summary = Get-EventField $e 'summary'
                    status = if (Get-EventField $e 'status') { Get-EventField $e 'status' } else { 'active' }
                    created_ts = $e.ts
                    last_ts = $e.ts
                    keywords = @()
                    key_event_ids = @($initialIds)
                    event_count = $initialIds.Count
                    first_event_id = if ($initialIds.Count -gt 0) { $initialIds[0] } else { $null }
                    last_event_id = if ($initialIds.Count -gt 0) { $initialIds[-1] } else { $null }
                    related_decisions = @()
                    related_tasks = @()
                    source = 'curated'
                }
                if ($order -notcontains $tid) { $order.Add($tid) }
            }
            'topic.updated' {
                $tid = Get-EventField $e 'topic_id'
                if (-not $tid -or -not $topicMap.ContainsKey($tid)) { continue }
                if (Get-EventField $e 'title') { $topicMap[$tid].title = Get-EventField $e 'title' }
                if (Get-EventField $e 'summary') { $topicMap[$tid].summary = Get-EventField $e 'summary' }
                if (Get-EventField $e 'status') { $topicMap[$tid].status = Get-EventField $e 'status' }
                $topicMap[$tid].last_ts = $e.ts
            }
            'topic.closed' {
                $tid = Get-EventField $e 'topic_id'
                if (-not $tid -or -not $topicMap.ContainsKey($tid)) { continue }
                $topicMap[$tid].status = 'completed'
                $topicMap[$tid].last_ts = $e.ts
            }
            'topic.event.linked' {
                $tid = Get-EventField $e 'topic_id'
                if (-not $tid -or -not $topicMap.ContainsKey($tid)) { continue }
                $eventIds = @(Get-EventField $e 'event_ids')
                if ($eventIds.Count -eq 0) {
                    $legacyLinkedId = Get-EventField $e 'linked_event_id'
                    if ($legacyLinkedId) { $eventIds = @($legacyLinkedId) }
                }
                foreach ($ev in $eventIds) {
                    if ($ev -and -not ($topicMap[$tid].key_event_ids -contains $ev)) {
                        $topicMap[$tid].key_event_ids += $ev
                        if (-not $topicMap[$tid].first_event_id) { $topicMap[$tid].first_event_id = $ev }
                        $topicMap[$tid].last_event_id = $ev
                    }
                }
                $topicMap[$tid].event_count = ($topicMap[$tid].key_event_ids).Count
                $topicMap[$tid].last_ts = $e.ts
            }
            default {
                $eventTopicIds = @()
                $singleTopic = Get-EventField $e 'topic_id'
                if ($singleTopic) { $eventTopicIds += $singleTopic }
                if ('topic_ids' -in $e.PSObject.Properties.Name -and $e.topic_ids) {
                    $eventTopicIds += @($e.topic_ids)
                }
                foreach ($tid in $eventTopicIds) {
                    if (-not $topicMap.ContainsKey($tid)) { continue }
                    if ($e.event -eq 'decision.recorded') {
                        $decisionId = Get-ContextEventId $e
                        if ($decisionId -and -not ($topicMap[$tid].related_decisions -contains $decisionId)) {
                            $topicMap[$tid].related_decisions += $decisionId
                        }
                    }
                    if ($e.event -in @('task.created', 'task.updated', 'task.closed')) {
                        $taskId = Get-EventField $e 'task_id'
                        if ($taskId -and -not ($topicMap[$tid].related_tasks -contains $taskId)) {
                            $topicMap[$tid].related_tasks += $taskId
                        }
                    }
                }
                # For regular events, if they have topic_ids, link them
                if ('topic_ids' -in $e.PSObject.Properties.Name -and $e.topic_ids) {
                    foreach ($tid in $e.topic_ids) {
                        if ($topicMap.ContainsKey($tid)) {
                            $eid = Get-ContextEventId $e
                            if ($eid -and -not ($topicMap[$tid].key_event_ids -contains $eid)) {
                                $topicMap[$tid].key_event_ids += $eid
                            }
                            $topicMap[$tid].event_count = ($topicMap[$tid].key_event_ids).Count
                            if (-not $topicMap[$tid].first_event_id) { $topicMap[$tid].first_event_id = $eid }
                            $topicMap[$tid].last_event_id = $eid
                            $topicMap[$tid].last_ts = $e.ts
                        }
                    }
                }
            }
        }
    }
    # Limit key_event_ids to 20 per Codex rec
    foreach ($tid in $topicMap.Keys) {
        if ($topicMap[$tid].key_event_ids.Count -gt 20) {
            $topicMap[$tid].key_event_ids = $topicMap[$tid].key_event_ids[0..19]
        }
        $topicMap[$tid].event_count = $topicMap[$tid].key_event_ids.Count
        if ($topicMap[$tid].event_count -gt 0) {
            $topicMap[$tid].first_event_id = $topicMap[$tid].key_event_ids[0]
            $topicMap[$tid].last_event_id = $topicMap[$tid].key_event_ids[-1]
        }
    }
    $topics = @($order | ForEach-Object { $topicMap[$_] })
    return [ordered]@{
        schema_version = 'conversation-esaa.topics.v0.1'
        updated = Get-IsoTimestamp
        workspace_root = $null
        topics = $topics
    }
}

function Project-TopicsMarkdown {
    param($TopicsPayload)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Topics')
    $lines.Add('')
    $lines.Add('> Generated by conversation-esaa project. Do not edit manually.')
    $lines.Add('')
    if (-not $TopicsPayload.topics -or $TopicsPayload.topics.Count -eq 0) {
        $lines.Add('_No topics yet._')
        return ($lines -join [Environment]::NewLine)
    }
    $active = @($TopicsPayload.topics | Where-Object { $_.status -eq 'active' })
    if ($active.Count -gt 0) {
        $lines.Add('## Active')
        foreach ($t in $active) {
            $lines.Add("- **$($t.id)** — $($t.title)")
            if ($t.summary) { $lines.Add("  $($t.summary)") }
            if ($t.key_event_ids -and $t.key_event_ids.Count -gt 0) {
                $lines.Add("  key events: $($t.key_event_ids -join ', ')")
            }
        }
    }
    $other = @($TopicsPayload.topics | Where-Object { $_.status -ne 'active' })
    if ($other.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Other')
        foreach ($t in $other) {
            $lines.Add("- **$($t.id)** [ $($t.status) ] — $($t.title)")
        }
    }
    return ($lines -join [Environment]::NewLine)
}

function Resolve-MemoryCliScriptForSync {
    if ($env:CONV_ESAA_MEMORY_CLI -and (Test-Path -LiteralPath $env:CONV_ESAA_MEMORY_CLI)) {
        return (Resolve-Path -LiteralPath $env:CONV_ESAA_MEMORY_CLI).Path
    }
    $bundledCandidate = Join-Path $PSScriptRoot 'memory/adapter/cli.js'
    if (Test-Path -LiteralPath $bundledCandidate) {
        return (Resolve-Path -LiteralPath $bundledCandidate).Path
    }
    $repoCandidate = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/memory/adapter/cli.js'
    if (Test-Path -LiteralPath $repoCandidate) {
        return (Resolve-Path -LiteralPath $repoCandidate).Path
    }
    $fallbackRepoCandidate = '/home/elzobrito/desenvolvimento/conversation-esaa/src/memory/adapter/cli.js'
    if (Test-Path -LiteralPath $fallbackRepoCandidate) {
        return (Resolve-Path -LiteralPath $fallbackRepoCandidate).Path
    }
    return $null
}

function Invoke-MemoryReconstructIfPresent {
    param($Paths, $Events)
    $hasMemoryEvents = @($Events | Where-Object { $_.event -like 'memory.consolidation.*' }).Count -gt 0
    $activePath = Join-Path (Join-Path $Paths.Esaa 'memory') 'active.json'
    if (-not $hasMemoryEvents -and -not (Test-Path -LiteralPath $activePath)) {
        return
    }
    $cliScript = Resolve-MemoryCliScriptForSync
    if (-not $cliScript) { return }
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) { return }
    $out = & $nodeCmd.Source $cliScript 'reconstruct-from-ledger' '--workspace' $Paths.Root '--json' 2>&1
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Failed to reconstruct memory active view from ledger: $($out -join ' ')"
    }
}

function Invoke-MemoryAccept {
    param($Paths)
    $cliScript = Resolve-MemoryCliScriptForSync
    if (-not $cliScript) { throw 'Memory-TCG Node CLI not found' }
    $nodeCmd = Get-Command node -ErrorAction Stop
    $targetId = if ($MemoryProposalId) { $MemoryProposalId } else { 'latest' }
    $rawOut = & $nodeCmd.Source $cliScript 'prepare-accept' '--workspace' $Paths.Root '--proposal-id' $targetId '--json' 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -and $exitCode -ne 0) {
        $errMsg = ($rawOut | ForEach-Object { [string]$_ }) -join "`n"
        throw "memory accept rejected (exit=$exitCode): $errMsg"
    }
    $jsonText = ($rawOut | Where-Object { $_ -is [string] }) -join "`n"
    $prep = $jsonText | ConvertFrom-Json
    $payload = $prep.event_payload
    $record = [ordered]@{
        schema_version          = 'conversation-esaa.v1'
        ts                      = Get-IsoTimestamp
        event                   = 'memory.consolidation.accepted'
        actor                   = 'assistant'
        agent_id                = $CuratorAgent
        workspace_root          = $Paths.Root
        proposal_id             = $payload.proposal_id
        snapshot_id             = $payload.snapshot_id
        watermark_event_id      = $payload.watermark_event_id
        graph_generation_id     = $payload.graph_generation_id
        previous_generation_id  = $payload.previous_generation_id
        policy_version          = $payload.policy_version
        workspace_id            = $payload.workspace_id
        active_digest           = $payload.active_digest
        active_view             = $payload.active_view
        proposal                = $payload.proposal
        graph                   = $payload.graph
        summary                 = "memory.consolidation.accepted $($payload.proposal_id) -> $($payload.graph_generation_id)"
        text                    = "Accepted memory consolidation proposal $($payload.proposal_id) producing generation $($payload.graph_generation_id)"
    }
    Append-CuratedEvent -Paths $Paths -Record $record
    $script:LastMemoryOpResult = [ordered]@{
        status              = 'OK'
        action              = 'accept'
        event_id            = $record.event_id
        proposal_id         = $payload.proposal_id
        graph_generation_id = $payload.graph_generation_id
        watermark_event_id  = $payload.watermark_event_id
        active_digest       = $payload.active_digest
    }
}

function Invoke-MemoryRollback {
    param($Paths)
    $cliScript = Resolve-MemoryCliScriptForSync
    if (-not $cliScript) { throw 'Memory-TCG Node CLI not found' }
    $nodeCmd = Get-Command node -ErrorAction Stop
    $targetGen = if ($MemoryGenerationId) { $MemoryGenerationId } else { 'previous' }
    $reasonText = if ($MemoryReason) { $MemoryReason } else { 'Explicit operator rollback' }
    $rawOut = & $nodeCmd.Source $cliScript 'prepare-rollback' '--workspace' $Paths.Root '--generation-id' $targetGen '--reason' $reasonText '--json' 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -and $exitCode -ne 0) {
        $errMsg = ($rawOut | ForEach-Object { [string]$_ }) -join "`n"
        throw "memory rollback rejected (exit=$exitCode): $errMsg"
    }
    $jsonText = ($rawOut | Where-Object { $_ -is [string] }) -join "`n"
    $prep = $jsonText | ConvertFrom-Json
    $payload = $prep.event_payload
    $record = [ordered]@{
        schema_version                 = 'conversation-esaa.v1'
        ts                             = Get-IsoTimestamp
        event                          = 'memory.consolidation.rolled_back'
        actor                          = 'assistant'
        agent_id                       = $CuratorAgent
        workspace_root                 = $Paths.Root
        workspace_id                   = $payload.workspace_id
        rolled_back_from_generation_id = $payload.rolled_back_from_generation_id
        restored_generation_id         = $payload.restored_generation_id
        reason                         = $payload.reason
        summary                        = "memory.consolidation.rolled_back $($payload.rolled_back_from_generation_id) -> $($payload.restored_generation_id)"
        text                           = "Rolled back memory generation from $($payload.rolled_back_from_generation_id) to $($payload.restored_generation_id): $($payload.reason)"
    }
    Append-CuratedEvent -Paths $Paths -Record $record
    $script:LastMemoryOpResult = [ordered]@{
        status                         = 'OK'
        action                         = 'rollback'
        event_id                       = $record.event_id
        rolled_back_from_generation_id = $payload.rolled_back_from_generation_id
        restored_generation_id         = $payload.restored_generation_id
        reason                         = $payload.reason
    }
}

function Get-ActiveMemoryProjectionBlock {
    param($Paths)
    $activeMemPath = Join-Path (Join-Path $Paths.Esaa 'memory') 'active.json'
    if (-not (Test-Path -LiteralPath $activeMemPath)) {
        return $null
    }
    $cliScript = Resolve-MemoryCliScriptForSync
    if (-not $cliScript) { return $null }
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) { return $null }
    try {
        $rawMemCtx = & $nodeCmd.Source $cliScript 'context' '--workspace' $Paths.Root '--budget-chars' '3200' '--json' 2>$null
        if ($LASTEXITCODE -eq 0 -and $rawMemCtx) {
            $memCtx = ($rawMemCtx -join "`n") | ConvertFrom-Json
            if ($memCtx.status -eq 'OK' -and $memCtx.markdown) {
                return [string]$memCtx.markdown
            }
        }
    } catch { }
    return $null
}

function Invoke-Project {
    param($Paths)

    $events = @(Get-WorkspaceEvents $Paths)
    Invoke-MemoryReconstructIfPresent -Paths $Paths -Events $events
    $tasksPayload = Project-TasksFromEvents $events
    [System.IO.File]::WriteAllText(
        $Paths.Tasks,
        (($tasksPayload | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    $tasks = $tasksPayload

    $decisionsMd = Project-DecisionsMarkdown $events
    [System.IO.File]::WriteAllText($Paths.Decisions, $decisionsMd, [System.Text.UTF8Encoding]::new($false))

    # Topics projection (ADR-009)
    $topicsPayload = Project-TopicsFromEvents $events
    $topicsPayload.workspace_root = $Paths.Root
    [System.IO.File]::WriteAllText(
        $Paths.Topics,
        (($topicsPayload | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )

    $topicsMd = Project-TopicsMarkdown $topicsPayload
    $topicsMdPath = Join-Path $Paths.Esaa 'topics.md'
    [System.IO.File]::WriteAllText($topicsMdPath, $topicsMd, [System.Text.UTF8Encoding]::new($false))

    $supersededDecisionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($de in @($events | Where-Object { $_.event -eq 'decision.recorded' })) {
        if (('supersedes' -in $de.PSObject.Properties.Name) -and $de.supersedes) {
            [void]$supersededDecisionIds.Add(([string]$de.supersedes -replace '^decision:', ''))
        }
        if (('supersedes_links' -in $de.PSObject.Properties.Name) -and $de.supersedes_links) {
            foreach ($lnk in @($de.supersedes_links)) {
                if ($lnk -and $lnk.target) {
                    [void]$supersededDecisionIds.Add(([string]$lnk.target -replace '^decision:', ''))
                }
            }
        }
    }
    $recordedDecisions = @($events | Where-Object {
        $_.event -eq 'decision.recorded' -and
        -not (('link_only' -in $_.PSObject.Properties.Name) -and $_.link_only) -and
        -not $supersededDecisionIds.Contains([string]$_.event_id)
    } | Select-Object -Last 5)
    $decisions = @($recordedDecisions | ForEach-Object { $_.decision })
    if ($decisions.Count -eq 0) {
        $decisions = @(
            'Usar estrutura separada do ESAA formal para nao poluir .roadmap.',
            'Incluir agent_id nos eventos sincronizados (grok, codex, claude, antigravity, cursor em assistant; null em user).',
            'activity.jsonl e fonte de verdade; read models sao projetados via conversation-esaa.'
        )
    }

    $recent = $events |
        Where-Object { ($_.event -notlike 'memory.*') -and ('summary' -in $_.PSObject.Properties.Name) -and $_.summary } |
        Select-Object -Last 5

    $activeTopics = @($topicsPayload.topics | Where-Object { $_.status -eq 'active' })

    $openTasks = @()
    $doneTasks = @()
    if ($tasks -and $tasks.tasks) {
        $openTasks = @($tasks.tasks | Where-Object { $_.status -in @('open', 'in_progress') })
        $doneTasks = @($tasks.tasks | Where-Object { $_.status -eq 'completed' })
    }

    $recentUserTurns = @($events |
        Where-Object { $_.event -eq 'conversation_turn' -and $_.actor -eq 'user' -and $_.summary } |
        Select-Object -Last 1)
    $recentConversationTurns = @($events |
        Where-Object { $_.event -eq 'conversation_turn' -and $_.summary } |
        Select-Object -Last 1)

    $objective = if (@($openTasks).Count -ge 1) {
        $t = $openTasks[0]
        $step = Get-EventField $t 'next_step'
        if ($step) { "$($t.title) — $step" } else { $t.title }
    } elseif ($activeTopics.Count -ge 1) {
        $topic = $activeTopics[0]
        if ($topic.summary) { "$($topic.id) — $($topic.title): $($topic.summary)" } else { "$($topic.id) — $($topic.title)" }
    } elseif ($recentUserTurns.Count -ge 1) {
        $recentUserTurns[0].summary
    } elseif ($recentConversationTurns.Count -ge 1) {
        $recentConversationTurns[0].summary
    } else {
        'Nenhum objetivo conversacional foi projetado; solicite orientação antes de agir.'
    }

    $nextAction = if (@($openTasks).Count -ge 1) {
        $t = $openTasks[0]
        $step = Get-EventField $t 'next_step'
        if ($step) { $step } else { "Trabalhar em $($t.id): $($t.title)" }
    } elseif ($activeTopics.Count -ge 1) {
        "Retomar $($activeTopics[0].id): $($activeTopics[0].title)"
    } else {
        'Confirmar com o humano qual trabalho deve ser iniciado ou retomado.'
    }

    $recentLines = @(foreach ($e in $recent) {
        $who = if ($e.actor) { $e.actor } else { 'system' }
        $hasAgent = ($e.PSObject.Properties.Name -contains 'agent_id') -and $e.agent_id
        $id = if ($hasAgent) { " ($($e.agent_id))" } else { '' }
        "- [$($e.ts)] $who$id — $($e.summary)"
    })
    if ($recentLines.Count -eq 0) { $recentLines = @('- Nenhum evento recente.') }

    $openLines = @(foreach ($t in $openTasks) {
        "- **$($t.id)** — $($t.title)"
    })
    if ($openLines.Count -eq 0) { $openLines = @('- Nenhuma tarefa aberta.') }

    $decisionBlock = ($decisions | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    $recentBlock = $recentLines -join [Environment]::NewLine
    $openBlock = $openLines -join [Environment]::NewLine

    $topicsBlock = if ($activeTopics.Count -gt 0) {
        ($activeTopics | ForEach-Object {
            $suffix = if ($_.summary) { " — $($_.summary)" } else { '' }
            "- **$($_.id)** — $($_.title)$suffix"
        }) -join [Environment]::NewLine
    } else { '- Nenhum tópico ativo.' }

    $activeMemoryMd = Get-ActiveMemoryProjectionBlock -Paths $Paths

    $stateLines = [System.Collections.Generic.List[string]]@(
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
        '## Tópicos / Assuntos Ativos'
        ''
        $topicsBlock
        ''
        '## Ultimos Eventos'
        ''
        $recentBlock
        ''
        '## Proxima Acao Recomendada'
        ''
        $nextAction
    )
    if (-not [string]::IsNullOrWhiteSpace($activeMemoryMd)) {
        $stateLines.Add('')
        $stateLines.Add($activeMemoryMd.Trim())
    }
    $state = $stateLines -join [Environment]::NewLine

    $handoffLines = [System.Collections.Generic.List[string]]@(
        '# Handoff para o Proximo Agente'
        ''
        '> Gerado automaticamente por conv-sync.ps1 project. Nao edite manualmente.'
        ''
        'Este diretorio usa um ESAA conversacional, nao o ESAA runtime formal.'
        ''
        '## Objetivo atual'
        ''
        $objective
        ''
        '## Proxima acao recomendada'
        ''
        $nextAction
        ''
        '## Decisoes vigentes'
        ''
        $decisionBlock
        ''
        '## Topicos ativos'
        ''
        $topicsBlock
        ''
        '## Tarefas abertas'
        ''
        $openBlock
        ''
        '## Eventos recentes'
        ''
        $recentBlock
    )
    if (-not [string]::IsNullOrWhiteSpace($activeMemoryMd)) {
        $handoffLines.Add('')
        $handoffLines.Add($activeMemoryMd.Trim())
    }
    $handoffTail = @(
        ''
        '## Se o resumo nao for suficiente'
        ''
        '- Consulte state.md, topics.md/topics.json, decisions.md ou tasks.json conforme a lacuna.'
        '- Use context --last 20 para uma janela filtrada; acrescente --topic-id TOP-xxx apenas com topico identificado.'
        '- Use --agent <id> somente quando precisar restringir a consulta a um agente.'
        '- Se este handoff estiver vazio ou inconsistente, execute verify e informe o impedimento.'
        ''
        '## Contrato operacional'
        ''
        '- Nao edite activity.jsonl nem os read models manualmente.'
        '- Nao trate .conversation-esaa como .roadmap.'
        '- activity.jsonl e os read models contem texto bruto das conversas; nao commite dados reais em repositorio publico.'
    )
    foreach ($tl in $handoffTail) { $handoffLines.Add($tl) }
    $handoff = $handoffLines -join [Environment]::NewLine

    [System.IO.File]::WriteAllText($Paths.State, $state.TrimEnd() + "`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($Paths.Handoff, $handoff.TrimEnd() + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Output 'project: regenerated state.md, handoff.md, tasks.json, and decisions.md'
}


function Get-TopicFieldValue {
    param($Topic, [string]$Name)
    if ($Topic -is [System.Collections.IDictionary]) {
        if ($Topic.Contains($Name)) { return $Topic[$Name] }
        return $null
    }
    if ($Topic.PSObject.Properties.Name -contains $Name) { return $Topic.$Name }
    return $null
}

function Test-TopicsProjectionMatch {
    param($ActualTopics, $ProjectedTopics)
    $aMap = @{}
    foreach ($t in @($ActualTopics)) {
        $id = [string](Get-TopicFieldValue $t 'id')
        if (-not $id) { return $false }
        $aMap[$id] = $t
    }
    $pMap = @{}
    foreach ($t in @($ProjectedTopics)) {
        $id = [string](Get-TopicFieldValue $t 'id')
        if (-not $id) { return $false }
        $pMap[$id] = $t
    }
    if ($aMap.Count -ne $pMap.Count) { return $false }
    foreach ($id in @($aMap.Keys)) {
        if (-not $pMap.ContainsKey($id)) { return $false }
        $a = $aMap[$id]
        $p = $pMap[$id]
        foreach ($field in @('title', 'summary', 'status')) {
            if ([string](Get-TopicFieldValue $a $field) -ne [string](Get-TopicFieldValue $p $field)) {
                return $false
            }
        }
        $aKeys = @($(Get-TopicFieldValue $a 'key_event_ids')) | ForEach-Object { [string]$_ }
        $pKeys = @($(Get-TopicFieldValue $p 'key_event_ids')) | ForEach-Object { [string]$_ }
        if (($aKeys -join '|') -ne ($pKeys -join '|')) { return $false }
    }
    return $true
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
    $allSeen = @{}
    $allEvents = [System.Collections.Generic.List[object]]::new()
    # Match the historical verification semantics: a creation may appear anywhere
    # in the ledger. Build this index once instead of reparsing the entire ledger
    # for every task update or close.
    $createdTaskIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)
    $createdTaskValues = [System.Collections.Generic.List[object]]::new()
    $nonStringTaskValues = [System.Collections.Generic.List[object]]::new()
    foreach ($taskLine in [System.IO.File]::ReadLines($Paths.Activity)) {
        if ([string]::IsNullOrWhiteSpace($taskLine)) { continue }
        try { $taskEvent = $taskLine | ConvertFrom-Json } catch { continue }
        if ($null -ne $taskEvent -and 'event' -in $taskEvent.PSObject.Properties.Name -and $taskEvent.event -eq 'task.created' -and 'task_id' -in $taskEvent.PSObject.Properties.Name -and $null -ne $taskEvent.task_id) {
            $createdTaskValues.Add($taskEvent.task_id)
            if ($taskEvent.task_id -is [string]) {
                [void]$createdTaskIds.Add($taskEvent.task_id)
            } else {
                $nonStringTaskValues.Add($taskEvent.task_id)
            }
        }
    }
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($Paths.Activity)) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json
        } catch {
            throw "Invalid JSON at activity.jsonl line $lineNo"
        }
        $allEvents.Add($event)
        if ('event_id' -in $event.PSObject.Properties.Name -and $event.event_id) {
            if ($allSeen.ContainsKey($event.event_id)) {
                throw "Duplicate event_id '$($event.event_id)' at line $lineNo"
            }
            $allSeen[$event.event_id] = $true
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
            if ($event.actor -eq 'assistant' -and $event.source -in @('grok', 'codex', 'claude', 'antigravity', 'cursor')) {
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
            foreach ($field in @('event_id', 'ts', 'event', 'actor', 'agent_id', 'workspace_root', 'decision')) {
                if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                    throw "Decision event missing '$field' at line $lineNo"
                }
            }
            if ('rationale' -notin $event.PSObject.Properties.Name) {
                throw "Decision event missing 'rationale' at line $lineNo"
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
                if ($event.task_id -is [string]) {
                    $priorCreated = $createdTaskIds.Contains($event.task_id)
                    $fallbackValues = $nonStringTaskValues
                } else {
                    $fallbackValues = $createdTaskValues
                }
                if (-not $priorCreated) {
                    foreach ($taskValue in $fallbackValues) {
                        if ($taskValue -eq $event.task_id) { $priorCreated = $true; break }
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

        if ($event.event -in @('topic.created', 'topic.updated', 'topic.closed', 'topic.event.linked')) {
            foreach ($field in @('event_id', 'ts', 'event', 'actor', 'agent_id', 'workspace_root', 'topic_id')) {
                if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                    throw "Topic event missing '$field' at line $lineNo"
                }
            }
            if ($event.topic_id -notmatch '^TOP-\d{3,}$') {
                throw "Invalid topic_id '$($event.topic_id)' at line $lineNo"
            }
            $eventRoot = (Resolve-Path -LiteralPath $event.workspace_root).Path
            if ($eventRoot -ne $expectedRoot) {
                throw "Event $($event.event_id) belongs to another workspace: $($event.workspace_root)"
            }
            if ($event.event -eq 'topic.created') {
                foreach ($field in @('title', 'summary', 'status')) {
                    if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                        throw "Topic created event missing '$field' at line $lineNo"
                    }
                }
            }
            if ($event.event -eq 'topic.event.linked') {
                if ('event_ids' -notin $event.PSObject.Properties.Name -or @($event.event_ids).Count -eq 0) {
                    throw "Topic link event missing 'event_ids' at line $lineNo"
                }
            }
            if (-not $seen.ContainsKey($event.event_id)) {
                $seen[$event.event_id] = $true
            }
        }

        if ($event.event -eq 'memory.consolidation.accepted') {
            foreach ($field in @('event_id', 'ts', 'event', 'actor', 'agent_id', 'workspace_root', 'proposal_id', 'snapshot_id', 'graph_generation_id', 'workspace_id', 'active_digest')) {
                if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                    throw "Memory accept event missing '$field' at line $lineNo"
                }
            }
            $eventRoot = (Resolve-Path -LiteralPath $event.workspace_root).Path
            if ($eventRoot -ne $expectedRoot) {
                throw "Event $($event.event_id) belongs to another workspace: $($event.workspace_root)"
            }
            if (-not $seen.ContainsKey($event.event_id)) {
                $seen[$event.event_id] = $true
            }
        }

        if ($event.event -eq 'memory.consolidation.rolled_back') {
            foreach ($field in @('event_id', 'ts', 'event', 'actor', 'agent_id', 'workspace_root', 'workspace_id', 'reason')) {
                if ($field -notin $event.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$event.$field)) {
                    throw "Memory rollback event missing '$field' at line $lineNo"
                }
            }
            $eventRoot = (Resolve-Path -LiteralPath $event.workspace_root).Path
            if ($eventRoot -ne $expectedRoot) {
                throw "Event $($event.event_id) belongs to another workspace: $($event.workspace_root)"
            }
            if (-not $seen.ContainsKey($event.event_id)) {
                $seen[$event.event_id] = $true
            }
        }
    }

    if (-not (Test-Path -LiteralPath $Paths.Topics)) {
        throw 'topics.json not found'
    }
    $topicsPayload = Get-Content -LiteralPath $Paths.Topics -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($topicsPayload.schema_version -ne 'conversation-esaa.topics.v0.1') {
        throw 'topics.json has invalid schema_version'
    }
    if ((Resolve-Path -LiteralPath $topicsPayload.workspace_root).Path -ne $expectedRoot) {
        throw 'topics.json workspace_root mismatch'
    }
    if (-not ($topicsPayload.PSObject.Properties.Name -contains 'topics')) {
        throw 'topics.json has no topics array'
    }

    $topicIds = @{}
    $activityEventIds = @{}
    foreach ($event in $allEvents) {
        $eid = Get-ContextEventId $event
        if ($eid) { $activityEventIds[$eid] = $true }
    }
    foreach ($topic in @($topicsPayload.topics)) {
        if (-not $topic.id -or $topic.id -notmatch '^TOP-\d{3,}$') {
            throw "topics.json has invalid topic id '$($topic.id)'"
        }
        if ($topicIds.ContainsKey($topic.id)) {
            throw "topics.json has duplicate topic id '$($topic.id)'"
        }
        $topicIds[$topic.id] = $true
        if ($topic.status -notin @('active', 'paused', 'completed', 'archived')) {
            throw "topics.json has invalid status '$($topic.status)' for $($topic.id)"
        }
        foreach ($eventId in @($topic.key_event_ids)) {
            if (-not $activityEventIds.ContainsKey($eventId)) {
                throw "topics.json references unknown event_id '$eventId'"
            }
        }
    }

    $projectedTopics = Project-TopicsFromEvents @(Get-WorkspaceEvents $Paths)
    $projectedTopics.workspace_root = $Paths.Root
    if (-not (Test-TopicsProjectionMatch -ActualTopics $topicsPayload.topics -ProjectedTopics $projectedTopics.topics)) {
        throw 'topics.json is not consistent with activity.jsonl. Repair: conversation-esaa project --workspace <path> then verify.'
    }

    Test-CursorAdapter -Paths $Paths

    $memoryDir = Join-Path $Paths.Esaa 'memory'
    $hasMemoryLedgerEvents = @($allEvents | Where-Object { $_.event -like 'memory.consolidation.*' }).Count -gt 0
    if ($hasMemoryLedgerEvents -or (Test-Path -LiteralPath $memoryDir)) {
        $cliScript = Resolve-MemoryCliScriptForSync
        $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
        if ($cliScript -and $nodeCmd) {
            $memVerifyOut = & $nodeCmd.Source $cliScript 'verify' '--workspace' $Paths.Root '--json' 2>&1
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "Memory-TCG verification failed: $($memVerifyOut -join ' ')"
            }
        }
    }

    Write-Output 'verify: ok'
}

$root = Resolve-WorkspaceRoot
$paths = Get-ConvPaths $root
if (-not (Test-Path -LiteralPath $paths.Esaa)) {
    throw "Missing .conversation-esaa at $($paths.Esaa)"
}

function Invoke-RagScheduleIfEnabled {
    param([string]$WorkspaceRoot)
    # Fail-open: never break main pipeline. Schedules async RAG refresh if enabled.
    try {
        $ragCfg = Join-Path $WorkspaceRoot '.conversation-esaa/rag/config.json'
        if (-not (Test-Path -LiteralPath $ragCfg)) { return }
        $cfg = Get-Content -LiteralPath $ragCfg -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if (-not $cfg.enabled) { return }
        $ragScript = Join-Path $PSScriptRoot 'conv-rag.ps1'
        if (-not (Test-Path -LiteralPath $ragScript)) { return }
        $null = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ragScript `
            -Action schedule -WorkspaceRoot $WorkspaceRoot 2>$null
    } catch {
        # ignore
    }
}

switch ($Command) {
    'sync-grok' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Repair-ActivityContract $paths.Activity
            $state = Load-SyncState $paths.SyncState $paths.Activity
            $null = Invoke-SyncGrok -Paths $paths -SyncState $state
            Save-SyncState $state $paths.SyncState
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        }
        try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
    }
    'sync-codex' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Repair-ActivityContract $paths.Activity
            $state = Load-SyncState $paths.SyncState $paths.Activity
            $null = Invoke-SyncCodex -Paths $paths -SyncState $state
            Save-SyncState $state $paths.SyncState
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        }
        try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
    }
    'sync-claude' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Repair-ActivityContract $paths.Activity
            $state = Load-SyncState $paths.SyncState $paths.Activity
            $null = Invoke-SyncClaude -Paths $paths -SyncState $state
            Save-SyncState $state $paths.SyncState
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        }
        try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
    }
    'sync-antigravity' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Repair-ActivityContract $paths.Activity
            $state = Load-SyncState $paths.SyncState $paths.Activity
            $null = Invoke-SyncAntigravity -Paths $paths -SyncState $state
            Save-SyncState $state $paths.SyncState
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        }
        try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
    }
    'sync-cursor' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Repair-ActivityContract $paths.Activity
            $state = Load-SyncState $paths.SyncState $paths.Activity
            $null = Invoke-SyncCursor -Paths $paths -SyncState $state
            Save-SyncState $state $paths.SyncState
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        }
        try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
    }
    'pack' {
        Invoke-Pack -Paths $paths
    }
    'project' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Invoke-Project -Paths $paths
        }
        try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
    }
    'verify' {
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
        try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
    }
    'task' {
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Invoke-TaskCommand -Paths $paths
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        }
        try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
    }
    'topic' {
        if ($TopicAction -in @('list', 'show')) {
            Invoke-TopicCommand -Paths $paths
        } else {
            Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
                Invoke-TopicCommand -Paths $paths
                Invoke-Project -Paths $paths
                Invoke-Verify -Paths $paths
            }
            try { Invoke-RagScheduleIfEnabled -WorkspaceRoot $paths.Root } catch { }
        }
    }
    'memory-accept' {
        $script:LastMemoryOpResult = $null
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Invoke-MemoryAccept -Paths $paths
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        } | Out-Null
        if ($script:LastMemoryOpResult) {
            ($script:LastMemoryOpResult | ConvertTo-Json -Depth 8) | Write-Output
        }
    }
    'memory-rollback' {
        $script:LastMemoryOpResult = $null
        Invoke-WithPipelineLock -WorkspaceRoot $paths.Root -CommandName $Command -TimeoutSeconds $LockTimeoutSeconds -Body {
            Invoke-MemoryRollback -Paths $paths
            Invoke-Project -Paths $paths
            Invoke-Verify -Paths $paths
        } | Out-Null
        if ($script:LastMemoryOpResult) {
            ($script:LastMemoryOpResult | ConvertTo-Json -Depth 8) | Write-Output
        }
    }
}
