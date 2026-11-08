#requires -Version 7.0
<#
.SYNOPSIS
    E2E and regression tests for Memory-TCG RRR shadow mode (CONV-MTCG-IMPL-008).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cliPath = Join-Path $repoRoot '.conversation-esaa/bin/conversation-esaa.ps1'

$passed = 0
$failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passed++
        Write-Output "  [PASS] $Message"
    } else {
        $script:failed++
        Write-Error "  [FAIL] $Message" -ErrorAction Continue
    }
}

function Get-FileSha256Hex {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

$tempWs = Join-Path ([System.IO.Path]::GetTempPath()) ("conv-esaa-mem-shadow-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempWs | Out-Null

try {
    Write-Output "=== Test Suite: Memory-TCG Shadow Mode (CONV-MTCG-IMPL-008) ==="

    & pwsh -NoProfile -File $cliPath init --workspace $tempWs | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "Workspace initialized via conversation-esaa init"

    # Check initial status is 'off'
    $initStatusRaw = & pwsh -NoProfile -File $cliPath memory status --workspace $tempWs --json
    $initStatus = $initStatusRaw | ConvertFrom-Json
    Assert-True ($initStatus.status -eq 'OK' -and $initStatus.mode -eq 'off') "Initial memory status is mode=off"

    # Seed realistic events in activity.jsonl
    $activityPath = Join-Path $tempWs '.conversation-esaa/activity.jsonl'
    $events = @(
        [ordered]@{
            schema_version    = 'conversation-esaa.v1'
            event_id          = 'ev-shadow-001'
            ts                = '2026-11-07T10:00:00Z'
            workspace_root    = $tempWs
            event             = 'topic.created'
            topic_id          = 'TOP-001'
            title             = 'Database Architecture'
            summary           = 'Selection of primary storage engine'
            status            = 'active'
            actor             = 'assistant'
            agent_id          = 'codex'
        },
        [ordered]@{
            schema_version    = 'conversation-esaa.v1'
            event_id          = 'ev-shadow-002'
            ts                = '2026-11-07T10:01:00Z'
            workspace_root    = $tempWs
            event             = 'conversation_turn'
            source            = 'codex'
            source_session_id = 'sess-1'
            source_index      = 1
            actor             = 'user'
            agent_id          = $null
            topic_id          = 'TOP-001'
            summary           = 'Initial discussion with credential ghp_SecretToken1234567890abcdef123456'
            text              = 'We are testing with token ghp_SecretToken1234567890abcdef123456 in dev.'
        },
        [ordered]@{
            schema_version    = 'conversation-esaa.v1'
            event_id          = 'ev-shadow-003'
            ts                = '2026-11-07T10:02:00Z'
            workspace_root    = $tempWs
            event             = 'conversation_turn'
            source            = 'claude'
            source_session_id = 'sess-2'
            source_index      = 1
            actor             = 'assistant'
            agent_id          = 'claude'
            topic_id          = 'TOP-001'
            summary           = 'Repeated operational note'
            text              = 'Repeated operational note'
        },
        [ordered]@{
            schema_version    = 'conversation-esaa.v1'
            event_id          = 'ev-shadow-004'
            ts                = '2026-11-07T10:03:00Z'
            workspace_root    = $tempWs
            event             = 'conversation_turn'
            source            = 'grok'
            source_session_id = 'sess-3'
            source_index      = 1
            actor             = 'assistant'
            agent_id          = 'grok'
            topic_id          = 'TOP-001'
            summary           = 'Repeated operational note'
            text              = 'Repeated operational note'
        },
        [ordered]@{
            schema_version    = 'conversation-esaa.v1'
            event_id          = 'ev-shadow-005'
            ts                = '2026-11-07T10:04:00Z'
            workspace_root    = $tempWs
            event             = 'decision.recorded'
            actor             = 'assistant'
            agent_id          = 'codex'
            topic_id          = 'TOP-001'
            decision          = 'Use SQLite for local MVP'
            rationale         = 'Zero external server dependency'
            related_turns     = @('ev-shadow-002')
        },
        [ordered]@{
            schema_version    = 'conversation-esaa.v1'
            event_id          = 'ev-shadow-006'
            ts                = '2026-11-07T10:05:00Z'
            workspace_root    = $tempWs
            event             = 'decision.recorded'
            actor             = 'assistant'
            agent_id          = 'claude'
            topic_id          = 'TOP-001'
            decision          = 'Use PostgreSQL 16 for production'
            rationale         = 'Concurrent write scalability'
            supersedes        = 'ev-shadow-005'
            related_turns     = @('ev-shadow-002')
        }
    )

    $lines = $events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }
    [System.IO.File]::WriteAllLines($activityPath, $lines, [System.Text.UTF8Encoding]::new($false))

    & pwsh -NoProfile -File $cliPath project --workspace $tempWs | Out-Null
    & pwsh -NoProfile -File $cliPath verify --workspace $tempWs | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "Projected and verified seeded workspace"

    $hashActivityBefore  = Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/activity.jsonl')
    $hashHandoffBefore   = Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/handoff.md')
    $hashStateBefore     = Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/state.md')
    $hashDecisionsBefore = Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/decisions.md')
    $hashTasksBefore     = Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/tasks.json')
    $hashTopicsBefore    = Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/topics.json')

    # Run shadow sleep #1
    $sleep1Raw = & pwsh -NoProfile -File $cliPath memory sleep --mode shadow --seed 42 --budget all --workspace $tempWs --json
    Assert-True ($LASTEXITCODE -eq 0) "memory sleep --mode shadow #1 succeeded"
    $sleep1 = $sleep1Raw | ConvertFrom-Json

    # Run shadow sleep #2 with same seed via 'sonhar' alias
    $sleep2Raw = & pwsh -NoProfile -File $cliPath sonhar --mode shadow --seed 42 --budget all --workspace $tempWs --json
    Assert-True ($LASTEXITCODE -eq 0) "memory sleep --mode shadow #2 (via 'sonhar' alias) succeeded"
    $sleep2 = $sleep2Raw | ConvertFrom-Json

    Assert-True ($sleep1.proposal_id -eq $sleep2.proposal_id) "Deterministic proposal_id across repeated shadow runs"
    Assert-True ($sleep1.graph_generation_id -eq $sleep2.graph_generation_id) "Deterministic graph_generation_id across repeated shadow runs"

    # Verify zero mutation of canonical ledger and active read models
    Assert-True ($hashActivityBefore -eq (Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/activity.jsonl'))) "activity.jsonl SHA-256 unchanged after shadow sleep"
    Assert-True ($hashHandoffBefore -eq (Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/handoff.md'))) "handoff.md SHA-256 unchanged after shadow sleep"
    Assert-True ($hashStateBefore -eq (Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/state.md'))) "state.md SHA-256 unchanged after shadow sleep"
    Assert-True ($hashDecisionsBefore -eq (Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/decisions.md'))) "decisions.md SHA-256 unchanged after shadow sleep"
    Assert-True ($hashTasksBefore -eq (Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/tasks.json'))) "tasks.json SHA-256 unchanged after shadow sleep"
    Assert-True ($hashTopicsBefore -eq (Get-FileSha256Hex (Join-Path $tempWs '.conversation-esaa/topics.json'))) "topics.json SHA-256 unchanged after shadow sleep"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempWs '.conversation-esaa/memory/active.json'))) "active.json is NOT created in shadow mode"

    # Check secret redaction in proposal, graph, and telemetry logs
    $proposalContent = Get-Content -LiteralPath $sleep1.proposal_path -Raw -Encoding UTF8
    $graphContent = Get-Content -LiteralPath $sleep1.graph_path -Raw -Encoding UTF8
    $runsLogContent = Get-Content -LiteralPath (Join-Path $tempWs '.conversation-esaa/memory/logs/runs.jsonl') -Raw -Encoding UTF8

    Assert-True ($proposalContent -notmatch 'ghp_SecretToken1234567890abcdef123456') "Secret token redacted in shadow proposal"
    Assert-True ($graphContent -notmatch 'ghp_SecretToken1234567890abcdef123456') "Secret token redacted in stored graph"
    Assert-True ($runsLogContent -notmatch 'ghp_SecretToken1234567890abcdef123456' -and $runsLogContent -notmatch 'PostgreSQL') "runs.jsonl contains only operational telemetry, zero conversation text"

    # Test inspect, diff, verify
    $inspectRaw = & pwsh -NoProfile -File $cliPath memory inspect --proposal-id $sleep1.proposal_id --workspace $tempWs --json
    Assert-True ($LASTEXITCODE -eq 0) "memory inspect succeeded"
    $inspectObj = $inspectRaw | ConvertFrom-Json
    Assert-True ($inspectObj.proposal.proposal_id -eq $sleep1.proposal_id) "memory inspect returned matching proposal"

    $diffRaw = & pwsh -NoProfile -File $cliPath memory diff --proposal-id $sleep1.proposal_id --workspace $tempWs --json
    Assert-True ($LASTEXITCODE -eq 0) "memory diff succeeded"
    $diffObj = $diffRaw | ConvertFrom-Json
    Assert-True ($diffObj.summary.retained_count -ge 2) "memory diff reports retained active items"
    Assert-True ($diffObj.summary.marked_historical_count -eq 1) "memory diff reports 1 superseded historical decision"
    Assert-True ($diffObj.summary.grouped_duplicates_count -eq 1) "memory diff reports 1 exact duplicate group"

    $verifyRaw = & pwsh -NoProfile -File $cliPath memory verify --workspace $tempWs --json
    Assert-True ($LASTEXITCODE -eq 0) "memory verify succeeded"
    $verifyObj = $verifyRaw | ConvertFrom-Json
    Assert-True ($verifyObj.status -eq 'OK' -and $verifyObj.verified_proposals -eq 1) "memory verify validated shadow proposal and graph"

    # Test forbidden auto mode fails closed
    $autoOut = & pwsh -NoProfile -File $cliPath memory sleep --mode auto --workspace $tempWs --json 2>$null
    $autoExit = $LASTEXITCODE
    Assert-True ($autoExit -ne 0) "memory sleep --mode auto is rejected with non-zero exit code"

    # Ensure standard conversation-esaa verify and context remain healthy
    & pwsh -NoProfile -File $cliPath verify --workspace $tempWs | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "conversation-esaa verify remains healthy after shadow runs"

    Write-Output "=== Summary: $passed passed, $failed failed ==="
    if ($failed -gt 0) { exit 1 }
    exit 0
} finally {
    if (Test-Path -LiteralPath $tempWs) {
        Remove-Item -LiteralPath $tempWs -Recurse -Force -ErrorAction SilentlyContinue
    }
}
