#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$bootstrap = Join-Path $repo '.conversation-esaa/bin/conv-bootstrap.ps1'
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) (
    'conversation-esaa-bootstrap-' + [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Force -Path $workspace | Out-Null

try {
    $private = Join-Path $workspace '.conversation-esaa'
    New-Item -ItemType Directory -Force -Path $private | Out-Null
    $activity = Join-Path $private 'activity.jsonl'
    [System.IO.File]::WriteAllText(
        $activity,
        "{`"event_id`":`"private-sentinel`",`"ts`":`"2026-07-23T00:00:00Z`",`"event`":`"conversation_turn`",`"actor`":`"user`",`"agent_id`":null,`"source`":`"test`",`"source_session_id`":`"test`",`"source_path`":`"fixture`",`"source_index`":1,`"workspace_root`":`"$($workspace.Replace('\','\\'))`",`"summary`":`"private sentinel`",`"text`":`"private sentinel`"}`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    $first = & pwsh -NoProfile -File $bootstrap `
        -WorkspaceRoot $workspace -Agents grok,codex -Json | ConvertFrom-Json
    if (-not $first.ok) { throw 'bootstrap did not return ok' }
    if (-not (Test-Path (Join-Path $workspace '.grok/hooks/conversation-esaa.json'))) {
        throw 'selected Grok hook was not created'
    }
    if (Test-Path (Join-Path $workspace '.claude/settings.json')) {
        throw 'unselected Claude integration was created'
    }
    if (Test-Path (Join-Path $workspace '.agents/hooks.json')) {
        throw 'unselected Antigravity integration was created'
    }
    if ((Get-Content -LiteralPath $activity -Raw) -notmatch 'private-sentinel') {
        throw 'private activity was overwritten'
    }

    $before = (Get-FileHash -Algorithm SHA256 -LiteralPath $activity).Hash
    $second = & pwsh -NoProfile -File $bootstrap `
        -WorkspaceRoot $workspace -Agents grok,codex -Json | ConvertFrom-Json
    $after = (Get-FileHash -Algorithm SHA256 -LiteralPath $activity).Hash
    if ($before -ne $after) { throw 'idempotent run changed private activity' }
    if (-not ($second.preserved -contains $activity)) {
        throw 'private activity was not reported as preserved'
    }

    $dryWorkspace = Join-Path $workspace 'dry-run-target'
    $dry = & pwsh -NoProfile -File $bootstrap `
        -WorkspaceRoot $dryWorkspace -Agents claude -DryRun -Json | ConvertFrom-Json
    if (-not $dry.ok -or (Test-Path -LiteralPath $dryWorkspace)) {
        throw 'dry-run changed the filesystem'
    }

    Write-Output 'test-installer-bootstrap: PASS'
} finally {
    if (Test-Path -LiteralPath $workspace) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}
