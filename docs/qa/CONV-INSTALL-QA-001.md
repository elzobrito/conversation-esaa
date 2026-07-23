# CONV-INSTALL-QA-001 — Installer end-to-end validation

## Scope

The release tarball is installed into clean temporary workspaces rather than
executed from the source checkout. Coverage includes:

- Grok, Claude Code, Codex, and Antigravity individually and together;
- existing unrelated hook configuration;
- spaces, Unicode, and shell metacharacters in workspace paths;
- JSON, non-interactive, and dry-run modes;
- status, doctor, repair, update, and uninstall;
- preservation of literal private history;
- managed RAG release consumption and fail-open core installation;
- archive traversal, symlink, checksum, and schema rejection;
- Codex manual versus explicitly requested user service;
- legacy Conversation ESAA and RAG regression suites.

## Local result

- Node installer/unit/lifecycle tests: green.
- PowerShell bootstrap v1.3 test: green.
- Legacy `conv-test.ps1`: 77 passed, 0 failed after governed hotfix
  `CONV-INSTALL-BOOTSTRAP-HOTFIX-001`.
- `AGENTS.md` and `.claude/CLAUDE.md`: byte-identical.
- ESAA verification: green.

## CI matrix

GitHub Actions runs the packed CLI on Ubuntu and Windows with Node.js 20 and 22
plus PowerShell 7. Network-dependent managed-RAG download is covered locally;
CI keeps network optional and retains deterministic archive-policy tests.
