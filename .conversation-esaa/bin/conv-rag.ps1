#requires -Version 7.0
<#
.SYNOPSIS
  Optional rag-sqlite adapter for Conversation ESAA v1.2 (projection only).
  Protocol: stdout JSON only; exit 0 success; exit 2 empty-index exception only.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('enable', 'status', 'refresh', 'disable', 'search', 'schedule', 'worker')]
    [string]$Action,

    [string]$WorkspaceRoot,
    [string]$CommandPath,
    [string]$BaseUrl = 'http://127.0.0.1:11434',
    [string]$Model = 'embeddinggemma',
    [int]$TimeoutSeconds = 120,
    [string]$Query,
    [int]$TopK = 5,
    [double]$MinScore = 0.25,
    [switch]$Force,
    [switch]$Purge,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Ws {
    if ($WorkspaceRoot) { return (Resolve-Path -LiteralPath $WorkspaceRoot).Path }
    if ($env:GROK_WORKSPACE_ROOT) { return $env:GROK_WORKSPACE_ROOT }
    return (Resolve-Path -LiteralPath (Get-Location).Path).Path
}

function Get-DictVal {
    param($Object, [string]$Key, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.ContainsKey($Key)) { return $Object[$Key] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $Default
}

function Get-RagPaths {
    param([string]$Ws)
    $root = Join-Path $Ws '.conversation-esaa'
    $rag = Join-Path $root 'rag'
    [pscustomobject]@{
        Workspace   = $Ws
        ConvRoot    = $root
        RagRoot     = $rag
        Config      = Join-Path $rag 'config.json'
        State       = Join-Path $rag 'state.json'
        Manifest    = Join-Path $rag 'manifest.json'
        Dirty       = Join-Path $rag 'dirty.marker'
        WorkerLock  = Join-Path $rag 'worker.lock'
        Corpus      = Join-Path $rag 'corpus'
        Db          = Join-Path $rag 'index.sqlite'
        LogDir      = Join-Path $rag 'logs'
        WorkerLog   = Join-Path (Join-Path $rag 'logs') 'worker.log'
        Activity    = Join-Path $root 'activity.jsonl'
    }
}

function New-RagException {
    param(
        [string]$Type,
        [string]$Message,
        [int]$PublicExitCode = 1,
        [hashtable]$Details = $null
    )
    $ex = [System.Exception]::new($Message)
    $ex.Data['RagErrorType'] = $Type
    $ex.Data['PublicExitCode'] = $PublicExitCode
    if ($Details) {
        foreach ($k in $Details.Keys) { $ex.Data[$k] = $Details[$k] }
    }
    return $ex
}

function Get-RagExceptionType {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex.Data -and $ex.Data['RagErrorType']) {
            return [string]$ex.Data['RagErrorType']
        }
        $ex = $ex.InnerException
    }
    return 'AdapterError'
}

function Get-RagPublicExitCode {
    param($ErrorRecord, [int]$Default = 1)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex.Data -and $null -ne $ex.Data['PublicExitCode']) {
            return [int]$ex.Data['PublicExitCode']
        }
        $ex = $ex.InnerException
    }
    return $Default
}

function Set-PrivatePermissions {
    param([string]$Path, [switch]$Directory, [switch]$Soft)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($IsWindows) { return }
    # Never follow symlinks: operate on the path as given; skip if symlink itself when hardening tree.
    $mode = if ($Directory) { '700' } else { '600' }
    $chmodOut = & chmod $mode -- $Path 2>&1
    $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    if ($code -ne 0) {
        $msg = "chmod $mode failed for $Path (exit=$code)"
        if ($Soft) {
            # Soft: used only for best-effort single paths outside critical hardening.
            return
        }
        throw (New-RagException -Type 'PermissionHardeningFailed' -Message $msg -PublicExitCode 1)
    }
}

function Set-PrivateTreePermissions {
    param(
        [string]$Root,
        [switch]$Soft
    )
    if ($IsWindows) { return }
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return }

    # Do not follow symlinks (no -L). Harden the root first if it is a real directory.
    $rootItem = Get-Item -LiteralPath $Root -Force
    if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        # Symlink at rag root: do not follow; nothing recursive to harden through it.
        return
    }
    if ($rootItem.PSIsContainer) {
        Set-PrivatePermissions -Path $Root -Directory -Soft:$Soft
    } else {
        Set-PrivatePermissions -Path $Root -Soft:$Soft
        return
    }

    # Enumerate without following directory symlinks: -Recurse still descends into symlink dirs on some PS versions;
    # filter ReparsePoint entries and do not recurse into them manually via stack.
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                # Skip symlinks entirely (file or dir) — do not chmod target, do not descend.
                continue
            }
            if ($child.PSIsContainer) {
                Set-PrivatePermissions -Path $child.FullName -Directory -Soft:$Soft
                $stack.Push($child.FullName)
            } else {
                Set-PrivatePermissions -Path $child.FullName -Soft:$Soft
            }
        }
    }

    # Explicit sensitive DB siblings that may appear after rag-sqlite runs (wal/shm).
    foreach ($suffix in @('', '-wal', '-shm')) {
        $dbPath = Join-Path $Root ("index.sqlite" + $suffix)
        if ((Test-Path -LiteralPath $dbPath) -and -not ((Get-Item -LiteralPath $dbPath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Set-PrivatePermissions -Path $dbPath -Soft:$Soft
        }
    }
}

function Protect-RagProjection {
    param($P, [switch]$Soft)
    if ($IsWindows) { return }
    if (-not (Test-Path -LiteralPath $P.RagRoot)) { return }
    Set-PrivateTreePermissions -Root $P.RagRoot -Soft:$Soft
}

function Ensure-RagDirs {
    param($P)
    New-Item -ItemType Directory -Force -Path $P.RagRoot, $P.Corpus, $P.LogDir | Out-Null
    Set-PrivatePermissions -Path $P.RagRoot -Directory
    Set-PrivatePermissions -Path $P.Corpus -Directory
    Set-PrivatePermissions -Path $P.LogDir -Directory
}

function Read-JsonFile {
    param([string]$Path, $Default = $null)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable)
    } catch {
        return $Default
    }
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $json = ($Object | ConvertTo-Json -Depth 12)
    [System.IO.File]::WriteAllText($Path, $json + "`n", [System.Text.UTF8Encoding]::new($false))
    Set-PrivatePermissions -Path $Path
}

