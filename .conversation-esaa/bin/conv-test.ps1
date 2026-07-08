#requires -Version 7.0
<#
.SYNOPSIS
    Testes de integracao do Conversation ESAA (bootstrap, verify, parsing, dedup).
#>
param(
    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).Path
}

$binDir = Join-Path $RepoRoot '.conversation-esaa\bin'
$fixtureRoot = Join-Path $RepoRoot '.conversation-esaa\tests\fixtures'
$bootstrap = Join-Path $binDir 'conv-bootstrap.ps1'
$sync = Join-Path $binDir 'conv-sync.ps1'
$cli = Join-Path $binDir 'conversation-esaa.ps1'

$passed = 0
$failed = 0
$results = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        $script:results.Add("PASS  $Name")
    } else {
        $script:failed++
        $line = "FAIL  $Name"
        if ($Detail) { $line += " — $Detail" }
        $script:results.Add($line)
    }
}

function Invoke-ConvCli {
    param(
        [string]$Workspace,
        [string]$Command,
        [hashtable]$Params = @{},
        [string[]]$ExtraArgs = @()
    )
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli, $Command) + $ExtraArgs + @('-Workspace', $Workspace)
    foreach ($key in $Params.Keys) {
        $val = $Params[$key]
        if ($val -is [bool]) {
            if ($val) { $args += "-$key" }
        } elseif ($null -ne $val -and "$val" -ne '') {
            $args += "-$key", "$val"
        }
    }
    $out = & pwsh @args 2>&1
    return @{
        ExitCode = $LASTEXITCODE
        Output = ($out | Out-String).Trim()
    }
}

function Invoke-ConvSync {
    param(
        [string]$Workspace,
        [string]$Command,
        [string[]]$Extra = @()
    )
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sync,
        $Command, '-WorkspaceRoot', $Workspace
    ) + $Extra
    $out = & pwsh @args 2>&1
    return @{
        ExitCode = $LASTEXITCODE
        Output = ($out | Out-String).Trim()
    }
}

function New-TestWorkspace {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("conv-esaa-test-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Count-ActivityEvents {
    param([string]$ActivityPath)
    if (-not (Test-Path -LiteralPath $ActivityPath)) { return 0 }
    $count = 0
    foreach ($line in [System.IO.File]::ReadLines($ActivityPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $count++ }
    }
    return $count
}

function Get-SyncedActivityEvents {
    param([string]$ActivityPath)
    $events = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $ActivityPath)) { return @($events) }
    foreach ($line in [System.IO.File]::ReadLines($ActivityPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json
        } catch {
            continue
        }
        if (('source' -in $event.PSObject.Properties.Name) -and $event.source) {
            $events.Add($event)
        }
    }
    return @($events)
}

