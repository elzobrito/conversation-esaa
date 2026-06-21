#requires -Version 7.0
<#
.SYNOPSIS
    Instala o Conversation ESAA em um workspace, gerando hooks e arquivos
    com os caminhos absolutos corretos para AQUELE workspace.

.DESCRIPTION
    Resolve o finding "hooks com paths absolutos nao publicaveis": em vez de
    versionar .grok/hooks e .claude/settings.json com caminhos fixos, o
    projeto publico envia este bootstrap, e cada usuario o roda apontando para
    o proprio workspace. O activity.jsonl sai em branco (sem historico do lab).

.EXAMPLE
    pwsh -File conv-bootstrap.ps1 -WorkspaceRoot C:\meu\projeto

.EXAMPLE
    pwsh -File conv-bootstrap.ps1 -WorkspaceRoot C:\meu\projeto -Force
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    # Sobrescreve arquivos existentes (activity.jsonl, hooks, etc.).
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Test-ShouldWrite {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -and -not $Force) { return $false }
    return $true
}

# --- Resolver caminhos ---------------------------------------------------
New-Dir $WorkspaceRoot
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path.TrimEnd('\', '/')

$srcBin   = $PSScriptRoot                               # bin de origem (este script)
$esaaDir  = Join-Path $WorkspaceRoot '.conversation-esaa'
$binDir   = Join-Path $esaaDir 'bin'
$plansDir = Join-Path $esaaDir 'plans'
$grokDir  = Join-Path $WorkspaceRoot '.grok\hooks'
$claudeDir = Join-Path $WorkspaceRoot '.claude'

$runDir = Join-Path $esaaDir 'run'
foreach ($d in @($esaaDir, $binDir, $plansDir, $runDir, $grokDir, $claudeDir)) { New-Dir $d }

# --- Copiar o motor (conv-sync.ps1 e codex-watch.ps1) --------------------
foreach ($engine in @('conv-sync.ps1', 'conversation-esaa.ps1', 'codex-watch.ps1')) {
    $from = Join-Path $srcBin $engine
    $to   = Join-Path $binDir $engine
    if (Test-Path -LiteralPath $from) {
        if ([System.IO.Path]::GetFullPath($from) -ne [System.IO.Path]::GetFullPath($to)) {
            Copy-Item -LiteralPath $from -Destination $to -Force
            Write-Output "engine: $engine"
        } else {
            Write-Output "engine: $engine (ja no destino)"
        }
    }
}

$convSync = Join-Path $binDir 'conv-sync.ps1'
$convCli = Join-Path $binDir 'conversation-esaa.ps1'

# --- Seeds em branco -----------------------------------------------------
$activity = Join-Path $esaaDir 'activity.jsonl'
if (Test-ShouldWrite $activity) { Write-Utf8 $activity '' ; Write-Output "seed: activity.jsonl (vazio)" }
else { Write-Output "skip (existe, use -Force): activity.jsonl" }

$syncState = Join-Path $esaaDir 'sync-state.json'
if (Test-ShouldWrite $syncState) {
    $ss = [ordered]@{ schema_version = 'conversation-esaa.sync-state.v0.1'; processed_event_ids = @() }
    Write-Utf8 $syncState (($ss | ConvertTo-Json -Depth 4) + "`n")
    Write-Output "seed: sync-state.json"
} else { Write-Output "skip (existe, use -Force): sync-state.json" }

$tasks = Join-Path $esaaDir 'tasks.json'
if (Test-ShouldWrite $tasks) {
    $tj = [ordered]@{ schema_version = 'conversation-esaa.tasks.v0.1'; tasks = @() }
    Write-Utf8 $tasks (($tj | ConvertTo-Json -Depth 4) + "`n")
    Write-Output "seed: tasks.json (vazio)"
} else { Write-Output "skip (existe, use -Force): tasks.json" }

# --- Hooks gerados com o caminho deste workspace -------------------------
function New-CommandLine {
    param([string]$Agent, [string]$Extra = '')
    $base = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$convCli`" sync --agent $Agent --workspace `"$WorkspaceRoot`""
    if ($Extra) { $base = "$base $Extra" }
    return $base
}

# Grok: .grok/hooks/conversation-esaa.json
$grokHookFile = Join-Path $grokDir 'conversation-esaa.json'
if (Test-ShouldWrite $grokHookFile) {
    $cmdGrok        = New-CommandLine -Agent 'grok'
    $cmdGrokCompact = New-CommandLine -Agent 'grok' -Extra '--Mode compact'
    $grokCfg = [ordered]@{
        hooks = [ordered]@{
            UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = $cmdGrok; timeout = 15 }) })
            Stop             = @(@{ hooks = @(@{ type = 'command'; command = $cmdGrok; timeout = 20 }) })
            PreCompact       = @(@{ hooks = @(@{ type = 'command'; command = $cmdGrokCompact; timeout = 25 }) })
        }
    }
    Write-Utf8 $grokHookFile (($grokCfg | ConvertTo-Json -Depth 8) + "`n")
    Write-Output "hook: .grok/hooks/conversation-esaa.json"
} else { Write-Output "skip (existe, use -Force): .grok/hooks/conversation-esaa.json" }

