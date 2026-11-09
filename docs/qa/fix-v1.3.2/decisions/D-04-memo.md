# D-04 — Teto de 4 itens/secção e 200 caracteres no `context`

**Status:** decisão humana. Sem Passo C.

## Fatos medidos (JS-06)

Quando `retainedDecisions + unresolvedConflicts > 20` **e** `--budget-chars <= 5000`, `cmdContext` aplica `maxPerSection=4` e corta linhas em 200 chars.

Sintético 30 decisões + 12 conflitos:

| canal | displayed decisões | displayed conflitos | omitted | chars | linhas cortadas |
|---|---:|---:|---:|---:|---:|
| `memory context` 4000 | 4 | 4 | 34 | 2232 | 8 |
| pack/context 3200 | 4 | 4 | 34 | 2232 | 8 |
| budget 20000 | 30 | 12 | 0 | 8835 | 0 |

O orçamento de caracteres **não** é o que corta: 2232 < 4000. O cap 4 corta primeiro. Subir o budget acima de 5000 desliga o cap.

## Opções

| | Opção | Efeito |
|---|---|---|
| Manter | comportamento atual, documentar |
| Parametrizar `--max-per-section` (default 4) | operador/pack escolhem; testes a 4000 e 20000 |
| Remover | `context` cresce com a vista ativa; ART-07/CN mudam de figura |

## Recomendação

**Parametrizar** com default 4 e corte 200, documentados. Não remover sem reavaliar ART-07 (o CN já não reproduz a saída Markdown).

Item bloqueado: JS-06.
