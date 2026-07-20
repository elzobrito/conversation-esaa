#requires -Version 7.0
<#
  Contract tests for conv-rag.ps1 rag-sqlite protocol (stubbed external binary).
  Covers exit 0/1/2/9, valid JSON, ok=false, empty/invalid stdout, stderr isolation,
  empty-index success, refresh failure preserving dirty/generation, public exit codes.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Assert-True (Test-Path -LiteralPath $rag) 'conv-rag.ps1 present'

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rag-contract-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

try {
    $ws = Join-Path $tmpRoot 'ws'
    $stubDir = Join-Path $tmpRoot 'stub'
    New-Item -ItemType Directory -Force -Path $ws, $stubDir | Out-Null
    $esaa = Join-Path $ws '.conversation-esaa'
    $ragDir = Join-Path $esaa 'rag'
    New-Item -ItemType Directory -Force -Path $esaa, $ragDir, (Join-Path $ragDir 'corpus'), (Join-Path $ragDir 'logs') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $esaa 'activity.jsonl'), '', [System.Text.UTF8Encoding]::new($false))

    $stub = Join-Path $stubDir 'rag-sqlite'
    $modeFile = Join-Path $stubDir 'mode.txt'

    # Portable stub: bash script that reads MODE and emits controlled stdout/stderr/exit.
    $stubBody = @'
#!/usr/bin/env bash
set -euo pipefail
MODE_FILE="$(dirname "$0")/mode.txt"
MODE="ok"
if [[ -f "$MODE_FILE" ]]; then MODE="$(cat "$MODE_FILE")"; fi
# shift past --db X --compact
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db) shift 2 || true ;;
    --compact) shift || true ;;
    *) break ;;
  esac
done
CMD="${1:-}"
case "$MODE" in
  ok)
    if [[ "$CMD" == "schema" ]]; then
      echo '{"schema_version":"rag_sqlite.schema.v1","ok":true,"name":"rag_sqlite"}'
      exit 0
    fi
    if [[ "$CMD" == "config" ]]; then
      echo '{"schema_version":"rag_sqlite.config.set.v1","ok":true}'
      exit 0
    fi
    if [[ "$CMD" == "index" || "$CMD" == "reindex" ]]; then
      echo '{"schema_version":"rag_sqlite.index.v1","ok":true,"generation_id":3,"totals":{"files":2,"indexed":2,"unchanged":0,"empty":0,"error":0}}'
      exit 0
    fi
    if [[ "$CMD" == "query" ]]; then
      echo '{"schema_version":"rag_sqlite.query.v1","ok":true,"hits":[],"meta":{"provider":"ollama","model":"embeddinggemma","backend":"sqlite-vec","generation_id":3}}'
      exit 0
    fi
    echo '{"ok":true}'
    exit 0
    ;;
  empty_index)
    echo '{"schema_version":"rag_sqlite.index.v1","ok":true,"generation_id":1,"totals":{"files":0,"indexed":0,"unchanged":0,"empty":0,"error":0}}' 
    # intentional stderr noise must not poison protocol
    echo 'diag on stderr' 1>&2
    exit 2
    ;;
  exit2_fail)
    echo '{"schema_version":"rag_sqlite.index.v1","ok":true,"generation_id":1,"totals":{"files":5,"indexed":0,"unchanged":0,"empty":0,"error":5}}'
    exit 2
    ;;
  ok_false)
    echo '{"schema_version":"rag_sqlite.index.v1","ok":false,"error":{"code":"boom","message":"nope"}}'
    echo 'stderr noise' 1>&2
    exit 1
    ;;
  empty_stdout)
    echo 'only stderr' 1>&2
    exit 0
    ;;
  invalid_json)
    echo 'NOT-JSON{{{'
    echo 'stderr' 1>&2
    exit 0
    ;;
  exit9)
    echo '{"ok":true,"schema_version":"rag_sqlite.index.v1","totals":{"files":1}}'
    exit 9
    ;;
  config_fail_mid)
    # first config ok via set-ollama, fail on later set
    if [[ "$CMD" == "schema" ]]; then
      echo '{"schema_version":"rag_sqlite.schema.v1","ok":true,"name":"rag_sqlite"}'
      exit 0
    fi
    if [[ "$CMD" == "config" && "${2:-}" == "set-ollama" ]]; then
      echo '{"schema_version":"rag_sqlite.config.set_ollama.v1","ok":true}'
      exit 0
    fi
    if [[ "$CMD" == "config" ]]; then
      echo '{"ok":false,"error":{"message":"mid fail"}}'
      exit 1
    fi
    echo '{"ok":true}'
    exit 0
    ;;
  *)
    echo '{"ok":false,"error":{"message":"unknown mode"}}'
    exit 1
    ;;
