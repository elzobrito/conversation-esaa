# ADR-013 — Memory-TCG como infraestrutura de consolidação RRR

**Status:** APROVADO (Fase MVP-0 a MVP-2) — **Data:** 2026-11-07 — **Task:** `CONV-MTCG-SPEC-002`

## 1. Contexto e Tese

O Conversation ESAA captura turnos visíveis via hooks/watchers em `activity.jsonl` (append-only), projeta tópicos (`topics.json`/`topics.md`), decisões (`decisions.md`), tarefas conversacionais (`tasks.json`) e handoff (`handoff.md`/`state.md`), além de oferecer RAG opcional (`adr-010`).

Quando o histórico cresce e decisões evoluem ao longo de sessões e múltiplos agentes (Grok, Codex, Claude Code, Antigravity, Cursor), a recuperação puramente cronológica ou por similaridade textual não resolve:
1. distinção entre evidência verificada e interpretação/eco de agente;
2. distinção entre decisão vigente e alternativa avaliada/superada;
3. separação explícita entre relações derivadas por regra determinística (`derived_edges`) e associações/conflitos candidatos (`possible_edges`);
4. preservação de incertezas (`boundaries` / `unresolved`) sem falso consenso.

O artigo *Do agents need to sleep?* (Haber & Tononi, 2026) propõe a hipótese teórica de que sistemas sob aprendizado contínuo e capacidade finita se beneficiam de manutenção offline inspirada em **RRR** (*Ringing*, *Resonance*, *Renormalization*). Como o artigo não contém algoritmos executáveis nem provas empíricas em arquiteturas digitais, adotamos o paradigma RRR como **mecanismo offline determinístico, opcional e falsificável por benchmark**, combinado aos invariantes formais do projeto **TCG** (*Traceability-Guided Change Governance*).

## 2. Decisões Arquiteturais (D-01 a D-10)

- **D-01 (Domínio separado):** Denominar o mecanismo **Memory-TCG** (*Memory Traceability and Consolidation Graph*). Não acoplar ao repositório Python `elzobrito/tcg` (focado em análise estática de código/rotas).
- **D-02 (Núcleo puro e extraível):** Implementar o núcleo em Node.js ESM puro (`src/memory/core/`) sem dependência de paths `.conversation-esaa`, `.roadmap`, PowerShell ou hooks. O adaptador (`src/memory/adapter/` + `.conversation-esaa/bin/conv-memory.ps1`) traduz `activity.jsonl` para o contrato `memory-tcg.facts.v1`.
- **D-03 (Numeração):** Formalizado como **ADR-013**, sucedendo ADR-010 (RAG), ADR-011 (Installer) e ADR-012 (Cursor Adapter).
- **D-04 (Fonte única da verdade):** `activity.jsonl` permanece append-only e única fonte canônica. `memory/active.json` é projeção derivada e integralmente reconstruível via replay.
- **D-05 (Separação de certeza — invariantes TCG):**
  - `derived_edges` exigem `rule_id`, `rule_version` e `evidence_event_ids` verificados;
  - `possible_edges` representam candidatos de duplicação, relação ou contradição e jamais são promovidas automaticamente por score ou repetição (eco);
  - `derived_edges` e `possible_edges` nunca compartilham o mesmo triplo `(source, relation, target)`;
  - ausência de regra determinística produz `boundary` / `unresolved` (*default deny*).
- **D-06 (Determinismo e Snapshot):** O ciclo RRR opera sobre snapshot somente-leitura com `source_snapshot_id` (`sha256`), `watermark_event_id`, `normalizer_version`, `policy_digest` e `seed` inteira. Mesma entrada + mesma seed + mesma política produzem saída canônica idêntica.
- **D-07 (Modo default `off` e `shadow` sem efeitos colaterais):** O modo padrão do produto é `off`. O comando `memory sleep --mode shadow` grava apenas em `.conversation-esaa/memory/shadow/` e `.conversation-esaa/memory/generations/`, sem alterar `activity.jsonl`, `handoff.md`, `state.md`, `decisions.md`, `tasks.json` ou `topics.json`.
- **D-08 (Promoção explícita, Stale-Check e Rollback):**
  - `memory accept <proposal_id>` revalida o watermark do snapshot contra o head atual do workspace; se houver qualquer evento novo relevante no ledger, falha fechado com `STALE_PROPOSAL`;
  - quando válido, grava evento canônico `memory.consolidation.accepted` contendo metadados, digests e payload consolidado suficiente para reconstrução determinística no `project`/`verify`;
  - `memory rollback <generation_id>` emite evento canônico `memory.consolidation.rolled_back` restaurando a geração ativa anterior sem deletar histórico.
