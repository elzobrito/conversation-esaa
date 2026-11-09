# FIX132 Fase 0 — Linha de base

Data: 2026-11-08 (execução 2026-11-09T00:08Z).
Repositório: `/home/elzobrito/desenvolvimento/conversation-esaa`.
Rodada: Conversation ESAA v1.3.1 → v1.3.2 (verificar → corrigir → provar).

## Git

| Campo | Valor |
|---|---|
| HEAD | `baea68d92ec2ab2885e938ea521d50878ffcd766` |
| Branch | `main` |
| origin/main | `baea68d92ec2ab2885e938ea521d50878ffcd766` (HEAD é ancestral) |
| Assunto | `feat(memory): deduplicate episodes in resonance conflicts, add decide --supersedes/--superseded-by, and add regression tests (CONV-MTCG-IMPL-024)` |
| `git status --short` | 63 caminhos (árvore suja **antes** desta rodada) |

Arquivos rastreados modificados no runtime (já sujos ao iniciar W0; esta rodada **não** os alterou):

- `.conversation-esaa/bin/conv-memory.ps1`
- `.conversation-esaa/bin/conv-sync.ps1` (+39/−14 vs HEAD)
- `.conversation-esaa/bin/conversation-esaa.ps1`
- `src/memory/adapter/cli.js`
- `src/memory/adapter/snapshot.js`
- `README.md`, `package.json`, `src/installer/install.js`, testes de memória/instalador

Há também artefatos não rastreados da avaliação RRR v1.2/v1.3 (`docs/qa/CONV-RRR-*`, `documentacao-tecnica/`, `tests/memory/v12-*`, `v13-*`) e eventos ESAA em `.roadmap/`.

## Ambiente

| Peça | Valor |
|---|---|
| SO | Linux `elzobrito-Nitro-AN515-51` 7.0.0-43-generic x86_64 (Ubuntu) |
| PowerShell | 7.5.2 |
| Node | v22.23.1 |
| Windows | não executado |

## R4 — ledger real do laboratório

Arquivo: `/home/elzobrito/.conversation-esaa/activity.jsonl`

| Momento | SHA-256 | Linhas |
|---|---|---|
| Início W0 | `2bd12689fc24b8acb4b9911735283a5bfabc23588b80cff0e97209218e2a58a2` | 17394 |
| Fim W0 | `2bd12689fc24b8acb4b9911735283a5bfabc23588b80cff0e97209218e2a58a2` | 17394 |

Os hashes coincidem. Nenhum teste desta fase escreveu no ledger real.

## Backup

`/tmp/fix132-backup-pre.tar.gz` — SHA-256 `e2ca639e947ff24da08e46a36af10464eee7fccfd8aeb18280b008f0d6c01fc6` (141 KiB). Conteúdo: `.conversation-esaa/bin`, `src`, `tests`, `package.json`.

## Suítes (contagem)

| Suíte | Comando | Pass | Fail | Exit |
|---|---|---:|---:|---:|
| Instalador | `npm test` | 27 | 0 | 0 |
| Memória Node (arquivos `*.test.js`) | `node --test tests/memory/*.test.js` | 15 | 0 | 0 |
| Instalador memória | `node --test tests/installer/memory/memory.test.js` | 2 | 0 | 0 |
| Integração PowerShell | `pwsh -NoProfile -File .conversation-esaa/bin/conv-test.ps1` | 111 | **1** | **1** |
| Bateria | `pwsh -NoProfile -File .conversation-esaa/bin/conv-test-battery.ps1 -SkipLab -SkipEsaa` | 111 | **1** | **1** |

`node --test tests/memory` (diretório, sem glob) falha com `MODULE_NOT_FOUND` porque o diretório mistura `.js`/`.py`. A suíte real de memória é `tests/memory/*.test.js` (15 verdes). Isso não é falha de produto; é limitação da invocação sugerida no plano neste Node.

## Vermelho herdado

**Teste:** `handoff_includes_recent_events` em `conv-test.ps1` (por volta da linha 457).

