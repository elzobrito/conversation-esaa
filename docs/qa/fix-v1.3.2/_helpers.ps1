#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$script:Repo = (git rev-parse --show-toplevel).Trim()
$script:Bin  = Join-Path $script:Repo '.conversation-esaa/bin'

function New-TestWorkspace {
  $d = Join-Path ([IO.Path]::GetTempPath()) ('fix132-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force $d | Out-Null
  (Resolve-Path $d).Path
}

# Bootstrap do repositório em um workspace temporário (copia os .ps1 atuais do repo para o bin do workspace)
function Initialize-Ws([string]$Ws, [string]$Agents = 'grok,claude,codex,antigravity,cursor') {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Bin 'conv-bootstrap.ps1') -WorkspaceRoot $Ws -Agents $Agents | Out-Null
  if ($LASTEXITCODE) { throw "bootstrap failed ($LASTEXITCODE)" }
}

# conv-sync.ps1 direto
function Sync([string]$Ws, [string]$Command, [string[]]$Extra = @()) {
  $o = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Bin 'conv-sync.ps1') $Command -WorkspaceRoot $Ws @Extra 2>&1
  [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($o | Out-String).Trim() }
}

# CLI pública (conversation-esaa.ps1)
function Cli([string]$Ws, [string]$Command, [string[]]$More = @()) {
  $o = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Bin 'conversation-esaa.ps1') $Command @More -Workspace $Ws 2>&1
  [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($o | Out-String).Trim() }
}

# Hook do Cursor instalado NO workspace (usa a cópia gerada pelo bootstrap)
function Invoke-CursorHook([string]$Ws, [string]$Event, [hashtable]$Payload) {
  $hook = Join-Path $Ws '.conversation-esaa/bin/cursor-hook.ps1'
  ($Payload | ConvertTo-Json -Compress) | & pwsh -NoProfile -ExecutionPolicy Bypass -File $hook -WorkspaceRoot $Ws -Event $Event
}

function Read-Ledger([string]$Ws) {
  $p = Join-Path $Ws '.conversation-esaa/activity.jsonl'
  if (-not (Test-Path $p)) { return @() }
  @(Get-Content $p -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Count-Lines([string]$Ws) { @(Read-Ledger $Ws).Count }

# Ledger sintético para medições (PS-07, JS-04). Nunca use texto real.
function New-SyntheticLedger([string]$Ws, [int]$Turns, [int]$Tasks = 0) {
  $p  = Join-Path $Ws '.conversation-esaa/activity.jsonl'
  $sw = [IO.StreamWriter]::new($p, $false, [Text.UTF8Encoding]::new($false))
  function Hid([string]$s) { [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','').ToLower() }
  try {
    for ($i = 0; $i -lt $Turns; $i++) {
      $actor = if ($i % 2 -eq 0) { 'user' } else { 'assistant' }
      $rec = [ordered]@{
        event_id = (Hid "gen|turn|$i"); ts = '2026-11-08T12:00:00-03:00'; event = 'conversation_turn'
        actor = $actor; agent_id = $(if ($actor -eq 'assistant') { 'codex' } else { $null })
        source = 'codex'; source_session_id = 'gen'; source_path = 'gen'; source_index = $i
        workspace_root = $Ws; summary = "turno sintetico $i"; text = "turno sintetico $i"
      }
      $sw.WriteLine(($rec | ConvertTo-Json -Compress))
    }
    for ($t = 1; $t -le $Tasks; $t++) {
      $tid = 'CONV-{0:D3}' -f $t
      foreach ($ev in 'task.created', 'task.updated') {
        $rec = [ordered]@{
          event_id = (Hid "gen|$ev|$t"); ts = '2026-11-08T12:00:00-03:00'; event = $ev; actor = 'assistant'
          agent_id = 'codex'; workspace_root = $Ws; task_id = $tid; title = "tarefa sintetica $t"
          status = $(if ($ev -eq 'task.created') { 'open' } else { 'in_progress' })
          summary = "$ev $tid"; text = "$ev $tid"
        }
        $sw.WriteLine(($rec | ConvertTo-Json -Compress))
      }
    }
  } finally { $sw.Dispose() }
  Sync $Ws 'project' | Out-Null
}

function Measure-Median([scriptblock]$Block, [int]$Runs = 3) {
  $t = 1..$Runs | ForEach-Object { (Measure-Command { & $Block | Out-Null }).TotalSeconds } | Sort-Object
  [pscustomobject]@{ Median = $t[[int][math]::Floor($t.Count / 2)]; Max = $t[-1] }
}
