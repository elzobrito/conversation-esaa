# Baseline Audit & Architecture Fit — Memory-TCG + RRR

| Campo | Valor |
|---|---|
| **Task ID** | `CONV-MTCG-SPEC-001` |
| **Data** | 2026-11-07 |
| **Produto-alvo** | Conversation ESAA (`elzobrito/conversation-esaa`) |
| **Status** | Auditado e aprovado para Gate G0 |

---

## 1. Estado Real dos Repositórios Locais (AC[0])

### 1.1 `conversation-esaa` (`/home/elzobrito/desenvolvimento/conversation-esaa`)
- **Branch:** `main`
- **HEAD:** `bb65d8db7bb48090b4a1e5066095b06f90cac1e2` (`Merge pull request #7 from elzobrito/cursor/conv-dx-p0-cursor-adapter-e8d6`)
- **Sincronização inicial:** o clone local estava em `7962501e9998e7f69c30a2a1e71cf9014f707e44` e foi avançado via `git merge --ff-only origin/main` para `bb65d8db7bb48090b4a1e5066095b06f90cac1e2`, alinhando-se exatamente ao SHA inspecionado pelo pacote de transferência.
- **Pacote de transferência (`rrr/`):** movido de dentro da árvore de trabalho para `/home/elzobrito/desenvolvimento/rrr-handoff` para preservar higiene do working tree e evitar versionamento acidental.
- **Suites de baseline executadas antes de qualquer alteração:**
  - `node --test tests/installer/all.test.js`: **21 passed, 0 failed** (`44.4s`).
  - `pwsh -NoProfile -File .conversation-esaa/bin/conv-test.ps1`: **112 passed, 0 failed**.
- **ADRs existentes:**
  - `docs/architecture/adr-010-optional-rag-sqlite.md`
  - `docs/architecture/adr-011-installer.md`
  - `docs/architecture/adr-012-cursor-adapter.md`
  - `.conversation-esaa/plans/adr-009-memoria-intermediaria-por-assuntos.md`
  - **Próximo ADR livre:** `docs/architecture/adr-013-memory-tcg-rrr.md` (**D-03** confirmado).

### 1.2 `tcg` (`/home/elzobrito/desenvolvimento/tcg`)
- **Branch:** `main`
- **HEAD:** `623c6d02271e2ce3005634c923b64e74c13889dc` (`feat: bind declared config to recognized routes`, evolução local Spike-05 além de `origin/main` `d33b78f`).
- **Working tree local:** possui modificações e artefatos experimentais locais (`src/tcg/impact.py`, `src/tcg/semantic/`, `src/tcg/styles/`, `docs/qa/*`) que **não devem ser tocados nem acoplados** ao Conversation ESAA.

---

## 2. Auditoria da API TCG Real, Contrato de Instalação e Respostas da Pré-Auditoria (AC[1])

### 2.1 Avaliação do TCG Local (`elzobrito/tcg`)
1. **API e escopo:** O pacote `tcg-local` (`pyproject.toml`, Python `>=3.12`) é um analisador estático de código-fonte (`scanner.py`, `language/`, `framework/`, `toolchain/`, `graph/e2e.py`, `impact.py`). Conforme `docs/tcg-architectural-direction.md`, não expõe Pack API pública genérica nem SDK agnóstico de domínio.
2. **Incompatibilidades com acoplamento direto:**
   - Exigiria runtime Python `>=3.12` no caminho do Conversation ESAA, cujo instalador/motor usa **Node.js 18+** (`src/`) e **PowerShell 7** (`.conversation-esaa/bin/`).
   - Os modelos internos (`src/tcg/models.py`) são específicos de AST, rotas HTTP, arquivos de código e configurações declaradas, incompatíveis com eventos conversacionais (`conversation_turn`, `decision.recorded`, `topic.*`, `task.*`).
3. **Invariantes transferíveis (`docs/tcg-core-invariants.md`):**
   - `INV-001` (`STALE_GRAPH` / `STALE_PROPOSAL`): rejeitar promoção quando o snapshot/watermark divergir do head atual do ledger.
   - `INV-003` (Separação de evidências): `derived_edges` e `possible_edges` são coleções disjuntas; o mesmo triplo `(source, relation, target)` jamais ocorre em ambas; `derived_edge` exige `rule_id`, `rule_version` e `evidence_event_ids`.
   - `INV-005` (`Default deny`): ausência de regra determinística aplicável gera `boundary` / `unresolved`, nunca relação derivada inferida.
   - `INV-006` (Preservação de incerteza): conflitos e candidatos permanecem explícitos até resolução verificada.
   - `INV-007` / `INV-009` / `INV-010` (Snapshot canônico e reprodutibilidade): normalização UTF-8 NFC, ordenação canônica determinística, exclusão de paths absolutos do host e timestamps voláteis do hash lógico.
   - `INV-011` / `INV-015` (Limites explícitos): orçamento de análise excedido falha com `LIMIT_EXCEEDED` sem truncagem silenciosa; orçamento de apresentação (`context`/`pack`) reporta IDs omitidos e razões.

