# Relatório de QA E2E — Promoção, Rollback, Privacidade e Instalador (`CONV-MTCG-QA-012`)

**Data:** 2026-11-07  
**Task ESAA:** `CONV-MTCG-QA-012`  
**Modo de Revisão:** `security`  
**Status:** APROVADO

---

## 1. Escopo da Auditoria E2E

Auditoria completa das fases de promoção explícita (`memory accept`), reversão (`memory rollback`), reconstrução determinística a partir de `activity.jsonl` (`project` + `verify`), integração opt-in do caminho de leitura ativa (`pack`, `context`, `memory context`), segurança/privacidade de `.conversation-esaa/memory` e ciclo de vida do instalador (`install`, `status`, `doctor`, `repair`, `update`, `uninstall`).

---

## 2. Evidências por Critério de Aceite

### 2.1 Suíte Completa sem Regressões e Verificação da CLI
- `node --test tests/memory/*.test.js` -> **9 passed, 0 failed**
- `pwsh -NoProfile -File tests/test-memory-shadow.ps1` -> **27 passed, 0 failed**
- `pwsh -NoProfile -File tests/test-memory-accept-replay.ps1` -> **18 passed, 0 failed**
- `pwsh -NoProfile -File tests/test-memory-read-path.ps1` -> **17 passed, 0 failed**
- `node --test tests/installer/memory/memory.test.js` -> **2 passed, 0 failed**
- `node --test tests/installer/all.test.js` -> **21 passed, 0 failed**
- `pwsh -NoProfile -File .conversation-esaa/bin/conv-test.ps1` -> **112 passed, 0 failed**

### 2.2 Cobertura de Conflitos, Corrupção, Symlinks, Permissões e Stale
1. **Conflitos (`UNRESOLVED_CONFLICT_NO_SILENT_WINNER`):**
   - Verificado em `tests/memory/resonance.test.js` e `tests/test-memory-read-path.ps1`: pares contraditórios (`MySQL` vs `MongoDB` sem `decision.recorded` resolutiva) permanecem com `epistemic_status = "unresolved"`, geram `possible_edges` (`possibly_contradicts`) + `boundaries` (`unresolved_conflict`) e aparecem rotulados como `[UNRESOLVED CONFLICT]` no `pack` e `memory context`.
2. **Corrupção de Proposta / Geração / Visão Ativa (`INTEGRITY_FAILURE`):**
   - Verificado em `tests/test-memory-accept-replay.ps1`: adulteração de qualquer campo em `shadow/<proposal>.json` ou `generations/<gen>/graph.json` é bloqueada por `verifyProposalIntegrity` / `verifyGraphIntegrity` com `INTEGRITY_FAILURE`.
   - Verificado em `tests/test-memory-read-path.ps1`: adulteração de `.conversation-esaa/memory/active.json` faz `memory context --json` retornar `status: "FALLBACK_LEGACY"` (`error_code: "INTEGRITY_FAILURE"`), e `pack` / `context` fazem fallback seguro para a projeção legada do ledger emitindo o marcador rastreável `MEMORY-FALLBACK`.
3. **Symlinks (`UNSAFE_PATH`):**
   - Verificado em `tests/memory/snapshot.test.js` e `tests/installer/memory/memory.test.js`: symlinks dentro de `.conversation-esaa/memory/**` ou apontando para fora do workspace são rejeitados com `UNSAFE_PATH` sem seguir nem alterar permissões do alvo externo.
4. **Permissões e Privacidade:**
   - Diretórios `.conversation-esaa/memory`, `shadow`, `generations` e `logs` são criados com modo `0700` e arquivos JSON/JSONL com `0600` em sistemas POSIX.
   - `.gitignore` do repositório e `Merge-Gitignore` em `conv-bootstrap.ps1` incluem `.conversation-esaa/memory/`.
   - `conv-rag.ps1` ignora eventos `memory.*` na exportação do corpus RAG, impedindo auto-reforço.
5. **Proposta Stale (`STALE_PROPOSAL`) e Workspace Incorreta (`WRONG_WORKSPACE`):**
   - Verificado em `tests/test-memory-accept-replay.ps1`: avanço do ledger após geração da proposta bloqueia `memory accept` com `STALE_PROPOSAL`; proposta originada em outro workspace é rejeitada com `WRONG_WORKSPACE`.
6. **Crash Recovery / Replay de Fonte Única (`activity.jsonl`):**
   - Verificado em `tests/test-memory-accept-replay.ps1`: após `Remove-Item -Recurse -Force .conversation-esaa/memory`, a execução de `conversation-esaa project` seguida de `conversation-esaa verify` reconstrói integralmente `.conversation-esaa/memory/active.json`, `manifest.json`, `shadow/<prop>.json` e `generations/<gen>/graph.json` a partir dos eventos `memory.consolidation.accepted` e `memory.consolidation.rolled_back` em `activity.jsonl`, preservando o mesmo `active_digest`.

### 2.3 Preservação de Dados pelo Bundle / Instalador (`update`, `repair`, `uninstall`)
- Verificado em `tests/installer/memory/memory.test.js`:
  - `install` registra `.conversation-esaa/bin/conv-memory.ps1` como `owned` em `install-manifest.json` sem incluir qualquer arquivo ou conteúdo privado de `.conversation-esaa/memory`.
  - `repair` e `update` restauram `.conversation-esaa/bin/conv-memory.ps1` quando ausente/modificado e preservam `.conversation-esaa/memory/active.json` intacto.
  - `uninstall` remove os scripts `owned` de `.conversation-esaa/bin/` e preserva `.conversation-esaa/memory` listado em `preserved_private` (`PRIVATE_PATHS`).

---

## 3. Conclusão

Todos os critérios de segurança, governança, privacidade, resiliência e ciclo de vida do instalador para `CONV-MTCG-QA-012` foram integralmente atendidos.
