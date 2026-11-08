# Relatório de Benchmark Comparativo — Memory-TCG / RRR (`CONV-MTCG-QA-013`)

**Data:** 2026-11-07  
**Task ESAA:** `CONV-MTCG-QA-013`  
**Modo de Revisão:** `functional`  
**Runner:** `node --test tests/memory/benchmark.js`

---

## 1. Desenho Experimental e Hipótese Falsificável

De acordo com o `ADR-013` (D-10) e com a análise crítica do artigo *Do agents need to sleep?* (Haber & Tononi, 2026), o mecanismo **Memory-TCG + RRR** é avaliado como hipótese de engenharia falsificável sobre fixtures sintéticas com ground truth congelado (`tests/memory/fixtures/README.md`), comparando quatro braços sob orçamento idêntico e cinco seeds determinísticas (`[11, 29, 42, 73, 101]`):

- **Braço A (`Baseline v1.3.1`):** Projeção cronológica legada (`decisions.md` últimas 5 decisões + últimos 8 eventos conversacionais), sem distinção entre decisão vigente e superada e sem detecção de conflitos.
- **Braço B (`Instructionist ADD/UPDATE/DELETE`):** Consolidador local instructionist que sobrescreve o slot da chave (`conflict_key`) pelo evento mais recente (`UPDATE`/`DELETE`), perdendo histórico e permitindo que um eco tardio de agente sobrescreva uma decisão explícita anterior.
- **Braço C (`Selectionist Memory-TCG + RRR`):** Ciclo completo **Ringing** (amostragem estratificada por `(topic_id, time_bucket)`), **Resonance** (consolidação de suporte independente e separação `derived_edges` vs `possible_edges` + `boundaries`) e **Renormalization** (`retain`, `mark_historical_explicit`, `group_exact_duplicates`, `deprioritize_in_active_view`, `flag_conflict`).
- **Braço D (`Ablations`):**
  - **D1 (`FIFO without Ringing`):** Truncagem FIFO simples no lugar da amostragem estratificada do Ringing.
  - **D2 (`Without Resonance`):** Executa Ringing + Renormalization sem a fase de Resonance.

---

## 2. Métricas Avaliadas

1. **CDA (*Current Decision Accuracy*, maior é melhor `[0..1]`):** Fração das decisões vigentes do ground truth que permanecem ativas na visão consolidada **sem** coabitar como vigentes com decisões obsoletas superadas ou ecos contraditórios.
2. **raw_active_recall (`[0..1]`):** Fração bruta das decisões vigentes presentes na visão ativa (mesmo quando contaminada por decisões antigas).
3. **HCC (*Historical Context Contamination*, menor é melhor `[0..1]`):** Fração de decisões explicitamente superadas ou ecos obsoletos de agentes que permanecem erroneamente expostos como verdade vigente.
4. **Provenance Precision & Recall (`[0..1]`):** Precisão e revocação dos `evidence_event_ids` preservados nas decisões ativas.
5. **Conflict F1 (`[0..1]`):** F1-score na identificação explícita de pares contraditórios sem decisão resolutiva (`unresolved_conflict`) sem eleger vencedor silencioso.
6. **Custo Computacional (`duration_ms`):** Tempo de parede do ciclo determinístico em CPU local (zero tokens / zero chamadas de LLM).

---

## 3. Resultados Empíricos

### 3.1 Cenário Canônico (`canonical-e001-e011`, 11 fatos, 3 tópicos)

