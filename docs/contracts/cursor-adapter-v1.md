# Conversation ESAA Cursor adapter v1 (P0)

Surface contract for `--agent cursor`, the message-send capture hook, the
read-only session-start injector, the cold-start pack budget, and Cursor-path
`verify` diagnostics. Implements CONV-PRD-DX-001 P0 / ADR-012.

Out of scope: MCP, FTS `search`, npm publish, ESAA-claude, merge into ESAA-Core.

## 1. Install

```text
node src/cli.js install --workspace <path> --agent cursor --non-interactive
node src/cli.js install --workspace <path> --agents grok,claude,codex,antigravity,cursor --non-interactive
```

- `cursor` is a supported agent in the Node installer, `conv-bootstrap.ps1`,
  and `conversation-esaa enable-hooks --agent cursor`.
- `--yes` selects every supported agent, including `cursor`.
- Idempotent: a second install does not duplicate Conversation ESAA Cursor
  hooks and does not overwrite private `activity.jsonl` / projections.
- Invalid existing `.cursor/hooks.json` fails closed (same as Claude settings).
- Unrelated hooks in `.cursor/hooks.json` are preserved.

### Integration file

Project hooks (Cloud Agents load only these):

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      {
        "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa/bin/cursor-hook.ps1 -Event sessionStart",
        "timeout": 20
      }
    ],
    "beforeSubmitPrompt": [
      {
        "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa/bin/cursor-hook.ps1 -Event beforeSubmitPrompt",
        "timeout": 20
      }
    ],
    "afterAgentResponse": [
      {
        "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa/bin/cursor-hook.ps1 -Event afterAgentResponse",
        "timeout": 20
      }
    ]
  }
}
```

The Node adapter may substitute the absolute `pwsh` discovered at install
time. The wrapper must still resolve `WorkspaceRoot` from the script path
when `-WorkspaceRoot` is omitted, so a Cloud Agent checkout works.

Runtime file added to the packaged set: `cursor-hook.ps1`.

## 2. Message-send capture (write path)

Canonical capture is the send hook, not session-start.

| Cursor event | Ledger effect |
|---|---|
| `beforeSubmitPrompt` | Append user `conversation_turn` from `prompt` |
| `afterAgentResponse` | Append assistant `conversation_turn` from `text` |
| `afterAgentThought` | Ignore |
| `sessionStart` | **No append** |
| `stop` | Optional transcript resync; deduped |

Event fields (same contract as grok/claude/codex/antigravity):

- `source = "cursor"`
- user: `actor=user`, `agent_id=null`
- assistant: `actor=assistant`, `agent_id=cursor`
- `workspace_root` required
- `source_session_id` = `conversation_id` (fallback `session_id`)
- `source_index` stable per session (generation ordinal or transcript index)
- skip empty / whitespace-only text

`sync --agent cursor` maps to `sync-cursor` in `conv-sync.ps1`. The hook
wrapper may pass `-CursorPrompt`, `-CursorRole`, `-CursorSessionId`, and
optional `-CursorTranscriptPath`. Fail-open: hook stdout is valid JSON,
exit 0, send is not blocked; errors go to
`.conversation-esaa/cursor-hook.log`.

`beforeSubmitPrompt` output on the capture path:

```json
{ "continue": true }
```

plus `additional_context` only when this conversation still needs the pack
(see §3).

## 3. Session-start injector (read path)

Must not write the ledger (`activity.jsonl`), `sync-state.json`, or run
`project`.

| Harness | When the pack is injected |
|---|---|
| Desktop / self-hosted | `sessionStart` → `{ "additional_context": "<pack>" }` |
| Cursor Cloud Agents | first `beforeSubmitPrompt` for that `conversation_id` |

Re-injection for the same conversation is suppressed using an ephemeral
marker under `.conversation-esaa/run/` (not a projection, not versioned).

If handoff/projections are missing or `verify` would fail, the injector
returns a short diagnostic telling the agent to run `verify` — still
without appending events.

## 4. Cold-start pack and budget

```text
conversation-esaa pack --workspace <path> [--budget-tokens N] [--budget-chars N]
```

Also reachable as `conv-sync.ps1 pack`.

Defaults: `--budget-tokens 4000` when neither flag is passed. Estimated
tokens = `ceil(utf8_length / 4)`. When both flags are passed, the stricter
(smaller) bound wins.

Stdout only on the session-start path. Shape (mechanical, no LLM):

```text
# cold-start v1 — mechanical, no LLM
## Handoff
...
## Decisions (active)
...
## Open tasks
...
## Recent events (topic=TOP-xxx|none)
...
```

Priority if over budget (drop from the bottom):

1. Keep `## Handoff` (truncate last if still over).
2. Then active decisions (top N that fit).
3. Then open tasks.
4. Then last K events of the active topic (`context --last` / topic key
   events).

The pack must be sufficient for a cold agent to state the current
objective, at least one standing decision when any exist, and open tasks.

## 5. Verify diagnostics (Cursor path)

`conversation-esaa verify` stays the projection integrity check. When
`cursor` is selected in `install-manifest.json` **or**
`.cursor/hooks.json` exists, it also reports:

| Finding | Why | Repair |
|---|---|---|
| wrapper missing | `cursor-hook.ps1` not in workspace runtime | `install --agent cursor` / `repair` |
| hooks.json missing or invalid | Cursor cannot load the adapter | `install --agent cursor` (fail closed on invalid JSON) |
| capture hook missing | `beforeSubmitPrompt` has no Conversation ESAA command | `install --agent cursor` |
| inject hook missing | neither `sessionStart` nor `beforeSubmitPrompt` injects pack | `install --agent cursor` |
| projection drift | named projection ≠ log | `project` then `verify` |

Messages name the projection or hook file. `doctor` surfaces the same
Cursor checks. Breaking a hook on purpose must be detected.

## 6. Public CLI additions

```text
conversation-esaa sync --agent cursor --workspace <path>
conversation-esaa enable-hooks --agent cursor --workspace <path>
conversation-esaa pack --workspace <path> [--budget-tokens N] [--budget-chars N]
conversation-esaa verify --workspace <path>
```

Help text, AGENTS.md, and `.claude/CLAUDE.md` list `cursor`. After any
contract-file edit, `diff AGENTS.md .claude/CLAUDE.md` is empty.

## 7. Tests

- Installer: `--agent cursor` accepted; unsupported agents still rejected;
  e2e install creates `.cursor/hooks.json`; second install is idempotent;
  unrelated Cursor hooks survive.
- Runtime: synthetic user+assistant payloads import two events; thinking
  skipped; second sync is a no-op; session-start / `pack` does not grow
  `activity.jsonl`; budget truncates in the specified order; verify
  explains a broken Cursor hook.
- Zero network / zero LLM in these tests.