function Test-LoopbackUrl {
    param([string]$Url)
    try {
        $u = [Uri]$Url
        $h = $u.Host.ToLowerInvariant()
        return $h -in @('127.0.0.1', 'localhost', '::1')
    } catch {
        return $false
    }
}

function Find-RagSqlite {
    param([string]$CommandPath)
    if ($CommandPath) {
        if (-not (Test-Path -LiteralPath $CommandPath)) {
            throw (New-RagException -Type 'RagUnavailable' -Message "rag-sqlite command not found: $CommandPath" -PublicExitCode 1)
        }
        return (Resolve-Path -LiteralPath $CommandPath).Path
    }
    $cmd = Get-Command rag-sqlite -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $HOME '.local/bin/rag-sqlite'
    if (Test-Path -LiteralPath $fallback) { return (Resolve-Path -LiteralPath $fallback).Path }
    throw (New-RagException -Type 'RagUnavailable' -Message 'rag-sqlite not found on PATH. Install wrapper or pass --command PATH. See rag-sqlite README.' -PublicExitCode 1)
}

function Invoke-ExternalCaptured {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    # ProcessStartInfo.ArgumentList preserves spaces in argv (Start-Process -ArgumentList does not).
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($a in @($Arguments)) {
        [void]$psi.ArgumentList.Add([string]$a)
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{
        ExitCode = [int]$proc.ExitCode
        Stdout   = if ($null -eq $stdout) { '' } else { $stdout.Trim() }
        Stderr   = if ($null -eq $stderr) { '' } else { $stderr.Trim() }
    }
}

function Invoke-RagSqlite {
    param(
        [string]$Exe,
        [string]$Db,
        [string[]]$RagArgs,
        $P = $null
    )
    # Capture stdout/stderr separately; never merge into a single stream for protocol parsing.
    $argList = [System.Collections.Generic.List[string]]::new()
    [void]$argList.Add('--db')
    [void]$argList.Add($Db)
    [void]$argList.Add('--compact')
    foreach ($a in @($RagArgs)) { [void]$argList.Add([string]$a) }

    try {
        $captured = Invoke-ExternalCaptured -FilePath $Exe -Arguments $argList.ToArray()
        return Resolve-RagSqliteProtocol -ExitCode $captured.ExitCode -Stdout $captured.Stdout -Stderr $captured.Stderr -RagArgs $RagArgs
    } finally {
        # Harden projection after engine may have created/rewritten DB, WAL, SHM, logs.
        if ($null -ne $P) {
            Protect-RagProjection -P $P
        } elseif ($Db) {
            $dbParent = Split-Path -Parent $Db
            if ($dbParent) { Set-PrivateTreePermissions -Root $dbParent }
        }
    }
}

function Resolve-RagSqliteProtocol {
    param(
        [int]$ExitCode,
        [string]$Stdout,
        [string]$Stderr,
        [string[]]$RagArgs
    )
    # Protocol summary never embeds full stdout/stderr (privacy + contract).
    $cmdHint = if ($RagArgs -and $RagArgs.Count -gt 0) { [string]$RagArgs[0] } else { 'rag-sqlite' }

    if ([string]::IsNullOrWhiteSpace($Stdout)) {
        throw (New-RagException -Type 'RagProtocolError' -Message "empty stdout from rag-sqlite ($cmdHint, exit=$ExitCode)" -PublicExitCode 1 -Details @{
            exit_code = $ExitCode
            stderr_len = $Stderr.Length
        })
    }

    $payload = $null
    try {
        $payload = $Stdout | ConvertFrom-Json -AsHashtable
    } catch {
        throw (New-RagException -Type 'RagProtocolError' -Message "invalid JSON on stdout from rag-sqlite ($cmdHint, exit=$ExitCode)" -PublicExitCode 1 -Details @{
            exit_code = $ExitCode
            stderr_len = $Stderr.Length
        })
    }

    $okFlag = Get-DictVal $payload 'ok' $null

    # Success: exit 0 + ok=true
    if ($ExitCode -eq 0 -and $okFlag -eq $true) {
        return [pscustomobject]@{
            ok        = $true
            payload   = $payload
            exit_code = $ExitCode
            stdout    = $Stdout
            stderr    = $Stderr
        }
    }

    # Special-case: empty index may return exit 2 with valid index payload.
    if ($ExitCode -eq 2) {
        $schema = [string](Get-DictVal $payload 'schema_version' '')
        $totals = Get-DictVal $payload 'totals' $null
        $files = -1
        if ($null -ne $totals) {
            $filesRaw = Get-DictVal $totals 'files' $null
            if ($null -ne $filesRaw) { $files = [int]$filesRaw }
        }
        if ($okFlag -eq $true -and $schema -eq 'rag_sqlite.index.v1' -and $files -eq 0) {
            return [pscustomobject]@{
                ok        = $true
                payload   = $payload
                exit_code = $ExitCode
                stdout    = $Stdout
                stderr    = $Stderr
            }
        }
        # Any other exit 2 is a command failure (including ok=false or non-empty index failures).
        $msg = "rag-sqlite failed ($cmdHint, exit=2)"
        if ($okFlag -eq $false) {
            $err = Get-DictVal $payload 'error' $null
            if ($err) { $msg = "rag-sqlite ok=false ($cmdHint): $(ConvertTo-Json $err -Compress -Depth 4)" }
        }
        throw (New-RagException -Type 'RagCommandFailed' -Message $msg -PublicExitCode 1 -Details @{
            exit_code = $ExitCode
            schema_version = $schema
        })
    }

    if ($okFlag -eq $false) {
        $err = Get-DictVal $payload 'error' $null
        $msg = if ($err) { "rag-sqlite ok=false ($cmdHint): $(ConvertTo-Json $err -Compress -Depth 4)" } else { "rag-sqlite ok=false ($cmdHint, exit=$ExitCode)" }
        throw (New-RagException -Type 'RagCommandFailed' -Message $msg -PublicExitCode 1 -Details @{ exit_code = $ExitCode })
    }

    if ($ExitCode -ne 0) {
        throw (New-RagException -Type 'RagCommandFailed' -Message "rag-sqlite non-zero exit ($cmdHint, exit=$ExitCode)" -PublicExitCode 1 -Details @{
            exit_code = $ExitCode
            stderr_len = $Stderr.Length
        })
    }

    # exit 0 but ok missing/false already handled; ok not true is protocol error
    throw (New-RagException -Type 'RagProtocolError' -Message "rag-sqlite exit 0 without ok=true ($cmdHint)" -PublicExitCode 1 -Details @{ exit_code = $ExitCode })
}

function Assert-RagSqliteCaps {
    param([string]$Exe)
    $captured = Invoke-ExternalCaptured -FilePath $Exe -Arguments @('schema', 'query')
    if ($captured.ExitCode -ne 0) {
        throw (New-RagException -Type 'RagCommandFailed' -Message "rag-sqlite schema query failed (exit $($captured.ExitCode))" -PublicExitCode 1)
    }
    if ($captured.Stdout -notmatch 'rag_sqlite') {
        throw (New-RagException -Type 'RagProtocolError' -Message 'rag-sqlite schema query did not look valid' -PublicExitCode 1)
    }
}

function Get-ActivityEventCount {
    param([string]$ActivityPath)
    if (-not (Test-Path -LiteralPath $ActivityPath)) { return 0 }
    $n = 0
    Get-Content -LiteralPath $ActivityPath -Encoding UTF8 | ForEach-Object {
        if ($_.Trim()) { $n++ }
    }
    return $n
}

function Get-EventById {
    param([string]$ActivityPath, [string]$EventId)
    if (-not (Test-Path -LiteralPath $ActivityPath)) { return $null }
    $reader = [System.IO.StreamReader]::new($ActivityPath, [System.Text.UTF8Encoding]::new($false))
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            try {
                $ev = $line | ConvertFrom-Json -AsHashtable
            } catch { continue }
            if ([string](Get-DictVal $ev 'event_id' '') -eq $EventId) { return $ev }
        }
    } finally {
        $reader.Close()
    }
    return $null
}

