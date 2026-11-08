#requires -Version 7.0
<#
.SYNOPSIS
    E2E and governance tests for Memory-TCG explicit accept, ledger event, rollback, and replay (CONV-MTCG-IMPL-010).
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

$tempWs1 = Join-Path ([System.IO.Path]::GetTempPath()) ("conv-esaa-mem-acc1-" + [System.Guid]::NewGuid().ToString('N'))
$tempWs2 = Join-Path ([System.IO.Path]::GetTempPath()) ("conv-esaa-mem-acc2-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempWs1, $tempWs2 | Out-Null

try {
    Write-Output "=== Test Suite: Memory-TCG Accept, Replay & Rollback (CONV-MTCG-IMPL-010) ==="

    & pwsh -NoProfile -File $cliPath init --workspace $tempWs1 | Out-Null
    & pwsh -NoProfile -File $cliPath init --workspace $tempWs2 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "Initialized isolated workspaces ws1 and ws2"

    & pwsh -NoProfile -File $cliPath decide "Use PostgreSQL 16 as primary DB" --rationale "ACID compliance" --agent codex --workspace $tempWs1 | Out-Null
    & pwsh -NoProfile -File $cliPath decide "Use SQLite for ws2" --rationale "Local file" --agent codex --workspace $tempWs2 | Out-Null

    # 1. Generate shadow proposal P1 in ws1
    $sleep1Raw = & pwsh -NoProfile -File $cliPath memory sleep --mode shadow --seed 42 --workspace $tempWs1 --json
    Assert-True ($LASTEXITCODE -eq 0) "Generated shadow proposal P1 in ws1"
    $sleep1 = $sleep1Raw | ConvertFrom-Json

    # 2. Wrong-workspace rejection test: copy P1 into ws2 and attempt accept
    $ws2ShadowDir = Join-Path $tempWs2 '.conversation-esaa/memory/shadow'
    New-Item -ItemType Directory -Force -Path $ws2ShadowDir | Out-Null
    Copy-Item -LiteralPath $sleep1.proposal_path -Destination $ws2ShadowDir -Force
    $wrongWsOut = & pwsh -NoProfile -File $cliPath memory accept --proposal-id $sleep1.proposal_id --workspace $tempWs2 --json 2>&1
    $wrongWsExit = $LASTEXITCODE
    $wrongWsText = $wrongWsOut -join "`n"
    Assert-True ($wrongWsExit -ne 0 -and $wrongWsText -match 'WRONG_WORKSPACE') "Rejected proposal from another workspace with WRONG_WORKSPACE"

    # 3. Corrupted proposal rejection test in ws2
    $ws2PropFile = Join-Path $ws2ShadowDir (Split-Path -Leaf $sleep1.proposal_path)
    $tampered = Get-Content -LiteralPath $ws2PropFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $tampered.policy_version = 'tampered-policy.v99'
    [System.IO.File]::WriteAllText($ws2PropFile, ($tampered | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    $corruptOut = & pwsh -NoProfile -File $cliPath memory accept --proposal-id $sleep1.proposal_id --workspace $tempWs2 --json 2>&1
    $corruptExit = $LASTEXITCODE
    $corruptText = $corruptOut -join "`n"
    Assert-True ($corruptExit -ne 0 -and $corruptText -match 'INTEGRITY_FAILURE') "Rejected tampered proposal with INTEGRITY_FAILURE"

    # 4. Stale proposal rejection test in ws1: advance ledger after P1 was created
    & pwsh -NoProfile -File $cliPath decide "Enable Redis read-through cache" --rationale "Latency" --agent codex --workspace $tempWs1 | Out-Null
    $staleOut = & pwsh -NoProfile -File $cliPath memory accept --proposal-id $sleep1.proposal_id --workspace $tempWs1 --json 2>&1
    $staleExit = $LASTEXITCODE
    $staleText = $staleOut -join "`n"
    Assert-True ($staleExit -ne 0 -and $staleText -match 'STALE_PROPOSAL') "Rejected stale proposal P1 after ledger head advanced with STALE_PROPOSAL"

    # 5. Generate fresh proposal P2 on current head of ws1 and accept it
    $sleep2Raw = & pwsh -NoProfile -File $cliPath memory sleep --mode shadow --seed 42 --workspace $tempWs1 --json
    Assert-True ($LASTEXITCODE -eq 0) "Generated fresh proposal P2 in ws1"
    $sleep2 = $sleep2Raw | ConvertFrom-Json

    $acc2Raw = & pwsh -NoProfile -File $cliPath memory accept --proposal-id $sleep2.proposal_id --workspace $tempWs1 --json
    Assert-True ($LASTEXITCODE -eq 0) "Accepted fresh proposal P2 in ws1"
    $acc2 = $acc2Raw | ConvertFrom-Json
    Assert-True ($acc2.status -eq 'OK' -and $acc2.graph_generation_id -eq $sleep2.graph_generation_id) "memory accept returned OK and activated G2"

    # Verify status is now active
    $statusAfterP2 = (& pwsh -NoProfile -File $cliPath memory status --workspace $tempWs1 --json) | ConvertFrom-Json
    Assert-True ($statusAfterP2.mode -eq 'active' -and $statusAfterP2.active_generation_id -eq $sleep2.graph_generation_id) "memory status reports mode=active and active_generation_id=G2"

    # Verify canonical event in activity.jsonl
    $activityLines = [System.IO.File]::ReadAllLines((Join-Path $tempWs1 '.conversation-esaa/activity.jsonl'))
    $acceptedEvents = @($activityLines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'memory.consolidation.accepted' })
    Assert-True ($acceptedEvents.Count -eq 1 -and $acceptedEvents[0].proposal_id -eq $sleep2.proposal_id) "Canonical memory.consolidation.accepted event recorded in activity.jsonl"

    # 6. Create second accepted generation G3, then rollback to G2
    & pwsh -NoProfile -File $cliPath decide "Enforce TLS 1.3 everywhere" --rationale "Security baseline" --agent codex --workspace $tempWs1 | Out-Null
    $sleep3 = (& pwsh -NoProfile -File $cliPath memory sleep --mode shadow --seed 42 --workspace $tempWs1 --json) | ConvertFrom-Json
    $acc3 = (& pwsh -NoProfile -File $cliPath memory accept --proposal-id $sleep3.proposal_id --workspace $tempWs1 --json) | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $acc3.graph_generation_id -eq $sleep3.graph_generation_id) "Accepted second generation G3"

    $rbRaw = & pwsh -NoProfile -File $cliPath memory rollback --generation-id $sleep2.graph_generation_id --reason "Operator rollback to G2" --workspace $tempWs1 --json
    Assert-True ($LASTEXITCODE -eq 0) "Executed memory rollback to G2"
    $rb = $rbRaw | ConvertFrom-Json
    Assert-True ($rb.rolled_back_from_generation_id -eq $sleep3.graph_generation_id -and $rb.restored_generation_id -eq $sleep2.graph_generation_id) "Rollback transitioned active generation from G3 back to G2"

    $statusAfterRb = (& pwsh -NoProfile -File $cliPath memory status --workspace $tempWs1 --json) | ConvertFrom-Json
    Assert-True ($statusAfterRb.active_generation_id -eq $sleep2.graph_generation_id) "memory status confirms active generation is G2 after rollback"

    # 7. Crash recovery / Replay from activity.jsonl alone (delete .conversation-esaa/memory completely)
    $activeBeforeDelete = Get-Content -LiteralPath (Join-Path $tempWs1 '.conversation-esaa/memory/active.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item -LiteralPath (Join-Path $tempWs1 '.conversation-esaa/memory') -Recurse -Force
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempWs1 '.conversation-esaa/memory'))) "Deleted .conversation-esaa/memory directory to simulate crash/clean checkout"

    & pwsh -NoProfile -File $cliPath project --workspace $tempWs1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "conversation-esaa project succeeded after deleting memory directory"

    & pwsh -NoProfile -File $cliPath verify --workspace $tempWs1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "conversation-esaa verify succeeded after reconstructing memory from activity.jsonl"

    $activeAfterReplay = Get-Content -LiteralPath (Join-Path $tempWs1 '.conversation-esaa/memory/active.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($activeAfterReplay.active_digest -eq $activeBeforeDelete.active_digest -and $activeAfterReplay.graph_generation_id -eq $sleep2.graph_generation_id) "Reconstructed active.json matches exact active_digest and generation G2 from ledger alone"

    Write-Output "=== Summary: $passed passed, $failed failed ==="
    if ($failed -gt 0) { exit 1 }
    exit 0
} finally {
    foreach ($d in @($tempWs1, $tempWs2)) {
        if (Test-Path -LiteralPath $d) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