**Condição esperada:** `handoff.md` contém `## Eventos recentes` **e** uma linha que casa `[.*] assistant \(grok\).*Resumo do assunto de teste`.

**Observado:** FAIL (a suíte não imprime o detalhe quando `Assert-True` é chamado sem `$Detail` neste assert). Os testes imediatamente anteriores (`handoff_objective_prioritizes_open_task`, `handoff_includes_active_decision`, `handoff_includes_active_topic`, `handoff_includes_open_task`) passaram, portanto o `handoff.md` existe e contém objetivo, decisão, tópico e tarefa; a falha é o recorte de “Eventos recentes” / ator `assistant (grok)`.

**Origem:** falha **antes** de qualquer alteração desta rodada, sobre a árvore de trabalho já suja (em especial `conv-sync.ps1` e `cli.js` não commitados). Não foi isolada contra HEAD limpo nesta fase.

## Parada (supersedida pela Emenda E-01)

§6.1 / R12 parou a Fase 0. Em 08/11/2026 o humano autorizou a **Emenda E-01**: aceitar o vermelho herdado e abrir a Fase 1 somente leitura.

## Emenda E-01 (humano 08/11/2026)

Exceção a §6.1.

1. Baseline aceito com 1 falha conhecida: `handoff_includes_recent_events` (111 pass / 1 fail na árvore suja). Registrado como **BASELINE-RED-01**.
2. Fase 1 (somente leitura) **autorizada**. Fase 2 continua **bloqueada** até o G1.
3. Cada VER registra `git rev-parse --short HEAD`, SHA-256 de `conv-sync.ps1` / `cli.js` / artigo, e `"medido em: árvore suja"` ou `"medido em: HEAD limpo"`. A árvore suja é a versão de referência.
4. Tarefa paralela `FIX132-BASELINE-RED-01` (somente leitura): worktree em HEAD, sem stash.
5. PS-01, PS-09 e PS-18 só emitem veredito depois de RED-01.
6. **Não corrigir** BASELINE-RED-01 nesta fase. A correção entra no G1 como item próprio, vermelho → verde.

## BASELINE-RED-01

| Campo | Valor |
|---|---|
| Teste | `handoff_includes_recent_events` |
| Árvore suja | 111 pass / 1 fail (`conv-test.ps1` e bateria `-SkipLab -SkipEsaa`) |
| HEAD limpo (`/tmp/fix132-head-clean`, `baea68d`, 0 caminhos sujos) | **112 pass / 0 fail** (76 s) |
| Causa | hunk não commitado em `Invoke-TopicCommand`: `agent_id = 'grok'` (HEAD) → `agent_id = $CuratorAgent` default `'unknown'` (árvore suja). `topics create` no teste não passa `-Agent`. Handoff recente: `assistant (unknown) — Resumo do assunto de teste`. |
| Mesma causa que PS-01? | **Não** (`source_index` Cursor / `Get-WorkspaceEvents`) |
| Mesma causa que PS-09? | **Não** (`pack` duplica bloco de memória) |
| Correção nesta fase | **proibida** (E-01 item 6) |

Hashes da referência (árvore suja):

| Artefato | SHA-256 |
|---|---|
| HEAD short | `baea68d` |
| `.conversation-esaa/bin/conv-sync.ps1` | `b5034666aa349f62625ce7ab1f43f8257dfb989947f8adad6855a31df25e6caf` |
| `src/memory/adapter/cli.js` | `31f89e0e7a2b4f14ae12e5ad797eff5af746ba213411ff82bdff27e08eac00de` |
| `documentacao-tecnica/DC-consolidacao-memoria-agentes-v1.3.md` | `3bd6cc0007fdcf50f66f73e21e89718bb86ce6545e194a93dce087e1f032e53a` |
| Ledger real | `2bd12689fc24b8acb4b9911735283a5bfabc23588b80cff0e97209218e2a58a2` (inalterado) |

Relatório do isolamento: `docs/qa/fix-v1.3.2/evidence/BASELINE-RED-01/report.md`.
Relatório da Fase 1: `docs/qa/fix-v1.3.2/01-verification-report.md`.
