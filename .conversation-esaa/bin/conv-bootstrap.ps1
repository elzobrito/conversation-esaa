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
    [switch]$DryRun
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

$supportedAgents = @('grok', 'claude', 'codex', 'antigravity')
if (-not $Agents -or $Agents.Count -eq 0) {
    $Agents = @('grok', 'claude', 'codex', 'antigravity')
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
    'codex-watch.ps1',
    'antigravity-hook-sync.ps1',
    'conv-rag.ps1'
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
function New-SyncCommand([string]$Agent, [string]$Extra = '') {
    $command = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$convCli`" sync --agent $Agent --workspace `"$WorkspaceRoot`""
    if ($Extra) { $command += " $Extra" }
    return $command
}

if ($Agents -contains 'grok') {
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

if ($Agents -contains 'claude') {
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

if ($Agents -contains 'antigravity') {
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
    '.conversation-esaa/vendor/',
    '.claude/settings.json',
    '.claude/settings.local.json',
    '.agents/hooks.json'
)

if (-not $DryRun) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $convCli project --workspace $WorkspaceRoot | Out-Null
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $convCli verify --workspace $WorkspaceRoot | Out-Null
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

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Output "bootstrap: ok -> $WorkspaceRoot"
    Write-Output "agents: $($Agents -join ', ')"
    if ($DryRun) { Write-Output 'dry-run: no changes applied' }
    foreach ($warning in $result.warnings) { Write-Output "next: $warning" }
}