function Export-EventMarkdown {
    param($Event)
    $eid = [string](Get-DictVal $Event 'event_id' '')
    $ts = [string](Get-DictVal $Event 'ts' '')
    $ev = [string](Get-DictVal $Event 'event' '')
    $actor = [string](Get-DictVal $Event 'actor' '')
    $agentRaw = Get-DictVal $Event 'agent_id' $null
    $agent = if ($null -eq $agentRaw) { '' } else { [string]$agentRaw }
    $source = [string](Get-DictVal $Event 'source' '')
    $ws = [string](Get-DictVal $Event 'workspace_root' '')
    $summary = [string](Get-DictVal $Event 'summary' '')
    $text = [string](Get-DictVal $Event 'text' '')
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Conversation event $eid")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- event_id: $eid")
    [void]$sb.AppendLine("- ts: $ts")
    [void]$sb.AppendLine("- event: $ev")
    [void]$sb.AppendLine("- actor: $actor")
    [void]$sb.AppendLine("- agent_id: $agent")
    [void]$sb.AppendLine("- source: $source")
    [void]$sb.AppendLine("- workspace_root: $ws")
    [void]$sb.AppendLine()
    if ($summary) {
        [void]$sb.AppendLine('## Summary')
        [void]$sb.AppendLine($summary)
        [void]$sb.AppendLine()
    }
    if ($text) {
        [void]$sb.AppendLine('## Text')
        [void]$sb.AppendLine($text)
        [void]$sb.AppendLine()
    }
    return $sb.ToString()
}