- **D-09 (Invariante Zero-Token):** `sync`, `project`, `verify`, `context`, `search`, `pack` e todo o ciclo determinístico `memory` operam com **zero chamadas de LLM e zero rede**. Eventos `memory.*` são excluídos da extração de evidências conversacionais e do corpus RAG para evitar ciclos de auto-reforço.
- **D-10 (Avaliação empírica):** Comparar braços A (baseline v1.3.1), B (instructionist local `ADD/UPDATE/DELETE/NOOP`), C (selectionist Memory-TCG RRR) e D (ablações) sobre fixtures sintéticas com ground truth congelado e múltiplas seeds.

## 3. Representação do Grafo e Ciclo RRR

### 3.1 Nós e Arestas
- **Nós (`kind`):** `episode`, `decision`, `topic`, `task`, `assertion`, `constraint`, `source`.
- **Status epistêmico (`epistemic_status`):** `verified_explicit`, `derived`, `candidate`, `unresolved`.
- **Status de vigência (`validity_status`):** `active`, `superseded`, `historical`, `unknown`.
- **Arestas derivadas (`derived_edges`):** `topic_contains_event`, `decision_supported_by_event`, `task_related_to_topic`, `explicit_supersedes`, `duplicate_exact_content`.
- **Arestas possíveis (`possible_edges`):** `possibly_related`, `possibly_duplicate`, `possibly_contradicts`, `possibly_supersedes`.

### 3.2 Fases RRR
1. **Ringing (`src/memory/core/ringing.js`):** Amostragem estratificada determinística por `(topic_id, time_bucket)` controlada por `seed` PRNG reproduzível e `budget` (`all` ou inteiro positivo). Se o grafo exceder limites operacionais duros (`max_nodes` / `max_edges`), falha explicitamente com `LIMIT_EXCEEDED` sem truncagem silenciosa.
2. **Resonance (`src/memory/core/resonance.js`):** Avalia vizinhanças amostradas, consolida suporte independente (deduplicando ecos de agentes sobre o mesmo turno/resumo), identifica duplicatas exatas por `content_digest` e registra contradições ou supersessões sem vínculo formal como `possible_edges` + `unresolved` / `boundaries`.
3. **Renormalization (`src/memory/core/renormalize.js`):** Gera proposta (`conversation-esaa.memory.proposal.v1`) restrita às ações:
   - `retain` (decisões vigentes explícitas e episódios de suporte);
   - `group_exact_duplicates` (agrupamento preservando todos os `evidence_event_ids`);
   - `deprioritize_in_active_view` (redução de saliência na visão ativa para turnos redundantes/ecos);
   - `mark_historical_explicit` (somente para decisões com `explicit_supersedes`);
   - `flag_conflict` (pares contraditórios sem resolução autoritativa).
   Nenhuma ação de deleção física (`delete`), sobrescrita (`overwrite`) ou inferência de verdade (`assert_true`) é permitida.

## 4. Contratos Canônicos Associados

- `docs/contracts/memory-tcg-facts.v1.schema.json`
- `docs/contracts/memory-tcg-graph.v1.schema.json`
- `docs/contracts/memory-proposal.v1.schema.json`

## 5. Status de Implementação e Evidências Empíricas

Todas as fases previstas (`MVP-0` a `MVP-2`, tarefas `CONV-MTCG-SPEC-001` a `CONV-MTCG-SPEC-014`) foram implementadas e verificadas:

- **Fase 0–1 (`Shadow` e Determinismo):** Validada em [`docs/qa/CONV-MTCG-SHADOW-QA.md`](../qa/CONV-MTCG-SHADOW-QA.md) (`tests/memory/*.test.js` e `tests/test-memory-shadow.ps1`), confirmando zero chamadas de rede/LLM, reprodutibilidade byte-a-byte sob a mesma seed e mutação zero das projeções ativas em modo `shadow`.
- **Fase 2 (Promoção Explícita, Replay, Rollback e Read Path):** Validada em [`docs/qa/CONV-MTCG-E2E-QA.md`](../qa/CONV-MTCG-E2E-QA.md) (`tests/test-memory-accept-replay.ps1`, `tests/test-memory-read-path.ps1` e `tests/installer/memory/memory.test.js`), cobrindo `STALE_PROPOSAL`, `WRONG_WORKSPACE`, `INTEGRITY_FAILURE`, reconstrução determinística de `memory/active.json` a partir de `activity.jsonl` e fallback seguro em `pack`/`context`.
- **Fase 3 (Avaliação exploratória):** O [benchmark original](../qa/CONV-MTCG-BENCHMARK.md) é um registro histórico de fixtures e métricas, não uma demonstração geral de superioridade. A [revisão v1.3.1](../../documentacao-tecnica/DC-consolidacao-memoria-agentes-v1.3.1.md) compara também uma baseline B′ sensível à autoridade e explicita limitações: B′ empatou com RRR completo em revocação de decisões nas nove combinações sintéticas; o comparador D1 corta fatos antes da construção do grafo e não isola o ringing do produto. O F1 de conflitos e a revocação variam com a fixture e o orçamento de saída. A avaliação não foi reproduzida de forma independente. Os resultados do estudo referem-se à política RRR v1.
