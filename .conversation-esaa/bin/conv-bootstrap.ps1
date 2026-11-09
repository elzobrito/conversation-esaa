#requires -Version 7.0
<#
.SYNOPSIS
    Installs Conversation ESAA runtime files and selected agent integrations.

.DESCRIPTION
    This is the PowerShell-only fallback and the low-level effect engine used by
    the npm installer. Legacy calls without -Agents configure every supported
    agent. Private Conversation ESAA state is never overwritten.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [string[]]$Agents,
    [switch]$Force,
    [switch]$Json,
    [switch]$DryRun,
    [switch]$SkipAgentIntegrations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    schema_version = 'conversation-esaa.bootstrap.v1'
    ok = $false
    workspace = ''
    agents = @()
    dry_run = [bool]$DryRun
    changed = [System.Collections.Generic.List[string]]::new()
    preserved = [System.Collections.Generic.List[string]]::new()
    warnings = [System.Collections.Generic.List[string]]::new()
}

function Add-Changed([string]$Path) { [void]$result.changed.Add($Path) }
function Add-Preserved([string]$Path) {
    [void]$result.preserved.Add($Path)
    if (-not $Json) { Write-Output "skip (existe): $Path" }
}

function New-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path) -and -not $DryRun) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    if (-not $DryRun) {
        New-Dir (Split-Path -Parent $Path)
        [System.IO.File]::WriteAllText(
            $Path, $Content, [System.Text.UTF8Encoding]::new($false)
        )
    }
    Add-Changed $Path
}

function Assert-JsonFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable
    } catch {
        throw "Invalid existing $Label JSON; refusing to overwrite: $Path"
    }
}

function Write-AgentJson {
    param([string]$Path, [hashtable]$Value, [string]$Label)
    Assert-JsonFile -Path $Path -Label $Label
    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        Add-Preserved $Path
        return
    }
    Write-Utf8 $Path (($Value | ConvertTo-Json -Depth 12) + "`n")
}

function Merge-Gitignore {
    param([string]$Path, [string[]]$Entries)
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [System.IO.File]::ReadLines(
            $Path, [System.Text.UTF8Encoding]::new($false)
        )) { [void]$lines.Add($line) }
    }
    $seen = @{}
    foreach ($line in $lines) {
        if ($line.Trim()) { $seen[$line.Trim()] = $true }
    }
    $added = $false
    foreach ($entry in $Entries) {
        if (-not $seen.ContainsKey($entry.Trim())) {
            if (-not $added -and $lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) {
                [void]$lines.Add('')
            }
            [void]$lines.Add($entry)
            $seen[$entry.Trim()] = $true
            $added = $true
        }
    }
    if ($added -or -not (Test-Path -LiteralPath $Path)) {
        Write-Utf8 $Path (($lines -join "`n") + "`n")
    } else {
        Add-Preserved $Path
    }
}

$supportedAgents = @('grok', 'claude', 'codex', 'antigravity', 'cursor')
if (-not $Agents -or $Agents.Count -eq 0) {
    $Agents = @('grok', 'claude', 'codex', 'antigravity', 'cursor')
} else {
    $Agents = @($Agents | ForEach-Object { $_ -split ',' } | ForEach-Object {
        $_.Trim().ToLowerInvariant()
    } | Where-Object { $_ })
    foreach ($agent in $Agents) {
        if ($agent -notin $supportedAgents) {
            throw "Unsupported agent: $agent"
        }
    }
}
$Agents = @($Agents | Select-Object -Unique)
$result.agents = @($Agents)