function Export-MissingEvents {
    param($P)
    $manifest = Read-JsonFile -Path $P.Manifest -Default (@{ events = @{} })
    if (-not $manifest.events) { $manifest.events = @{} }
    $exported = 0
    $skipped = 0
    if (-not (Test-Path -LiteralPath $P.Activity)) {
        return [pscustomobject]@{ exported = 0; skipped = 0; total_manifest = $manifest.events.Count }
    }
    $reader = [System.IO.StreamReader]::new($P.Activity, [System.Text.UTF8Encoding]::new($false))
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            try {
                $ev = $line | ConvertFrom-Json -AsHashtable
            } catch { continue }
            $eid = [string](Get-DictVal $ev 'event_id' '')
            if (-not $eid) { continue }
            $text = [string](Get-DictVal $ev 'text' '')
            $summary = [string](Get-DictVal $ev 'summary' '')
            if (-not $text -and -not $summary) {
                $skipped++
                continue
            }
            $md = Export-EventMarkdown -Event $ev
            $hash = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($md))
            ).Replace('-', '').ToLowerInvariant()
            $existing = $manifest.events[$eid]
            $existingHash = Get-DictVal $existing 'content_hash' $null
            if ($existing -and $existingHash -eq $hash) {
                $skipped++
                continue
            }
            $prefix = $eid.Substring(0, [Math]::Min(2, $eid.Length)).ToLowerInvariant()
            $dir = Join-Path $P.Corpus $prefix
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-PrivatePermissions -Path $dir -Directory
            $path = Join-Path $dir ($eid + '.md')
            [System.IO.File]::WriteAllText($path, $md, [System.Text.UTF8Encoding]::new($false))
            Set-PrivatePermissions -Path $path
            $manifest.events[$eid] = @{
                content_hash = $hash
                path         = $path
                ts           = [string](Get-DictVal $ev 'ts' '')
            }
            $exported++
        }
    } finally {
        $reader.Close()
    }

    $alive = [System.Collections.Generic.HashSet[string]]::new([string[]]@($manifest.events.Keys))
    if (Test-Path -LiteralPath $P.Corpus) {
        Get-ChildItem -Path $P.Corpus -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $stem = $_.BaseName
            if (-not $alive.Contains($stem)) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                if ($manifest.events.ContainsKey($stem)) { $manifest.events.Remove($stem) }
            }
        }
    }

    Write-JsonFile -Path $P.Manifest -Object $manifest
    return [pscustomobject]@{
        exported       = $exported
        skipped        = $skipped
        total_manifest = $manifest.events.Count
    }
}

function Write-DirtyMarker {
    param($P)
    Ensure-RagDirs -P $P
    $count = Get-ActivityEventCount -ActivityPath $P.Activity
    $payload = @{
        marked_at      = (Get-Date).ToString('o')
        activity_lines = $count
    }
    Write-JsonFile -Path $P.Dirty -Object $payload
}

function Read-Dirty {
    param($P)
    return (Read-JsonFile -Path $P.Dirty -Default $null)
}

function Clear-DirtyIfCurrent {
    param($P, $AtStartCount)
    $now = Get-ActivityEventCount -ActivityPath $P.Activity
    if ($now -le $AtStartCount -and (Test-Path -LiteralPath $P.Dirty)) {
        Remove-Item -LiteralPath $P.Dirty -Force -ErrorAction SilentlyContinue
    }
}

