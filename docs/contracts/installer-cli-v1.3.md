# Conversation ESAA installer CLI v1.3

## Invocation

```text
npx conversation-esaa <command> [options]
conversation-esaa <command> [options]
```

Node.js 18+ and PowerShell 7+ are required. `install` defaults to the current
directory. Interactive prompts are enabled only on a TTY and may be disabled
with `--yes` or `--non-interactive`.

## Common options

| Option | Meaning |
|---|---|
| `--workspace <path>` | Installation boundary; default current directory |
| `--json` | Emit one JSON document and no presentation text |
| `--dry-run` | Plan without changing files or services |
| `--yes` | Accept safe defaults; never implies service installation |
| `--non-interactive` | Reject missing required choices |
| `--force` | Replace locally modified installer-owned files |

## Commands

### `install`

Options:

- `--agent <grok|claude|codex|antigravity>` repeatable, or
  `--agents <comma-list>`;
- `--rag <off|existing|managed>`; default `off` non-interactively;
- `--rag-command <path>` required by `existing` unless discoverable on PATH;
- `--codex-service <off|user>`; default `off`; `user` is an explicit
  confirmation equivalent;
- `--release <version>` for controlled package testing.

The command validates prerequisites, installs the packaged PowerShell runtime,
merges selected integrations, initializes missing data files, runs `project` and
`verify`, and writes the ownership manifest. Existing private files are kept.

### `status`

Read-only inventory of package version, selected agents, RAG mode, watcher
configuration, manifest integrity, and the latest non-sensitive diagnostic.
Exit `0` even when optional components are absent; use `doctor` for health.

### `doctor`

Checks Node, `pwsh`, runtime presence, manifest hashes, hook wiring, private
gitignore rules, Conversation ESAA `verify`, and configured RAG availability.
No network is used unless `--network` is passed. Exit `0` when healthy, `2` for
actionable drift, and `3` for unusable prerequisites or corrupted state.

### `update`

Replaces unchanged installer-owned runtime files with the requested package
version, migrates the manifest, reapplies selected integrations, and verifies.
Private data is never migrated destructively. Modified owned files cause exit
`2` unless `--force`.

### `repair`

Recreates missing or unchanged owned files from the current package, repairs
selected hook entries and gitignore rules, then verifies. It does not change the
selected version or RAG mode.

### `uninstall`

Removes unchanged installer-owned runtime files, named hook entries, and an
installer-created Codex user service. It preserves private/canonical data,
read models, `.conversation-esaa/rag/`, the manifest backup, unknown files, and
locally modified owned files. `--purge-data` is intentionally unsupported.

## Result model

JSON mode returns:

```json
{
  "schema_version": "conversation-esaa.installer.v1",
  "ok": true,
  "command": "install",
  "workspace": "/absolute/path",
  "version": "1.3.0",
  "changed": [],
  "preserved": [],
  "warnings": [],
  "errors": [],
  "next_steps": []
}
```

Paths may be present; conversation text, tokens, environment values, and file
contents must not be emitted.

## Exit semantics

| Code | Meaning |
|---:|---|
| 0 | requested operation completed or healthy |
| 1 | invalid CLI usage |
| 2 | actionable drift, conflict, or partial optional failure |
| 3 | prerequisite, integrity, or primary runtime failure |
| 4 | verified download or security policy failure |

On non-zero exit, JSON mode still emits the result model. A partial failure lists
every applied and skipped action. Re-running `repair` must be safe.

## Manifest

`.conversation-esaa/install-manifest.json` includes schema/version, normalized
workspace, selected agents, RAG mode and pinned release metadata, service mode,
and `{path, sha256, kind}` entries for installer-owned files. It never includes
conversation content. Paths are workspace-relative and cannot contain `..`.
