# Relatório final — Conversation ESAA v1.3.2 (rodada interrompida na Fase 0)

## 1. Resumo

A Fase 0 encontrou **1 teste vermelho herdado** (`handoff_includes_recent_events`: 111 passed, 1 failed em `conv-test.ps1` e na bateria `-SkipLab -SkipEsaa`). A condição de parada §6.1 / R12 aplica-se. **Nenhum Passo V do catálogo foi executado. Nenhuma correção foi escrita. Nenhum ID do plano recebeu veredito.** Gate G1 não se aplica ainda: não há `01-verification-report.md`.

## 2. Tabela ID → veredito → ação

Nenhum ID PS/JS/DOC/ART foi verificado. A única ação desta rodada foi registrar a linha de base e parar.

| ID | Veredito | Ação | Vermelho/verde | Patch |
|---|---|---|---|---|
| — | — | parada §6.1 | `handoff_includes_recent_events` já vermelho no baseline | nenhum |

## 3. Itens NÃO CONFIRMADOS

Não há. A Fase 1 não começou.

## 4. Decisões pendentes (D-01…D-05)

Não preparadas (Fase 1 não começou). Continuam bloqueadas conforme o plano.

## 5. Mudanças de comportamento

Nenhuma. Texto proposto para `RELEASE.md`: nenhum. `RELEASE.md` não foi editado.

## 6. Matriz de plataformas

| Item | Linux + pwsh 7 | Windows + pwsh 7 |
|---|---|---|
| Suítes completas | ✘ (`conv-test` 1 fail) | não executado |
| PS-02 (caminho `\\`) | não executado | não executado |
| JS-01 (espaço/acento/`C:\`) | não executado | não executado |
| PS-03 (lock) | não executado | não executado |

## 7. R4 — hash do ledger real

| Momento | SHA-256 |
|---|---|
| Fase 0 início | `2bd12689fc24b8acb4b9911735283a5bfabc23588b80cff0e97209218e2a58a2` |
| Fase 0 fim | `2bd12689fc24b8acb4b9911735283a5bfabc23588b80cff0e97209218e2a58a2` |

Idênticos.

## 8. Arquivos tocados nesta rodada

Somente evidência da Fase 0 (ainda a commitar via ESAA `file_updates`, sem git commit de produto):

- `docs/qa/fix-v1.3.2/00-baseline.md`
- `docs/qa/fix-v1.3.2/03-final-report.md`
- `docs/qa/fix-v1.3.2/_helpers.ps1`

## 9. O que NÃO foi feito e por quê

- Fase 1 (Passos V de PS-01…18, JS-01…06, DOC-01/02, ART-01…10): bloqueada por §6.1.
- Criação das 36 tarefas `FIX132-<ID>`: adiada até o humano decidir se o vermelho herdado libera exceção ou deve ser isolado primeiro.
- Fase 2, patches, Gate G1, artigo v1.3.1, bump 1.3.2, commit, push, npm: fora de escopo após a parada.

## 10. Riscos residuais

- A árvore já estava suja (`conv-sync.ps1`, `cli.js`, artigo RRR v1.3, eval). O vermelho pode ser efeito desses diffs, não de `baea68d` limpo. Isolar isso exige autorização humana (não faz parte desta rodada após §6.1).
- `node --test tests/memory` (diretório) não é invocação válida neste Node; a suíte real (`*.test.js`) está verde.

## Pedido ao humano

Para retomar:

1. **Exceção a §6.1** — autorizar a Fase 1 (somente leitura) mesmo com o teste vermelho herdado; ou
2. **Isolar o vermelho** — nova tarefa só para `handoff_includes_recent_events` (reproduzir em HEAD limpo vs árvore suja) **antes** de qualquer Passo V do catálogo; ou
3. **Aceitar o vermelho como conhecido** e registrar skip no baseline, com autorização explícita.

Sem uma dessas três, a rodada permanece parada. Sem commit, sem push, sem bump.
