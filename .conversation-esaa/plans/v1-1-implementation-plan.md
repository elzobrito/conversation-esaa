# Conversation ESAA v1.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Conversation ESAA v1.1 as a greenfield CLI-driven memory runtime with workspace isolation, write locking, paginated context, curated decision/task events, and projected read models.

**Architecture:** `activity.jsonl` is the only source of truth. All writes go through `conversation-esaa` commands, acquire a lock, validate inputs, append events, project read models, and run `verify`. `state.md`, `handoff.md`, `decisions.md`, `tasks.json`, `sync-state.json`, and context windows are derived artifacts.

**Tech Stack:** PowerShell 7 (`pwsh`), existing `.conversation-esaa/bin/conv-sync.ps1`, existing `.conversation-esaa/bin/conv-bootstrap.ps1`, existing `.conversation-esaa/bin/codex-watch.ps1`, JSONL files, Markdown projections, existing `.conversation-esaa/bin/conv-test.ps1`.

---

## File Structure

### Create

- `.conversation-esaa/bin/conversation-esaa.ps1`
  - Public v1.1 CLI wrapper.
  - Accepts domain commands: `init`, `enable-hooks`, `sync`, `project`, `verify`, `context`, `decide`, `task`.
  - Internally can call existing `conv-sync.ps1` during transition.

- `.conversation-esaa/decisions.md`
  - Generated read model.
  - Never edited manually.

- `.conversation-esaa/run/.gitkeep`
  - Keeps runtime directory structure in template.
  - Actual lockfiles are generated and ignored.

- `.conversation-esaa/tests/fixtures/context/activity.context.jsonl`
  - Deterministic event fixture for `context` tests.
  - Contains multiple agents, workspaces, event ids, topics, and timestamps.

### Modify

- `.conversation-esaa/bin/conv-sync.ps1`
  - Add `workspace_root` to new events.
  - Enforce workspace isolation in `verify`.
  - Add lockfile helpers or call shared lock helpers.
  - Add event projection for `decision.recorded` and `task.*`.
  - Add context command implementation if wrapper delegates to it.

- `.conversation-esaa/bin/conv-bootstrap.ps1`
  - Bootstrap greenfield v1.1 with generated read models and empty event store.
  - Ensure `tasks.json` is generated or baseline-projected, not authored as source of truth.
  - Install `conversation-esaa.ps1` in new workspaces.

- `.conversation-esaa/bin/conv-test.ps1`
  - Add tests for workspace isolation, lockfile, context windows, decisions projection, tasks projection, and enable-hooks.

- `.conversation-esaa/tests/fixtures/grok/chat_history.jsonl`
  - Grok transcript fixture; filename matches `~/.grok/sessions/.../chat_history.jsonl`.

- `.conversation-esaa/tests/fixtures/codex/rollout.jsonl`
  - Add expected `workspace_root` behavior or pair with workspace metadata.

- `.conversation-esaa/tests/fixtures/claude/session.jsonl`
  - Add expected `workspace_root` behavior or pair with workspace metadata.

- `README.md`
  - Document public `conversation-esaa` commands instead of direct `conv-sync.ps1` as primary interface.

- `PRIVACY.md`
  - Clarify redaction is export-derived and does not mutate local append-only log.

- `.gitignore`
  - Ensure `.conversation-esaa/run/*.lock`, generated projections, and real logs remain excluded.

---

## Implementation Invariants

1. No manual editing of `activity.jsonl`, `tasks.json`, `decisions.md`, `state.md`, or `handoff.md`.
2. No legacy compatibility path in v1.1 public workflow.
3. New events must include `workspace_root`.
4. Every write command runs:

```text
acquire lock
validate input
append event(s)
project read models
verify
release lock
```

5. `context` reads only events from the target workspace.
6. `tasks.json` and `decisions.md` are projected, not authored.
7. Hooks call the CLI, not internal functions.

---

## Task 1: Add Greenfield Workspace Schema

**Files:**
- Modify: `.conversation-esaa/bin/conv-sync.ps1`
- Modify: `.conversation-esaa/bin/conv-test.ps1`
- Modify: `.conversation-esaa/tests/fixtures/grok/chat_history.jsonl`
- Modify: `.conversation-esaa/tests/fixtures/codex/rollout.jsonl`
- Modify: `.conversation-esaa/tests/fixtures/claude/session.jsonl`

