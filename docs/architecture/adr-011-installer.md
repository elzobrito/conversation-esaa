# ADR-011 — Installer and lifecycle manager (Conversation ESAA v1.3)

**Status:** Accepted
**Date:** 2026-07-23

## Context

The v1.2 bootstrap is functional but requires users to copy the runtime,
understand each agent integration, and configure optional RAG separately. The
installation flow is now the largest adoption barrier.

## Decision

1. Publish `conversation-esaa@1.3.0` as a dependency-free Node.js package with
   `npx conversation-esaa <command>` as the primary cross-platform entrypoint.
2. Keep `conv-bootstrap.ps1` as the PowerShell-only fallback and runtime
   primitive. The Node installer owns orchestration, prompts, downloads,
   lifecycle state, and diagnostics.
3. Support Grok, Claude Code, Codex, and Google Antigravity independently.
   Selection is explicit in non-interactive mode and multi-select in interactive
   mode. Existing unrelated hook settings are merged, never replaced.
4. Treat the workspace as the installation boundary. The default is the current
   directory; `--workspace` selects another directory.
5. Record only installer-owned paths and hashes in
   `.conversation-esaa/install-manifest.json`. User conversation data,
   projections, decisions, tasks, and `.conversation-esaa/rag/` are never
   installer-owned.
6. Make installation transactional at file granularity: validate prerequisites
   first, stage downloads in a temporary directory, verify checksums, then use
   atomic replacement. A failure returns the partial action report and leaves
   pre-existing files untouched.
7. Offer optional RAG modes:
   - `off`: do not configure RAG;
   - `existing`: validate a user-supplied `rag-sqlite` command;
   - `managed`: download the pinned public `rag-sqlite v0.1.0` release, verify
     SHA-256, and install it below `.conversation-esaa/vendor/rag-sqlite/`.
8. Keep ADR-010 invariants: RAG is opt-in, fail-open for sync/project/verify,
   local-only, and its index is a disposable projection.
9. Codex has no native hook. The installer can configure a watcher and may offer
   a user service only after explicit confirmation. Unsupported service managers
   produce actionable manual instructions, not silent success.
10. Lifecycle commands are `install`, `status`, `doctor`, `update`, `repair`,
    and `uninstall`. All support machine-readable JSON; mutating commands support
    dry-run.

ESAA-Core is deliberately out of scope. The installer configures Conversation
ESAA only and does not bootstrap or mutate `.roadmap/`.

## Safety and privacy

- The installer never reads or uploads conversation text.
- Logs redact environment values and contain paths/actions only.
- Update and repair overwrite only manifest-owned files. A locally modified
  owned file requires `--force`.
- Uninstall removes only unchanged manifest-owned files. It preserves
  `activity.jsonl`, `sync-state.json`, all read models, decisions, tasks,
  plans, RAG data, and unknown files.
- No shell interpolation is used for workspace paths or downloaded commands.
- Managed archives reject absolute paths, traversal, and symbolic links before
  extraction.

## Consequences

The npm package becomes the canonical onboarding surface while the PowerShell
runtime remains portable and independently usable. The ownership manifest makes
upgrade, repair, and uninstall deterministic without treating private data as
package content.