function Encode-GrokCwd {
    param([string]$Path)
    return [uri]::EscapeDataString($Path.TrimEnd('\'))
}

function Install-GrokFixture {
    param(
        [string]$Workspace,
        [string]$GrokHome,
        [string]$SessionId = 'test-grok-session'
    )
    $encoded = Encode-GrokCwd $Workspace
    $sessionDir = Join-Path $GrokHome "sessions\$encoded\$SessionId"
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
    $fixture = Join-Path $fixtureRoot 'grok\chat_history.jsonl'
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $sessionDir 'chat_history.jsonl') -Force
    return $SessionId
}

# --- Tests ---------------------------------------------------------------

$ws = New-TestWorkspace
try {
    $ws = (Resolve-Path -LiteralPath $ws).Path
    $bootOut = & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrap -WorkspaceRoot $ws 2>&1 | Out-String
    $verify = Invoke-ConvSync -Workspace $ws -Command 'verify'
    Assert-True ($verify.ExitCode -eq 0 -and $verify.Output -match 'verify: ok') `
        'bootstrap_creates_valid_workspace' `
        $(if ($verify.ExitCode -ne 0) { $verify.Output } else { '' })

    $statePath = Join-Path $ws '.conversation-esaa\state.md'
    $handoffPath = Join-Path $ws '.conversation-esaa\handoff.md'
    Assert-True ((Test-Path -LiteralPath $statePath) -and (Test-Path -LiteralPath $handoffPath)) `
        'bootstrap_projects_baseline'

    $grokHook = Get-Content -LiteralPath (Join-Path $ws '.grok\hooks\conversation-esaa.json') -Raw
    $hookCmd = ($grokHook | ConvertFrom-Json).hooks.UserPromptSubmit[0].hooks[0].command
    Assert-True ($hookCmd.Contains($ws)) 'bootstrap_hooks_use_target_workspace'

    $boot2 = & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrap -WorkspaceRoot $ws 2>&1 | Out-String
    Assert-True ($boot2 -match 'skip \(existe') 'bootstrap_idempotent_without_force'

    # Codex parsing + idempotency
    $codexFixture = Join-Path $fixtureRoot 'codex\rollout.jsonl'
    $activity = Join-Path $ws '.conversation-esaa\activity.jsonl'
    $count0 = Count-ActivityEvents $activity

    $sync1 = Invoke-ConvSync -Workspace $ws -Command 'sync-codex' -Extra @('-CodexSessionPath', $codexFixture)
    $count1 = Count-ActivityEvents $activity
    Assert-True ($sync1.Output -match 'verify: ok') 'sync_codex_pipeline_ok' $sync1.Output
    Assert-True (($count1 - $count0) -eq 2) 'sync_codex_parses_fixture' "before=$count0 after=$count1"

    $syncedAfterCodex = Get-SyncedActivityEvents $activity
    $missingRoot = @($syncedAfterCodex | Where-Object {
        -not (('workspace_root' -in $_.PSObject.Properties.Name) -and $_.workspace_root)
    })
    Assert-True ($missingRoot.Count -eq 0) 'new_events_include_workspace_root' "missing=$($missingRoot.Count)"
    $wrongRoot = @($syncedAfterCodex | Where-Object {
        (Resolve-Path -LiteralPath $_.workspace_root).Path -ne $ws
    })
    Assert-True ($wrongRoot.Count -eq 0) 'new_events_workspace_root_matches_target' "wrong=$($wrongRoot.Count)"

    $sync2 = Invoke-ConvSync -Workspace $ws -Command 'sync-codex' -Extra @('-CodexSessionPath', $codexFixture)
    $count2 = Count-ActivityEvents $activity
    Assert-True ($count2 -eq $count1) 'sync_codex_idempotent' "count=$count2"

    # Claude parsing
    $claudeFixture = Join-Path $fixtureRoot 'claude\session.jsonl'
    $beforeClaude = Count-ActivityEvents $activity
    $syncClaude = Invoke-ConvSync -Workspace $ws -Command 'sync-claude' -Extra @('-ClaudeSessionPath', $claudeFixture)
    $count3 = Count-ActivityEvents $activity
    Assert-True (($count3 - $beforeClaude) -eq 2) 'sync_claude_parses_fixture' "delta=$($count3 - $beforeClaude)"
    Assert-True ($count3 -eq 4) 'sync_claude_skips_thinking_and_sidechain' "count=$count3"

    # Grok parsing via GROK_HOME
    $grokHome = Join-Path $ws 'grok-home'
    $sessionId = Install-GrokFixture -Workspace $ws -GrokHome $grokHome
    $prevGrokHome = $env:GROK_HOME
    $env:GROK_HOME = $grokHome
    try {
        $beforeGrok = Count-ActivityEvents $activity
        $syncGrok = Invoke-ConvSync -Workspace $ws -Command 'sync-grok' -Extra @('-GrokSessionId', $sessionId)
        $count4 = Count-ActivityEvents $activity
        Assert-True (($count4 - $beforeGrok) -eq 2) 'sync_grok_parses_fixture' "delta=$($count4 - $beforeGrok)"
        Assert-True ($count4 -eq 6) 'sync_grok_event_count' "count=$count4"
    } finally {
        if ($null -eq $prevGrokHome) { Remove-Item Env:GROK_HOME -ErrorAction SilentlyContinue }
        else { $env:GROK_HOME = $prevGrokHome }
    }

    # Dedup reconstructs from activity when sync-state is missing
    $syncState = Join-Path $ws '.conversation-esaa\sync-state.json'
    Remove-Item -LiteralPath $syncState -Force
    $beforeRebuild = Count-ActivityEvents $activity
    $syncRebuild = Invoke-ConvSync -Workspace $ws -Command 'sync-codex' -Extra @('-CodexSessionPath', $codexFixture)
    $count5 = Count-ActivityEvents $activity
    Assert-True ($count5 -eq $beforeRebuild) 'dedup_rebuilds_from_activity_jsonl' "count=$count5"
    Assert-True ($count5 -eq 6) 'dedup_no_extra_after_state_loss' "count=$count5"

    # Pipeline lockfile (ADR-001)
    $lockPath = Join-Path $ws '.conversation-esaa\run\conversation-esaa.lock'
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'lock_removed_after_successful_sync'

    $staleLock = [ordered]@{
        pid = 99999999
        command = 'stale-test'
        started_at = '2026-06-21T00:00:00-03:00'
        workspace_root = $ws
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
    [System.IO.File]::WriteAllText(
        $lockPath,
        (($staleLock | ConvertTo-Json -Compress) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    $staleProject = Invoke-ConvSync -Workspace $ws -Command 'project'
    Assert-True ($staleProject.Output -match 'project: regenerated') 'stale_lock_removed_and_sync_succeeds' $staleProject.Output
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'stale_lock_cleaned_after_success'

    $liveLock = [ordered]@{
        pid = $PID
        command = 'live-test'
        started_at = '2026-06-21T00:00:00-03:00'
        workspace_root = $ws
    }
    [System.IO.File]::WriteAllText(
        $lockPath,
        (($liveLock | ConvertTo-Json -Compress) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    $blocked = Invoke-ConvSync -Workspace $ws -Command 'project' -Extra @('-LockTimeoutSeconds', '2')
    Assert-True ($blocked.ExitCode -ne 0 -or $blocked.Output -match 'lock timeout') `
        'live_lock_blocks_until_timeout' $blocked.Output
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue

    # verify rejects synced events missing workspace_root
    $syncedSample = @(Get-SyncedActivityEvents $activity | Select-Object -First 1)
    if ($syncedSample.Count -ge 1) {
        $noRootWs = New-TestWorkspace
        try {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrap -WorkspaceRoot $noRootWs | Out-Null
            $noRootActivity = Join-Path $noRootWs '.conversation-esaa\activity.jsonl'
            $badEvent = $syncedSample[0] | ConvertTo-Json -Compress -Depth 8
            $badEventObj = $badEvent | ConvertFrom-Json
            $badEventObj.PSObject.Properties.Remove('workspace_root')
            [System.IO.File]::WriteAllText(
                $noRootActivity,
                (($badEventObj | ConvertTo-Json -Compress -Depth 8) + "`n"),
                [System.Text.UTF8Encoding]::new($false)
            )
            $noRootVerify = Invoke-ConvSync -Workspace $noRootWs -Command 'verify'
            Assert-True ($noRootVerify.ExitCode -ne 0 -or $noRootVerify.Output -notmatch 'verify: ok') `
                'verify_rejects_missing_workspace_root' $noRootVerify.Output
        } finally {
            Remove-Item -LiteralPath $noRootWs -Recurse -Force -ErrorAction SilentlyContinue
        }

        $mismatchWs = New-TestWorkspace
        try {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrap -WorkspaceRoot $mismatchWs | Out-Null
            $mismatchActivity = Join-Path $mismatchWs '.conversation-esaa\activity.jsonl'
            $mismatchEvent = $syncedSample[0] | ConvertTo-Json -Compress -Depth 8 | ConvertFrom-Json
            $mismatchEvent.workspace_root = 'C:\other\workspace'
            [System.IO.File]::WriteAllText(
                $mismatchActivity,
                (($mismatchEvent | ConvertTo-Json -Compress -Depth 8) + "`n"),
                [System.Text.UTF8Encoding]::new($false)
            )
            $mismatchVerify = Invoke-ConvSync -Workspace $mismatchWs -Command 'verify'
            Assert-True ($mismatchVerify.ExitCode -ne 0 -or $mismatchVerify.Output -notmatch 'verify: ok') `
                'verify_rejects_mismatched_workspace_root' $mismatchVerify.Output
        } finally {
            Remove-Item -LiteralPath $mismatchWs -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Assert-True $false 'verify_rejects_missing_workspace_root' 'no synced events to test'
        Assert-True $false 'verify_rejects_mismatched_workspace_root' 'no synced events to test'
    }

    # conversation-esaa CLI wrapper
    $wrapVerify = Invoke-ConvCli -Workspace $ws -Command 'verify'
    Assert-True ($wrapVerify.Output -match 'verify: ok') 'wrapper_verify_ok' $wrapVerify.Output
    $wrapProject = Invoke-ConvCli -Workspace $ws -Command 'project'
    Assert-True ($wrapProject.Output -match 'project: regenerated') 'wrapper_project_ok' $wrapProject.Output
    Assert-True (Test-Path -LiteralPath (Join-Path $binDir 'conversation-esaa.ps1')) 'bootstrap_installs_wrapper'

    # enable-hooks
    $ehGrok = Invoke-ConvCli -Workspace $ws -Command 'enable-hooks' -Params @{ Agent = 'grok'; Trust = $true }
    Assert-True (Test-Path -LiteralPath (Join-Path $ws '.grok\hooks\conversation-esaa.json')) 'enable_hooks_grok_json'
    Assert-True ($ehGrok.Output -match 'verify: ok') 'enable_hooks_grok_verify' $ehGrok.Output
    $ehClaude = Invoke-ConvCli -Workspace $ws -Command 'enable-hooks' -Params @{ Agent = 'claude' }
    Assert-True (Test-Path -LiteralPath (Join-Path $ws '.claude\settings.json')) 'enable_hooks_claude_settings'
    $ehCodex = Invoke-ConvCli -Workspace $ws -Command 'enable-hooks' -Params @{ Agent = 'codex'; Watcher = $true }
    Assert-True ($ehCodex.Output -match 'codex-watch') 'enable_hooks_codex_watcher_hint' $ehCodex.Output

    # decide + task projection
    $decide = Invoke-ConvCli -Workspace $ws -Command 'decide' -Params @{
        Decision = 'Usar context --agent para handoff seletivo'
        Rationale = 'Evita ler log inteiro'
        Agent = 'codex'
    }
    Assert-True ($decide.Output -match 'decide: recorded') 'decide_appends_event' $decide.Output
    $decisionsPath = Join-Path $ws '.conversation-esaa\decisions.md'
    Assert-True (Test-Path -LiteralPath $decisionsPath) 'decisions_md_generated'
    $decisionsText = Get-Content -LiteralPath $decisionsPath -Raw
    Assert-True ($decisionsText -match 'handoff seletivo') 'decisions_md_contains_decision'

    $taskCreate2 = Invoke-ConvSync -Workspace $ws -Command 'task' -Extra @('-TaskAction', 'create', '-TaskTitle', 'Implementar context --agent')
    Assert-True ($taskCreate2.Output -match 'task: created') 'task_create_event' $taskCreate2.Output
    $createdId = if ($taskCreate2.Output -match 'task: created (CONV-\d+)') { $Matches[1] } else { $null }
    Assert-True ($null -ne $createdId) 'task_create_returns_id' $taskCreate2.Output
    $taskUpdate = Invoke-ConvSync -Workspace $ws -Command 'task' -Extra @('-TaskAction', 'update', '-TaskId', $createdId, '-TaskStatus', 'in_progress', '-TaskNextStep', 'add tests')
    Assert-True ($taskUpdate.Output -match 'task: updated') 'task_update_event' $taskUpdate.Output
    $taskClose = Invoke-ConvSync -Workspace $ws -Command 'task' -Extra @('-TaskAction', 'close', '-TaskId', $createdId, '-TaskEvidence', 'context tests pass')
    Assert-True ($taskClose.Output -match 'task: closed') 'task_close_event' $taskClose.Output
    $tasksJson = Get-Content -LiteralPath (Join-Path $ws '.conversation-esaa\tasks.json') -Raw | ConvertFrom-Json
    $closed = @($tasksJson.tasks | Where-Object { $_.id -eq $createdId })
    Assert-True (($closed.Count -eq 1) -and ($closed[0].status -eq 'completed')) 'tasks_json_projected_from_events'

    # ADR-009 topic memory layer
    $topicCreate = Invoke-ConvCli -Workspace $ws -Command 'topics' -ExtraArgs @('create', 'Assunto de teste') -Params @{
        Summary = 'Resumo do assunto de teste'
    }
    Assert-True ($topicCreate.Output -match 'topic: created TOP-001') 'topic_create_event' $topicCreate.Output
    $topicsPath = Join-Path $ws '.conversation-esaa\topics.json'
    $topicsJson = Get-Content -LiteralPath $topicsPath -Raw | ConvertFrom-Json
    $createdTopic = @($topicsJson.topics | Where-Object { $_.id -eq 'TOP-001' })
    Assert-True (($createdTopic.Count -eq 1) -and ($createdTopic[0].title -eq 'Assunto de teste')) 'topics_json_projected_from_events'

    $topicList = Invoke-ConvCli -Workspace $ws -Command 'topics' -ExtraArgs @('list')
    Assert-True ($topicList.Output -match 'TOP-001') 'topics_list_outputs_topic' $topicList.Output
    $topicShow = Invoke-ConvCli -Workspace $ws -Command 'topics' -ExtraArgs @('show', 'TOP-001')
    Assert-True ($topicShow.Output -match 'Resumo do assunto de teste') 'topics_show_outputs_summary' $topicShow.Output

    $topicEventId = ($topicCreate.Output | Select-String -Pattern 'topic: created TOP-001') | Out-Null
    $topicCreatedEvent = Get-Content -LiteralPath $activity -Raw |
        ForEach-Object { $_ -split "`n" } |
        Where-Object { $_ -match '"event":"topic.created"' } |
        Select-Object -First 1 |
        ConvertFrom-Json
    $topicLink = Invoke-ConvCli -Workspace $ws -Command 'topics' -ExtraArgs @('link', 'TOP-001') -Params @{
        EventId = $topicCreatedEvent.event_id
    }
    Assert-True ($topicLink.Output -match 'topic: linked event to TOP-001') 'topic_link_event' $topicLink.Output
    $topicContext = Invoke-ConvCli -Workspace $ws -Command 'context' -Params @{ TopicId = 'TOP-001' }
    Assert-True (($topicContext.Output -match 'topic_id=TOP-001') -and ($topicContext.Output -match $topicCreatedEvent.event_id)) 'context_topic_id_returns_linked_event' $topicContext.Output

    $topicClose = Invoke-ConvCli -Workspace $ws -Command 'topics' -ExtraArgs @('close', 'TOP-001') -Params @{
        Evidence = 'done'
    }
    Assert-True ($topicClose.Output -match 'topic: closed TOP-001') 'topic_close_event' $topicClose.Output
    $topicsJsonAfterClose = Get-Content -LiteralPath $topicsPath -Raw | ConvertFrom-Json
    $closedTopic = @($topicsJsonAfterClose.topics | Where-Object { $_.id -eq 'TOP-001' })
    Assert-True ($closedTopic[0].status -eq 'completed') 'topic_close_projects_completed'

    # verify rejects duplicate event_id
    $lines = [System.IO.File]::ReadAllLines($activity)
    $dupWs = New-TestWorkspace
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrap -WorkspaceRoot $dupWs | Out-Null
        $dupActivity = Join-Path $dupWs '.conversation-esaa\activity.jsonl'
        if ($lines.Count -ge 1) {
            [System.IO.File]::WriteAllText($dupActivity, ($lines[0] + "`n" + $lines[0] + "`n"), [System.Text.UTF8Encoding]::new($false))
            $badVerify = Invoke-ConvSync -Workspace $dupWs -Command 'verify'
            Assert-True ($badVerify.ExitCode -ne 0 -or $badVerify.Output -notmatch 'verify: ok') `
                'verify_rejects_duplicate_event_id' $badVerify.Output
        } else {
            Assert-True $false 'verify_rejects_duplicate_event_id' 'no events to duplicate'
        }
    } finally {
        Remove-Item -LiteralPath $dupWs -Recurse -Force -ErrorAction SilentlyContinue
    }

} finally {
    Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Context fixture tests -----------------------------------------------
$ctxWs = New-TestWorkspace
try {
    $ctxWs = (Resolve-Path -LiteralPath $ctxWs).Path
    $otherWs = 'C:\other\workspace'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrap -WorkspaceRoot $ctxWs | Out-Null
    $ctxFixture = Join-Path $fixtureRoot 'context\activity.context.jsonl'
    $ctxActivity = Join-Path $ctxWs '.conversation-esaa\activity.jsonl'
    $raw = Get-Content -LiteralPath $ctxFixture -Raw
    $raw = $raw.Replace('__WORKSPACE_A__', $ctxWs.Replace('\', '\\'))
    $raw = $raw.Replace('__WORKSPACE_B__', $otherWs.Replace('\', '\\'))
    [System.IO.File]::WriteAllText($ctxActivity, $raw.TrimEnd() + "`n", [System.Text.UTF8Encoding]::new($false))

    $ctxLast3 = Invoke-ConvCli -Workspace $ctxWs -Command 'context' -Params @{ Last = 3 }
    Assert-True ($ctxLast3.Output -match 'evt_ctx_010') 'context_last_3' $ctxLast3.Output
    Assert-True ($ctxLast3.Output -match 'evt_ctx_012') 'context_last_3_includes_latest' $ctxLast3.Output
    Assert-True ($ctxLast3.Output -notmatch 'evt_ctx_other_001') 'context_workspace_isolation'

    $ctxGrok2 = Invoke-ConvCli -Workspace $ctxWs -Command 'context' -Params @{ Agent = 'grok'; Last = 2 }
    Assert-True ($ctxGrok2.Output -match 'evt_ctx_011') 'context_agent_grok_last_2' $ctxGrok2.Output
    Assert-True ($ctxGrok2.Output -notmatch 'evt_ctx_003') 'context_agent_grok_excludes_codex'

    $ctxBefore = Invoke-ConvCli -Workspace $ctxWs -Command 'context' -Params @{ Before = 'evt_ctx_006'; Last = 2 }
    Assert-True ($ctxBefore.Output -match 'evt_ctx_004') 'context_before_window' $ctxBefore.Output
    Assert-True ($ctxBefore.Output -match 'evt_ctx_005') 'context_before_window_second' $ctxBefore.Output
    Assert-True ($ctxBefore.Output -notmatch '- \[.*evt_ctx_006') 'context_before_excludes_target'

    $ctxAround = Invoke-ConvCli -Workspace $ctxWs -Command 'context' -Params @{ Around = 'evt_ctx_006'; Window = 1 }
    Assert-True ($ctxAround.Output -match 'evt_ctx_005') 'context_around_prev' $ctxAround.Output
    Assert-True ($ctxAround.Output -match 'evt_ctx_006') 'context_around_target' $ctxAround.Output
    Assert-True ($ctxAround.Output -match 'evt_ctx_007') 'context_around_next' $ctxAround.Output

    $ctxTopic = Invoke-ConvCli -Workspace $ctxWs -Command 'context' -Params @{ Topic = 'workspace' }
    Assert-True ($ctxTopic.Output -match 'evt_ctx_') 'context_topic_matches' $ctxTopic.Output
    Assert-True ($ctxTopic.Output -notmatch 'evt_ctx_other_001') 'context_topic_respects_workspace'
    Assert-True ($ctxTopic.Output -match '\(legacy\)') 'context_topic_handles_legacy_event_without_id' $ctxTopic.Output
} finally {
    Remove-Item -LiteralPath $ctxWs -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Report --------------------------------------------------------------
Write-Output ''
foreach ($line in $results) { Write-Output $line }
Write-Output ''
Write-Output "conv-test: $passed passed, $failed failed"

if ($failed -gt 0) { exit 1 }
exit 0
