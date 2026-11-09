# D-03 — Como conter o crescimento do ledger por `accept`?

**Status:** decisão humana. Sem Passo C. Limiar do cartão **ultrapassado**.

## Fatos medidos (JS-04, workspace TEMP)

| Fatos | bytes da linha `memory.consolidation.accepted` |
|---:|---:|
| 48 | 473 241 (462 KiB) |
| 480 | **3 517 869 (3,35 MiB)** |
| 1920 (stored 179 nós) | 308 336 |

Limiar: 256 KiB a 480 fatos. Já 48 fatos excede.

~90–98% do payload é o **grafo**. `cmdPrepareAccept` embebe `graph` quando `nodes.length <= 500` — o caso 480 é o pior. Cinco accepts a 48 fatos → +2,38 MiB mesmo sem fatos novos (`memory.*` fora do snapshot).

`verify` / `reconstruct` neste N não mostraram superlinearidade clara (dezenas a ~150 ms). O custo operacional é o tamanho da linha e o `ConvertTo-Json` no PowerShell (3–6 s por accept).

## Opções

| | Opção | Replay | Tamanho |
|---|---|---|---|
| Manter | replay integral no jsonl | 3 MiB/accept a 480 |
| Digest + path | relê `generations/<hex>/graph.json` e `shadow/<hex>.json` | linha curta; replay depende dos ficheiros |
| Snapshot periódico | evento de compactação | médio |

## Recomendação

**Digest + path** (os ficheiros já existem). Teste de regressão: linha accept a 480 fatos ≤ 256 KiB (ou tecto documentado). Não serializar `graph`/`proposal`/`active_view` completos no jsonl.

Implementado em FIX132-JS04 (G1 E-02): `cmdPrepareAccept` e `Invoke-MemoryAccept` gravam `artifact_encoding=digest_path.v1` com `proposal_path` / `graph_path`. `reconstruct`/`verify` relêem os ficheiros e aceitam payload embutido legado. Sem os ficheiros, falha fechado.
