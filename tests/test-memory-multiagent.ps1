# Synthetic handoff: identifiers are declared by the test, not real agent execution.
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '../.conversation-esaa/bin/conversation-esaa.ps1'
$ws = Join-Path ([System.IO.Path]::GetTempPath()) ('conv-multi-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ws | Out-Null
try {
    & pwsh -NoProfile -File $cli init --workspace $ws | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'init failed' }
    & pwsh -NoProfile -File $cli topics create 'Travessia sintética' --summary 'Pessoa retorna para casa' --agent grok --workspace $ws | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'topic creation failed' }
    & pwsh -NoProfile -File $cli task create 'Preparar evidência sintética' --agent antigravity --workspace $ws | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'task creation failed' }
    & pwsh -NoProfile -File $cli decide 'Decisão sem identificação declarada' --workspace $ws | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'decision creation failed' }
    $sleep = (& pwsh -NoProfile -File $cli sonhar --accept --agent codex --workspace $ws --json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $sleep.accepted) { throw 'sleep accept failed' }
    $ctx = (& pwsh -NoProfile -File $cli memory context --topic-id TOP-001 --workspace $ws --json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or @($ctx.retained_topics_and_tasks | Where-Object { $_.memory_id -eq 'TOP-001' }).Count -ne 1) { throw 'topic not available' }
    $events = @(Get-Content (Join-Path $ws '.conversation-esaa/activity.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($pair in @(@('topic.created','grok'), @('task.created','antigravity'), @('memory.consolidation.accepted','codex'))) {
        if (@($events | Where-Object { $_.event -eq $pair[0] -and $_.agent_id -eq $pair[1] }).Count -ne 1) { throw "wrong declared origin: $($pair -join '/')" }
        if (@($events | Where-Object { $_.event -eq $pair[0] -and $_.agent_id_source -eq 'declared' }).Count -ne 1) { throw "missing declared provenance: $($pair[0])" }
    }
    if (@($events | Where-Object { $_.event -eq 'decision.recorded' -and $_.agent_id -eq 'unknown' -and $_.agent_id_source -eq 'unknown' }).Count -ne 1) { throw 'missing unknown provenance' }
    & pwsh -NoProfile -File $cli verify --workspace $ws | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'verification failed' }
    Write-Output 'PASS: synthetic declared multiagent handoff and provenance'
} finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
