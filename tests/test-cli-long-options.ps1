#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceCli = Join-Path $repo '.conversation-esaa/bin/conversation-esaa.ps1'
$temp = Join-Path ([System.IO.Path]::GetTempPath()) (
    'conversation-esaa-long-options-' + [guid]::NewGuid().ToString('N')
)
$bin = Join-Path $temp '.conversation-esaa/bin'
$cli = Join-Path $bin 'conversation-esaa.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Quote-PowerShellLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Cli {
    param(
        [ValidateSet('File', 'Command')]
        [string]$Mode,
        [string[]]$Arguments,
        [switch]$ExpectFailure
    )
    if ($Mode -eq 'File') {
        $output = & $pwsh -NoProfile -File $cli @Arguments 2>&1
    } else {
        $expression = @(
            '&'
            (Quote-PowerShellLiteral $cli)
            ($Arguments | ForEach-Object { Quote-PowerShellLiteral $_ })
        ) -join ' '
        $output = & $pwsh -NoProfile -Command $expression 2>&1
    }
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($ExpectFailure) {
        Assert-True ($exitCode -ne 0) "$Mode invocation unexpectedly succeeded: $text"
        return $text
    }
    Assert-True ($exitCode -eq 0) "$Mode invocation failed ($exitCode): $text"
    return ($text | ConvertFrom-Json)
}

function Assert-ContainsSequence {
    param(
        [object[]]$Values,
        [string[]]$Sequence,
        [string]$Message
    )
    $joined = @($Values) -join [char]0x1f
    $expected = $Sequence -join [char]0x1f
    Assert-True ($joined.Contains($expected)) $Message
}

