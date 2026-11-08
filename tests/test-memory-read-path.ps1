#requires -Version 7.0
<#
.SYNOPSIS
    E2E and regression tests for Memory-TCG opt-in active read path in pack/context (CONV-MTCG-IMPL-011).
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

$tempWs = Join-Path ([System.IO.Path]::GetTempPath()) ("conv-esaa-mem-read-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempWs | Out-Null

try {
    Write-Output "=== Test Suite: Memory-TCG Active Read Path in Pack/Context (CONV-MTCG-IMPL-011) ==="

    & pwsh -NoProfile -File $cliPath init --workspace $tempWs | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "Workspace initialized"

    $activityPath = Join-Path $tempWs '.conversation-esaa/activity.jsonl'
    $events = @(
        [ordered]@{
            schema_version = 'conversation-esaa.v1'
            event_id       = 'ev-read-001'
            ts             = '2026-11-07T12:00:00Z'
            workspace_root = $tempWs
            event          = 'topic.created'
            topic_id       = 'TOP-001'
            title          = 'Storage & Persistence'
            summary        = 'Database selection and migration'
            status         = 'active'
            actor          = 'assistant'
            agent_id       = 'codex'
        },
        [ordered]@{
            schema_version    = 'conversation-esaa.v1'
            event_id          = 'ev-read-002'
            ts                = '2026-11-07T12:01:00Z'
            workspace_root    = $tempWs
            event             = 'conversation_turn'
            source            = 'codex'
            source_session_id = 'sess-r1'
            source_index      = 1
            actor             = 'user'
            agent_id          = $null
            topic_id          = 'TOP-001'
            summary           = 'O banco oficial é MySQL no ambiente legado'
            text              = 'O banco oficial é MySQL no ambiente legado'
        },
        [ordered]@{
            schema_version    = 'conversation-esaa.v1'
            event_id          = 'ev-read-003'
            ts                = '2026-11-07T12:02:00Z'
            workspace_root    = $tempWs
            event             = 'conversation_turn'
            source            = 'claude'
            source_session_id = 'sess-r2'
            source_index      = 1
            actor             = 'assistant'
            agent_id          = 'claude'
            topic_id          = 'TOP-001'
            summary           = 'O banco oficial é MongoDB segundo nota antiga'
            text              = 'O banco oficial é MongoDB segundo nota antiga'
        },
        [ordered]@{
            schema_version = 'conversation-esaa.v1'
            event_id       = 'ev-read-004'
            ts             = '2026-11-07T12:03:00Z'
            workspace_root = $tempWs
            event          = 'decision.recorded'
            actor          = 'assistant'
            agent_id       = 'codex'
            topic_id       = 'TOP-001'
            decision       = 'Adotar SQLite temporariamente no prototipo'
            rationale      = 'Simplicidade local'
            related_turns  = @('ev-read-002')
            summary        = 'Adotar SQLite temporariamente no prototipo'
            text           = 'Adotar SQLite temporariamente no prototipo'
        },
        [ordered]@{
            schema_version = 'conversation-esaa.v1'
            event_id       = 'ev-read-005'
            ts             = '2026-11-07T12:04:00Z'
            workspace_root = $tempWs
            event          = 'decision.recorded'
            actor          = 'assistant'
            agent_id       = 'claude'
            topic_id       = 'TOP-001'
            decision       = 'Adotar PostgreSQL 16 como banco oficial definitivo'
            rationale      = 'Consistencia transacional e suporte JSONB'
            supersedes     = 'ev-read-004'
            related_turns  = @('ev-read-002', 'ev-read-003')
            summary        = 'Adotar PostgreSQL 16 como banco oficial definitivo'
            text           = 'Adotar PostgreSQL 16 como banco oficial definitivo'
        }
    )

    $lines = $events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }
    [System.IO.File]::WriteAllLines($activityPath, $lines, [System.Text.UTF8Encoding]::new($false))

    & pwsh -NoProfile -File $cliPath project --workspace $tempWs | Out-Null
    & pwsh -NoProfile -File $cliPath verify --workspace $tempWs | Out-Null

    # 1. Capture baseline pack and context when memory is OFF
    $packOff = (& pwsh -NoProfile -File $cliPath pack --workspace $tempWs) -join "`n"
    $contextOff = (& pwsh -NoProfile -File $cliPath context --workspace $tempWs) -join "`n"

    # 2. Run shadow sleep and verify pack and context are byte-for-byte identical to OFF
    $sleepOut = (& pwsh -NoProfile -File $cliPath memory sleep --mode shadow --seed 42 --workspace $tempWs --json) | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0) "memory sleep --mode shadow succeeded"

    $packShadow = (& pwsh -NoProfile -File $cliPath pack --workspace $tempWs) -join "`n"
    $contextShadow = (& pwsh -NoProfile -File $cliPath context --workspace $tempWs) -join "`n"

    Assert-True ($packOff -eq $packShadow) "pack output in shadow mode is byte-for-byte identical to memory off baseline"
    Assert-True ($contextOff -eq $contextShadow) "context output in shadow mode is byte-for-byte identical to memory off baseline"

    # 3. Accept proposal to activate Memory-TCG generation
    $accOut = (& pwsh -NoProfile -File $cliPath memory accept --proposal-id $sleepOut.proposal_id --workspace $tempWs --json) | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $accOut.status -eq 'OK') "Accepted proposal to activate Memory-TCG read path"

    # 4. Verify memory context and pack/context with active memory
    $memCtxJson = (& pwsh -NoProfile -File $cliPath memory context --workspace $tempWs --json) | ConvertFrom-Json
    Assert-True ($memCtxJson.status -eq 'OK' -and $memCtxJson.mode -eq 'active') "memory context --json returns status=OK and mode=active"
    Assert-True ($memCtxJson.retained_decisions.Count -eq 1 -and $memCtxJson.retained_decisions[0].summary -match 'PostgreSQL 16') "Active decision retained with provenance"
    Assert-True ($memCtxJson.historical_decisions.Count -eq 1 -and $memCtxJson.historical_decisions[0].summary -match 'SQLite') "Superseded decision separated as historical"
    Assert-True ($memCtxJson.unresolved_conflicts.Count -ge 1) "Unresolved conflict surfaced in active memory context"

    $packActive = (& pwsh -NoProfile -File $cliPath pack --workspace $tempWs) -join "`n"
    Assert-True ($packActive -match '\[ACTIVE\].*PostgreSQL 16.*evidence:.*ev-read-005') "pack with active memory displays [ACTIVE] decision and provenance"
    Assert-True ($packActive -match '\[HISTORICAL / SUPERSEDED\].*SQLite.*superseded by decision:ev-read-005') "pack with active memory labels superseded decision as [HISTORICAL / SUPERSEDED]"
    Assert-True ($packActive -match '\[UNRESOLVED CONFLICT\]') "pack with active memory surfaces [UNRESOLVED CONFLICT]"

    $contextActive = (& pwsh -NoProfile -File $cliPath context --workspace $tempWs) -join "`n"
    Assert-True ($contextActive -match 'Memory-TCG Consolidated Context') "context with active memory includes consolidated Memory-TCG section"

    # 5. Verify strict character budget truncation and omitted IDs reporting
    $tightCtx = (& pwsh -NoProfile -File $cliPath memory context --workspace $tempWs --budget-chars 320 --json) | ConvertFrom-Json
    Assert-True ($tightCtx.status -eq 'OK' -and @($tightCtx.omitted_memory_ids).Count -ge 1) "memory context respects tight --budget-chars and reports omitted_memory_ids"

    # 6. Verify safe fallback and traceable warning when active.json is corrupted
    $activeFile = Join-Path $tempWs '.conversation-esaa/memory/active.json'
    [System.IO.File]::WriteAllText($activeFile, '{"schema_version":"conversation-esaa.memory.active.v1","active_digest":"sha256:0000"}', [System.Text.UTF8Encoding]::new($false))

    $fallbackJson = (& pwsh -NoProfile -File $cliPath memory context --workspace $tempWs --json) | ConvertFrom-Json
    Assert-True ($fallbackJson.status -eq 'FALLBACK_LEGACY' -and $fallbackJson.error_code -eq 'INTEGRITY_FAILURE') "Corrupted active.json triggers status=FALLBACK_LEGACY with INTEGRITY_FAILURE"

    $packFallback = (& pwsh -NoProfile -File $cliPath pack --workspace $tempWs) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $packFallback -match 'MEMORY-FALLBACK') "pack falls back safely to legacy decisions and emits traceable MEMORY-FALLBACK marker"

    $ctxFallback = (& pwsh -NoProfile -File $cliPath context --workspace $tempWs) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $ctxFallback -match 'MEMORY-FALLBACK') "context falls back safely to legacy ledger and emits traceable MEMORY-FALLBACK marker"

    Write-Output "=== Summary: $passed passed, $failed failed ==="
    if ($failed -gt 0) { exit 1 }
    exit 0
} finally {
    if (Test-Path -LiteralPath $tempWs) {
        Remove-Item -LiteralPath $tempWs -Recurse -Force -ErrorAction SilentlyContinue
    }
}
