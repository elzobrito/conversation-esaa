#requires -Version 7.0
<#
  Unix permission hardening for Conversation ESAA RAG projection.
  Requires Linux/macOS (skips on Windows).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($IsWindows) {
    Write-Host 'SKIP: permission hardening tests are Unix-only'
    exit 0
}

$repo = Split-Path -Parent $PSScriptRoot
$rag = Join-Path $repo '.conversation-esaa/bin/conv-rag.ps1'
$failed = 0

function Assert-True($cond, $msg) {
    if (-not $cond) {
        Write-Host "FAIL: $msg" -ForegroundColor Red
        $script:failed++
    } else {
        Write-Host "OK: $msg"
    }
}

function Get-Mode([string]$Path) {
    $stat = & stat -c '%a' -- $Path 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return [string]$stat.Trim()
}

Assert-True (Test-Path -LiteralPath $rag) 'conv-rag.ps1 present'

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rag-perm-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

try {
    $ws = Join-Path $tmpRoot 'ws'
    $esaa = Join-Path $ws '.conversation-esaa'
    $ragDir = Join-Path $esaa 'rag'
    $corpus = Join-Path $ragDir 'corpus'
    $logs = Join-Path $ragDir 'logs'
    New-Item -ItemType Directory -Force -Path $esaa, $ragDir, $corpus, $logs | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $esaa 'activity.jsonl'), '', [System.Text.UTF8Encoding]::new($false))

    # Deliberately permissive modes + wal/shm/lock/logs (valid JSON where applicable)
    New-Item -ItemType Directory -Force -Path (Join-Path $corpus 'aa') | Out-Null
    $fileContents = @{
        (Join-Path $ragDir 'config.json')      = "{`"schema_version`":`"conversation-esaa.rag-config.v1`",`"enabled`":false}`n"
        (Join-Path $ragDir 'state.json')       = "{`"activity_lines`":0}`n"
        (Join-Path $ragDir 'manifest.json')    = "{`"events`":{}}`n"
        (Join-Path $ragDir 'dirty.marker')     = "{`"marked_at`":`"t`",`"activity_lines`":0}`n"
        (Join-Path $ragDir 'worker.lock')      = ''
        (Join-Path $ragDir 'index.sqlite')     = 'sqlite-placeholder'
        (Join-Path $ragDir 'index.sqlite-wal') = 'wal'
        (Join-Path $ragDir 'index.sqlite-shm') = 'shm'
        (Join-Path $logs 'worker.log')         = "log`n"
        (Join-Path $corpus 'aa/doc.md')        = "# doc`n"
    }
    foreach ($p in $fileContents.Keys) {
        [System.IO.File]::WriteAllText($p, $fileContents[$p], [System.Text.UTF8Encoding]::new($false))
        & chmod 777 -- $p 2>$null
    }
    & chmod 777 -- $ragDir $corpus $logs (Join-Path $corpus 'aa') 2>$null

    # Symlink that must NOT be followed / must not alter target
    $outside = Join-Path $tmpRoot 'outside-secret'
    [System.IO.File]::WriteAllText($outside, "secret`n", [System.Text.UTF8Encoding]::new($false))
    & chmod 644 -- $outside
    $link = Join-Path $ragDir 'evil-link'
    & ln -s -- $outside $link
    $modeOutsideBefore = Get-Mode $outside

    # Stub rag-sqlite that succeeds
    $stubDir = Join-Path $tmpRoot 'stub'
    New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
    $stub = Join-Path $stubDir 'rag-sqlite'
    $stubBody = @'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db) shift 2 || true ;;
    --compact) shift || true ;;
    *) break ;;
  esac
done
CMD="${1:-}"
if [[ "$CMD" == "schema" ]]; then
  echo '{"schema_version":"rag_sqlite.schema.v1","ok":true,"name":"rag_sqlite"}'
  exit 0
fi
if [[ "$CMD" == "config" ]]; then
  echo '{"schema_version":"rag_sqlite.config.set.v1","ok":true}'
  exit 0
fi
if [[ "$CMD" == "index" || "$CMD" == "reindex" ]]; then
  # recreate wal/shm loose if missing
  DBDIR="$(dirname "${RAG_DB_HINT:-}")"
  echo '{"schema_version":"rag_sqlite.index.v1","ok":true,"generation_id":1,"totals":{"files":0,"indexed":0,"unchanged":0,"empty":0,"error":0}}'
  exit 2
fi
if [[ "$CMD" == "query" ]]; then
  echo '{"schema_version":"rag_sqlite.query.v1","ok":true,"hits":[],"meta":{}}'
  exit 0