try {
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item -LiteralPath $sourceCli -Destination $cli
    $capture = @'
param(
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)
[ordered]@{
    command = $Command
    rest = @($Rest)
} | ConvertTo-Json -Compress
'@
    foreach ($name in @('conv-sync.ps1', 'conv-rag.ps1')) {
        [System.IO.File]::WriteAllText(
            (Join-Path $bin $name),
            $capture,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    foreach ($name in @(
        'conv-bootstrap.ps1',
        'codex-watch.ps1',
        'antigravity-hook-sync.ps1'
    )) {
        [System.IO.File]::WriteAllText(
            (Join-Path $bin $name),
            "Write-Output 'stub'`n",
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    foreach ($mode in @('File', 'Command')) {
        $separate = Invoke-Cli -Mode $mode -Arguments @(
            'sync', '--agent', 'claude', '--workspace', $temp
        )
        Assert-True ($separate.command -eq 'sync-claude') "$mode separated agent"
        Assert-ContainsSequence $separate.rest @('-WorkspaceRoot', $temp) (
            "$mode separated workspace"
        )

        $equals = Invoke-Cli -Mode $mode -Arguments @(
            'sync', '--agent=codex', "--workspace=$temp", '--mode=compact'
        )
        Assert-True ($equals.command -eq 'sync-codex') "$mode equals agent"
        Assert-ContainsSequence $equals.rest @('-Mode', 'compact') "$mode equals mode"

        if ($mode -eq 'File') {
            $native = Invoke-Cli -Mode $mode -Arguments @(
                'sync', '-Agent', 'grok', '-Workspace', $temp
            )
            Assert-True ($native.command -eq 'sync-grok') "$mode native single dash"
        }

        $decision = Invoke-Cli -Mode $mode -Arguments @(
            'decide', 'keep positional text', "--workspace=$temp", '--source=EV-7'
        )
        Assert-ContainsSequence $decision.rest @(
            '-DecisionText', 'keep positional text'
        ) "$mode decision text"
        Assert-ContainsSequence $decision.rest @(
            '-DecisionSource', 'EV-7'
        ) "$mode source override"

        $topic = Invoke-Cli -Mode $mode -Arguments @(
            'topics', 'link', 'TOP-001', '--event-id', 'EV-1',
            '--events=EV-2', "--workspace=$temp"
        )
        Assert-ContainsSequence $topic.rest @(
            '-TopicEventIds', 'EV-1,EV-2'
        ) "$mode repeated alias array"

        $rag = Invoke-Cli -Mode $mode -Arguments @(
            'rag', 'enable', "--workspace=$temp", '--command=/tmp/rag tool',
            '--timeout=7', '--base_url=http://127.0.0.1:11434', '--json'
        )
        Assert-ContainsSequence $rag.rest @(
            '-CommandPath', '/tmp/rag tool'
        ) "$mode command override"
        Assert-ContainsSequence $rag.rest @(
            '-TimeoutSeconds', '7'
        ) "$mode timeout override"
        Assert-ContainsSequence $rag.rest @('-Json') "$mode switch"

        $search = Invoke-Cli -Mode $mode -Arguments @(
            'search', 'needle', "--workspace=$temp", '--top_k=7',
            '--min-score=0.5'
        )
        Assert-ContainsSequence $search.rest @('-Query', 'needle') "$mode query"
        Assert-ContainsSequence $search.rest @('-TopK', '7') "$mode typed integer"
        Assert-ContainsSequence $search.rest @(
            '-MinScore', '0.5'
        ) "$mode typed double"

        $unknown = Invoke-Cli -Mode $mode -Arguments @(
            'decide', '--literal-unknown', "--workspace=$temp"
        )
        Assert-ContainsSequence $unknown.rest @(
            '-DecisionText', '--literal-unknown'
        ) "$mode unknown token preserved"

        $missing = Invoke-Cli -Mode $mode -Arguments @(
            'sync', '--agent'
        ) -ExpectFailure
        $expectedMissing = if ($mode -eq 'File') {
            "Missing an argument for parameter 'Agent'."
        } else {
            'Option --agent requires a value.'
        }
        Assert-True ($missing.Contains($expectedMissing)) "$mode missing value error"

        $emptyAttached = Invoke-Cli -Mode $mode -Arguments @(
            'sync', '--agent='
        ) -ExpectFailure
        Assert-True (
            $emptyAttached.Contains('Option --agent requires a value.')
        ) "$mode empty attached value error"

        $switchValue = Invoke-Cli -Mode $mode -Arguments @(
            'verify', '--json=true', "--workspace=$temp"
        ) -ExpectFailure
        Assert-True (
            $switchValue.Contains('Option --json does not accept a value.')
        ) "$mode switch value error"
    }

    $conflictExpression = "& $(Quote-PowerShellLiteral $cli) sync " +
        "-Agent claude --agent grok -Workspace $(Quote-PowerShellLiteral $temp)"
    $conflictOutput = & $pwsh -NoProfile -Command $conflictExpression 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'native and normalized conflict must fail'
    $conflict = ($conflictOutput | Out-String).Trim()
    Assert-True (
        $conflict.Contains(
            'Option --agent conflicts with PowerShell parameter -Agent.'
        )
    ) 'native and normalized duplicate conflict'

    $nativeExpression = "& $(Quote-PowerShellLiteral $cli) sync " +
        "-Agent grok -Workspace $(Quote-PowerShellLiteral $temp)"
    $nativeOutput = & $pwsh -NoProfile -Command $nativeExpression 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'Command native single dash invocation'
    $nativeCommand = (($nativeOutput | Out-String).Trim() | ConvertFrom-Json)
    Assert-True (
        $nativeCommand.command -eq 'sync-grok'
    ) 'Command native single dash binding'

    $invalidMode = Invoke-Cli -Mode Command -Arguments @(
        'sync', '--agent=claude', '--mode=turbo', "--workspace=$temp"
    ) -ExpectFailure
    Assert-True (
        $invalidMode.Contains("Option --mode has invalid value 'turbo'.") -and
        $invalidMode.Contains('Expected one of: normal,') -and
        $invalidMode.Contains('compact.')
    ) 'ValidateSet error'

    Write-Output 'test-cli-long-options: ALL PASSED'
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}
