#requires -Version 7.0
<#
.SYNOPSIS
    Memory-TCG / RRR Shadow & Governance Adapter for Conversation ESAA (ADR-013).
    Zero-LLM, zero-network offline memory consolidation adapter.
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'sleep', 'inspect', 'diff', 'verify', 'accept', 'rollback', 'context')]
    [string]$Action = 'status',

    [string]$WorkspaceRoot,
    [string]$Mode = 'shadow',
    [int]$Seed = 42,
    [string]$Budget = 'all',
    [string]$ProposalId,
    [string]$GenerationId,
    [string]$Reason,
    [string]$TopicId,
    [int]$BudgetChars = 4000,
    [int]$MaxNodes = 0,
    [int]$MaxEdges = 0,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-WorkspaceRootPath {
    if ($WorkspaceRoot) { return (Resolve-Path -LiteralPath $WorkspaceRoot).Path }
    if ($env:GROK_WORKSPACE_ROOT) { return (Resolve-Path -LiteralPath $env:GROK_WORKSPACE_ROOT).Path }
    $parent = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    return (Resolve-Path -LiteralPath $parent).Path
}

function Resolve-MemoryCliScript {
    if ($env:CONV_ESAA_MEMORY_CLI -and (Test-Path -LiteralPath $env:CONV_ESAA_MEMORY_CLI)) {
        return (Resolve-Path -LiteralPath $env:CONV_ESAA_MEMORY_CLI).Path
    }
    $repoCandidate = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src/memory/adapter/cli.js'
    if (Test-Path -LiteralPath $repoCandidate) {
        return (Resolve-Path -LiteralPath $repoCandidate).Path
    }
    $bundledCandidate = Join-Path $PSScriptRoot 'memory/adapter/cli.js'
    if (Test-Path -LiteralPath $bundledCandidate) {
        return (Resolve-Path -LiteralPath $bundledCandidate).Path
    }
    $fallbackRepoCandidate = '/home/elzobrito/desenvolvimento/conversation-esaa/src/memory/adapter/cli.js'
    if (Test-Path -LiteralPath $fallbackRepoCandidate) {
        return (Resolve-Path -LiteralPath $fallbackRepoCandidate).Path
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
    $output = & $pwshExe @syncArgs
    $exitCode = $LASTEXITCODE
    if ($null -ne $output) { $output | Write-Output }
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
    $output = & $pwshExe @syncArgs
    $exitCode = $LASTEXITCODE
    if ($null -ne $output) { $output | Write-Output }
    if ($exitCode -and $exitCode -ne 0) { exit $exitCode }
    exit 0
}

$cliScript = Resolve-MemoryCliScript
$nodeCmd = Get-Command node -ErrorAction Stop

if ($Action -eq 'context') {
    $effBudget = if ($BudgetChars -gt 0) { $BudgetChars } else { 4000 }
    $nodeArgs = @($cliScript, 'context', '--workspace', $ws, '--budget-chars', "$effBudget", '--json')
    if ($TopicId) { $nodeArgs += @('--topic-id', $TopicId) }
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
        if ($Json) { $nodeArgs += '--json' }
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

$output = & $nodeCmd.Source @nodeArgs
$exitCode = $LASTEXITCODE
if ($null -ne $output) {
    $output | Write-Output
}
if ($exitCode -and $exitCode -ne 0) {
    exit $exitCode
}
exit 0
