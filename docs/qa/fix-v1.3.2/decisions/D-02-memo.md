# D-02 — JS-02 / JS-03 devem bump de `policy_version`?

**Status:** decisão humana. Sem Passo C. Medido em árvore suja, HEAD `baea68d`.

## Problema

Duas correções no motor mudam digest/ordem:

1. **JS-02** — `scoreConflictRelevance`: `activeTopicIds.has(node.topic_id) || node.topic_id` é verdadeiro para qualquer `topic_id` não vazio. Par activo vs frio: scores iguais. Nos fixtures 48/480 o motor **não** retém nós `kind=topic`, então `activeTopicIds` é vazio e **0 posições trocam** hoje; um fixture com tópicos mistos reordenaria.
2. **JS-03** — `resonance.js` lê `a.session_id`. Nós do grafo **não têm** esse campo (`graph.js` expõe `topic_id`, `time_bucket`, `timestamp`, …). A expressão avalia `false`. Injectar `session_id` igual cria `possibly_contradicts` que a produção não emite.

## Opções

| | Opção | Efeito | Custo |
|---|---|---|---|
| **Bump** `rrr-policy.v2` | golden files novos; resultados publicados ficam da v1 | médio (goldens + nota no artigo) |
| **Correção silenciosa** | mesmos IDs de política; reprodução dos artefatos v1.3 quebra | baixo agora, alto depois |

## Recomendação

**Bump** (`rrr-policy.v2` + goldens novos + nota no artigo: números públicos são da política v1), como o plano. Para JS-03, a opção de implementação (derivar sessão das evidências vs remover a condição morta vs renomear campo) só depois deste bump.

Itens bloqueados: JS-02, JS-03.