# Claude Code: .claude/settings.json
$claudeSettings = Join-Path $claudeDir 'settings.json'
if (Test-ShouldWrite $claudeSettings) {
    $cmdClaude        = New-CommandLine -Agent 'claude'
    $cmdClaudeCompact = New-CommandLine -Agent 'claude' -Extra '--Mode compact'
    $claudeCfg = [ordered]@{
        hooks = [ordered]@{
            UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = $cmdClaude; timeout = 20 }) })
            Stop             = @(@{ hooks = @(@{ type = 'command'; command = $cmdClaude; timeout = 30 }) })
            PreCompact       = @(@{ hooks = @(@{ type = 'command'; command = $cmdClaudeCompact; timeout = 30 }) })
        }
    }
    Write-Utf8 $claudeSettings (($claudeCfg | ConvertTo-Json -Depth 8) + "`n")
    Write-Output "hook: .claude/settings.json"
} else { Write-Output "skip (existe, use -Force): .claude/settings.json" }

# --- .gitignore (protege os dados privados gerados) ----------------------
$gitignore = Join-Path $WorkspaceRoot '.gitignore'
if (Test-ShouldWrite $gitignore) {
    $gi = @(
        '# Conversation ESAA - dados privados gerados (NAO COMMITAR). Ver PRIVACY.md'
        '.conversation-esaa/activity.jsonl'
        '.conversation-esaa/sync-state.json'
        '.conversation-esaa/state.md'
        '.conversation-esaa/handoff.md'
        '.conversation-esaa/run/*.lock'
        '.claude/settings.json'
        '.claude/settings.local.json'
    ) -join [Environment]::NewLine
    Write-Utf8 $gitignore ($gi + [Environment]::NewLine)
    Write-Output ".gitignore"
} else { Write-Output "skip (existe, use -Force): .gitignore" }

# --- Projetar baseline (state.md + handoff.md) e verificar ---------------
& pwsh -NoProfile -ExecutionPolicy Bypass -File $convCli project --workspace $WorkspaceRoot | Out-Null
& pwsh -NoProfile -ExecutionPolicy Bypass -File $convCli verify --workspace $WorkspaceRoot

Write-Output ''
Write-Output "bootstrap: ok -> $WorkspaceRoot"
Write-Output 'Proximos passos:'
Write-Output '  - Grok:   confie no projeto em ~/.grok/trusted-hook-projects e recarregue (/hooks -> r).'
Write-Output '  - Claude: reinicie a sessao para carregar/aprovar .claude/settings.json.'
Write-Output '  - Codex:  rode bin/codex-watch.ps1 para auto-sync (sem hook nativo).'