if (-not (Test-Path -LiteralPath $WorkspaceRoot)) {
    if ($DryRun) {
        $WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    } else {
        New-Item -ItemType Directory -Force -Path $WorkspaceRoot | Out-Null
        $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    }
} else {
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
}
$WorkspaceRoot = $WorkspaceRoot.TrimEnd('\', '/')
$result.workspace = $WorkspaceRoot

$srcBin = $PSScriptRoot
$esaaDir = Join-Path $WorkspaceRoot '.conversation-esaa'
$binDir = Join-Path $esaaDir 'bin'
$plansDir = Join-Path $esaaDir 'plans'
$runDir = Join-Path $esaaDir 'run'
foreach ($directory in @($esaaDir, $binDir, $plansDir, $runDir)) {
    New-Dir $directory
}

foreach ($engine in @(
    'conv-sync.ps1',
    'conversation-esaa.ps1',
    'conv-bootstrap.ps1',
    'codex-watch.ps1',
    'antigravity-hook-sync.ps1',
    'cursor-hook.ps1',
    'conv-rag.ps1',
    'conv-memory.ps1'
)) {
    $source = Join-Path $srcBin $engine
    $target = Join-Path $binDir $engine
    if (-not (Test-Path -LiteralPath $source)) { continue }
    if ([System.IO.Path]::GetFullPath($source) -eq [System.IO.Path]::GetFullPath($target)) {
        Add-Preserved $target
        continue
    }
    if (-not $DryRun) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    Add-Changed $target
}

# Seed only absent private state. -Force intentionally has no effect here.
$privateSeeds = [ordered]@{
    'activity.jsonl' = ''
    'sync-state.json' = (
        ([ordered]@{
            schema_version = 'conversation-esaa.sync-state.v0.1'
            processed_event_ids = @()
        } | ConvertTo-Json -Depth 4) + "`n"
    )
    'tasks.json' = (
        ([ordered]@{
            schema_version = 'conversation-esaa.tasks.v0.1'
            tasks = @()
        } | ConvertTo-Json -Depth 4) + "`n"
    )
}
foreach ($name in $privateSeeds.Keys) {
    $path = Join-Path $esaaDir $name
    if (Test-Path -LiteralPath $path) {
        Add-Preserved $path
    } else {
        Write-Utf8 $path $privateSeeds[$name]
    }
}

$convCli = Join-Path $binDir 'conversation-esaa.ps1'
function Quote-CommandPart([string]$Value) {
    return '"' + ($Value -replace '"', '"') + '"'
}
function Get-PwshExecutable {
    return [string](Get-Command pwsh -ErrorAction Stop).Source
}
function New-SyncCommand([string]$Agent, [string]$Extra = '') {
    $pwshExe = Get-PwshExecutable
    $command = "$(Quote-CommandPart $pwshExe) -NoProfile -ExecutionPolicy Bypass -File $(Quote-CommandPart $convCli) sync --agent $Agent --workspace $(Quote-CommandPart $WorkspaceRoot) --SkipIfLocked"
    if ($Extra) { $command += " $Extra" }
    return $command
}

if (-not $SkipAgentIntegrations -and $Agents -contains 'grok') {
    $path = Join-Path $WorkspaceRoot '.grok/hooks/conversation-esaa.json'
    $value = [ordered]@{
        hooks = [ordered]@{
            UserPromptSubmit = @(@{ hooks = @(@{
                type = 'command'; command = (New-SyncCommand 'grok'); timeout = 15
            }) })
            Stop = @(@{ hooks = @(@{
                type = 'command'; command = (New-SyncCommand 'grok'); timeout = 20
            }) })
            PreCompact = @(@{ hooks = @(@{
                type = 'command'; command = (New-SyncCommand 'grok' '--Mode compact'); timeout = 25
            }) })
        }
    }
    Write-AgentJson -Path $path -Value $value -Label 'Grok hook'
}

if (-not $SkipAgentIntegrations -and $Agents -contains 'claude') {
    $path = Join-Path $WorkspaceRoot '.claude/settings.json'
    $value = [ordered]@{
        hooks = [ordered]@{
            UserPromptSubmit = @(@{ hooks = @(@{
                type = 'command'; command = (New-SyncCommand 'claude'); timeout = 20
            }) })
            Stop = @(@{ hooks = @(@{
                type = 'command'; command = (New-SyncCommand 'claude'); timeout = 30
            }) })
            PreCompact = @(@{ hooks = @(@{
                type = 'command'; command = (New-SyncCommand 'claude' '--Mode compact'); timeout = 30
            }) })
        }
    }
    Write-AgentJson -Path $path -Value $value -Label 'Claude settings'
}

if (-not $SkipAgentIntegrations -and $Agents -contains 'antigravity') {
    $path = Join-Path $WorkspaceRoot '.agents/hooks.json'
    $hooks = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        Assert-JsonFile -Path $path -Label 'Antigravity hooks'
        $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable
        foreach ($key in $existing.Keys) { $hooks[$key] = $existing[$key] }
    }
    $wrapper = Join-Path $binDir 'antigravity-hook-sync.ps1'
    $command = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -WorkspaceRoot `"$WorkspaceRoot`""
    $hooks['conversation-esaa'] = [ordered]@{
        Stop = @(@{ type = 'command'; command = $command; timeout = 60 })
    }
    Write-Utf8 $path (($hooks | ConvertTo-Json -Depth 12) + "`n")
}

