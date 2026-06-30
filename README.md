# Conversation ESAA

> Shared conversational memory for heterogeneous LLM coding agents.

Conversation ESAA is an event-sourced memory layer for continuity, handoff, and
curation across agents such as Codex, Grok, Claude Code, and other assistants.
It captures visible conversation turns into a local append-only log and projects
compact read models that a cold agent can use without ingesting the full history.

In one line:

```text
Agent log/hook -> conversation-esaa sync -> append activity.jsonl -> project read models -> handoff/context
```

This repository contains the public v1.1.0 Conversation ESAA distribution: local
CLI scripts, hooks/watchers, deterministic projections, tests, privacy guidance,
and design notes.

Paper: [ESAA-Conversational: An Event-Sourced Memory Layer for Continuity, Handoff, and Curation Across Heterogeneous LLM Coding Agents](https://arxiv.org/pdf/2606.23752)

## At A Glance

- Visible conversation turns are captured mechanically from agent logs, hooks,
  or watcher surfaces.
- `.conversation-esaa/activity.jsonl` is the append-only source of truth.
- `handoff.md`, `state.md`, `decisions.md`, and `tasks.json` are deterministic
  read models, not hand-edited truth.
- Durable decisions and conversational tasks are curated explicitly through CLI
  commands.
- Mechanical capture, deduplication, projection, and verification do not require
  LLM inference.
- The public distribution is greenfield: it ships with no private conversation
  history.

## What It Solves

Modern developers often move between multiple LLM coding agents. One agent may
be better at local edits, another at architectural review, and another at long
context reading. The problem is that each agent usually stores its conversation
in a private, vendor-specific log.

That creates conversational state drift:

| Problem | Conversation ESAA response |
| --- | --- |
| Goals and decisions are trapped in one agent session | Projected handoff and state files give the next agent a compact entry point |
| Manual context copying is lossy and token-expensive | Hooks and watchers capture visible turns mechanically |
| Summaries can become the source of truth | The append-only event log remains authoritative |
| Agent memory formats are incompatible | Native logs are normalized into a shared local event vocabulary |
| Private conversation history is easy to leak | The public package is greenfield and `.gitignore` excludes generated logs/read models |

## How It Relates To ESAA-Core

Conversation ESAA is a domain specialization of ESAA, but it governs a different
object.

```text
ESAA-Core
  governs agentic work over a project

Conversation ESAA
  governs memory, continuity, handoff, curation, and synchronization across agents
```

ESAA-Core uses an orchestrator to validate agent intentions before project state
changes. Conversation ESAA uses an inverted ingestion model: it reads native
agent logs, hooks, or watcher output and normalizes visible turns into a shared
event store.

The central rule is:

```text
turns = evidence
decisions = durable knowledge
tasks = operational continuity
handoff = operational entry point
context = selective log reading
```

## Requirements

- Windows or Linux
- A workspace where `.conversation-esaa/` can be installed
- On Windows: PowerShell 7 or newer (`pwsh`) to run the bundled `.ps1` CLI

The v1.1.0 release is intentionally local and file-based. This repository is
usable as a Linux workspace, including the environment used to maintain it. The
bundled Windows-oriented operational scripts are PowerShell scripts; on Linux,
`pwsh` is only needed if you choose to run those `.ps1` scripts directly.
Agent-specific hooks may still depend on the host tool and its native log or
hook behavior.

## Quickstart

Set the workspace root.

Linux example:

```powershell
$root = '/home/elzobrito/desenvolvimento/conversation-esaa'
New-Item -ItemType Directory -Force -Path $root | Out-Null
```

Windows example:

```powershell
$root = 'C:\path\to\your\project'
New-Item -ItemType Directory -Force -Path $root | Out-Null
```

Bootstrap Conversation ESAA into that workspace:

```powershell
$bootstrap = Join-Path $root '.conversation-esaa/bin/conv-bootstrap.ps1'
pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrap -WorkspaceRoot $root
```

The bootstrap installs scripts, creates a clean local structure, and generates
agent integration files with paths for your workspace. It creates an empty
`activity.jsonl`; it does not ship private history.

Define the CLI path:

```powershell
$cli = Join-Path $root '.conversation-esaa/bin/conversation-esaa.ps1'
```

Verify the installation:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli verify --workspace $root
```

Expected first signal: `verify` reports that the projected read models are
consistent with the local event store.

## Enable Automatic Sync

### Grok

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli enable-hooks --agent grok --workspace $root --trust
```

Then add the project to `~/.grok/trusted-hook-projects` and reload hooks with
`/hooks` followed by `r`.

### Claude Code

The bootstrap creates `.claude/settings.json`. Reopen the session and approve
the hooks when prompted.

### Codex

Codex does not expose a native hook in the v1.1.0 design. Use the watcher:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli enable-hooks --agent codex --workspace $root --watcher
```

Or start it manually:

```powershell
$watcher = Join-Path $root '.conversation-esaa/bin/codex-watch.ps1'
pwsh -NoProfile -ExecutionPolicy Bypass -File $watcher -WorkspaceRoot $root
```

## Daily Use

Synchronize visible conversation after working with an agent:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync --agent grok --workspace $root
```

Validate integrity:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli verify --workspace $root
```

Read context for handoff to another agent or a new session:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli context --agent grok --last 20 --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli context --topic "authentication" --last 5 --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli context --agent grok --last 5 --json --workspace $root
```

Record durable decisions and conversational tasks:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli decide -Decision "Use JWT" -Rationale "stateless service boundary" --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli task create -Title "Implement login" --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli task close CONV-001 -Evidence "tests pass" --workspace $root
```

Additional commands include `context --before`, `context --around`,
`task update`, and `project`. Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli help
```

## Architecture

```text
native agent log / hook / watcher
  -> conversation-esaa CLI
    -> write-path lock
      -> append .conversation-esaa/activity.jsonl
        -> project read models
          -> verify
            -> handoff/context for the next agent
```

The layers are intentionally small:

| Layer | Responsibility |
| --- | --- |
| Agent surface | Exposes visible turns through a log, hook, or watched output |
| Adapter/sync | Normalizes visible turns into conversation events |
| Event store | Persists admitted events in append-only order |
| Projector | Rebuilds compact read models from the event store |
| Context reader | Provides selective, paginated windows over the log |
| Curator | Records explicit decisions and conversational tasks |

Conversation ESAA is not a semantic memory system by default. Topic filtering is
deterministic textual retrieval. Embeddings, generated indexes, and richer search
can be added later as derived projections, but they should not become the source
of truth.

## Core Concepts

**Event store.** `.conversation-esaa/activity.jsonl` is the local append-only
source of truth. Treat it as sensitive because it can contain literal
conversation text.

**Read models.** `handoff.md`, `state.md`, `decisions.md`, and `tasks.json` are
derived from the event store. They are useful for agent entry and inspection,
but they should not be edited manually.

**Inverted ingestion.** Agents do not need to speak the Conversation ESAA
protocol. Hooks and watchers observe native surfaces and call the local CLI.

**Mechanical capture versus curation.** Captured turns are evidence. Decisions
and tasks are explicit curated events created through commands such as `decide`
and `task`.

**Selective reading.** A cold agent should start with `handoff.md`, `state.md`,
`decisions.md`, and `tasks.json`, then use `context` for focused windows instead
of loading the whole log.

**Workspace isolation.** Events include workspace context so that one local
installation does not silently mix unrelated projects.

## Repository Layout

```text
conversation-esaa/
  LICENSE
  README.md
  PRIVACY.md
  RELEASE.md

  .conversation-esaa/
    bin/
      conversation-esaa.ps1      public CLI
      conv-bootstrap.ps1         workspace bootstrap
      conv-sync.ps1              synchronization helper
      codex-watch.ps1            Codex watcher
      conv-test.ps1              focused tests
      conv-test-battery.ps1      broader test battery
    plans/
      adr-001-008-conversation-esaa-v1-1.md
      system-design-conversation-esaa-v1-v2.md
      v1-1-implementation-plan.md
    tests/fixtures/
    run/.gitkeep
    activity.jsonl               generated locally, do not commit

  .grok/hooks/                   generated by bootstrap
  .claude/settings.json          generated by bootstrap
```

Generated read models and operational files are intentionally excluded from
version control. See [PRIVACY.md](PRIVACY.md) before sharing or publishing a
workspace.

## Privacy

Conversation ESAA records the literal text of visible conversation. This is what
makes operational handoff possible, but it also means the local `.conversation-esaa/`
directory can contain private goals, code snippets, paths, credentials mentioned
by mistake, customer details, or unpublished decisions.

The v1.1.0 policy is conservative:

- The public package contains no private history.
- `.gitignore` excludes generated logs, read models, and operational files.
- Sync should avoid hidden reasoning, raw tool outputs, system prompts, and
  internal side channels.
- Redaction and anonymized export are future work, not implicit local mutation.

Read [PRIVACY.md](PRIVACY.md) before committing, pushing, zipping, or sharing a
workspace.

## Testing

Run the focused tests:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa/bin/conv-test.ps1
```

Run the broader battery:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa/bin/conv-test-battery.ps1 -SkipLab -SkipEsaa
```

## Public v1.1.0 Status

Implemented in the public release:

- `init`, `enable-hooks`, `sync`, `project`, `verify`, `context`, `decide`, and
  `task` commands
- local file-based runtime with bundled PowerShell scripts for Windows operation
- Grok and Claude Code hook integration
- Codex watcher integration
- Append-only `activity.jsonl`
- Deterministic read models for handoff, state, decisions, and tasks
- Workspace root isolation
- Write-path lockfile
- Greenfield public distribution without private history

Current limitations:

- On Windows, PowerShell 7 is required for the bundled `.ps1` scripts.
- On Linux, PowerShell 7 is optional and only needed for direct `.ps1` execution;
  the repository layout, documentation, event model, and handoff artifacts are
  maintained in a Linux workspace.
- Native hooks depend on each agent's platform behavior.
- Agent log and hook formats are external surfaces and may change.
- Topic retrieval is textual, not semantic.
- Codex uses a watcher rather than a native hook.
- The release provides operational auditability, not cryptographic forensic
  guarantees.
- There is no snapshot, cold replay, redaction, anonymized export, or vector
  index in v1.1.0.

## Future Work

Planned directions from the paper include:

- snapshots for compacting older history into durable state
- cold replay and hash-based reconstruction checks
- redacted exports and explicit privacy policies
- stronger forensic auditability with hash chains or signatures
- semantic indexes as derived projections over the event store
- broader platform-specific hook coverage
- possible ESAA-Core profile integration without losing the conversational
  vocabulary

## Documentation

| Resource | Contents |
| --- | --- |
| [PRIVACY.md](PRIVACY.md) | Privacy model and sharing guidance |
| [RELEASE.md](RELEASE.md) | v1.1.0 release notes |
| `.conversation-esaa/plans/` | System design, ADRs, and implementation plan |
| [arXiv:2606.23752](https://arxiv.org/abs/2606.23752) | ESAA-Conversational paper |

## License

MIT. See [LICENSE](LICENSE).