esac
'@
    [System.IO.File]::WriteAllText($stub, $stubBody.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    & chmod +x $stub

    function Set-StubMode([string]$Mode) {
        [System.IO.File]::WriteAllText($modeFile, $Mode, [System.Text.UTF8Encoding]::new($false))
    }

    function Invoke-RagAction {
        param([string[]]$Extra)
        $outFile = Join-Path $tmpRoot ("out-" + [guid]::NewGuid().ToString('n') + ".txt")
        $errFile = Join-Path $tmpRoot ("err-" + [guid]::NewGuid().ToString('n') + ".txt")
        $args = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rag,
            '-WorkspaceRoot', $ws
        ) + $Extra
        $p = Start-Process -FilePath 'pwsh' -ArgumentList $args -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $code = if ($null -ne $p.ExitCode) { [int]$p.ExitCode } else { 0 }
        $stdout = if (Test-Path $outFile) { [System.IO.File]::ReadAllText($outFile).Trim() } else { '' }
        $stderr = if (Test-Path $errFile) { [System.IO.File]::ReadAllText($errFile).Trim() } else { '' }
        return [pscustomobject]@{ Code = $code; Stdout = $stdout; Stderr = $stderr }
    }

    function Write-EnabledConfig {
        $cfg = @{
            schema_version     = 'conversation-esaa.rag-config.v1'
            enabled            = $true
            rag_sqlite_command = $stub
            db_path            = (Join-Path $ragDir 'index.sqlite')
            corpus_path        = (Join-Path $ragDir 'corpus')
            base_url           = 'http://127.0.0.1:11434'
            model              = 'embeddinggemma'
            timeout_seconds    = 120
            enabled_at         = (Get-Date).ToString('o')
        }
        $json = $cfg | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText((Join-Path $ragDir 'config.json'), $json + "`n", [System.Text.UTF8Encoding]::new($false))
        # prior successful generation
        $state = @{
            last_refresh_at    = '2026-01-01T00:00:00Z'
            last_index_ok      = $true
            activity_lines     = 7
            last_generation_id = 99
            last_error         = $null
        }
        [System.IO.File]::WriteAllText((Join-Path $ragDir 'state.json'), (($state | ConvertTo-Json -Depth 6) + "`n"), [System.Text.UTF8Encoding]::new($false))
        $dirty = @{ marked_at = '2026-01-01T00:00:00Z'; activity_lines = 7 }
        [System.IO.File]::WriteAllText((Join-Path $ragDir 'dirty.marker'), (($dirty | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
        # touch db path so search readiness checks pass when needed
        [System.IO.File]::WriteAllText((Join-Path $ragDir 'index.sqlite'), 'x', [System.Text.UTF8Encoding]::new($false))
    }

    # --- enable happy path ---
    Set-StubMode 'ok'
    $r = Invoke-RagAction -Extra @('-Action', 'enable', '-CommandPath', $stub, '-Json')
    Assert-True ($r.Code -eq 0) 'enable exit 0'
    $ej = $r.Stdout | ConvertFrom-Json
    Assert-True ($ej.ok -eq $true -and $ej.enabled -eq $true) 'enable ok payload'

    # --- enable mid-fail does not replace prior valid config ---
    Write-EnabledConfig
    $priorCfg = Get-Content (Join-Path $ragDir 'config.json') -Raw
    Set-StubMode 'config_fail_mid'
    $r = Invoke-RagAction -Extra @('-Action', 'enable', '-CommandPath', $stub, '-Json')
    Assert-True ($r.Code -eq 1) 'enable partial fail exit 1'
    $ej = $r.Stdout | ConvertFrom-Json
    Assert-True ($ej.ok -eq $false) 'enable fail ok=false'
    Assert-True ($ej.error.type -in @('RagCommandFailed', 'RagProtocolError', 'AdapterError')) "enable typed error ($($ej.error.type))"
    $afterCfg = Get-Content (Join-Path $ragDir 'config.json') -Raw
    Assert-True ($afterCfg -eq $priorCfg) 'enable partial preserves config.json'

    # --- empty index exit 2 success ---
    Write-EnabledConfig
    Set-StubMode 'empty_index'
    $r = Invoke-RagAction -Extra @('-Action', 'refresh', '-Json')
    Assert-True ($r.Code -eq 0) 'empty index refresh exit 0'
    $rj = $r.Stdout | ConvertFrom-Json
    Assert-True ($rj.ok -eq $true) 'empty index refresh ok'
    Assert-True ($rj.index.totals.files -eq 0) 'empty index files=0'
    $state = Get-Content (Join-Path $ragDir 'state.json') -Raw | ConvertFrom-Json
    Assert-True ($state.last_index_ok -eq $true) 'empty index last_index_ok'

    # --- other exit 2 is failure; preserves generation + dirty ---
    Write-EnabledConfig
    Set-StubMode 'exit2_fail'
    $r = Invoke-RagAction -Extra @('-Action', 'refresh', '-Json')
    Assert-True ($r.Code -eq 1) 'non-empty exit2 refresh exit 1'
    $rj = $r.Stdout | ConvertFrom-Json
    Assert-True ($rj.ok -eq $false) 'non-empty exit2 ok=false'
    Assert-True ($rj.error.type -eq 'RagCommandFailed') 'non-empty exit2 type'
    $state = Get-Content (Join-Path $ragDir 'state.json') -Raw | ConvertFrom-Json
    Assert-True ([int]$state.activity_lines -eq 7) 'failure preserves activity_lines'
    Assert-True ([int]$state.last_generation_id -eq 99) 'failure preserves generation'
    Assert-True (Test-Path (Join-Path $ragDir 'dirty.marker')) 'failure preserves dirty marker'

    # --- ok=false ---
    Write-EnabledConfig
    Set-StubMode 'ok_false'
    $r = Invoke-RagAction -Extra @('-Action', 'refresh', '-Json')
    Assert-True ($r.Code -eq 1) 'ok=false exit 1'
    $rj = $r.Stdout | ConvertFrom-Json
    Assert-True ($rj.ok -eq $false -and $rj.error.type -eq 'RagCommandFailed') 'ok=false typed'
    # public payload must not dump full stderr noise as sole message dump of streams
    Assert-True ($r.Stdout -notmatch 'stderr noise') 'stdout response omits raw stderr noise'

    # --- empty stdout ---
    Write-EnabledConfig
    Set-StubMode 'empty_stdout'
    $r = Invoke-RagAction -Extra @('-Action', 'refresh', '-Json')
    Assert-True ($r.Code -eq 1) 'empty stdout exit 1'
    $rj = $r.Stdout | ConvertFrom-Json
    Assert-True ($rj.error.type -eq 'RagProtocolError') 'empty stdout RagProtocolError'
    Assert-True (Test-Path (Join-Path $ragDir 'dirty.marker')) 'empty stdout keeps dirty'
    $state = Get-Content (Join-Path $ragDir 'state.json') -Raw | ConvertFrom-Json
    Assert-True ([int]$state.activity_lines -eq 7) 'empty stdout preserves activity_lines'

    # --- invalid JSON ---
    Write-EnabledConfig
    Set-StubMode 'invalid_json'
    $r = Invoke-RagAction -Extra @('-Action', 'refresh', '-Json')
    Assert-True ($r.Code -eq 1) 'invalid json exit 1'
    $rj = $r.Stdout | ConvertFrom-Json
    Assert-True ($rj.error.type -eq 'RagProtocolError') 'invalid json RagProtocolError'

    # --- exit 9 ---
    Write-EnabledConfig
    Set-StubMode 'exit9'
    $r = Invoke-RagAction -Extra @('-Action', 'refresh', '-Json')
    Assert-True ($r.Code -eq 1) 'exit9 exit 1'
    $rj = $r.Stdout | ConvertFrom-Json
    Assert-True ($rj.error.type -eq 'RagCommandFailed') 'exit9 RagCommandFailed'

    # --- search disabled exit 2 ---
    Remove-Item -LiteralPath (Join-Path $ragDir 'config.json') -Force -ErrorAction SilentlyContinue
    $r = Invoke-RagAction -Extra @('-Action', 'search', '-Query', 'hello', '-Json')
    Assert-True ($r.Code -eq 2) 'search disabled exit 2'
    $sj = $r.Stdout | ConvertFrom-Json
    Assert-True ($sj.ok -eq $false -and $sj.error.type -eq 'RagUnavailable') 'search disabled typed'
    Assert-True ($sj.schema_version -eq 'conversation-esaa.search.v1') 'search schema'

    # --- search protocol error exit 2 ---
    Write-EnabledConfig
    Set-StubMode 'invalid_json'
    $r = Invoke-RagAction -Extra @('-Action', 'search', '-Query', 'hello', '-Json')
    Assert-True ($r.Code -eq 2) 'search protocol exit 2'
    $sj = $r.Stdout | ConvertFrom-Json
    Assert-True ($sj.error.type -eq 'RagProtocolError') 'search protocol type'

    # --- happy refresh then search ---
    Write-EnabledConfig
    Set-StubMode 'ok'
    $r = Invoke-RagAction -Extra @('-Action', 'refresh', '-Json')
    Assert-True ($r.Code -eq 0) 'happy refresh exit 0'
    $r = Invoke-RagAction -Extra @('-Action', 'search', '-Query', 'hello', '-Json')
    Assert-True ($r.Code -eq 0) 'happy search exit 0'
    $sj = $r.Stdout | ConvertFrom-Json
    Assert-True ($sj.ok -eq $true) 'happy search ok'

    # --- worker always exit 0 (fail-open) even on failure ---
    Write-EnabledConfig
    Set-StubMode 'exit9'
    $r = Invoke-RagAction -Extra @('-Action', 'worker')
    Assert-True ($r.Code -eq 0) 'worker fail-open exit 0'
}
finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host "FAILED $failed assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL RAG COMMAND CONTRACT TESTS PASSED'
exit 0
