#requires -Version 7.0
<#
  Minimal regression for optional RAG adapter.
  Uses ONLY the runtime installed into a temporary workspace by bootstrap —
  never the repository-source .conversation-esaa/bin paths for CLI/adapter execution.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$srcBootstrap = Join-Path $repo '.conversation-esaa/bin/conv-bootstrap.ps1'
$srcRag = Join-Path $repo '.conversation-esaa/bin/conv-rag.ps1'
$failed = 0

function Assert-True($cond, $msg) {
    if (-not $cond) {
        Write-Host "FAIL: $msg" -ForegroundColor Red
        $script:failed++
    } else {
        Write-Host "OK: $msg"
    }
}

Assert-True (Test-Path -LiteralPath $srcBootstrap) 'source conv-bootstrap.ps1 present'
Assert-True (Test-Path -LiteralPath $srcRag) 'source conv-rag.ps1 present'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("conv-rag-test-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # Custom sentinel in pre-existing .gitignore must be preserved across bootstrap runs.
    $customLine = '# CUSTOM-SENTINEL-RAG-BOOTSTRAP-TEST-do-not-remove'
    $giPath = Join-Path $tmp '.gitignore'
    [System.IO.File]::WriteAllText($giPath, ($customLine + [Environment]::NewLine + 'my-custom-ignore.bin' + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

    # bootstrap store from source engine dir (bootstrap copies engines into tmp)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $srcBootstrap -WorkspaceRoot $tmp
    Assert-True ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) 'bootstrap exit'

    $installedBin = Join-Path $tmp '.conversation-esaa/bin'
    $cli = Join-Path $installedBin 'conversation-esaa.ps1'
    $rag = Join-Path $installedBin 'conv-rag.ps1'
    Assert-True (Test-Path -LiteralPath $cli) 'installed conversation-esaa.ps1'
    Assert-True (Test-Path -LiteralPath $rag) 'installed conv-rag.ps1'

    $srcHash = (Get-FileHash -LiteralPath $srcRag -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash -LiteralPath $rag -Algorithm SHA256).Hash
    Assert-True ($srcHash -eq $dstHash) 'conv-rag.ps1 hash matches source'

    # Bootstrap must not enable RAG or create index/config/ollama state
    $ragRoot = Join-Path $tmp '.conversation-esaa/rag'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ragRoot 'config.json'))) 'bootstrap did not create config.json'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ragRoot 'index.sqlite'))) 'bootstrap did not create index.sqlite'

    $gi = Get-Content -LiteralPath $giPath -Raw
    Assert-True ($gi.Contains($customLine)) 'custom gitignore sentinel preserved'
    Assert-True ($gi.Contains('my-custom-ignore.bin')) 'custom gitignore entry preserved'
    Assert-True ($gi.Contains('.conversation-esaa/rag/')) 'gitignore has rag/'
    $ragCount = ([regex]::Matches($gi, [regex]::Escape('.conversation-esaa/rag/'))).Count
    Assert-True ($ragCount -eq 1) 'single rag/ gitignore entry after first bootstrap'

    # Idempotent re-bootstrap
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $srcBootstrap -WorkspaceRoot $tmp
    Assert-True ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) 'bootstrap rerun exit'
    $gi2 = Get-Content -LiteralPath $giPath -Raw
    Assert-True ($gi2.Contains($customLine)) 'sentinel after rerun'
    $ragCount2 = ([regex]::Matches($gi2, [regex]::Escape('.conversation-esaa/rag/'))).Count
    Assert-True ($ragCount2 -eq 1) 'single rag/ entry after rerun'
    $activity = Join-Path $tmp '.conversation-esaa/activity.jsonl'
    Assert-True (Test-Path -LiteralPath $activity) 'activity store preserved'

    $eid1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $eid2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $ev1 = @{
        event_id = $eid1
        ts = '2026-07-20T12:00:00-03:00'
        event = 'conversation_turn'
        actor = 'user'
        agent_id = $null
        source = 'test'
        workspace_root = $tmp
        summary = 'TOP-011 flask-dashboard RAG embeddings discussion'
        text = 'We discussed TOP-011 about flask-dashboard RAG embeddings and rag.py CLI.'
    } | ConvertTo-Json -Compress
    $ev2 = @{
        event_id = $eid2
        ts = '2026-07-20T12:01:00-03:00'
        event = 'decision.recorded'
        actor = 'user'
        agent_id = $null
        source = 'test'
        workspace_root = $tmp
        summary = 'DEC-0035 example decision about canonical workspace'
        text = 'Decision DEC-0035: only /home/elzobrito/.conversation-esaa is the canonical conversational store.'
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($activity, $ev1 + "`n" + $ev2 + "`n", [System.Text.UTF8Encoding]::new($false))

    # search while disabled -> RagUnavailable (INSTALLED cli only)
    $outFile = Join-Path $tmp 'search-out.txt'
    $errFile = Join-Path $tmp 'search-err.txt'
    $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
        'search', 'TOP-011', '--workspace', $tmp
    ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $code = if ($null -ne $p.ExitCode) { [int]$p.ExitCode } else { 0 }
    $out = if (Test-Path $outFile) { [System.IO.File]::ReadAllText($outFile).Trim() } else { '' }
    Assert-True ($code -eq 2) 'search disabled exit 2'
    $j = $out | ConvertFrom-Json
    Assert-True ($j.ok -eq $false) 'search disabled ok=false'
    Assert-True ($j.error.type -eq 'RagUnavailable') 'search disabled type'

    $ragCmd = (Get-Command rag-sqlite -ErrorAction SilentlyContinue)
    if (-not $ragCmd) {
        Write-Host 'SKIP: rag-sqlite not on PATH — enable/refresh/search happy path skipped'
    } else {
        $enFile = Join-Path $tmp 'en-out.txt'
        $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
            'rag', 'enable', '--workspace', $tmp, '--json'
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $enFile -RedirectStandardError (Join-Path $tmp 'en-err.txt')
        $en = [System.IO.File]::ReadAllText($enFile).Trim()
        $ej = $en | ConvertFrom-Json
        Assert-True ($ej.ok -eq $true -and $ej.enabled -eq $true) 'rag enable via installed CLI'

        # reject remote url via INSTALLED conv-rag.ps1 only
        $remoteFailed = $false
        $rfOut = Join-Path $tmp 'remote-out.txt'
        $rfErr = Join-Path $tmp 'remote-err.txt'
        $rp = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rag,
            '-Action', 'enable', '-WorkspaceRoot', $tmp, '-BaseUrl', 'https://evil.example.com', '-Json'
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $rfOut -RedirectStandardError $rfErr
        $rcode = if ($null -ne $rp.ExitCode) { [int]$rp.ExitCode } else { 0 }
        if ($rcode -ne 0) { $remoteFailed = $true }
        Assert-True $remoteFailed 'remote ollama rejected'

        $rfFile = Join-Path $tmp 'rf-out.txt'
        $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
            'rag', 'refresh', '--workspace', $tmp, '--json'
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $rfFile -RedirectStandardError (Join-Path $tmp 'rf-err.txt')
        $rf = [System.IO.File]::ReadAllText($rfFile).Trim()
        $rj = $rf | ConvertFrom-Json
        Assert-True ($rj.ok -eq $true) 'rag refresh ok via installed CLI'

        # export idempotent second pass via installed adapter
        $rf2File = Join-Path $tmp 'rf2-out.txt'
        $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rag,
            '-Action', 'refresh', '-WorkspaceRoot', $tmp, '-Json'
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $rf2File -RedirectStandardError (Join-Path $tmp 'rf2-err.txt')
        $rf2 = [System.IO.File]::ReadAllText($rf2File).Trim()
        $rj2 = $rf2 | ConvertFrom-Json
        Assert-True ($rj2.export.exported -eq 0) 'second export exported=0'

        $sqFile = Join-Path $tmp 'sq-out.txt'
        $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
            'search', 'TOP-011 flask-dashboard RAG', '--workspace', $tmp, '--min-score', '0.1'
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $sqFile -RedirectStandardError (Join-Path $tmp 'sq-err.txt')
        $sq = [System.IO.File]::ReadAllText($sqFile).Trim()
        $sj = $sq | ConvertFrom-Json
        Assert-True ($sj.schema_version -eq 'conversation-esaa.search.v1') 'search schema'
        Assert-True ($sj.ok -eq $true) 'search ok'
        Assert-True ($sj.content_untrusted -eq $true) 'untrusted'
        Assert-True ($sj.hit_count -ge 1) 'at least one hit'
        if ($sj.hits -and $sj.hits.Count -gt 0) {
            Assert-True ($sj.hits[0].event_id -eq $eid1 -or $sj.hits[0].PSObject.Properties.Name -contains 'event_id') 'hit has event_id'
        }

        $dsFile = Join-Path $tmp 'ds-out.txt'
        $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
            'rag', 'disable', '--workspace', $tmp, '--json'
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $dsFile -RedirectStandardError (Join-Path $tmp 'ds-err.txt')
        $ds = [System.IO.File]::ReadAllText($dsFile).Trim()
        $dj = $ds | ConvertFrom-Json
        Assert-True ($dj.enabled -eq $false) 'disable preserves'

        $pgFile = Join-Path $tmp 'pg-out.txt'
        $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
            'rag', 'disable', '--workspace', $tmp, '--purge', '--json'
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $pgFile -RedirectStandardError (Join-Path $tmp 'pg-err.txt')
        $pg = [System.IO.File]::ReadAllText($pgFile).Trim()
        $pj = $pg | ConvertFrom-Json
        Assert-True ($pj.purged -eq $true) 'purge'
        Assert-True (-not (Test-Path (Join-Path $tmp '.conversation-esaa/rag'))) 'rag dir removed'
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host "FAILED $failed assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL RAG ADAPTER TESTS PASSED'
exit 0
