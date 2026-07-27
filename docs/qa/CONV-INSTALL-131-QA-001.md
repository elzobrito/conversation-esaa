# Conversation ESAA 1.3.1 release-candidate QA

Date: 2026-07-27
Task: `CONV-INSTALL-131-QA-001`

## Environment

- Ubuntu, Node.js `v22.23.1`
- npm `10.9.8`
- PowerShell `7.5.2`
- CI matrix: `ubuntu-latest` and `windows-latest`, Node.js 20 and 22

## Local results

| Check | Result |
|---|---|
| `npm test` | 21 tests passed, including the live managed-RAG package path |
| `tests/test-installer-bootstrap.ps1` | passed |
| `tests/test-cli-long-options.ps1` | passed for `-File` and `-Command` |
| `.conversation-esaa/bin/conv-test.ps1` | 77 passed, 0 failed |
| `tests/test-rag-adapter.ps1` | all passed |
| `tests/test-rag-command-contract.ps1` | all passed |
| `tests/test-rag-permissions.ps1` | all passed |
| `git diff --check` | passed |
| `python -m esaa --root . verify` | `verify_status: ok` |

The installer suite covers clean installations for every supported agent and
all agents together, Unicode and whitespace in paths, legacy duplicate hook
variants, preservation of unrelated hooks, lifecycle commands, command
injection resistance, and installation from the generated tarball.

## Corrected regressions

- GNU-style options are normalized identically when the public PowerShell CLI
  is invoked through `pwsh -File` or the call operator under `pwsh -Command`.
- The npm path invokes the bootstrap with `-SkipAgentIntegrations`; the Node
  adapter is therefore the sole hook writer.
- Existing literal-`pwsh`, absolute-`pwsh`, and equals-form agent commands
  converge to one canonical hook per event. Unrelated hooks remain untouched.
- `conv-bootstrap.ps1` is installed in the workspace, recorded as an owned
  runtime file, checked by `status`/`doctor`, restored by `repair`/`update`,
  and removed by `uninstall`.
- Private activity, sync state, projections, tasks, decisions, and RAG data are
  preserved across reinstall, repair, update, and uninstall.

## Package inspection

`npm pack` produced `conversation-esaa-1.3.1.tgz` with 24 allowlisted public
files. The inspected candidate had SHA-256
`124953e72602a32a951df8065a139bf31304a8f50d7c92edee60c0e846fc813a`.

The archive contains the public PowerShell runtime, Node installer, README,
LICENSE, PRIVACY, and package metadata. A filename scan found no event stores,
read models, SQLite databases, credentials, local configuration, or unrelated
internal baseline artifacts.

The publication task must calculate and publish a new final checksum after the
release documentation is updated, because README is part of the npm package.

## Cross-platform gate

The GitHub Actions workflow runs `npm test`, the bootstrap contract, and the
long-option contract in all four Ubuntu/Windows and Node 20/22 cells. The
legacy and RAG suites run in both operating systems on Node 22. Publication is
blocked until that matrix is green for the reviewed release commit.
