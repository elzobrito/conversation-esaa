# Fixtures Sintéticas e Ground Truth — Benchmark Memory-TCG / RRR (`CONV-MTCG-QA-013`)

Este diretório documenta os cenários sintéticos determinísticos utilizados por `tests/memory/benchmark.js` para avaliar falsificavelmente o mecanismo **Memory-TCG + RRR** frente aos braços experimentais definidos no `ADR-013` (D-10).

## 1. Regras de Privacidade e Reprodutibilidade
- **Zero dados reais do operador:** Todos os eventos são 100% sintéticos, gerados em memória com `workspace_id` canônico (`sha256`).
- **Ground Truth congelado (`v1.0.0`):** Cada cenário define explicitamente:
  - `active_decision_ids`: decisões vigentes esperadas como ativas;
  - `superseded_decision_ids`: decisões históricas explicitamente superadas que **não** devem contaminar a visão ativa como vigentes;
  - `echo_turn_ids`: turnos onde um agente repete resumo antigo sem autoridade de decisão;
  - `duplicate_groups`: conjuntos de turnos com `content_digest` idêntico cujo agrupamento deve preservar 100% dos `evidence_event_ids`;
  - `unresolved_conflict_pairs`: pares de afirmações contraditórias sem decisão resolutiva que devem ser reportados como `unresolved` (sem vencedor silencioso).

## 2. Cenários Versionados

1. **`canonical-e001-e011` (11 eventos, 3 tópicos):**
   - `E001`: Criação do tópico `TOP-001` (Banco de Dados).
   - `E002`: Decisão explícita inicial (`SQLite para MVP`).
   - `E003`, `E004`: Turnos duplicados exatos (`Configuração de pool de conexões = 10`).
   - `E005`: Turno de suporte técnico sobre escalabilidade de escrita.
   - `E006`: Decisão explícita superadora (`PostgreSQL 16 em produção`, `supersedes: E002`).
   - `E007`: Eco tardio de agente repetindo o resumo antigo (`Usar SQLite no MVP`) sem evento `decision.recorded`.
   - `E008`, `E009`: Conflito não resolvido no tópico `TOP-002` (`O banco oficial é Redis` vs `O banco oficial é Memcached`).
   - `E010`, `E011`: Decisão ativa independente no tópico `TOP-003` (`Adotar TLS 1.3 estrito`).

2. **`scaled-multi-topic-50` (50 eventos, 5 tópicos):**
   - 5 tópicos (`TOP-001` a `TOP-005`), contendo 5 decisões explicitamente superadas, 5 decisões vigentes ativas, 10 ecos de agentes, 10 duplicatas exatas, 4 pares de conflitos não resolvidos e 16 turnos episódicos de ruído sob orçamento restrito (`budgetChars = 900`, `ringingBudget = 28`).

## 3. Como Executar

```bash
node --test tests/memory/benchmark.js
# ou para imprimir a tabela JSON/Markdown completa:
node tests/memory/benchmark.js --report
```
