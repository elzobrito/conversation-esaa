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
    [string]$AntigravityTranscriptPath,
    [string]$AntigravityConversationId,
    [string]$CursorSessionId,
    [string]$CursorTranscriptPath,
    [string]$CursorPrompt,
    [switch]$CursorPromptStdin,
    [ValidateSet('user', 'assistant')]
    [string]$CursorRole,
    [int]$CursorSourceIndex = -1,
    [int]$BudgetTokens = 0,
    [int]$BudgetChars = 0,
    [Nullable[int]]$MaxPerSection = $null,
    [string]$Mode = 'normal',
    [int]$Seed = 42,
    [string]$Budget = 'all',
    [string]$ProposalId,
    [string]$GenerationId,
    [string]$Reason,
    [int]$MaxNodes = 0,
    [int]$MaxEdges = 0,
    [switch]$Accept,
    [switch]$Trust,
    [switch]$Watcher,
    [switch]$SkipIfLocked,
    [int]$Last = 0,
    [string]$Before,
    [string]$Around,
    [int]$Window = 1,
    [string]$Topic,
    [switch]$Json,
    [string]$Rationale,
    [string]$Decision,
    [string]$SourceEvent,
    [string]$Supersedes,
    [string]$SupersededBy,
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
    [string]$CommandPath,
    [string]$BaseUrl,
    [string]$Model,
    [int]$TimeoutSeconds = 0,
    [int]$TopK = 0,
    [double]$MinScore = -1,
    [switch]$Force,
    [switch]$Purge,
    [parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-LongOptionKey {
    param([string]$Name)
    return (($Name -replace '[-_]', '').ToLowerInvariant())
}

function Convert-LongOptionValue {
    param(
        [System.Management.Automation.ParameterMetadata]$Metadata,
        [string]$Option,
        [string]$Value
    )

    $targetType = $Metadata.ParameterType
    if ($targetType.IsArray) {
        $targetType = $targetType.GetElementType()
    }
    try {
        $converted = [System.Management.Automation.LanguagePrimitives]::ConvertTo(
            $Value,
            $targetType,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "Option --$Option has invalid value '$Value'."
    }

    foreach ($attribute in $Metadata.Attributes) {
        if (
            $attribute -is [System.Management.Automation.ValidateSetAttribute] -and
            $attribute.ValidValues -inotcontains [string]$converted
        ) {
            $expected = $attribute.ValidValues -join ', '
            throw "Option --$Option has invalid value '$Value'. Expected one of: $expected."
        }
    }
    return $converted
}

function Initialize-LongOptions {
    param(
        [System.Collections.IDictionary]$Parameters,
        [System.Collections.IDictionary]$NativeBound
    )

    if (-not $script:Rest) { return }

    $optionMap = @{}
    foreach ($entry in $Parameters.GetEnumerator()) {
        $canonical = [string]$entry.Key
        if ($canonical -in @('Command', 'Rest')) { continue }
        foreach ($spelling in @($canonical) + @($entry.Value.Aliases)) {
            $key = ConvertTo-LongOptionKey $spelling
            if (-not $optionMap.ContainsKey($key)) {
                $optionMap[$key] = $canonical
            }
        }
    }
    foreach ($override in @{
        source  = 'SourceEvent'
        command = 'CommandPath'
        timeout = 'TimeoutSeconds'
    }.GetEnumerator()) {
        $optionMap[$override.Key] = $override.Value
    }

    $remaining = [System.Collections.Generic.List[string]]::new()
    $normalized = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    for ($index = 0; $index -lt $script:Rest.Count; $index++) {
        $token = [string]$script:Rest[$index]
        if ($token -notmatch '^--([^=]+)(?:=(.*))?$') {
            $remaining.Add($token)
            continue
        }

        $option = $Matches[1]
        $hasAttachedValue = $token.Contains('=')
        $attachedValue = if ($hasAttachedValue) { $Matches[2] } else { $null }
        $key = ConvertTo-LongOptionKey $option
        if (-not $optionMap.ContainsKey($key)) {
            $remaining.Add($token)
            continue
        }

        $canonical = $optionMap[$key]
        $metadata = $Parameters[$canonical]
        $isSwitch = (
            $metadata.ParameterType -eq
            [System.Management.Automation.SwitchParameter]
        )
        if ($NativeBound.Contains($canonical)) {
            throw "Option --$option conflicts with PowerShell parameter -$canonical."
        }
        if ($isSwitch) {
            if ($hasAttachedValue) {
                throw "Option --$option does not accept a value."
            }
            if (-not $normalized.Add($canonical)) {
                throw "Option --$option was specified more than once."
            }
            Set-Variable -Scope Script -Name $canonical -Value $true
            continue
        }

        if ($hasAttachedValue) {
            if ([string]::IsNullOrEmpty($attachedValue)) {
                throw "Option --$option requires a value."
            }
            $rawValue = $attachedValue
        } else {
            if (
                ($index + 1) -ge $script:Rest.Count -or
                [string]$script:Rest[$index + 1] -like '--*'
            ) {
                throw "Option --$option requires a value."
            }
            $rawValue = [string]$script:Rest[++$index]
        }

        $converted = Convert-LongOptionValue `
            -Metadata $metadata `
            -Option $option `
            -Value $rawValue
        if ($metadata.ParameterType.IsArray) {
            $existing = @(Get-Variable -Scope Script -Name $canonical -ValueOnly)
            if ($existing.Count -eq 1 -and $null -eq $existing[0]) {
                $existing = @()
            }
            Set-Variable `
                -Scope Script `
                -Name $canonical `
                -Value @($existing + $converted)
            [void]$normalized.Add($canonical)
        } else {
            if (-not $normalized.Add($canonical)) {
                throw "Option --$option was specified more than once."
            }
            Set-Variable -Scope Script -Name $canonical -Value $converted
        }
    }
    $script:Rest = @($remaining)
}

$nativeBoundParameters = @{}
foreach ($key in $PSBoundParameters.Keys) {
    $nativeBoundParameters[$key] = $true
}
Initialize-LongOptions `
    -Parameters $MyInvocation.MyCommand.Parameters `
    -NativeBound $nativeBoundParameters

$binDir = $PSScriptRoot
$convCli = Join-Path $binDir 'conversation-esaa.ps1'
$convSync = Join-Path $binDir 'conv-sync.ps1'
$convBootstrap = Join-Path $binDir 'conv-bootstrap.ps1'
$codexWatch = Join-Path $binDir 'codex-watch.ps1'
$antigravityHook = Join-Path $binDir 'antigravity-hook-sync.ps1'
$cursorHook = Join-Path $binDir 'cursor-hook.ps1'
$convRag = Join-Path $binDir 'conv-rag.ps1'
$convMemory = Join-Path $binDir 'conv-memory.ps1'

function Resolve-WorkspacePath {
    if ($Workspace) { return (Resolve-Path -LiteralPath $Workspace).Path }
    if ($env:GROK_WORKSPACE_ROOT) { return $env:GROK_WORKSPACE_ROOT }
    $parent = Split-Path -Parent (Split-Path -Parent $binDir)
    return (Resolve-Path -LiteralPath $parent).Path
}

function Invoke-ConvSyncCli {
    param(
        [string]$SyncCommand,
        [string[]]$Extra = @(),
        [switch]$PipeStdin,
        [string]$StdinText
    )
    $ws = Resolve-WorkspacePath
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $convSync,
        $SyncCommand, '-WorkspaceRoot', $ws
    ) + $Extra
    if ($PipeStdin) { $StdinText | & $pwshExe @args } else { & $pwshExe @args }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Show-Help {
    @'
Conversation ESAA v1.3.1

Usage:
  conversation-esaa init --workspace <path>
  conversation-esaa enable-hooks --agent <grok|claude|codex|antigravity|cursor> --workspace <path> [--trust] [--watcher]
  conversation-esaa sync --agent <grok|claude|codex|antigravity|cursor> --workspace <path>
  conversation-esaa sync --agent cursor --workspace <path> -CursorRole <user|assistant> -CursorPromptStdin
  conversation-esaa pack --workspace <path> [--budget-tokens N] [--budget-chars N]
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
  conversation-esaa rag enable|status|refresh|disable [--workspace <path>] [--command PATH] [--purge] [--force] [--json]
  conversation-esaa search "<query>" [--workspace <path>] [--top-k N] [--min-score F] [--json]
  conversation-esaa sonhar|dream [--workspace <path>] [--accept] [--mode shadow|manual] [--seed N] [--budget all|N] [--json]
  conversation-esaa memory status|sleep|sonhar|dream|inspect|diff|accept|rollback|context|verify [--workspace <path>] [--accept] [--mode shadow|manual] [--seed N] [--budget all|N] [--proposal-id ID] [--generation-id ID] [--topic-id TOP-001] [--budget-chars N] [--max-per-section N] [--json]
'@ | Write-Output
}

function Invoke-ConvMemory {
    param([string[]]$Extra = @())
    if (-not (Test-Path -LiteralPath $convMemory)) {
        throw "Memory adapter not found: $convMemory"
    }
    $ws = Resolve-WorkspacePath
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $convMemory,
        '-WorkspaceRoot', $ws
    ) + $Extra
    if ($Agent) { $args += @('-Agent', $Agent) }
    & $pwshExe @args
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-ConvRag {
    param([string[]]$Extra = @())
    if (-not (Test-Path -LiteralPath $convRag)) {
        throw "RAG adapter not found: $convRag"
    }
    $ws = Resolve-WorkspacePath
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $convRag,
        '-WorkspaceRoot', $ws
    ) + $Extra
    & pwsh @args
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$sub = if ($Rest -and $Rest.Count -ge 1) { $Rest[0] } else { $null }

switch ($Command) {
    'help' { Show-Help }
    'init' {
        $ws = Resolve-WorkspacePath
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $convBootstrap -WorkspaceRoot $ws
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    'sync' {
        if (-not $Agent) { throw 'sync requires --agent grok|claude|codex|antigravity|cursor' }
        if ($Mode -notin @('normal', 'compact')) {
            throw "Option --Mode has invalid value '$Mode'. Expected one of: normal, compact."
        }
        $map = @{ grok = 'sync-grok'; codex = 'sync-codex'; claude = 'sync-claude'; antigravity = 'sync-antigravity'; cursor = 'sync-cursor' }
        if ($Agent -notin $map.Keys) { throw "Unknown agent: $Agent" }
        $extra = @()
        if ($Mode -eq 'compact') { $extra += '-Mode', 'compact' }
        if ($SkipIfLocked) { $extra += '-SkipIfLocked' }
        if ($GrokSessionId) { $extra += '-GrokSessionId', $GrokSessionId }
        if ($CodexSessionPath) { $extra += '-CodexSessionPath', $CodexSessionPath }
        if ($ClaudeSessionPath) { $extra += '-ClaudeSessionPath', $ClaudeSessionPath }
        if ($AntigravityTranscriptPath) { $extra += '-AntigravityTranscriptPath', $AntigravityTranscriptPath }
        if ($AntigravityConversationId) { $extra += '-AntigravityConversationId', $AntigravityConversationId }
        if ($CursorSessionId) { $extra += '-CursorSessionId', $CursorSessionId }
        if ($CursorTranscriptPath) { $extra += '-CursorTranscriptPath', $CursorTranscriptPath }
        if ($CursorPromptStdin -and ($Agent -ne 'cursor' -or $CursorPrompt)) { throw 'CursorPromptStdin requires cursor and cannot be combined with CursorPrompt' }
        $promptInput = $null
        if ($CursorPromptStdin) { $promptInput = [Console]::In.ReadToEnd(); $extra += '-CursorPromptStdin' }
        if ($CursorPrompt) { $extra += '-CursorPrompt', $CursorPrompt }
        if ($CursorRole) { $extra += '-CursorRole', $CursorRole }
        if ($CursorSourceIndex -ge 0) { $extra += '-CursorSourceIndex', "$CursorSourceIndex" }
        Invoke-ConvSyncCli -SyncCommand $map[$Agent] -Extra $extra -PipeStdin:$CursorPromptStdin -StdinText $promptInput
    }
    'project' { Invoke-ConvSyncCli -SyncCommand 'project' }
    'verify' { Invoke-ConvSyncCli -SyncCommand 'verify' }
    'pack' {
        $extra = @()
        if ($BudgetTokens -gt 0) { $extra += '-BudgetTokens', "$BudgetTokens" }
        if ($BudgetChars -gt 0) { $extra += '-BudgetChars', "$BudgetChars" }
        Invoke-ConvSyncCli -SyncCommand 'pack' -Extra $extra
    }
    'enable-hooks' {
        if (-not $Agent) { throw 'enable-hooks requires --agent grok|claude|codex|antigravity|cursor' }
        $ws = Resolve-WorkspacePath
        $grokDir = Join-Path $ws '.grok\hooks'
        $claudeDir = Join-Path $ws '.claude'
        $agentsDir = Join-Path $ws '.agents'
        $cursorDir = Join-Path $ws '.cursor'
        New-Item -ItemType Directory -Force -Path $grokDir, $claudeDir, $agentsDir, $cursorDir | Out-Null
        $pwshExe = [string](Get-Command pwsh -ErrorAction Stop).Source
        function Quote-HookPart([string]$Value) { return '"' + ($Value -replace '"', '"') + '"' }
        $cmdGrok = "$(Quote-HookPart $pwshExe) -NoProfile -ExecutionPolicy Bypass -File $(Quote-HookPart $convCli) sync --agent grok --workspace $(Quote-HookPart $ws) --SkipIfLocked"
        $cmdGrokCompact = "$cmdGrok --Mode compact"
        $cmdClaude = "$(Quote-HookPart $pwshExe) -NoProfile -ExecutionPolicy Bypass -File $(Quote-HookPart $convCli) sync --agent claude --workspace $(Quote-HookPart $ws) --SkipIfLocked"
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
            $claudePath = Join-Path $claudeDir 'settings.json'
            $claudeCfg = [ordered]@{}
            $originalBytes = $null
            if (Test-Path -LiteralPath $claudePath) {
                $item = Get-Item -LiteralPath $claudePath -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Claude settings symlinks are not supported for enable-hooks' }
                $originalBytes = [IO.File]::ReadAllBytes($claudePath)
                $claudeCfg = ([Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xFEFF)) | ConvertFrom-Json -AsHashtable
                if ($claudeCfg -isnot [System.Collections.IDictionary]) { throw 'Claude settings must be a JSON object' }
            }
            if (-not $claudeCfg.Contains('hooks')) { $claudeCfg['hooks'] = [ordered]@{} }
            if ($claudeCfg['hooks'] -isnot [System.Collections.IDictionary]) { throw 'Claude settings hooks must be a JSON object' }
            function Test-CanonicalClaudeHook([string]$CommandText, [string]$EventName) {
                if ([string]::IsNullOrWhiteSpace($CommandText)) { return $false }
                $tokens = $null; $parseErrors = $null
                $ast = [Management.Automation.Language.Parser]::ParseInput("& " + $CommandText, [ref]$tokens, [ref]$parseErrors)
                if (@($parseErrors).Count -ne 0 -or @($ast.EndBlock.Statements).Count -ne 1) { return $false }
                $statement = $ast.EndBlock.Statements[0]
                if ($statement -isnot [Management.Automation.Language.PipelineAst] -or @($statement.PipelineElements).Count -ne 1) { return $false }
                $cmd = $statement.PipelineElements[0]
                if ($cmd -isnot [Management.Automation.Language.CommandAst] -or @($cmd.Redirections).Count -gt 0) { return $false }
                $parts = [System.Collections.Generic.List[string]]::new()
                foreach ($element in $cmd.CommandElements) {
                    if ($element -is [Management.Automation.Language.StringConstantExpressionAst]) { $parts.Add([string]$element.Value) }
                    elseif ($element -is [Management.Automation.Language.CommandParameterAst] -and $null -eq $element.Argument) { $parts.Add('-' + $element.ParameterName) }
                    else { return $false }
                }
                if ($parts.Count -lt 12) { return $false }
                $program = [IO.Path]::GetFileName($parts[0].Replace('\', '/'))
                if ($program -notin @('pwsh','pwsh.exe')) { return $false }
                if ($parts[1] -ine '-NoProfile' -or $parts[2] -ine '-ExecutionPolicy' -or $parts[3] -ine 'Bypass' -or $parts[4] -ine '-File' -or $parts[6] -ine 'sync' -or $parts[7] -ine '--agent' -or $parts[8] -ine 'claude' -or $parts[9] -ine '--workspace') { return $false }
                $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
                try {
                    if (-not [string]::Equals([IO.Path]::GetFullPath($parts[5]), [IO.Path]::GetFullPath($convCli), $pathComparison)) { return $false }
                    if (-not [string]::Equals([IO.Path]::GetFullPath($parts[10]), [IO.Path]::GetFullPath($ws), $pathComparison)) { return $false }
                } catch { return $false }
                $tail = @($parts | Select-Object -Skip 11) -join ' '
                if ($EventName -eq 'PreCompact') { return $tail -ieq '--SkipIfLocked --Mode compact' -or $tail -ieq '--Mode compact --SkipIfLocked' }
                return $tail -ieq '--SkipIfLocked'
            }
            foreach ($spec in @(
                @{ Event = 'UserPromptSubmit'; Command = $cmdClaude; Timeout = 20 },
                @{ Event = 'Stop'; Command = $cmdClaude; Timeout = 30 },
                @{ Event = 'PreCompact'; Command = $cmdClaudeCompact; Timeout = 30 }
            )) {
                $eventName = $spec.Event
                $groups = [System.Collections.Generic.List[object]]::new()
                if ($claudeCfg['hooks'].Contains($eventName)) {
                    $originalGroups = $claudeCfg['hooks'][$eventName]
                    if ($originalGroups -isnot [array]) { throw "Claude hooks $eventName must be an array" }
                    foreach ($group in $originalGroups) {
                        if ($group -isnot [System.Collections.IDictionary] -or -not $group.Contains('hooks') -or $group['hooks'] -isnot [array]) { throw "Claude hooks $eventName contains an invalid group" }
                        $remaining = [System.Collections.Generic.List[object]]::new()
                        foreach ($hook in $group['hooks']) {
                            if ($hook -isnot [System.Collections.IDictionary]) { throw "Claude hooks $eventName contains an invalid hook" }
                            $command = if ($hook.Contains('command')) { [string]$hook['command'] } else { '' }
                            # Only replace commands exactly generated by this
                            # runtime. Preserve wrappers and ambiguous commands.
                            $isOurs = Test-CanonicalClaudeHook -CommandText $command -EventName $eventName
                            if ($isOurs) {
                                $extraGroupKeys = @($group.Keys | Where-Object { $_ -ne 'hooks' })
                                $extraHookKeys = @($hook.Keys | Where-Object { $_ -notin @('type', 'command', 'timeout') })
                                if ($extraGroupKeys.Count -gt 0 -or $extraHookKeys.Count -gt 0 -or $hook['type'] -ne 'command' -or $hook['timeout'] -ne $spec.Timeout) {
                                    throw "Claude hook $eventName has customized metadata; resolve it before enabling hooks"
                                }
                            } else { $remaining.Add($hook) }
                        }
                        if ($remaining.Count -gt 0 -or $group['hooks'].Count -eq 0) { $group['hooks'] = @($remaining); $groups.Add($group) }
                    }
                }
                $groups.Add(@{ hooks = @(@{ type = 'command'; command = $spec.Command; timeout = $spec.Timeout }) })
                $claudeCfg['hooks'][$eventName] = @($groups)
            }
            $claudeJsonText = ($claudeCfg | ConvertTo-Json -Depth 100 -WarningAction Stop) + "`n"
            $tempPath = Join-Path $claudeDir ('.settings.json.tmp-' + [guid]::NewGuid().ToString('N'))
            try {
                [IO.File]::WriteAllText($tempPath, $claudeJsonText, [Text.UTF8Encoding]::new($false))
                if ($null -ne $originalBytes) {
                    if (-not (Test-Path -LiteralPath $claudePath)) { throw 'Claude settings changed concurrently' }
                    $currentBytes = [IO.File]::ReadAllBytes($claudePath)
                    if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($originalBytes, $currentBytes)) { throw 'Claude settings changed concurrently' }
                    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($tempPath, [IO.File]::GetUnixFileMode($claudePath)) }
                } elseif (Test-Path -LiteralPath $claudePath) { throw 'Claude settings changed concurrently' }
                [IO.File]::Move($tempPath, $claudePath, $true)
            } finally {
                if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
            }
            Write-Output 'enable-hooks: merged .claude/settings.json'
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
        if ($Agent -eq 'antigravity') {
            if (-not (Test-Path -LiteralPath $antigravityHook)) {
                throw "Antigravity hook wrapper not found: $antigravityHook"
            }
            $hooksPath = Join-Path $agentsDir 'hooks.json'
            $hooksConfig = [ordered]@{}
            if (Test-Path -LiteralPath $hooksPath) {
                try {
                    $existing = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                    foreach ($key in $existing.Keys) { $hooksConfig[$key] = $existing[$key] }
                } catch {
                    throw "Invalid existing Antigravity hooks file: $hooksPath"
                }
            }
            $hookCommand = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$antigravityHook`" -WorkspaceRoot `"$ws`""
            $hooksConfig['conversation-esaa'] = [ordered]@{
                Stop = @(@{ type = 'command'; command = $hookCommand; timeout = 60 })
            }
            [System.IO.File]::WriteAllText(
                $hooksPath,
                (($hooksConfig | ConvertTo-Json -Depth 10) + "`n"),
                [System.Text.UTF8Encoding]::new($false)
            )
            Write-Output 'enable-hooks: merged conversation-esaa into .agents/hooks.json'
        }
        if ($Agent -eq 'cursor') {
            if (-not (Test-Path -LiteralPath $cursorHook)) {
                throw "Cursor hook wrapper not found: $cursorHook"
            }
            $hooksPath = Join-Path $cursorDir 'hooks.json'
            $hooksConfig = [ordered]@{ version = 1; hooks = [ordered]@{} }
            if (Test-Path -LiteralPath $hooksPath) {
                try {
                    $existing = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
                    foreach ($key in $existing.Keys) { $hooksConfig[$key] = $existing[$key] }
                    if (-not $hooksConfig.Contains('hooks') -or $null -eq $hooksConfig['hooks']) {
                        $hooksConfig['hooks'] = [ordered]@{}
                    }
                } catch {
                    throw "Invalid existing Cursor hooks file: $hooksPath"
                }
            }
            $pwshExe = [string](Get-Command pwsh -ErrorAction Stop).Source
            function New-CursorHookCommand([string]$EventName) {
                return "$(Quote-HookPart $pwshExe) -NoProfile -ExecutionPolicy Bypass -File $(Quote-HookPart $cursorHook) -WorkspaceRoot $(Quote-HookPart $ws) -Event $EventName"
            }
            $cursorHooks = $hooksConfig['hooks']
            if ($cursorHooks -isnot [System.Collections.IDictionary]) {
                $cursorHooks = [ordered]@{}
                $hooksConfig['hooks'] = $cursorHooks
            }
            foreach ($pair in @(
                @{ Name = 'sessionStart'; Timeout = 20 },
                @{ Name = 'beforeSubmitPrompt'; Timeout = 20 },
                @{ Name = 'afterAgentResponse'; Timeout = 20 }
            )) {
                $eventName = $pair.Name
                $kept = [System.Collections.Generic.List[object]]::new()
                foreach ($entry in @($cursorHooks[$eventName] | Where-Object { $null -ne $_ })) {
                    $command = if ($entry -is [System.Collections.IDictionary]) {
                        [string]$entry['command']
                    } else {
                        [string]$entry.command
                    }
                    if ($command -and $command -notmatch 'cursor-hook\.ps1') {
                        [void]$kept.Add($entry)
                    }
                }
                [void]$kept.Add(@{
                    command = (New-CursorHookCommand $eventName)
                    timeout = $pair.Timeout
                })
                $cursorHooks[$eventName] = @($kept)
            }
            $hooksConfig['version'] = 1
            [System.IO.File]::WriteAllText(
                $hooksPath,
                (($hooksConfig | ConvertTo-Json -Depth 10) + "`n"),
                [System.Text.UTF8Encoding]::new($false)
            )
            Write-Output 'enable-hooks: merged conversation-esaa into .cursor/hooks.json'
        }
        Invoke-ConvSyncCli -SyncCommand 'verify'
    }
    'context' {
        $extra = @()
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
        if ($Supersedes) { $extra += '-DecisionSupersedes', $Supersedes }
        if ($SupersededBy) { $extra += '-DecisionSupersededBy', $SupersededBy }
        Invoke-ConvSyncCli -SyncCommand 'decide' -Extra $extra
    }
    'task' {
        if (-not $sub) { throw 'task requires create|update|close' }
        $extra = @('-TaskAction', $sub)
        if ($Agent) { $extra += @('-CuratorAgent', $Agent) }
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
        if ($Agent) { $extra += @('-CuratorAgent', $Agent) }
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
    'rag' {
        if (-not $sub) { throw 'rag requires enable|status|refresh|disable' }
        $extra = @('-Action', $sub)
        if ($CommandPath) { $extra += '-CommandPath', $CommandPath }
        if ($BaseUrl) { $extra += '-BaseUrl', $BaseUrl }
        if ($Model) { $extra += '-Model', $Model }
        if ($TimeoutSeconds -gt 0) { $extra += '-TimeoutSeconds', "$TimeoutSeconds" }
        if ($Force) { $extra += '-Force' }
        if ($Purge) { $extra += '-Purge' }
        if ($Json) { $extra += '-Json' }
        Invoke-ConvRag -Extra $extra
    }
    'search' {
        $q = if ($Rest -and $Rest.Count -ge 1) { ($Rest -join ' ').Trim() } else { $Title }
        if ([string]::IsNullOrWhiteSpace($q)) { throw 'search requires query text' }
        $tk = if ($TopK -gt 0) { $TopK } else { 5 }
        $ms = if ($MinScore -ge 0) { $MinScore } else { 0.25 }
        $extra = @('-Action', 'search', '-Query', $q, '-TopK', "$tk", '-MinScore', "$ms", '-Json')
        Invoke-ConvRag -Extra $extra
    }
    { $_ -in @('sonhar', 'dream', 'sleep') } {
        $sleepMode = if ($PSBoundParameters.ContainsKey('Mode') -or $Mode -ne 'normal') { $Mode } else { 'shadow' }
        $extra = @('-Action', 'sleep', '-Mode', $sleepMode, '-Seed', "$Seed", '-Budget', $Budget)
        if ($MaxNodes -gt 0) { $extra += @('-MaxNodes', "$MaxNodes") }
        if ($MaxEdges -gt 0) { $extra += @('-MaxEdges', "$MaxEdges") }
        if ($Accept) { $extra += '-Accept' }
        if ($Json) { $extra += '-Json' }
        Invoke-ConvMemory -Extra $extra
    }
    'memory' {
        $memAction = if ($sub) { $sub } else { 'status' }
        if ($memAction -in @('sonhar', 'dream')) { $memAction = 'sleep' }
        $extra = @('-Action', $memAction)
        switch ($memAction) {
            'status' {
                if ($Json) { $extra += '-Json' }
            }
            'sleep' {
                $sleepMode = if ($PSBoundParameters.ContainsKey('Mode') -or $Mode -ne 'normal') { $Mode } else { 'shadow' }
                $extra += @('-Mode', $sleepMode, '-Seed', "$Seed", '-Budget', $Budget)
                if ($MaxNodes -gt 0) { $extra += @('-MaxNodes', "$MaxNodes") }
                if ($MaxEdges -gt 0) { $extra += @('-MaxEdges', "$MaxEdges") }
                if ($Accept) { $extra += '-Accept' }
                if ($Json) { $extra += '-Json' }
            }
            'inspect' {
                $pidVal = if ($ProposalId) { $ProposalId } elseif ($Rest.Count -ge 2) { $Rest[1] } else { 'latest' }
                $extra += @('-ProposalId', $pidVal)
                if ($Json) { $extra += '-Json' }
            }
            'diff' {
                $pidVal = if ($ProposalId) { $ProposalId } elseif ($Rest.Count -ge 2) { $Rest[1] } else { 'latest' }
                $extra += @('-ProposalId', $pidVal)
                if ($Json) { $extra += '-Json' }
            }
            'verify' {
                if ($Json) { $extra += '-Json' }
            }
            'accept' {
                $pidVal = if ($ProposalId) { $ProposalId } elseif ($Rest.Count -ge 2) { $Rest[1] } else { 'latest' }
                $extra += @('-ProposalId', $pidVal)
                if ($Json) { $extra += '-Json' }
            }
            'rollback' {
                $gidVal = if ($GenerationId) { $GenerationId } elseif ($Rest.Count -ge 2) { $Rest[1] } else { 'previous' }
                $extra += @('-GenerationId', $gidVal)
                if ($Reason) { $extra += @('-Reason', $Reason) }
                if ($Json) { $extra += '-Json' }
            }
            'context' {
                if ($TopicId) { $extra += @('-TopicId', $TopicId) }
                if ($BudgetChars -gt 0) { $extra += @('-BudgetChars', "$BudgetChars") }
                if ($null -ne $MaxPerSection) {
                    if ($MaxPerSection -le 0) { throw 'max-per-section must be a positive integer' }
                    $extra += @('-MaxPerSection', "$MaxPerSection")
                }
                if ($Json) { $extra += '-Json' }
            }
            default {
                throw "Unknown memory action: $memAction"
            }
        }
        Invoke-ConvMemory -Extra $extra
    }
    default { throw "Unknown command: $Command" }
}
