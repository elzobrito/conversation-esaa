# D-01 — O ledger deve chegar ao Cloud Agent do Cursor?

**Status:** decisão humana. Sem Passo C. Medido em árvore suja, HEAD `baea68d`.

## Problema

`verify` falha se `workspace_root` do evento ≠ raiz atual. `Get-WorkspaceEvents` descarta esses eventos. Hooks do Cursor gerados pelo bootstrap embutem **pwsh absoluto** e **`-WorkspaceRoot` absoluto**. `.cursor/hooks.json` está no `.gitignore`.

## Fatos medidos (PS-05)

Workspace sintético + clone recursivo após um turno Cursor:

- origem: `verify: ok`
- clone: exit 1, `Event … belongs to another workspace: <origem>`
- comando do hook: `"/home/elzobrito/.local/opt/pwsh/pwsh" … -WorkspaceRoot "<origem>"`
- `.gitignore` do bootstrap ignora `activity.jsonl`, `handoff.md`, `state.md`, `.cursor/hooks.json`; **não** ignora `codex-watch.log`, `antigravity-hook.log`, `run/cursor-*.txt`, `*.bak-*`

Não houve Windows nem Cloud Agent real nesta medição.

## Opções

| | Opção | Custo | Risco |
|---|---|---|---|
| **A** | Ledger só local. Remover do ADR-012 a promessa de pack no Cloud Agent. | Baixo (texto) | Cloud Agent continua sem continuidade |
| **B** | `export-handoff` redigido e versionado, opt-in | Médio (comando + testes + PRIVACY) | vazamento se a redação falhar |
| **C** | `relocate` com evento `workspace.relocated` (append-only); snapshot/verify honram a nova raiz | Alto (contrato + migrate + testes) | clone/CI passam; semântica de identidade do workspace muda |

## Recomendação

**A agora**, com **B** como trabalho futuro se o operador precisar levar handoff ao Cloud Agent. **C** só se houver caso real de mover o diretório sem rebootstrap.

Itens bloqueados: PS-05 (código). PS-17 cobre os buracos de `.gitignore` independentemente.