fi
echo '{"ok":true}'
exit 0
'@
    [System.IO.File]::WriteAllText($stub, $stubBody.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    & chmod +x -- $stub

    function Invoke-Rag {
        param([string[]]$Extra)
        $outFile = Join-Path $tmpRoot ("o-" + [guid]::NewGuid().ToString('n'))
        $errFile = Join-Path $tmpRoot ("e-" + [guid]::NewGuid().ToString('n'))
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rag, '-WorkspaceRoot', $ws) + $Extra
        $p = Start-Process -FilePath 'pwsh' -ArgumentList $args -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $code = if ($null -ne $p.ExitCode) { [int]$p.ExitCode } else { 0 }
        $stdout = if (Test-Path $outFile) { [System.IO.File]::ReadAllText($outFile).Trim() } else { '' }
        return [pscustomobject]@{ Code = $code; Stdout = $stdout }
    }

    # enable should harden tree
    $r = Invoke-Rag -Extra @('-Action', 'enable', '-CommandPath', $stub, '-Json')
    Assert-True ($r.Code -eq 0) 'enable exit 0'
    $ej = $r.Stdout | ConvertFrom-Json
    Assert-True ($ej.ok -eq $true) 'enable ok'

    Assert-True ((Get-Mode $ragDir) -eq '700') 'rag root 0700'
    Assert-True ((Get-Mode $corpus) -eq '700') 'corpus 0700'
    Assert-True ((Get-Mode $logs) -eq '700') 'logs 0700'
    foreach ($name in @('config.json', 'dirty.marker', 'index.sqlite')) {
        $p = Join-Path $ragDir $name
        if (Test-Path -LiteralPath $p) {
            Assert-True ((Get-Mode $p) -eq '600') "$name 0600"
        }
    }
    # wal/shm if present
    foreach ($name in @('index.sqlite-wal', 'index.sqlite-shm', 'worker.lock')) {
        $p = Join-Path $ragDir $name
        if (Test-Path -LiteralPath $p) {
            Assert-True ((Get-Mode $p) -eq '600') "$name 0600"
        }
    }
    $modeOutsideAfter = Get-Mode $outside
    Assert-True ($modeOutsideAfter -eq $modeOutsideBefore) 'symlink target mode unchanged'
    # symlink itself may or may not be chmod'd; we skip reparse points so target untouched is the key

    # Make loose again and refresh
    & chmod 777 -- $ragDir $corpus $logs 2>$null
    foreach ($name in @('config.json', 'state.json', 'index.sqlite', 'index.sqlite-wal', 'index.sqlite-shm', 'dirty.marker')) {
        $p = Join-Path $ragDir $name
        if (Test-Path $p) { & chmod 666 -- $p 2>$null }
    }
    $r = Invoke-Rag -Extra @('-Action', 'refresh', '-Json')
    Assert-True ($r.Code -eq 0) 'refresh exit 0'
    $rj = $r.Stdout | ConvertFrom-Json
    Assert-True ($rj.ok -eq $true) 'refresh ok'
    Assert-True ((Get-Mode $ragDir) -eq '700') 'after refresh rag 0700'
    Assert-True ((Get-Mode (Join-Path $ragDir 'index.sqlite')) -eq '600') 'after refresh db 0600'

    # --- chmod failure simulation via PATH shim ---
    $shimDir = Join-Path $tmpRoot 'shim'
    New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
    $realChmod = (Get-Command chmod).Source
    $shim = Join-Path $shimDir 'chmod'
    $shimBody = @'
#!/usr/bin/env bash
# Fail when hardening the rag config file
for a in "$@"; do
  if [[ "$a" == *"/rag/config.json" ]]; then
    echo "simulated chmod failure" >&2
    exit 1
  fi
done
exec REAL_CHMOD_PLACEHOLDER "$@"
'@
    $shimBody = $shimBody.Replace('REAL_CHMOD_PLACEHOLDER', $realChmod).Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($shim, $shimBody, [System.Text.UTF8Encoding]::new($false))
    & $realChmod +x -- $shim

    # Ensure dirty exists before failed refresh
    [System.IO.File]::WriteAllText((Join-Path $ragDir 'dirty.marker'), "{`"marked_at`":`"t`"}`n", [System.Text.UTF8Encoding]::new($false))
    $priorState = @{
        last_refresh_at    = '2026-01-01T00:00:00Z'
        last_index_ok      = $true
        activity_lines     = 3
        last_generation_id = 42
        last_error         = $null
    }
    [System.IO.File]::WriteAllText((Join-Path $ragDir 'state.json'), (($priorState | ConvertTo-Json) + "`n"), [System.Text.UTF8Encoding]::new($false))

    $env:PATH = "${shimDir}:" + $env:PATH
    try {
        $r = Invoke-Rag -Extra @('-Action', 'refresh', '-Json')
        Assert-True ($r.Code -eq 1) 'chmod fail refresh exit 1'
        $rj = $r.Stdout | ConvertFrom-Json
        Assert-True ($rj.ok -eq $false) 'chmod fail not ok=true'
        Assert-True ($rj.error.type -eq 'PermissionHardeningFailed') "chmod fail type ($($rj.error.type))"
        Assert-True (Test-Path (Join-Path $ragDir 'dirty.marker')) 'chmod fail preserves dirty'
        $st = Get-Content (Join-Path $ragDir 'state.json') -Raw | ConvertFrom-Json
        Assert-True ([int]$st.activity_lines -eq 3 -or [int]$st.last_generation_id -eq 42 -or $st.last_index_ok -eq $false) 'chmod fail does not claim success generation'
    } finally {
        # restore PATH by removing shim prefix
        $env:PATH = ($env:PATH -split ':' | Where-Object { $_ -ne $shimDir }) -join ':'
    }

    # worker fail-open: still exit 0 even if hardening fails
    $env:PATH = "${shimDir}:" + $env:PATH
    try {
        # Contract: worker exits 0 (fail-open for conversational pipeline).
        $r = Invoke-Rag -Extra @('-Action', 'worker')
        Assert-True ($r.Code -eq 0) 'worker fail-open exit 0 under chmod failure'
    } finally {
        $env:PATH = ($env:PATH -split ':' | Where-Object { $_ -ne $shimDir }) -join ':'
    }
}
finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host "FAILED $failed assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL RAG PERMISSIONS TESTS PASSED'
exit 0
