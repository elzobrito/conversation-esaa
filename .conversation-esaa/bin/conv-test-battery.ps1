#requires -Version 7.0
<#
.SYNOPSIS
    Bateria de testes Conversation ESAA v1.1 (integracao + smoke lab + esaa-core).

.DESCRIPTION
    Suite 1 - integration: workspaces temporarios via conv-test.ps1
    Suite 2 - lab_smoke:   activity real do lab (context, verify, topic + legado)
    Suite 3 - esaa_core:   py -3 -m esaa verify no .roadmap

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test-battery.ps1

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test-battery.ps1 -LabWorkspace C:\meu\projeto -SkipEsaa
#>
param(
    [string]$RepoRoot,
    [string]$LabWorkspace,
    [switch]$SkipLab,
    [switch]$SkipEsaa,
    [switch]$JsonReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))).Path
}
if (-not $LabWorkspace) {
    $LabWorkspace = $RepoRoot
}
$LabWorkspace = (Resolve-Path -LiteralPath $LabWorkspace).Path

$binDir = Join-Path $RepoRoot '.conversation-esaa\bin'
$convTest = Join-Path $binDir 'conv-test.ps1'
$cli = Join-Path $binDir 'conversation-esaa.ps1'

$suites = [ordered]@{}
$startedAt = [datetimeoffset]::UtcNow