if (-not $SkipAgentIntegrations -and $Agents -contains 'cursor') {
    $path = Join-Path $WorkspaceRoot '.cursor/hooks.json'
    Assert-JsonFile -Path $path -Label 'Cursor hooks'
    $cursorCfg = [ordered]@{ version = 1; hooks = [ordered]@{} }
    if (Test-Path -LiteralPath $path) {
        $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable
        foreach ($key in $existing.Keys) { $cursorCfg[$key] = $existing[$key] }
        if (-not $cursorCfg.Contains('hooks') -or $null -eq $cursorCfg['hooks']) {
            $cursorCfg['hooks'] = [ordered]@{}
        }
    }
    $wrapper = Join-Path $binDir 'cursor-hook.ps1'
    $pwshExe = Get-PwshExecutable
    $cursorHooks = $cursorCfg['hooks']
    if ($cursorHooks -isnot [System.Collections.IDictionary]) {
        $cursorHooks = [ordered]@{}
        $cursorCfg['hooks'] = $cursorHooks
    }
    foreach ($pair in @(
        @{ Name = 'sessionStart'; Timeout = 20 },
        @{ Name = 'beforeSubmitPrompt'; Timeout = 20 },
        @{ Name = 'afterAgentResponse'; Timeout = 20 }
    )) {
        $eventName = $pair.Name
        $command = "$(Quote-CommandPart $pwshExe) -NoProfile -ExecutionPolicy Bypass -File $(Quote-CommandPart $wrapper) -WorkspaceRoot $(Quote-CommandPart $WorkspaceRoot) -Event $eventName"
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($cursorHooks[$eventName] | Where-Object { $null -ne $_ })) {
            $existingCommand = if ($entry -is [System.Collections.IDictionary]) {
                [string]$entry['command']
            } else {
                [string]$entry.command
            }
            if ($existingCommand -and $existingCommand -notmatch 'cursor-hook\.ps1') {
                [void]$kept.Add($entry)
            }
        }
        [void]$kept.Add(@{ command = $command; timeout = $pair.Timeout })
        $cursorHooks[$eventName] = @($kept)
    }
    $cursorCfg['version'] = 1
    Write-Utf8 $path (($cursorCfg | ConvertTo-Json -Depth 12) + "`n")
}

$gitignore = Join-Path $WorkspaceRoot '.gitignore'
Merge-Gitignore -Path $gitignore -Entries @(
    '# Conversation ESAA - dados privados gerados (NAO COMMITAR). Ver PRIVACY.md',
    '.conversation-esaa/activity.jsonl',
    '.conversation-esaa/sync-state.json',
    '.conversation-esaa/state.md',
    '.conversation-esaa/handoff.md',
    '.conversation-esaa/install-manifest.json',
    '.conversation-esaa/run/*.lock',
    '.conversation-esaa/rag/',
    '.conversation-esaa/memory/',
    '.conversation-esaa/vendor/',
    '.claude/settings.json',
    '.claude/settings.local.json',
    '.claude/.settings.json.tmp-*',
    '.agents/hooks.json',
    '.cursor/hooks.json',
    '.conversation-esaa/cursor-hook.log',
    '.conversation-esaa/codex-watch.log',
    '.conversation-esaa/antigravity-hook.log',
    '.conversation-esaa/decisions.md',
    '.conversation-esaa/tasks.json',
    '.conversation-esaa/topics.md',
    '.conversation-esaa/topics.json',
    '.conversation-esaa/*.bak-*',
    '.conversation-esaa/*.tmp-*',
    '.conversation-esaa/run/'
)

if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $esaaDir 'topics.json'))) {
    # Invoke conv-sync directly (no nested conversation-esaa.ps1 -> pwsh hop).
    # Fail closed if project/verify cannot materialize topics.json etc.
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $convSync = Join-Path $binDir 'conv-sync.ps1'
    foreach ($syncCommand in @('project', 'verify')) {
        $syncArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $convSync,
            $syncCommand,
            '-WorkspaceRoot', $WorkspaceRoot
        )
        $syncOutput = & $pwshExe @syncArgs
        $syncExit = $LASTEXITCODE
        if ($syncExit -and $syncExit -ne 0) {
            $syncDetail = ($syncOutput | Out-String).Trim()
            if ($syncDetail) {
                throw "bootstrap $syncCommand failed with exit ${syncExit}: $syncDetail"
            }
            throw "bootstrap $syncCommand failed with exit $syncExit for $WorkspaceRoot"
        }
    }
}

$result.ok = $true
if ($Agents -contains 'grok') {
    [void]$result.warnings.Add('Trust the project in Grok and reload hooks.')
}
if ($Agents -contains 'claude') {
    [void]$result.warnings.Add('Restart Claude Code and approve the hooks.')
}
if ($Agents -contains 'codex') {
    [void]$result.warnings.Add('Start codex-watch.ps1 or configure a user service.')
}
if ($Agents -contains 'antigravity') {
    [void]$result.warnings.Add('Restart Antigravity to reload hooks.')
}
if ($Agents -contains 'cursor') {
    [void]$result.warnings.Add('Reload Cursor project hooks (.cursor/hooks.json). Cloud Agents pick them up from the repo after install.')
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Output "bootstrap: ok -> $WorkspaceRoot"
    Write-Output "agents: $($Agents -join ', ')"
    if ($DryRun) { Write-Output 'dry-run: no changes applied' }
    foreach ($warning in $result.warnings) { Write-Output "next: $warning" }
}