function Try-AcquireWorkerLock {
    param($P)
    Ensure-RagDirs -P $P
    try {
        $fs = [System.IO.File]::Open(
            $P.WorkerLock,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        Set-PrivatePermissions -Path $P.WorkerLock
        return $fs
    } catch {
        return $null
    }
}

function Write-WorkerLog {
    param($P, [string]$Message)
    Ensure-RagDirs -P $P
    $line = "{0} {1}" -f (Get-Date).ToString('o'), $Message
    Add-Content -LiteralPath $P.WorkerLog -Value $line -Encoding utf8
    Set-PrivatePermissions -Path $P.WorkerLog
}

function Copy-HashtableShallow {
    param($Source)
    $out = @{}
    if ($null -eq $Source) { return $out }
    if ($Source -is [System.Collections.IDictionary]) {
        foreach ($k in $Source.Keys) { $out[[string]$k] = $Source[$k] }
        return $out
    }
    foreach ($p in $Source.PSObject.Properties) { $out[$p.Name] = $p.Value }
    return $out
}

function Invoke-RagRefresh {
    param($P, [switch]$Force)
    $cfg = Read-JsonFile -Path $P.Config -Default $null
    if (-not $cfg -or -not (Get-DictVal $cfg 'enabled' $false)) {
        throw (New-RagException -Type 'RagUnavailable' -Message 'RAG is not enabled. Run: conversation-esaa rag enable' -PublicExitCode 1)
    }
    $exe = [string](Get-DictVal $cfg 'rag_sqlite_command' '')
    if (-not (Test-Path -LiteralPath $exe)) {
        throw (New-RagException -Type 'RagUnavailable' -Message "Configured rag-sqlite missing: $exe" -PublicExitCode 1)
    }

    $priorState = Read-JsonFile -Path $P.State -Default @{}
    $prior = Copy-HashtableShallow $priorState
    $priorActivityLines = Get-DictVal $prior 'activity_lines' $null
    $priorGeneration = Get-DictVal $prior 'last_generation_id' $null
    $hadDirty = Test-Path -LiteralPath $P.Dirty

    $lock = Try-AcquireWorkerLock -P $P
    if (-not $lock) {
        Write-WorkerLog -P $P -Message 'refresh skipped: worker lock held'
        return @{ ok = $false; error = @{ type = 'WorkerBusy'; message = 'another worker holds the lock' } }
    }
    try {
        $startCount = Get-ActivityEventCount -ActivityPath $P.Activity
        $export = Export-MissingEvents -P $P
        Write-WorkerLog -P $P -Message ("export exported={0} skipped={1} manifest={2}" -f $export.exported, $export.skipped, $export.total_manifest)

        $db = [string](Get-DictVal $cfg 'db_path' $P.Db)
        if ($Force) {
            $inv = Invoke-RagSqlite -Exe $exe -Db $db -RagArgs @('reindex', '--force') -P $P
        } else {
            $inv = Invoke-RagSqlite -Exe $exe -Db $db -RagArgs @('index', $P.Corpus, '--sync', '--prune') -P $P
        }
        $indexResult = $inv.payload

        # Harden full tree after successful index (includes wal/shm). Failure is not success.
        Protect-RagProjection -P $P

        $genId = Get-DictVal $indexResult 'generation_id' $null
        $state = @{
            last_refresh_at    = (Get-Date).ToString('o')
            last_export        = $export
            last_index_ok      = $true
            activity_lines     = Get-ActivityEventCount -ActivityPath $P.Activity
            last_error         = $null
            last_generation_id = $genId
        }
        Write-WorkerLog -P $P -Message 'index ok'
        Clear-DirtyIfCurrent -P $P -AtStartCount $startCount
        $endCount = Get-ActivityEventCount -ActivityPath $P.Activity
        if ($endCount -gt $startCount) {
            Write-DirtyMarker -P $P
            Write-WorkerLog -P $P -Message 'dirty re-set: events arrived during refresh'
        }
        Write-JsonFile -Path $P.State -Object $state
        Protect-RagProjection -P $P
        return @{
            ok     = $true
            export = $export
            index  = $indexResult
            state  = $state
        }
    } catch {
        $errType = Get-RagExceptionType $_
        $msg = $_.Exception.Message
        Write-WorkerLog -P $P -Message ("refresh error type={0}: {1}" -f $errType, $msg)

        # Preserve previous generation, activity_lines; keep/restore dirty marker.
        $state = Copy-HashtableShallow $prior
        $state['last_error'] = @{ type = $errType; message = $msg }
        $state['last_refresh_at'] = (Get-Date).ToString('o')
        $state['last_index_ok'] = $false
        if ($null -ne $priorActivityLines) {
            $state['activity_lines'] = $priorActivityLines
        }
        if ($null -ne $priorGeneration) {
            $state['last_generation_id'] = $priorGeneration
        }
        try { Write-JsonFile -Path $P.State -Object $state } catch {}
        if (-not (Test-Path -LiteralPath $P.Dirty)) {
            try { Write-DirtyMarker -P $P } catch {}
        }
        if ($hadDirty -and -not (Test-Path -LiteralPath $P.Dirty)) {
            try { Write-DirtyMarker -P $P } catch {}
        }
        try { Protect-RagProjection -P $P -Soft } catch {}
        return @{ ok = $false; error = @{ type = $errType; message = $msg } }
    } finally {
        $lock.Dispose()
        if (Test-Path -LiteralPath $P.WorkerLock) {
            try { Remove-Item -LiteralPath $P.WorkerLock -Force -ErrorAction SilentlyContinue } catch {}
        }
        try { Protect-RagProjection -P $P -Soft } catch {}
    }
}

function Invoke-RagEnable {
    param($P)
    if (-not (Test-Path -LiteralPath $P.ConvRoot)) {
        throw (New-RagException -Type 'AdapterError' -Message "Conversation ESAA store not found at $($P.ConvRoot). Run conversation-esaa init first." -PublicExitCode 1)
    }
    if (-not (Test-LoopbackUrl -Url $BaseUrl)) {
        throw (New-RagException -Type 'AdapterError' -Message "v1.2 allows only loopback Ollama URLs (127.0.0.1, localhost, ::1). Got: $BaseUrl" -PublicExitCode 1)
    }
    $exe = Find-RagSqlite -CommandPath $CommandPath
    Assert-RagSqliteCaps -Exe $exe
    Ensure-RagDirs -P $P

    # Do not publish config until ALL config commands succeed (no partial enable).
    $existingCfg = Read-JsonFile -Path $P.Config -Default $null

    try {
        $null = Invoke-RagSqlite -Exe $exe -Db $P.Db -RagArgs @('config', 'set-ollama', '--url', $BaseUrl, '--model', $Model, '--timeout', "$TimeoutSeconds") -P $P
        $null = Invoke-RagSqlite -Exe $exe -Db $P.Db -RagArgs @('config', 'set', 'index_root', $P.Corpus) -P $P
        $null = Invoke-RagSqlite -Exe $exe -Db $P.Db -RagArgs @('config', 'set', 'allowed_hosts', '127.0.0.1,localhost,::1') -P $P
        $null = Invoke-RagSqlite -Exe $exe -Db $P.Db -RagArgs @('config', 'set', 'allow_symlinks', 'false') -P $P
        $null = Invoke-RagSqlite -Exe $exe -Db $P.Db -RagArgs @('config', 'set', 'vector_backend', 'auto') -P $P
    } catch {
        # Preserve previous valid config on partial failure.
        if ($null -ne $existingCfg -and (Get-DictVal $existingCfg 'enabled' $false)) {
            Write-WorkerLog -P $P -Message ("enable aborted; previous config preserved: {0}" -f $_.Exception.Message)
        }
        try { Protect-RagProjection -P $P -Soft } catch {}
        throw
    }

    $cfg = @{
        schema_version     = 'conversation-esaa.rag-config.v1'
        enabled            = $true
        rag_sqlite_command = $exe
        db_path            = $P.Db
        corpus_path        = $P.Corpus
        base_url           = $BaseUrl
        model              = $Model
        timeout_seconds    = $TimeoutSeconds
        enabled_at         = (Get-Date).ToString('o')
    }
    Write-JsonFile -Path $P.Config -Object $cfg
    Write-DirtyMarker -P $P
    Protect-RagProjection -P $P

    return @{
        schema_version = 'conversation-esaa.rag-status.v1'
        ok             = $true
        enabled        = $true
        workspace      = $P.Workspace
        rag_sqlite     = $exe
        db             = $P.Db
        corpus         = $P.Corpus
        base_url       = $BaseUrl
        model          = $Model
        message        = 'RAG enabled. Run: conversation-esaa rag refresh (first index may take minutes).'
    }
}

function Invoke-RagStatus {
    param($P)
    $cfg = Read-JsonFile -Path $P.Config -Default $null
    $state = Read-JsonFile -Path $P.State -Default $null
    $dirty = Read-Dirty -P $P
    $activityLines = Get-ActivityEventCount -ActivityPath $P.Activity
    $indexedRaw = Get-DictVal $state 'activity_lines' 0
    $indexedLines = if ($null -ne $indexedRaw) { [int]$indexedRaw } else { 0 }
    $lag = [Math]::Max(0, $activityLines - $indexedLines)
    $out = @{
        schema_version  = 'conversation-esaa.rag-status.v1'
        ok              = $true
        enabled         = [bool](Get-DictVal $cfg 'enabled' $false)
        workspace       = $P.Workspace
        rag_root        = $P.RagRoot
        rag_sqlite      = Get-DictVal $cfg 'rag_sqlite_command' $null
        db              = Get-DictVal $cfg 'db_path' $null
        corpus          = Get-DictVal $cfg 'corpus_path' $null
        base_url        = Get-DictVal $cfg 'base_url' $null
        model           = Get-DictVal $cfg 'model' $null
        dirty           = [bool]$dirty
        activity_lines  = $activityLines
        indexed_lines   = $indexedLines
        event_lag       = $lag
        last_refresh_at = Get-DictVal $state 'last_refresh_at' $null
        last_error      = Get-DictVal $state 'last_error' $null
        last_generation_id = Get-DictVal $state 'last_generation_id' $null
    }
    return $out
}

function Invoke-RagDisable {
    param($P, [switch]$Purge)
    $cfg = Read-JsonFile -Path $P.Config -Default @{}
    if ($Purge) {
        if (Test-Path -LiteralPath $P.RagRoot) {
            Remove-Item -LiteralPath $P.RagRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        return @{
            schema_version = 'conversation-esaa.rag-status.v1'
            ok             = $true
            enabled        = $false
            purged         = $true
            workspace      = $P.Workspace
        }
    }
    if ($cfg -is [System.Collections.IDictionary]) {
        $cfg['enabled'] = $false
        $cfg['disabled_at'] = (Get-Date).ToString('o')
        Ensure-RagDirs -P $P
        Write-JsonFile -Path $P.Config -Object $cfg
    }
    return @{
        schema_version = 'conversation-esaa.rag-status.v1'
        ok             = $true
        enabled        = $false
        purged         = $false
        workspace      = $P.Workspace
        message        = 'RAG disabled; data preserved. Use --purge to remove .conversation-esaa/rag/'
    }
}

function Extract-EventIdFromHit {
    param($Hit)
    $path = [string](Get-DictVal $Hit 'source_path' '')
    if ($path) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
        if ($name -and $name.Length -ge 16) { return $name }
    }
    $text = [string](Get-DictVal $Hit 'chunk_text' '')
    if ($text -match 'event_id:\s*([0-9a-fA-F]{16,})') { return $Matches[1] }
    if ($text -match 'Conversation event\s+([0-9a-fA-F]{16,})') { return $Matches[1] }
    return $null
}

function New-SearchError {
    param(
        [string]$Type,
        [string]$Message,
        [string]$Query,
        [string]$Workspace,
        [hashtable]$Extra = $null
    )
    $out = @{
        schema_version    = 'conversation-esaa.search.v1'
        ok                = $false
        query             = $Query
        workspace         = $Workspace
        hits              = @()
        hit_count         = 0
        content_untrusted = $true
        error             = @{ type = $Type; message = $Message }
    }
    if ($Extra) {
        foreach ($k in $Extra.Keys) { $out[$k] = $Extra[$k] }
    }
    return $out
}

function Invoke-RagSearch {
    param($P, [string]$Query, [int]$TopK, [double]$MinScore)
    $cfg = Read-JsonFile -Path $P.Config -Default $null
    if (-not $cfg -or -not (Get-DictVal $cfg 'enabled' $false)) {
        return (New-SearchError -Type 'RagUnavailable' -Message 'RAG is not enabled' -Query $Query -Workspace $P.Workspace)
    }
    $exe = [string](Get-DictVal $cfg 'rag_sqlite_command' '')
    if (-not (Test-Path -LiteralPath $exe)) {
        return (New-SearchError -Type 'RagUnavailable' -Message "rag-sqlite missing: $exe" -Query $Query -Workspace $P.Workspace)
    }
    $state = Read-JsonFile -Path $P.State -Default $null
    $dirty = Read-Dirty -P $P
    $activityLines = Get-ActivityEventCount -ActivityPath $P.Activity
    $indexedRaw = Get-DictVal $state 'activity_lines' 0
    $indexedLines = if ($null -ne $indexedRaw) { [int]$indexedRaw } else { 0 }
    $lag = [Math]::Max(0, $activityLines - $indexedLines)
    $dbPath = [string](Get-DictVal $cfg 'db_path' $P.Db)
    $hasIndex = Test-Path -LiteralPath $dbPath
    $lastRefresh = Get-DictVal $state 'last_refresh_at' $null
    $lastOk = Get-DictVal $state 'last_index_ok' $false
    if (-not $hasIndex -or -not $lastRefresh -or -not $lastOk) {
        return (New-SearchError -Type 'RagNotReady' -Message 'No usable RAG generation. Run: conversation-esaa rag refresh' -Query $Query -Workspace $P.Workspace -Extra @{
            stale = $true
            event_lag = $lag
            pending_events = $lag
        })
    }

    try {
        $inv = Invoke-RagSqlite -Exe $exe -Db $dbPath -RagArgs @(
            'query', $Query, '--top-k', "$TopK", '--min-score', "$MinScore"
        ) -P $P
    } catch {
        $errType = Get-RagExceptionType $_
        # Search public exit is always 2 for unavailability/protocol/command failures.
        return (New-SearchError -Type $errType -Message $_.Exception.Message -Query $Query -Workspace $P.Workspace)
    }
    $rag = $inv.payload

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($h in @($rag.hits)) {
        $eid = Extract-EventIdFromHit -Hit $h
        if (-not $eid) { continue }
        if (-not $seen.Add($eid)) { continue }
        $ev = Get-EventById -ActivityPath $P.Activity -EventId $eid
        if (-not $ev) { continue }
        $ews = [string](Get-DictVal $ev 'workspace_root' '')
        if ($ews -and $ews -ne $P.Workspace) { continue }
        $snippet = [string](Get-DictVal $h 'chunk_text' '')
        if ($snippet.Length -gt 800) { $snippet = $snippet.Substring(0, 800) + [char]0x2026 }
        $agentRaw = Get-DictVal $ev 'agent_id' $null
        $hits.Add(@{
            event_id          = $eid
            ts                = [string](Get-DictVal $ev 'ts' $null)
            event             = [string](Get-DictVal $ev 'event' $null)
            actor             = [string](Get-DictVal $ev 'actor' $null)
            agent_id          = if ($null -eq $agentRaw) { $null } else { [string]$agentRaw }
            source            = [string](Get-DictVal $ev 'source' $null)
            score             = [double](Get-DictVal $h 'score' 0)
            snippet           = $snippet
            content_untrusted = $true
        })
    }

    $stale = [bool]$dirty -or ($lag -gt 0)
    $meta = Get-DictVal $rag 'meta' $null
    return @{
        schema_version       = 'conversation-esaa.search.v1'
        ok                   = $true
        query                = $Query
        workspace            = $P.Workspace
        provider             = Get-DictVal $meta 'provider' (Get-DictVal $cfg 'model' $null)
        model                = Get-DictVal $meta 'model' (Get-DictVal $cfg 'model' $null)
        backend              = Get-DictVal $meta 'backend' $null
        stale                = $stale
        event_lag            = $lag
        pending_events       = $lag
        indexed_at           = Get-DictVal $state 'last_refresh_at' $null
        active_generation_id = Get-DictVal $meta 'generation_id' $null
        hit_count            = $hits.Count
        content_untrusted    = $true
        hits                 = @($hits)
    }
}

function Invoke-ScheduleWorker {
    param($P)
    $cfg = Read-JsonFile -Path $P.Config -Default $null
    if (-not $cfg -or -not (Get-DictVal $cfg 'enabled' $false)) { return }
    Write-DirtyMarker -P $P
    $self = $PSCommandPath
    # Detached one-shot worker (fail-open if spawn fails)
    try {
        if ($IsWindows) {
            Start-Process -FilePath 'pwsh' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self,
                '-Action', 'worker', '-WorkspaceRoot', $P.Workspace
            ) -WindowStyle Hidden | Out-Null
        } else {
            Ensure-RagDirs -P $P
            $stdout = Join-Path $P.LogDir 'worker-stdout.log'
            $stderr = Join-Path $P.LogDir 'worker-stderr.log'
            Start-Process -FilePath 'pwsh' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self,
                '-Action', 'worker', '-WorkspaceRoot', $P.Workspace
            ) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru | Out-Null
            Set-PrivatePermissions -Path $stdout
            Set-PrivatePermissions -Path $stderr
            Protect-RagProjection -P $P
        }
    } catch {
        Write-WorkerLog -P $P -Message ("schedule failed: {0}" -f $_.Exception.Message)
    }
}