| Braço Experimental | CDA ↑ | Raw Recall ↑ | HCC ↓ | Prov. Precision ↑ | Prov. Recall ↑ | Conflict F1 ↑ | Latência (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|
| **A (`Baseline v1.3.1`)** | `0.0000` | `1.0000` | `1.0000` | `1.0000` | `1.0000` | `0.0000` | `19.595` |
| **B (`Instructionist ADD/UPDATE/DELETE`)** | `0.0000` | `0.5000` | `0.5000` | `0.5000` | `0.5000` | `0.0000` | `0.065` |
| **C (`Memory-TCG RRR budget=all`)** | **`1.0000`** | **`1.0000`** | **`0.0000`** | **`1.0000`** | **`1.0000`** | **`1.0000`** | `7.735` |
| **D2 (`Ablation: without Resonance`)** | `1.0000` | `1.0000` | `0.0000` | `1.0000` | `1.0000` | `0.0000` | `3.194` |

### 3.2 Cenário Escalado Multi-Tópico (`scaled-multi-topic-50`, 50 fatos, 5 tópicos)

| Braço Experimental | CDA ↑ | Raw Recall ↑ | HCC ↓ | Prov. Precision ↑ | Prov. Recall ↑ | Conflict F1 ↑ | Latência (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|
| **A (`Baseline v1.3.1`)** | `0.0000` | `0.6000` | `0.4000` | `0.6000` | `0.6000` | `0.0000` | `0.099` |
| **B (`Instructionist ADD/UPDATE/DELETE`)** | `0.0000` | `0.0000` | `0.5000` | `0.0000` | `0.0000` | `0.0000` | `0.334` |
| **C (`Memory-TCG RRR budget=all`)** | **`1.0000`** | **`1.0000`** | **`0.0000`** | **`1.0000`** | **`1.0000`** | **`1.0000`** | `8.110` |
| **D1 (`Ablation: FIFO without Ringing, budget=28`)** | `0.0000` | `0.6000` | `0.1000` | `0.6000` | `0.6000` | `0.6667` | `7.125` |
| **D2 (`Ablation: without Resonance, budget=28`)** | `1.0000` | `1.0000` | `0.0000` | `1.0000` | `1.0000` | `0.0000` | `2.882` |

### 3.3 Estabilidade Multi-Seed do Braço C sob Orçamento Restrito (`budget=28` em 50 fatos)

| Seed | CDA ↑ | Raw Recall ↑ | HCC ↓ | Prov. Precision ↑ | Prov. Recall ↑ | Conflict F1 ↑ | Latência (ms) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| `11` | `1.0000` | `1.0000` | `0.0000` | `1.0000` | `1.0000` | `0.0000` | `6.412` |
| `29` | `1.0000` | `1.0000` | `0.0000` | `1.0000` | `1.0000` | `0.0000` | `5.655` |
| `42` | `1.0000` | `1.0000` | `0.0000` | `1.0000` | `1.0000` | `0.0000` | `6.600` |
| `73` | `1.0000` | `1.0000` | `0.0000` | `1.0000` | `1.0000` | `0.0000` | `8.446` |
| `101` | `1.0000` | `1.0000` | `0.0000` | `1.0000` | `1.0000` | `0.0000` | `8.024` |

---

## 4. Análise Crítica: Melhorias Comprovadas, Trade-offs e Limitações

1. **Melhorias comprovadas do Braço C (`Memory-TCG + RRR`):**
   - **Eliminação de contaminação por decisões superadas e ecos (`HCC = 0.0000`, `CDA = 1.0000`):** Enquanto o Braço A mantém decisões antigas e atuais misturadas na janela das últimas 5 decisões (`HCC = 1.0` no canônico e `0.4` no escalado) e o Braço B permite que um turno/eco posterior (`E007`) sobrescreva uma decisão explícita (`decision:E006`), o Braço C preserva `decision:E006` como `retain` (`[ACTIVE]`) e classifica `decision:E002` como `mark_historical_explicit` (`[HISTORICAL / SUPERSEDED]`).
   - **Papel demonstrado do Ringing (`C` vs `D1`):** Sob orçamento restrito (`budget = 28`), a truncagem FIFO sem Ringing (`D1`) perde as decisões dos tópicos `TOP-004` e `TOP-005` (`Raw Recall = 0.6000`), enquanto a amostragem estratificada por `(topic_id, time_bucket)` + retenção prioritária de decisões explícitas no Braço C mantém `CDA = 1.0000` e `Provenance Recall = 1.0000` nas 5 seeds.
   - **Papel demonstrado da Resonance (`C` vs `D2`):** Sem a fase de Resonance (`D2`), a acurácia de decisões explícitas (`CDA = 1.0`) é mantida pelo grafo base, mas a detecção de conflitos abertos entre episódios (`E008` vs `E009`) cai para `Conflict F1 = 0.0000`.
2. **Trade-off e Regressão Documentada sob Sub-Amostragem Severa (`budget = 28` vs `budget = all`):**
   - No cenário de 50 eventos, quando o orçamento de amostragem do Ringing é reduzido para `budget = 28` (em vez de `budget = all`), `CDA` e `HCC` permanecem perfeitos (`1.0` e `0.0`), porém `Conflict F1` cai de `1.0000` (`budget = all`) para `0.0000` (`budget = 28`).
   - **Causa técnica:** Como a detecção de conflito entre episódios sem decisão (`T*-CONF-1` vs `T*-CONF-2`) é quadrática dentro da amostra selecionada pelo Ringing, ambos os episódios do par contraditório precisam ser amostrados simultaneamente no mesmo ciclo para que a aresta `possibly_contradicts` seja formada.
   - **Recomendação operacional:** Para workspaces até `25.000` nós, o padrão recomendado para `memory sleep` é `--budget all` (custo de ~`8ms` para 50 fatos, zero tokens), reservando `--budget <N>` apenas para inspeções rápidas onde a prioridade é a preservação de decisões explícitas e cobertura inter-tópicos.
