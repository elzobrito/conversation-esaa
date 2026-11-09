#requires -Version 7.0
param(
    [string]$WorkspaceRoot,
    [ValidateSet('sessionStart', 'beforeSubmitPrompt', 'afterAgentResponse', 'stop')]
    [string]$Event
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-HookWorkspace {
    if ($WorkspaceRoot) {
        try { return (Resolve-Path -LiteralPath $WorkspaceRoot).Path } catch { }
    }
    $esaaDir = Split-Path -Parent $PSScriptRoot
    $root = Split-Path -Parent $esaaDir
    try { return (Resolve-Path -LiteralPath $root).Path } catch { return $root }
}

function Write-HookResult {
    param([hashtable]$Result = @{})
    [Console]::Out.WriteLine(($Result | ConvertTo-Json -Compress -Depth 6))
}

function Write-HookLog {
    param([string]$Workspace, [string]$Message)
    try {
        $logPath = Join-Path $Workspace '.conversation-esaa\cursor-hook.log'
        $line = "{0} {1}`n" -f ([DateTimeOffset]::Now.ToString('o')), $Message
        [System.IO.File]::AppendAllText($logPath, $line, [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

function Get-PayloadProperty {
    param($Payload, [string]$Name)
    if ($null -eq $Payload) { return $null }
    if ($Payload -is [System.Collections.IDictionary]) {
        if ($Payload.Contains($Name)) { return $Payload[$Name] }
        return $null
    }
    if ($Payload.PSObject.Properties.Name -contains $Name) { return $Payload.$Name }
    return $null
}

function Get-InjectedPath {
    param([string]$Workspace)
    Join-Path $Workspace '.conversation-esaa\run\cursor-injected.json'
}

function Test-AlreadyInjected {
    param([string]$Workspace, [string]$ConversationId)
    if ([string]::IsNullOrWhiteSpace($ConversationId)) { return $false }
    $path = Get-InjectedPath $Workspace
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $payload = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($payload.ids) -contains $ConversationId
    } catch {
        return $false
    }
}

function Set-Injected {
    param([string]$Workspace, [string]$ConversationId)
    if ([string]::IsNullOrWhiteSpace($ConversationId)) { return }
    $path = Get-InjectedPath $Workspace
    $dir = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ids = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($id in @($existing.ids)) {
                if ($id) { [void]$ids.Add([string]$id) }
            }
        } catch { }
    }
    if ($ids -notcontains $ConversationId) { [void]$ids.Add($ConversationId) }
    if ($ids.Count -gt 64) {
        $ids = [System.Collections.Generic.List[string]]::new($ids.GetRange($ids.Count - 64, 64))
    }
    $doc = [ordered]@{
        schema_version = 'conversation-esaa.cursor-injected.v1'
        ids = @($ids)
    }
    [System.IO.File]::WriteAllText(
        $path,
        (($doc | ConvertTo-Json -Depth 4) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Invoke-PackText {
    param([string]$Workspace)
    $sync = Join-Path $Workspace '.conversation-esaa\bin\conv-sync.ps1'
    if (-not (Test-Path -LiteralPath $sync)) {
        return "cold-start pack unavailable; run verify."
    }
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $output = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sync pack -WorkspaceRoot $Workspace 2>&1
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        return "Handoff pack could not be built. Run verify and repair via project/install --agent cursor."
    }
    return ($output | Out-String).Trim()
}

function Invoke-CursorSync {
    param(
        [string]$Workspace,
        [string]$Role,
        [string]$Text,
        [string]$SessionId,
        [string]$TranscriptPath,
        [int]$SourceIndex = -1
    )
    $cli = Join-Path $Workspace '.conversation-esaa\bin\conversation-esaa.ps1'
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
        'sync', '--agent', 'cursor', '--workspace', $Workspace, '--SkipIfLocked'
    )
    if ($SessionId) { $args += '-CursorSessionId', $SessionId }
    if ($Role -and $Text) {
        $args += '-CursorRole', $Role, '-CursorPromptStdin'
    }
    if ($SourceIndex -ge 0) { $args += '-CursorSourceIndex', "$SourceIndex" }
    if ($TranscriptPath) { $args += '-CursorTranscriptPath', $TranscriptPath }
    if ($Role -and $Text) {
        $syncOutput = ($Text | & $pwshExe @args 2>&1 | Out-String).Trim()
    } else {
        $syncOutput = (& $pwshExe @args 2>&1 | Out-String).Trim()
    }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "sync exit=$LASTEXITCODE output=$syncOutput"
    }
    return $syncOutput
}

$workspace = Resolve-HookWorkspace
$result = [ordered]@{}

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $payload = $raw | ConvertFrom-Json
    }
    $eventName = $Event
    if (-not $eventName) {
        $eventName = [string](Get-PayloadProperty $payload 'hook_event_name')
    }
    $conversationId = [string](Get-PayloadProperty $payload 'conversation_id')
    if (-not $conversationId) {
        $conversationId = [string](Get-PayloadProperty $payload 'session_id')
    }
    $transcript = [string](Get-PayloadProperty $payload 'transcript_path')

    switch ($eventName) {
        'sessionStart' {
            $pack = Invoke-PackText -Workspace $workspace
            $result['additional_context'] = $pack
            Set-Injected -Workspace $workspace -ConversationId $conversationId
            Write-HookLog $workspace "sessionStart inject conversationId=$conversationId"
        }
        'beforeSubmitPrompt' {
            $prompt = [string](Get-PayloadProperty $payload 'prompt')
            if (-not [string]::IsNullOrWhiteSpace($prompt)) {
                $null = Invoke-CursorSync `
                    -Workspace $workspace `
                    -Role 'user' `
                    -Text $prompt `
                    -SessionId $conversationId
            }
            $result['continue'] = $true
            if ($conversationId -and -not (Test-AlreadyInjected -Workspace $workspace -ConversationId $conversationId)) {
                $result['additional_context'] = Invoke-PackText -Workspace $workspace
                Set-Injected -Workspace $workspace -ConversationId $conversationId
                Write-HookLog $workspace "beforeSubmitPrompt capture+inject conversationId=$conversationId"
            } else {
                Write-HookLog $workspace "beforeSubmitPrompt capture conversationId=$conversationId"
            }
        }
        'afterAgentResponse' {
            $text = [string](Get-PayloadProperty $payload 'text')
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $null = Invoke-CursorSync `
                    -Workspace $workspace `
                    -Role 'assistant' `
                    -Text $text `
                    -SessionId $conversationId
            }
            Write-HookLog $workspace "afterAgentResponse capture conversationId=$conversationId"
        }
        'stop' {
            if ($transcript -and (Test-Path -LiteralPath $transcript)) {
                $null = Invoke-CursorSync `
                    -Workspace $workspace `
                    -Role '' `
                    -Text '' `
                    -SessionId $conversationId `
                    -TranscriptPath $transcript
            }
            Write-HookLog $workspace "stop conversationId=$conversationId"
        }
        default {
            Write-HookLog $workspace "skip unknown event=$eventName"
        }
    }
} catch {
    Write-HookLog $workspace "fail_open error=$($_.Exception.Message)"
    if (-not $result.Contains('continue')) { $result['continue'] = $true }
}

Write-HookResult -Result $result
exit 0