- [ ] **Step 1: Add failing tests for `workspace_root`**

Add tests to `conv-test.ps1` that assert:

```powershell
# New generated events must include workspace_root equal to the test workspace.
# verify must reject new-schema events missing workspace_root.
# verify must reject events whose workspace_root differs from -WorkspaceRoot.
```

Expected fixture event shape:

```json
{
  "event_id": "evt_context_codex_001",
  "ts": "2026-06-21T14:00:00-03:00",
  "event": "conversation_turn",
  "actor": "assistant",
  "agent_id": "codex",
  "source": "codex",
  "source_session_id": "test-session",
  "source_path": "fixture",
  "source_index": 1,
  "workspace_root": "C:\\Temp\\conversation-esaa-test",
  "summary": "Codex visible message",
  "text": "Codex visible message"
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
```

Expected:

```text
FAIL ... workspace_root ...
```

- [ ] **Step 3: Add `workspace_root` to event creation**

In all new event builders inside `conv-sync.ps1`, set:

```powershell
workspace_root = $Paths.Root
```

Use the resolved absolute workspace root, not the current shell directory.

- [ ] **Step 4: Enforce workspace isolation in `verify`**

For every event that has modern required fields, enforce:

```powershell
if (-not $event.workspace_root) {
  throw "Event $($event.event_id) missing workspace_root"
}

if ((Resolve-Path -LiteralPath $event.workspace_root).Path -ne (Resolve-Path -LiteralPath $WorkspaceRoot).Path) {
  throw "Event $($event.event_id) belongs to another workspace: $($event.workspace_root)"
}
```

For the lab's existing legacy events, keep current local tolerance only if explicitly guarded as lab-only. Public bootstrap must generate empty logs.