function Add-SuiteResult {
    param(
        [string]$Name,
        [int]$Passed,
        [int]$Failed,
        [string[]]$Details = @()
    )
    $script:suites[$Name] = [ordered]@{
        passed = $Passed
        failed = $Failed
        details = $Details
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

function Assert-Lab {
    param(
        [bool]$Condition,
        [ref]$Passed,
        [ref]$Failed,
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Name,
        [string]$Detail = ''
    )
    if ($Condition) {
        $Passed.Value++
        $Lines.Add("PASS  $Name")
    } else {
        $Failed.Value++
        $line = "FAIL  $Name"
        if ($Detail) { $line += " — $Detail" }
        $Lines.Add($line)
    }
}

# --- Suite 1: integration (conv-test.ps1) --------------------------------
Write-Output '== suite: integration =='
$integrationOut = & pwsh -NoProfile -ExecutionPolicy Bypass -File $convTest -RepoRoot $RepoRoot 2>&1 | Out-String
$integrationPassed = 0
$integrationFailed = 0
if ($integrationOut -match 'conv-test:\s+(\d+)\s+passed,\s+(\d+)\s+failed') {
    $integrationPassed = [int]$Matches[1]
    $integrationFailed = [int]$Matches[2]
} else {
    $integrationFailed = 1
}
$integrationDetails = @($integrationOut -split "`n" | Where-Object { $_ -match '^\s*(PASS|FAIL)\s' })
Add-SuiteResult -Name 'integration' -Passed $integrationPassed -Failed $integrationFailed -Details $integrationDetails

# --- Suite 2: lab_smoke (activity real) ------------------------------------
$labPassed = 0
$labFailed = 0
$labLines = [System.Collections.Generic.List[string]]::new()

if (-not $SkipLab) {
    Write-Output '== suite: lab_smoke =='

    $labVerify = Invoke-ConvCli -Workspace $LabWorkspace -Command 'verify'
    Assert-Lab ($labVerify.Output -match 'verify: ok') ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_verify_ok' $labVerify.Output

    $ctxGrok = Invoke-ConvCli -Workspace $LabWorkspace -Command 'context' -Params @{ Agent = 'grok'; Last = 20 }
    Assert-Lab ($ctxGrok.ExitCode -eq 0 -and $ctxGrok.Output -match 'count:\s+(\d+)') ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_context_grok_last_20' $ctxGrok.Output
    if ($ctxGrok.Output -match 'count:\s+(\d+)') {
        $grokCount = [int]$Matches[1]
        Assert-Lab ($grokCount -gt 0) ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_context_grok_nonempty' "count=$grokCount"
    }
    Assert-Lab ($ctxGrok.Output -notmatch 'foreign workspace leak') ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_context_grok_no_foreign_leak'

    $ctxCodex = Invoke-ConvCli -Workspace $LabWorkspace -Command 'context' -Params @{ Agent = 'codex'; Last = 5 }
    Assert-Lab ($ctxCodex.ExitCode -eq 0 -and $ctxCodex.Output -match 'assistant/codex') ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_context_codex_last_5' $ctxCodex.Output

    $ctxTopicGrok = Invoke-ConvCli -Workspace $LabWorkspace -Command 'context' -Params @{ Topic = 'Grok' }
    Assert-Lab ($ctxTopicGrok.ExitCode -eq 0 -and $ctxTopicGrok.Output -match '## Events') ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_context_topic_grok' $ctxTopicGrok.Output

    $ctxTopicWs = Invoke-ConvCli -Workspace $LabWorkspace -Command 'context' -Params @{ Topic = 'workspace'; Last = 5 }
    Assert-Lab ($ctxTopicWs.ExitCode -eq 0 -and $ctxTopicWs.Output -match 'count:') ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_context_topic_workspace_last_5' $ctxTopicWs.Output
    Assert-Lab ($ctxTopicWs.Output -match '\(legacy\)|evt_') ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_context_topic_handles_mixed_log'

    $ctxJson = Invoke-ConvCli -Workspace $LabWorkspace -Command 'context' -Params @{ Agent = 'grok'; Last = 3; Json = $true }
    $jsonOk = $false
    if ($ctxJson.ExitCode -eq 0) {
        try {
            $parsed = $ctxJson.Output | ConvertFrom-Json
            $jsonOk = ($parsed -is [array]) -or ($parsed.PSObject.Properties.Name.Count -gt 0)
        } catch {
            $jsonOk = $false
        }
    }
    Assert-Lab $jsonOk ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_context_json_output' $ctxJson.Output

    $labProject = Invoke-ConvCli -Workspace $LabWorkspace -Command 'project'
    Assert-Lab ($labProject.Output -match 'project: regenerated') ([ref]$labPassed) ([ref]$labFailed) $labLines 'lab_project_ok' $labProject.Output

    Add-SuiteResult -Name 'lab_smoke' -Passed $labPassed -Failed $labFailed -Details @($labLines)
} else {
    Add-SuiteResult -Name 'lab_smoke' -Passed 0 -Failed 0 -Details @('SKIP  lab_smoke')
}

# --- Suite 3: esaa_core ----------------------------------------------------
$esaaPassed = 0
$esaaFailed = 0
$esaaDetails = [System.Collections.Generic.List[string]]::new()

if (-not $SkipEsaa) {
    Write-Output '== suite: esaa_core =='
    $esaaOut = & py -3 -m esaa --root $LabWorkspace verify 2>&1 | Out-String
    $esaaOk = $false
    try {
        $esaaJson = $esaaOut | ConvertFrom-Json
        $esaaOk = ($esaaJson.verify_status -eq 'ok')
    } catch {
        $esaaOk = $false
    }
    if ($esaaOk) {
        $esaaPassed = 1
        $esaaDetails.Add('PASS  esaa_verify_ok')
    } else {
        $esaaFailed = 1
        $esaaDetails.Add("FAIL  esaa_verify_ok — $esaaOut")
    }
    Add-SuiteResult -Name 'esaa_core' -Passed $esaaPassed -Failed $esaaFailed -Details @($esaaDetails)
} else {
    Add-SuiteResult -Name 'esaa_core' -Passed 0 -Failed 0 -Details @('SKIP  esaa_core')
}

# --- Report ----------------------------------------------------------------
$totalPassed = 0
$totalFailed = 0
foreach ($name in $suites.Keys) {
    $totalPassed += $suites[$name].passed
    $totalFailed += $suites[$name].failed
}

$finishedAt = [datetimeoffset]::UtcNow
$report = [ordered]@{
    schema_version = 'conversation-esaa.test-battery.v1'
    repo_root = $RepoRoot
    lab_workspace = $LabWorkspace
    started_at = $startedAt.ToString('o')
    finished_at = $finishedAt.ToString('o')
    suites = $suites
    totals = [ordered]@{
        passed = $totalPassed
        failed = $totalFailed
    }
}

Write-Output ''
Write-Output '=== Conversation ESAA Test Battery ==='
Write-Output ''
foreach ($name in $suites.Keys) {
    $s = $suites[$name]
    Write-Output ("suite {0}: {1} passed, {2} failed" -f $name, $s.passed, $s.failed)
    foreach ($line in $s.details) {
        if ($line -match '^\s*(PASS|FAIL|SKIP)\s') { Write-Output "  $line" }
    }
    Write-Output ''
}
Write-Output ("battery: {0} passed, {1} failed" -f $totalPassed, $totalFailed)

if ($JsonReport) {
    $reportPath = Join-Path $RepoRoot '.conversation-esaa\run\test-battery-report.json'
    $runDir = Split-Path -Parent $reportPath
    if (-not (Test-Path -LiteralPath $runDir)) {
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    }
    [System.IO.File]::WriteAllText(
        $reportPath,
        (($report | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Output "report: $reportPath"
}

if ($totalFailed -gt 0) { exit 1 }
exit 0