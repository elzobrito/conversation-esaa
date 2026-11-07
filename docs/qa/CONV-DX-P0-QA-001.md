# CONV-DX-P0-QA-001 — Cursor adapter and read-only session-start pack

Date: 2026-11-07
Task: `CONV-DX-P0-QA-001`
Depends on: `CONV-DX-P0-IMPL-001` (done)
Spec: `CONV-DX-P0-SPEC-001` / ADR-012 / `docs/contracts/cursor-adapter-v1.md`

## Environment

- Ubuntu, Node.js `v22.23.4`
- PowerShell `7.6.9` (`~/.local/bin/pwsh`)
- `esaa-core==0.5.0b25`
- Branch: `cursor/conv-dx-p0-cursor-adapter-e8d6`

## Results

| Check | Result |
|---|---|
| `npm test` | 27 passed, 0 failed (includes packed e2e for `cursor` alone and `--yes`) |
| `tests/test-installer-bootstrap.ps1` | PASS; unselected Cursor integration is not created |
| `tests/test-cli-long-options.ps1` | ALL PASSED (`sync --agent=cursor`, `pack --budget-tokens/--budget-chars`) |
| `.conversation-esaa/bin/conv-test.ps1` | 112 passed, 0 failed |
| `python3 -m esaa --root . verify` | `verify_status: ok` |
| LLM on Conversation ESAA path | none — pack/sessionStart/sync are mechanical PowerShell |

## Acceptance

### Clean install is repeatable and does not duplicate Cursor hooks

- Node adapter test `Cursor preserves unrelated hooks and is idempotent` keeps
  `afterFileEdit` / unrelated `beforeSubmitPrompt` and writes exactly one
  `cursor-hook.ps1` command per event (`sessionStart`, `beforeSubmitPrompt`,
  `afterAgentResponse`).
- Packed e2e installs `--agent cursor` and `--yes`; the combined workspace has
  one Conversation ESAA command per Cursor event.
- Bootstrap default agents now include `cursor`; a second bootstrap without
  `-Force` reports `skip (existe`.

### Broken hook is detected by verify/doctor with a repair path

- `conv-test` `verify_rejects_missing_cursor_capture_hook`: emptying
  `beforeSubmitPrompt` makes `verify` fail (not `verify: ok`).
- Lifecycle test `doctor reports missing Cursor capture hook`: selected
  `cursor` without `cursor-hook.ps1` / capture wiring yields
  `cursor-hooks` check `ok: false` and detail naming
  `install --agent cursor`.

### Cold agent recovers objective/decision/tasks from the mechanical pack only

- `sessionStart` returns `additional_context` containing `cold-start v1` and
  does **not** append `activity.jsonl` (`cursor_session_start_does_not_write_ledger`).
- `pack --budget-tokens 40` against a 4000-character handoff stays within the
  token budget and truncates (`truncated to budget` / omitted sections).
- Pack CLI does not take the pipeline lock and does not append ledger events.
- Cloud Agents: `sessionStart` is still installed for desktop/self-hosted;
  first `beforeSubmitPrompt` injects the pack when the conversation id is new.

### Capture of visible Cursor turns

- Fixture `.conversation-esaa/tests/fixtures/cursor/session.jsonl` imports two
  visible turns (`source=cursor`); thinking/tool lines are skipped.
- User events have `agent_id=null`; assistant events have `agent_id=cursor`.
- Second `sync-cursor` of the same fixture is idempotent.
- Live `beforeSubmitPrompt` with `prompt` appends one user event;
  `afterAgentResponse` with `text` appends one assistant event.
- Missing runtime fail-opens (`continue: true`, exit 0).

## Out of scope (confirmed not implemented)

MCP, P1 FTS `search`, npm publish, ESAA-claude, merge into ESAA-Core.

## Residual risk

- Cursor-managed Cloud Agents do not fire `sessionStart`; recovery depends on
  the first `beforeSubmitPrompt` injector. That path is covered by tests and
  by the hook wrapper.
- `.cursor/hooks.json` is gitignored like other generated integrations; a
  Cloud Agent workspace must run `install --agent cursor` (or `enable-hooks`)
  so the clone gets machine-local `pwsh` paths. The wrapper self-resolves
  the workspace when `-WorkspaceRoot` does not exist on the clone.