function Write-ActionResult {
    param($Result, [switch]$AsJson, [string]$TextOk, [int]$FailExit = 1)
    if ($AsJson -or $Action -eq 'search') {
        $Result | ConvertTo-Json -Depth 12
    } else {
        if ($Result -is [System.Collections.IDictionary] -or $Result.PSObject) {
            $ok = Get-DictVal $Result 'ok' $true
            if ($ok) {
                if ($TextOk) { $TextOk } else { $Result | ConvertTo-Json -Depth 6 -Compress }
            } else {
                "failed: $((Get-DictVal $Result 'error' $Result) | ConvertTo-Json -Compress -Depth 6)"
            }
        }
    }
    $okFlag = Get-DictVal $Result 'ok' $true
    if ($okFlag -eq $false) { exit $FailExit }
}

function Write-TypedFailure {
    param(
        $ErrorRecord,
        [int]$DefaultExit = 1,
        [switch]$SearchShape
    )
    $errType = Get-RagExceptionType $ErrorRecord
    $msg = $ErrorRecord.Exception.Message
    $exitCode = Get-RagPublicExitCode $ErrorRecord -Default $DefaultExit
    if ($SearchShape) {
        $payload = New-SearchError -Type $errType -Message $msg -Query $Query -Workspace $paths.Workspace
        $payload | ConvertTo-Json -Depth 8
        exit 2
    }
    $payload = @{
        ok    = $false
        error = @{ type = $errType; message = $msg }
    }
    $payload | ConvertTo-Json -Depth 8
    exit $exitCode
}