- [ ] **Step 5: Run tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-sync.ps1 verify -WorkspaceRoot C:\xampp\htdocs\esaa-conversational-lab
```

Expected:

```text
conv-test: all passed
verify: ok
```

---

## Task 2: Add Pipeline Lockfile

**Files:**
- Modify: `.conversation-esaa/bin/conv-sync.ps1`
- Modify: `.conversation-esaa/bin/conv-test.ps1`
- Modify: `.gitignore`
- Create: `.conversation-esaa/run/.gitkeep`

- [ ] **Step 1: Add lock tests**

Add tests that simulate:

```text
existing live lock -> command exits or waits then times out
stale lock -> command removes stale lock and continues
normal write -> lock file removed after success
write failure -> lock file removed after failure
```

- [ ] **Step 2: Add lock ignored path**

Update `.gitignore`:

```gitignore
.conversation-esaa/run/*.lock
```

Add `.conversation-esaa/run/.gitkeep`.

- [ ] **Step 3: Implement lock helpers**

Add helpers to `conv-sync.ps1` or a small included section:

```powershell
function Acquire-PipelineLock {
  param(
    [string]$WorkspaceRoot,
    [string]$CommandName,
    [int]$TimeoutSeconds = 30
  )
  # Creates .conversation-esaa/run/conversation-esaa.lock atomically.
  # Stores pid, command, started_at, workspace_root.
}

function Release-PipelineLock {
  param([string]$WorkspaceRoot)
  # Removes lock if owned by current process.
}
```

- [ ] **Step 4: Wrap all write commands**

Wrap:

```text
sync-grok
sync-codex
sync-claude
project when called after writes
future decide/task
```

with:

```powershell
try {
  Acquire-PipelineLock -WorkspaceRoot $WorkspaceRoot -CommandName $Command
  # write pipeline
}
finally {
  Release-PipelineLock -WorkspaceRoot $WorkspaceRoot
}
```

- [ ] **Step 5: Run tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
```

Expected:

```text
all lock tests pass
```

---

## Task 3: Create `conversation-esaa` CLI Wrapper

**Files:**
- Create: `.conversation-esaa/bin/conversation-esaa.ps1`
- Modify: `.conversation-esaa/bin/conv-bootstrap.ps1`
- Modify: `.conversation-esaa/bin/conv-test.ps1`
- Modify: `README.md`

- [ ] **Step 1: Add wrapper CLI tests**

Add tests that call:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conversation-esaa.ps1 verify --workspace C:\xampp\htdocs\esaa-conversational-lab
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conversation-esaa.ps1 project --workspace C:\xampp\htdocs\esaa-conversational-lab
```

Expected output:

```text
verify: ok
project: regenerated state.md and handoff.md
```

- [ ] **Step 2: Implement command parsing**

Support:

```powershell
conversation-esaa init --workspace <path>
conversation-esaa enable-hooks --agent <grok|claude|codex> --workspace <path> [--trust] [--watcher]
conversation-esaa sync --agent <grok|claude|codex> --workspace <path>
conversation-esaa project --workspace <path>
conversation-esaa verify --workspace <path>
conversation-esaa context ...
conversation-esaa decide ...
conversation-esaa task ...
```

Initial wrapper may delegate:

```powershell
sync --agent grok   -> conv-sync.ps1 sync-grok
sync --agent codex  -> conv-sync.ps1 sync-codex
sync --agent claude -> conv-sync.ps1 sync-claude
project             -> conv-sync.ps1 project
verify              -> conv-sync.ps1 verify
init                -> conv-bootstrap.ps1
```

- [ ] **Step 3: Bootstrap installs wrapper**

Update `conv-bootstrap.ps1` to copy `conversation-esaa.ps1` into new workspaces.

- [ ] **Step 4: Update README**

Document wrapper commands as primary:

```powershell
$root = 'C:\caminho\do\projeto'
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conversation-esaa.ps1 init --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conversation-esaa.ps1 enable-hooks --agent grok --workspace $root --trust
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conversation-esaa.ps1 sync --agent codex --workspace $root
```

- [ ] **Step 5: Run tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
```

Expected:

```text
all wrapper tests pass
```

---

## Task 4: Implement `enable-hooks`

**Files:**
- Modify: `.conversation-esaa/bin/conversation-esaa.ps1`
- Modify: `.conversation-esaa/bin/conv-bootstrap.ps1`
- Modify: `.conversation-esaa/bin/conv-test.ps1`
- Modify: `README.md`

- [ ] **Step 1: Add enable-hooks tests**

Test Grok:

```powershell
conversation-esaa enable-hooks --agent grok --workspace <temp> --trust
```

Expected:

```text
<temp>\.grok\hooks\conversation-esaa.json exists
~\.grok\trusted-hook-projects contains <temp>
verify: ok
```

Test Claude:

```powershell
conversation-esaa enable-hooks --agent claude --workspace <temp> --trust
```

Expected:

```text
<temp>\.claude\settings.json exists
approval_required if no trusted-file surface is supported
verify: ok
```

Test Codex:

```powershell
conversation-esaa enable-hooks --agent codex --workspace <temp> --watcher
```

Expected:

```text
codex-watch.ps1 copied/configured
verify: ok
```

- [ ] **Step 2: Implement Grok hook enablement**

Generate `.grok/hooks/conversation-esaa.json` with commands that call:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<workspace>\.conversation-esaa\bin\conversation-esaa.ps1" sync --agent grok --workspace "<workspace>"
```

When `--trust` is passed, add the workspace path to:

```text
~/.grok/trusted-hook-projects
```

without duplicating entries.

- [ ] **Step 3: Implement Claude hook enablement**

Generate `.claude/settings.json` with commands that call:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<workspace>\.conversation-esaa\bin\conversation-esaa.ps1" sync --agent claude --workspace "<workspace>"
```

If no trusted file surface is supported:

```text
approval_required: approve Claude Code project hooks in the harness
```

This is not a failure if files are written and verify passes; it is an explicit post-install status.

- [ ] **Step 4: Implement Codex watcher enablement**

Ensure `codex-watch.ps1` exists and document/run command:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<workspace>\.conversation-esaa\bin\codex-watch.ps1" -WorkspaceRoot "<workspace>"
```

- [ ] **Step 5: Run tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
```

Expected:

```text
enable-hooks tests pass
```

---

## Task 5: Implement `context --last`, `--before`, `--around`, `--agent`

**Files:**
- Modify: `.conversation-esaa/bin/conversation-esaa.ps1`
- Modify: `.conversation-esaa/bin/conv-sync.ps1` if context is delegated there
- Modify: `.conversation-esaa/bin/conv-test.ps1`
- Create: `.conversation-esaa/tests/fixtures/context/activity.context.jsonl`

- [ ] **Step 1: Create context fixture**

Create fixture with:

- two workspaces;
- agents `grok`, `codex`, `claude`;
- at least 12 events;
- stable event ids;
- topic words like `workspace`, `hooks`, `snapshot`;
- mixed actor/source/agent_id.

- [ ] **Step 2: Add context tests**

Required assertions:

```text
context --last 3 returns last 3 events for workspace
context --agent grok --last 2 returns only Grok events
context --before evt_006 --last 2 returns two events before evt_006
context --around evt_006 --window 1 returns previous, target, next
context never returns events from another workspace
```

- [ ] **Step 3: Implement context reader**

Read `activity.jsonl`, filter first by `workspace_root`, then apply:

```text
--agent: event.agent_id == value OR event.source == value
--before: events with index before target event
--around: centered window around target event
--last: take last N after filters
```

- [ ] **Step 4: Implement Markdown output**

Return deterministic Markdown:

```markdown
# Context Window

workspace: C:\...
filter: agent=grok
count: 2

## Events

- [2026-06-21T14:30:29-03:00] assistant/grok evt_abc
  summary text
```

- [ ] **Step 5: Add optional JSON output**

Support:

```powershell
conversation-esaa context --agent grok --last 20 --json
```

Output an array of event objects after filtering.

- [ ] **Step 6: Run tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
```

Expected:

```text
context tests pass
```

---

## Task 6: Implement `decide` and `decisions.md`

**Files:**
- Modify: `.conversation-esaa/bin/conversation-esaa.ps1`
- Modify: `.conversation-esaa/bin/conv-sync.ps1`
- Modify: `.conversation-esaa/bin/conv-test.ps1`
- Create generated: `.conversation-esaa/decisions.md`

- [ ] **Step 1: Add decision tests**

Test:

```powershell
conversation-esaa decide "Usar context --agent para handoff seletivo" --rationale "Evita ler log inteiro" --workspace <temp>
```

Expected:

```text
activity.jsonl contains decision.recorded
decisions.md contains decision and rationale
state.md includes recent decision if relevant
verify: ok
```

- [ ] **Step 2: Implement decision event schema**

Append:

```json
{
  "event": "decision.recorded",
  "actor": "assistant",
  "agent_id": "codex",
  "workspace_root": "C:\\...",
  "decision": "...",
  "rationale": "...",
  "related_turns": []
}
```

CLI options:

```powershell
--rationale <text>
--agent <agent_id>
--source <event_id>
--workspace <path>
```

- [ ] **Step 3: Project decisions.md**

Format:

```markdown
# Decisions

> Generated by conversation-esaa project. Do not edit manually.

## Active Decisions

### DEC-0001 — Usar context --agent para handoff seletivo

- ts: ...
- actor: assistant
- agent_id: codex
- rationale: Evita ler log inteiro
- related_turns: ...
```

- [ ] **Step 4: Verify decision events**

`verify` must require:

```text
event_id
ts
event=decision.recorded
actor
agent_id
workspace_root
decision
rationale
```

- [ ] **Step 5: Run tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
```

Expected:

```text
decision tests pass
```

---

## Task 7: Implement `task` Events and Projected `tasks.json`

**Files:**
- Modify: `.conversation-esaa/bin/conversation-esaa.ps1`
- Modify: `.conversation-esaa/bin/conv-sync.ps1`
- Modify: `.conversation-esaa/bin/conv-test.ps1`
- Modify generated behavior: `.conversation-esaa/tasks.json`

- [ ] **Step 1: Add task projection tests**

Test:

```powershell
conversation-esaa task create "Implementar context --agent" --workspace <temp>
conversation-esaa task update CONV-001 --status in_progress --workspace <temp>
conversation-esaa task close CONV-001 --evidence "context tests pass" --workspace <temp>
```

Expected:

```text
activity.jsonl contains task.created/task.updated/task.closed
tasks.json is projected from events
manual edits are overwritten by project
verify: ok
```

- [ ] **Step 2: Define task events**

Use:

```json
{
  "event": "task.created",
  "task_id": "CONV-001",
  "title": "Implementar context --agent",
  "status": "open",
  "workspace_root": "C:\\..."
}
```

```json
{
  "event": "task.updated",
  "task_id": "CONV-001",
  "status": "in_progress",
  "next_step": "..."
}
```

```json
{
  "event": "task.closed",
  "task_id": "CONV-001",
  "status": "completed",
  "evidence": "context tests pass"
}
```

- [ ] **Step 3: Project tasks.json from task events**

Projection rules:

```text
task.created creates task
task.updated patches known task
task.closed marks completed and sets completed_at
last event wins for scalar fields
unknown task update fails verify
```

- [ ] **Step 4: Update handoff/state projections**

`handoff.md` open tasks must come from projected tasks, not manual source.

`state.md` counts open/completed tasks from projected tasks.

- [ ] **Step 5: Run tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
```

Expected:

```text
task projection tests pass
```

---

## Task 8: Implement `context --topic`

**Files:**
- Modify: `.conversation-esaa/bin/conversation-esaa.ps1`
- Modify: `.conversation-esaa/bin/conv-test.ps1`

- [ ] **Step 1: Add topic tests**

Using context fixture, assert:

```text
context --topic "workspace" returns events containing workspace in summary/text/decision
ranking is deterministic by match count, then recency
results stay inside workspace_root
```

- [ ] **Step 2: Implement textual matching**

Search fields:

```text
summary
text
decision
rationale
title
next_step
```

Ranking:

```text
primary: number of case-insensitive exact substring matches
secondary: ts descending
tertiary: event_id ascending
```

- [ ] **Step 3: Run tests**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
```

Expected:

```text
topic context tests pass
```

---

## Task 9: Documentation and Verification

**Files:**
- Modify: `README.md`
- Modify: `PRIVACY.md`
- Modify: `.conversation-esaa/plans/system-design-conversation-esaa-v1-v2.md` only if implementation discovers design correction

- [ ] **Step 1: Update README command surface**

Primary examples:

```powershell
conversation-esaa init --workspace C:\caminho\projeto
conversation-esaa enable-hooks --agent grok --trust --workspace C:\caminho\projeto
conversation-esaa context --agent grok --last 20 --workspace C:\caminho\projeto
conversation-esaa decide "..." --rationale "..." --workspace C:\caminho\projeto
conversation-esaa task create "..." --workspace C:\caminho\projeto
```

- [ ] **Step 2: Update privacy model**

Clarify:

```text
activity.jsonl is local source of truth
redaction does not mutate local log
public export uses redacted derivative or empty log
```

- [ ] **Step 3: Run full verification**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conversation-esaa.ps1 verify --workspace C:\xampp\htdocs\esaa-conversational-lab
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conversation-esaa.ps1 context --agent grok --last 20 --workspace C:\xampp\htdocs\esaa-conversational-lab
```

Expected:

```text
all tests pass
verify: ok
context window contains only grok events for this workspace
```

---

## Recommended Execution Order

1. Task 1: workspace isolation.
2. Task 2: lockfile.
3. Task 3: CLI wrapper.
4. Task 4: enable-hooks.
5. Task 5: context core.
6. Task 6: decisions.
7. Task 7: tasks projection.
8. Task 8: topic context.
9. Task 9: docs and full verification.

Do not start paper rewriting until Task 5 is demonstrably working. The first visible product proof is:

```powershell
conversation-esaa context --agent grok --last 20 --workspace C:\xampp\htdocs\esaa-conversational-lab
```

---

## Plan Corrections

### CE-V11-010 — Grok fixture path (2026-06-21)

The original Task 1 file list and `CE-V11-001` roadmap target listed
`.conversation-esaa/tests/fixtures/grok/session.jsonl`. That path was never
created. Runtime and tests use `grok/chat_history.jsonl`, matching the Grok
session layout (`chat_history.jsonl` under `~/.grok/sessions/<encoded-cwd>/<id>/`).

`CE-V11-001` remains `done` with its historical `task.create` targets unchanged
(esaa-core has no `task.update`; done tasks are immutable). This plan is the
canonical reference for the correct Grok fixture filename.