### 2.2 Decisão de Localização Física e Linguagem do Núcleo Memory-TCG (D-01, D-02)
- **Linguagem do núcleo:** **Node.js ESM puro** (zero dependências externas de npm, usando apenas módulos built-in `node:crypto`, `node:fs`, `node:path`), já requerido pelo instalador do produto (`Node.js 18+`).
- **Isolamento arquitetural:**
  - `src/memory/core/` (`canonical.js`, `graph.js`, `ringing.js`, `resonance.js`, `renormalize.js`): **núcleo puro e extraível**. Não conhece `.conversation-esaa`, `.roadmap`, PowerShell nem hooks; opera exclusivamente sobre `memory-tcg.facts.v1` e emite `memory-tcg.graph.v1` e `conversation-esaa.memory.proposal.v1`.
  - `src/memory/adapter/` (`snapshot.js`, `cli.js`): adaptador que lê `<workspace>/.conversation-esaa/activity.jsonl` de forma somente-leitura, extrai fatos normalizados, persiste gerações/propostas em `<workspace>/.conversation-esaa/memory/` com permissões privadas (`0700`/`0600` em POSIX) e expõe ponte JSON para o PowerShell.
  - `.conversation-esaa/bin/conv-memory.ps1` + dispatch em `.conversation-esaa/bin/conversation-esaa.ps1`: interface CLI pública compatível com o ecossistema PowerShell existente.

### 2.3 Respostas às 6 Questões de Pré-Auditoria do `conv-sync.ps1` e Instalador (`docs/02_BASELINE_REPOSITORIO.md`)
1. **Eventos existentes em `conv-sync.ps1`:**
   - `conversation_turn` e `pre_compact_sync`: campos `event_id`, `ts`, `event`, `actor`, `agent_id`, `source`, `source_session_id`, `source_path`, `source_index`, `workspace_root`, `summary`, `text` (+ opcionalmente `topic_id`/`topic_ids`).
   - `decision.recorded`: campos `event_id`, `ts`, `event`, `actor`, `agent_id`, `workspace_root`, `decision`, `rationale`, `related_turns` (array de `event_id` passado via `-SourceEvent`/`--source`), `summary`, `text`.
   - `task.created`, `task.updated`, `task.closed`: campos `event_id`, `ts`, `event`, `actor`, `agent_id`, `workspace_root`, `task_id` (`CONV-xxx`), `title`, `status`, `next_step`, `evidence`, `summary`, `text`.
   - `topic.created`, `topic.updated`, `topic.closed`, `topic.event.linked`: campos `event_id`, `ts`, `event`, `actor`, `agent_id`, `workspace_root`, `topic_id` (`TOP-xxx`), `title`, `summary`, `status`, `event_ids`.
2. **Resolução de decisão efetiva/superada hoje:**
   - `Project-DecisionsMarkdown` lista todas as `decision.recorded` e `Invoke-Project` seleciona as últimas 5 (`Select-Object -Last 5`). Não há ainda semântica de supersessão explícita no `conv-sync.ps1`. O Memory-TCG introduzirá suporte a `supersedes_decision_id` / `supersedes` explícito quando presente no evento, marcando a decisão anterior como `historical` apenas com vínculo explícito (nunca por recência).
3. **Funcionamento atual do `pack` (`Invoke-Pack`):**
   - Lê projeções (`handoff.md`, `decisions.md`, `tasks.json`, `topics.json`) e filtra os últimos 8 eventos de `Get-WorkspaceEvents`, aplicando degradação determinística por orçamento (`-BudgetTokens`, default 4000, ou `-BudgetChars`). Com `memory off` (default), `Invoke-Pack` permanece byte-a-byte idêntico.
4. **Funcionamento atual do `verify` (`Invoke-Verify`):**
   - Valida integridade de `activity.jsonl` (JSON por linha, `event_id` único, `workspace_root` igual ao workspace esperado, campos obrigatórios por tipo de evento), consistência de `tasks.json`, `topics.json` vs `Project-TopicsFromEvents` e `Test-CursorAdapter`. A verificação de memória (`memory verify`) será isolada e fail-safe para não quebrar workspaces com `memory off`.
5. **Instalador e ciclo de vida (`src/installer/install.js`, `src/installer/lifecycle/index.js`, `conv-bootstrap.ps1`):**
   - `PRIVATE_PATHS` em `src/installer/lifecycle/index.js` preserva artefatos privados no `uninstall`; `.conversation-esaa/memory/` e `.gitignore` devem preservar dados privados do usuário em `update`/`repair`/`uninstall`.
6. **Segurança de paths, symlinks e permissões (`conv-rag.ps1`):**
   - `conv-rag.ps1` implementa `Set-PrivatePermissions` (`chmod 700` para diretórios, `600` para arquivos no Linux/macOS) e verifica `ReparsePoint` para recusar travessia de symlinks. O diretório `.conversation-esaa/memory/` seguirá exatamente a mesma proteção contra symlinks e permissões `0700`/`0600`.

---

## 3. Governança ESAA-Core, IDs e Boundaries (AC[2])

- **Verificação do event store `.roadmap/`:** `esaa --root . verify` retorna `verify_status: "ok"`.
- **Colisão de IDs:** nenhuma colisão com as 71 tarefas anteriores; as 14 tarefas `CONV-MTCG-SPEC-001` a `CONV-MTCG-SPEC-014` foram cadastradas via CLI oficial (`esaa task create`) com `task_type=memory` e `required_review_mode` correspondente.
- **Boundary grants configurados no cadastro (`T-2070`):**
  - `CONV-MTCG-IMPL-008`: `.conversation-esaa/bin/**`, `.gitignore`
  - `CONV-MTCG-IMPL-010`: `.conversation-esaa/bin/**`
  - `CONV-MTCG-IMPL-011`: `.conversation-esaa/bin/**`
  - `CONV-MTCG-SPEC-014`: `README.md`, `PRIVACY.md`, `RELEASE.md`, `AGENTS.md`, `.claude/CLAUDE.md`
- **Decisões arquiteturais D-01 a D-10:** revisadas e aceitas integralmente para formalização no ADR-013 (`CONV-MTCG-SPEC-002`).