# --- main ---
$ws = Resolve-Ws
$paths = Get-RagPaths -Ws $ws

switch ($Action) {
    'enable' {
        try {
            $result = Invoke-RagEnable -P $paths
            if ($Json) { $result | ConvertTo-Json -Depth 8 } else {
                "RAG enabled for $($paths.Workspace)"
                "rag-sqlite: $($result.rag_sqlite)"
                "db: $($result.db)"
                $result.message
            }
        } catch {
            Write-TypedFailure -ErrorRecord $_ -DefaultExit 1
        }
    }
    'status' {
        try {
            $result = Invoke-RagStatus -P $paths
            if ($Json) { $result | ConvertTo-Json -Depth 8 } else {
                "enabled=$($result.enabled) dirty=$($result.dirty) lag=$($result.event_lag)"
                "rag-sqlite=$($result.rag_sqlite)"
                "db=$($result.db)"
                if ($result.last_error) { "last_error=$($result.last_error | ConvertTo-Json -Compress -Depth 4)" }
            }
        } catch {
            Write-TypedFailure -ErrorRecord $_ -DefaultExit 1
        }
    }
    'refresh' {
        try {
            Start-Sleep -Seconds 1
            $result = Invoke-RagRefresh -P $paths -Force:$Force
            if ($Json) { $result | ConvertTo-Json -Depth 10 } else {
                if ($result.ok) {
                    "refresh ok export=$($result.export.exported) manifest=$($result.export.total_manifest)"
                } else {
                    "refresh failed: $($result.error | ConvertTo-Json -Compress -Depth 6)"
                }
            }
            if (-not $result.ok) { exit 1 }
        } catch {
            Write-TypedFailure -ErrorRecord $_ -DefaultExit 1
        }
    }
    'disable' {
        try {
            $result = Invoke-RagDisable -P $paths -Purge:$Purge
            if ($Json) { $result | ConvertTo-Json -Depth 6 } else {
                "RAG disabled purged=$($result.purged)"
            }
        } catch {
            Write-TypedFailure -ErrorRecord $_ -DefaultExit 1
        }
    }
    'search' {
        try {
            if ([string]::IsNullOrWhiteSpace($Query)) {
                throw (New-RagException -Type 'AdapterError' -Message 'search requires -Query' -PublicExitCode 2)
            }
            $result = Invoke-RagSearch -P $paths -Query $Query -TopK $TopK -MinScore $MinScore
            $result | ConvertTo-Json -Depth 10
            if (-not $result.ok) { exit 2 }
        } catch {
            Write-TypedFailure -ErrorRecord $_ -DefaultExit 2 -SearchShape
        }
    }
    'schedule' {
        # Fail-open for conversational pipeline
        try {
            Invoke-ScheduleWorker -P $paths
            if ($Json) { @{ ok = $true; scheduled = $true } | ConvertTo-Json } else { 'rag worker scheduled' }
        } catch {
            Write-WorkerLog -P $paths -Message ("schedule outer fail-open: {0}" -f $_.Exception.Message)
            if ($Json) { @{ ok = $true; scheduled = $false; fail_open = $true } | ConvertTo-Json } else { 'rag worker schedule fail-open' }
        }
    }
    'worker' {
        # Worker failures must not block sync/project/hooks (caller ignores).
        try {
            Start-Sleep -Seconds 10
            $result = Invoke-RagRefresh -P $paths
            $guard = 0
            while ((Test-Path -LiteralPath $paths.Dirty) -and $guard -lt 5 -and $result.ok) {
                $guard++
                Start-Sleep -Seconds 2
                $result = Invoke-RagRefresh -P $paths
            }
        } catch {
            try { Write-WorkerLog -P $paths -Message ("worker fail-open: {0}" -f $_.Exception.Message) } catch {}
        } finally {
            try { Protect-RagProjection -P $paths -Soft } catch {}
        }
        exit 0
    }
}
