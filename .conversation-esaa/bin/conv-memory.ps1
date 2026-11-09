#requires -Version 7.0
<#
.SYNOPSIS
    Memory-TCG / RRR Shadow & Governance Adapter for Conversation ESAA (ADR-013).
    Zero-LLM, zero-network offline memory consolidation adapter.
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'sleep', 'sonhar', 'dream', 'inspect', 'diff', 'verify', 'accept', 'rollback', 'context')]
    [string]$Action = 'status',

    [string]$WorkspaceRoot,
    [string]$Agent,
    [string]$Mode = 'shadow',
    [int]$Seed = 42,
    [string]$Budget = 'all',
    [string]$ProposalId,
    [string]$GenerationId,
    [string]$Reason,
    [string]$TopicId,
    [int]$BudgetChars = 4000,
    [Nullable[int]]$MaxPerSection = $null,
    [int]$MaxNodes = 0,
    [int]$MaxEdges = 0,
    [switch]$Accept,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Action -in @('sonhar', 'dream')) {
    $Action = 'sleep'
}

function Resolve-WorkspaceRootPath {
    if ($WorkspaceRoot) { return (Resolve-Path -LiteralPath $WorkspaceRoot).Path }
    $installRoot = (Resolve-Path -LiteralPath (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).Path
    # Environment routing is retained for the user-global installation only.
    # A project-installed runtime otherwise targets its own workspace.
    $homeRoot = (Resolve-Path -LiteralPath $HOME).Path
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($env:GROK_WORKSPACE_ROOT -and [string]::Equals($installRoot, $homeRoot, $comparison)) {
        return (Resolve-Path -LiteralPath $env:GROK_WORKSPACE_ROOT).Path
    }
    return $installRoot
}

function Resolve-MemoryCliScript {
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
    throw "Memory-TCG Node CLI not found relative to $PSScriptRoot"
}

$ws = Resolve-WorkspaceRootPath
$convSync = Join-Path $PSScriptRoot 'conv-sync.ps1'

if ($Action -eq 'accept') {
    $targetId = if ($ProposalId) { $ProposalId } else { 'latest' }
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $syncArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $convSync,
        'memory-accept', '-WorkspaceRoot', $ws, '-MemoryProposalId', $targetId
    )
    if ($Json) { $syncArgs += '-MemoryJson' }
    if ($Agent) { $syncArgs += @('-CuratorAgent', $Agent) }
    & $pwshExe @syncArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -and $exitCode -ne 0) { exit $exitCode }
    exit 0
}

if ($Action -eq 'rollback') {
    $targetGen = if ($GenerationId) { $GenerationId } else { 'previous' }
    $reasonText = if ($Reason) { $Reason } else { 'Explicit operator rollback' }
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $syncArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $convSync,
        'memory-rollback', '-WorkspaceRoot', $ws,
        '-MemoryGenerationId', $targetGen,
        '-MemoryReason', $reasonText
    )
    if ($Json) { $syncArgs += '-MemoryJson' }
    if ($Agent) { $syncArgs += @('-CuratorAgent', $Agent) }
    & $pwshExe @syncArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -and $exitCode -ne 0) { exit $exitCode }
    exit 0
}

$cliScript = Resolve-MemoryCliScript
$nodeCmd = Get-Command node -ErrorAction Stop

if ($Action -eq 'context') {
    $effBudget = if ($BudgetChars -gt 0) { $BudgetChars } else { 4000 }
    $nodeArgs = @($cliScript, 'context', '--workspace', $ws, '--budget-chars', "$effBudget", '--json')
    if ($TopicId) { $nodeArgs += @('--topic-id', $TopicId) }
    if ($null -ne $MaxPerSection) {
        if ($MaxPerSection -le 0) { throw 'max-per-section must be a positive integer' }
        $nodeArgs += @('--max-per-section', "$MaxPerSection")
    }
    $rawOut = & $nodeCmd.Source @nodeArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -and $exitCode -ne 0) {
        if ($null -ne $rawOut) { $rawOut | Write-Output }
        exit $exitCode
    }
    $parsed = ($rawOut -join "`n") | ConvertFrom-Json
    if ($Json) {
        $rawOut | Write-Output
        exit 0
    }
    if ($parsed.status -eq 'OK') {
        $parsed.markdown | Write-Output
        exit 0
    }
    if ($parsed.status -eq 'FALLBACK_LEGACY') {
        Write-Output "> [MEMORY-FALLBACK: active.json integrity check failed ($($parsed.error_code): $($parsed.reason)); falling back to legacy context]"
    }
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $convSync, 'context', '-WorkspaceRoot', $ws)
    if ($TopicId) { $syncArgs += @('-ContextTopicId', $TopicId) }
    & $pwshExe @syncArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    exit 0
}

$nodeArgs = @($cliScript, $Action, '--workspace', $ws)

switch ($Action) {
    'status' {
        if ($Json) { $nodeArgs += '--json' }
    }
    'sleep' {
        $nodeArgs += @('--mode', $Mode, '--seed', "$Seed", '--budget', $Budget)
        if ($MaxNodes -gt 0) { $nodeArgs += @('--max-nodes', "$MaxNodes") }
        if ($MaxEdges -gt 0) { $nodeArgs += @('--max-edges', "$MaxEdges") }
        if ($Json -or $Accept) { $nodeArgs += '--json' }
    }
    'inspect' {
        $targetId = if ($ProposalId) { $ProposalId } else { 'latest' }
        $nodeArgs += @('--proposal-id', $targetId)
        if ($Json) { $nodeArgs += '--json' }
    }
    'diff' {
        $targetId = if ($ProposalId) { $ProposalId } else { 'latest' }
        $nodeArgs += @('--proposal-id', $targetId)
        if ($Json) { $nodeArgs += '--json' }
    }
    'verify' {
        if ($Json) { $nodeArgs += '--json' }
    }
}

if ($Action -eq 'sleep' -and $Accept) {
    $rawSleep = & $nodeCmd.Source @nodeArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -and $exitCode -ne 0) {
        if ($null -ne $rawSleep) { $rawSleep | Write-Output }
        exit $exitCode
    }
    $sleepObj = ($rawSleep -join "`n") | ConvertFrom-Json
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
    $syncArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $convSync,
        'memory-accept', '-WorkspaceRoot', $ws, '-MemoryProposalId', $sleepObj.proposal_id
    )
    if ($Json) { $syncArgs += '-MemoryJson' }
    if ($Agent) { $syncArgs += @('-CuratorAgent', $Agent) }
    $rawAccept = & $pwshExe @syncArgs
    $accExit = $LASTEXITCODE
    if ($accExit -and $accExit -ne 0) {
        if ($null -ne $rawAccept) { $rawAccept | Write-Output }
        exit $accExit
    }
    $accObj = ($rawAccept -join "`n") | ConvertFrom-Json
    $sleepObj | Add-Member -NotePropertyName accepted -NotePropertyValue $true -Force
    $sleepObj | Add-Member -NotePropertyName accept_event_id -NotePropertyValue $accObj.event_id -Force
    $sleepObj | Add-Member -NotePropertyName active_digest -NotePropertyValue $accObj.active_digest -Force
    ($sleepObj | ConvertTo-Json -Depth 10) | Write-Output
    exit 0
}

& $nodeCmd.Source @nodeArgs
$exitCode = $LASTEXITCODE
if ($exitCode -and $exitCode -ne 0) {
    exit $exitCode
}
exit 0
