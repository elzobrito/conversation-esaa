# ADR-012 — Cursor adapter and read-only session-start pack (P0)

**Status:** Accepted; amended by D-01 (local ledger only)
**Date:** 2026-11-07
**Depends on:** CONV-PRD-DX-001, ADR-011
**Implements:** CONV-DX-P0-SPEC-001

## Context

Conversation ESAA already captures Grok, Claude Code, Codex, and Antigravity.
Cursor Cloud Agents are now the operator's primary harness, but v1.3.1 has no
`--agent cursor` installer path. Cold start still depends on the agent
remembering to open `.conversation-esaa/handoff.md`.

Cursor Cloud Agents run command hooks from `.cursor/hooks.json` in the
repository. `sessionStart` does **not** fire for Cursor-managed Cloud Agents
(it would run too late, after the first write). `beforeSubmitPrompt` does fire
and can return `additional_context`. Self-hosted workers and the desktop app
still run `sessionStart`.

## Decision

1. Add `cursor` to the closed installer agent list next to
   `grok|claude|codex|antigravity`. Install is idempotent: merge named
   Conversation ESAA entries in `.cursor/hooks.json`; never replace unrelated
   hooks.
2. Capture canonical turns on the **message-send** path:
   - `beforeSubmitPrompt` records the visible user prompt (`actor=user`,
     `agent_id=null`, `source=cursor`).
   - `afterAgentResponse` records visible assistant text (`actor=assistant`,
     `agent_id=cursor`, `source=cursor`).
   - Skip thinking (`afterAgentThought`), tool I/O, and empty payloads.
   - Optional `stop` + `transcript_path` may re-sync turns. Live capture and
     transcript import do not guarantee a shared message identity; ambiguous
     deliveries may be duplicated.
3. Session-start **only reads**. It never appends `activity.jsonl`, never
   updates `sync-state.json`, and never runs `project`. It builds the
   mechanical cold-start pack and returns it as hook `additional_context`.
4. Local injector: `sessionStart` injects the pack where it runs. When it is
   not fired, the first `beforeSubmitPrompt` of a `conversation_id` attempts
   injection from the ledger available in that workspace. Tracking is
   ephemeral under `.conversation-esaa/run/`. The ledger is local; no transfer
   to a Cloud Agent or continuity across clones is promised.
5. The pack is bounded by `--budget-tokens` and `--budget-chars` (stricter
   bound wins; default 4000 estimated tokens). Truncation order, highest
   priority kept first: handoff, active decisions, open tasks, recent events
   of the active topic.
6. `verify` (and installer `doctor`) diagnose the Cursor path: missing
   wrapper, missing/broken `.cursor/hooks.json` entries, projection drift.
   Repair is `install --agent cursor` for hooks and `project` for
   projections. Fail closed on invalid JSON; fail open on hook runtime
   errors so send is never blocked.
7. The hook wrapper lives at `.conversation-esaa/bin/cursor-hook.ps1`. It
   can resolve a workspace from its own location. Generated hook commands
   may also contain absolute paths, and the local hook configuration is not
   transferred automatically by Git. A clone must be installed and configured in its
   own workspace; continuity from another workspace is not provided.
8. Zero LLM on this path. ESAA-Core remains a separate store; this adapter
   does not read or write `.roadmap/`.

## Consequences

- `SUPPORTED_AGENTS`, bootstrap, public CLI `sync --agent`, AGENTS.md, and
  tests all gain `cursor`.
- `.cursor/hooks.json` is installer-owned when generated (manifest hash);
  unrelated Cursor hooks are preserved.
- A Cloud Agent may run supported hooks after local installation, but the
  local ledger and generated hook configuration are not automatically transported by this adapter.
  Cross-workspace handoff, redacted export and relocation remain future work.
