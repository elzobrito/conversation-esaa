#requires -Version 7.0
<#
  Regression tests for the double-dash options documented in Show-Help and AGENTS.md
  (--agent, --workspace, --top-k, --json ...).

  These bind under `pwsh -File script.ps1 ...`, where the argument binder normalizes the
  leading double dash. They do NOT bind when the script is dot-invoked from an expression --
  `pwsh -Command "& '...\conversation-esaa.ps1' sync --agent claude"` -- because there the
  parser hands `--agent` to the ValueFromRemainingArguments parameter and $Agent stays empty,
  so the command dies with the very message telling you to pass --agent. Same command line,
  two behaviours, no diagnostic. The shim makes both paths bind.

  These tests run the CLI BOTH ways and assert on the ERROR it reaches, never on a
  successful sync, so no ESAA workspace is required: reaching a *later* error is the proof
  that the option bound.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $repo '.conversation-esaa/bin/conversation-esaa.ps1'
$failed = 0

function Assert-True($cond, $msg) {
    if (-not $cond) {
        Write-Host "FAIL: $msg" -ForegroundColor Red
        $script:failed++
    } else {
        Write-Host "OK: $msg"
    }
}

# -File: PowerShell's argument binder already normalizes the leading double dash.
function Invoke-Cli {
    param([string[]]$CliArgs)
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $cli @CliArgs 2>&1
    return ($out | Out-String)
}

# -Command with the call operator: the path that silently dropped the options before the
# shim. This is how wrappers, task runners and agent tooling usually invoke the CLI.
function Invoke-CliViaCommand {
    param([string]$Line)
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$cli' $Line" 2>&1
    return ($out | Out-String)
}

Assert-True (Test-Path -LiteralPath $cli) 'conversation-esaa.ps1 present'

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cli-longopts-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

try {
    # --agent binds: we must NOT see the "sync requires --agent" guard any more.
    $o = Invoke-Cli @('sync', '--agent', 'claude', '--workspace', $tmpRoot)
    Assert-True ($o -notmatch 'sync requires --agent') '--agent value binds (guard not hit)'

    # --agent=value form.
    $o = Invoke-Cli @('sync', '--agent=claude', '--workspace', $tmpRoot)
    Assert-True ($o -notmatch 'sync requires --agent') '--agent=value binds'

    # The value still reaches the agent whitelist: a bogus one hits "Unknown agent".
    $o = Invoke-Cli @('sync', '--agent', 'nope', '--workspace', $tmpRoot)
    Assert-True ($o -match 'Unknown agent') 'bogus --agent reaches the whitelist check'

    # Single-dash PowerShell binding keeps working.
    $o = Invoke-Cli @('sync', '-Agent', 'claude', '-Workspace', $tmpRoot)
    Assert-True ($o -notmatch 'sync requires --agent') '-Agent still binds (no regression)'

    # Missing --agent still produces the documented guard.
    $o = Invoke-Cli @('sync', '--workspace', $tmpRoot)
    Assert-True ($o -match 'sync requires --agent') 'missing --agent still guarded'

    # Unknown long options are left alone, not rejected.
    $o = Invoke-Cli @('verify', '--not-a-real-option', 'x', '--workspace', $tmpRoot)
    Assert-True ($o -notmatch 'Option --not-a-real-option') 'unknown long option is ignored, not fatal'

    # A long option with no value is a clear error, never a silent empty bind. Under -File
    # PowerShell's own binder reports it first; under -Command the shim does.
    $o = Invoke-Cli @('sync', '--agent')
    Assert-True ($o -match 'requires a value|Missing an argument') 'valueless long option errors explicitly (-File)'

    # help is untouched.
    $o = Invoke-Cli @('help')
    Assert-True ($o -match 'Conversation ESAA') 'help still works'

    # ---- the path this shim exists for: -Command with the call operator ----
    $o = Invoke-CliViaCommand "sync --agent claude --workspace '$tmpRoot'"
    Assert-True ($o -notmatch 'sync requires --agent') '--agent binds under -Command (the regression)'

    $o = Invoke-CliViaCommand "sync --agent=claude --workspace '$tmpRoot'"
    Assert-True ($o -notmatch 'sync requires --agent') '--agent=value binds under -Command'

    $o = Invoke-CliViaCommand "sync --agent nope --workspace '$tmpRoot'"
    Assert-True ($o -match 'Unknown agent') 'bogus --agent reaches the whitelist under -Command'

    $o = Invoke-CliViaCommand "sync --workspace '$tmpRoot'"
    Assert-True ($o -match 'sync requires --agent') 'missing --agent still guarded under -Command'

    $o = Invoke-CliViaCommand "sync --agent"
    Assert-True ($o -match 'requires a value') 'valueless long option errors explicitly (-Command)'

    $o = Invoke-CliViaCommand 'help'
    Assert-True ($o -match 'Conversation ESAA') 'help still works under -Command'
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host "`n$failed test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll long-option tests passed."
exit 0
