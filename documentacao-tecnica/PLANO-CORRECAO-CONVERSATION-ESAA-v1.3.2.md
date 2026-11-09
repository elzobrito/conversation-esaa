---
titulo: "Plano de correção — Conversation ESAA v1.3.1 → v1.3.2 (verificar → corrigir → provar)"
tipo: "Instrução operacional para agente executor"
versao: "1.0"
data: "08/11/2026"
destinatario: "Agente executor (Codex / Grok Bot / Agy) sob governança ESAA"
escopo: "Runtime PowerShell, motor Memory-TCG (Node), documentação e artigo RRR v1.3"
regra_central: "NENHUMA correção é escrita antes de o problema ser CONFIRMADO por verificação reproduzível."
---

# Plano de correção — Conversation ESAA v1.3.1 → v1.3.2

## 0. Leia antes de qualquer ação

Este documento é a **única fonte de instruções** desta rodada. Ele existe porque uma revisão de código (feita sobre cópias dos arquivos, sem executar nada) levantou suspeitas e problemas prováveis. **Revisão estática não é prova.** Por isso o plano tem a ordem fixa:

```
Fase 0  Linha de base (nada pode estar vermelho antes de começar)
Fase 1  VERIFICAR  — somente leitura/medição; cada problema recebe um veredito
Gate G1 Humano lê o relatório de verificação e libera/barra correções
Fase 2  CORRIGIR   — somente problemas CONFIRMADOS e liberados
Fase 3  Regressão total + fechamento
```

### 0.1 Regras invioláveis

| # | Regra |
|---|---|
| R1 | **Verificar primeiro.** Para cada problema, execute o *Passo V* do cartão e registre o veredito. Só avance para o *Passo C* (correção) se o veredito for `CONFIRMADO` **e** o Gate G1 estiver liberado. |
| R2 | **Veredito `NÃO CONFIRMADO` encerra o item.** Registre a evidência, não altere código, não "melhore por precaução". |
| R3 | **Veredito `INCONCLUSIVO`** (ex.: problema só reproduz no Windows e você está no Linux): tente **uma** sonda alternativa (teste unitário com entrada sintética). Se continuar inconclusivo, **pare naquele item** e peça decisão humana. Não corrija às cegas. |
| R4 | **Nunca toque no ledger real.** Todo teste usa workspace temporário criado por `New-TestWorkspace` (Apêndice A). Antes e depois da rodada, calcule SHA-256 do `.conversation-esaa/activity.jsonl` real do laboratório; os dois hashes **devem ser idênticos**. |
| R5 | **Dados sintéticos apenas.** Não copie texto de conversas reais para fixtures, relatórios ou logs. |
| R6 | **Sem commit, sem push, sem publicação, sem bump de versão.** O repositório de produto permanece com a árvore de trabalho modificada. Entregue um patch por tarefa (`git diff -- <arquivos> > docs/qa/fix-v1.3.2/patches/<ID>.patch`). Bump para 1.3.2 só com autorização humana explícita. |
| R7 | **Cada correção prova a si mesma:** o teste de regressão precisa **falhar antes** da correção (vermelho) e **passar depois** (verde). Registre as duas saídas. Teste que nunca ficou vermelho não vale. |
| R8 | **Diff mínimo.** Não refatore, não renomeie, não reformate arquivos inteiros. Um problema = um conjunto pequeno de alterações. |
| R9 | **Não altere a política RRR.** Qualquer mudança que modifique saída/digest de proposta, grafo ou visão ativa exige a Decisão D-02 (ver §5). Sem D-02 aprovada, não altere. |
| R10 | **Não invente eventos ESAA.** Use o mecanismo do projeto (claim → complete → review → verify). Não edite `activity.jsonl`, `.roadmap/` nem read models à mão. |
| R11 | **Compatibilidade:** PowerShell 7+, Node ≥ 18, Windows e Linux. Arquivos `.ps1` com `#requires -Version 7.0`, `Set-StrictMode -Version Latest`, UTF-8 **sem BOM**. Nenhuma dependência nova. |
| R12 | **Pare e reporte** nas condições da §6 (condições de parada). |

### 0.2 O que **não** é objetivo desta rodada

- Reescrever o motor RRR ou mudar o algoritmo de ringing/resonance/renormalization.
- Mudar o esquema do ledger (exceto onde uma Decisão humana aprovar).
- Implementar ADR-012 para Cloud Agent sem a Decisão D-01.
- Reexecutar o benchmark inteiro (apenas as conferências indicadas nos cartões `ART-*`).
- Publicar o artigo ou o pacote npm.

---

## 1. Convenções

### 1.1 Vereditos permitidos (únicos)

| Veredito | Significado | Consequência |
|---|---|---|
| `CONFIRMADO` | O comportamento defeituoso foi **reproduzido** (ou provado por teste unitário equivalente). | Item elegível para o Passo C após G1. |
| `NÃO CONFIRMADO` | Foi tentado reproduzir e o comportamento correto foi observado. | Item encerrado sem alteração. |
| `INCONCLUSIVO` | Não foi possível reproduzir nem refutar (limitação de plataforma/dado). | Uma sonda extra; depois, decisão humana. |
| `DECISÃO` | O item não é bug objetivo; exige escolha humana (§5). | Agente só **prepara o memorando**, não implementa. |
| `MEDIÇÃO` | O item é uma suspeita de desempenho/tamanho; só vira correção se o limiar do cartão for ultrapassado. | Agente mede e reporta números. |

### 1.2 Severidade (para ordenar, não para pular verificação)

`ALTA` = perda/duplicação de dado, contaminação entre projetos ou quebra de integridade. `MÉDIA` = falha silenciosa ou robustez. `BAIXA` = higiene/documentação.

### 1.3 Artefatos desta rodada (todos em `docs/qa/fix-v1.3.2/`)

```
docs/qa/fix-v1.3.2/
├── 00-baseline.md                  # Fase 0
├── 01-verification-report.md       # Fase 1 (um bloco por ID; template no Apêndice B)
├── evidence/<ID>/                  # saídas brutas dos comandos (sem texto de conversa)
├── decisions/D-0x-memo.md          # memorandos de decisão (§5)
├── patches/<ID>.patch              # Fase 2
├── 02-fix-log.md                   # Fase 2: vermelho→verde por ID
└── 03-final-report.md              # Fase 3
```

### 1.4 Onde ficam as coisas (confirme com `git ls-files` antes de editar; **não presuma**)

| Peça | Local provável |
|---|---|
| Scripts do runtime | `.conversation-esaa/bin/*.ps1` (`conv-sync`, `conversation-esaa`, `conv-bootstrap`, `conv-memory`, `conv-rag`, `codex-watch`, `cursor-hook`, `antigravity-hook-sync`, `conv-test`, `conv-test-battery`) |
| Motor Memory-TCG | `src/memory/**` (CLI em `src/memory/adapter/cli.js`) |
| Instalador | `src/installer/**`, `src/cli.js`, `package.json` |
| Testes do instalador | `tests/installer/**` |
| ADRs / contratos | `docs/adr/**`, `docs/contracts/**`, `docs/plans/**` |
| Artigo | `documentacao-tecnica/DC-consolidacao-memoria-agentes-v1.3.md` |
| Harness do benchmark | **desconhecido** — localizar em `ART-01` (`git grep -il "FAIR-OUTPUT\|ablation\|fifo"` e no repositório `conversation-esaa-rrr-artifacts`) |

Se um caminho acima não existir, **não crie por conta própria**: localize com `git grep`/`git ls-files`, registre o caminho real no relatório e siga.

---

## 2. Catálogo (visão geral)

Cada ID tem um **cartão** na §4 com: *Evidência*, **Passo V (verificar)**, *Critério de existência*, **Passo C (corrigir)**, *Testes*, *Aceite*, *Riscos*.

| ID | Problema (hipótese a verificar) | Sev. | Arquivos principais | Tipo |
|---|---|---|---|---|
| **PS-01** | Cursor ao vivo grava `source_index` fixo (0/1); o read model deduplica por `fonte\|sessão\|índice\|ator` e esconde turnos | ALTA | `conv-sync.ps1`, `cursor-hook.ps1` | Bug |
| **PS-02** | Codex/Windows: regex com caminho não casa com `\\` do JSON; fallback pega rollout de **qualquer** projeto | ALTA | `conv-sync.ps1`, `codex-watch.ps1` | Bug |
| **PS-03** | `--SkipIfLocked` com lock órfão pula para sempre (só checa existência do arquivo) | MÉDIA | `conv-sync.ps1` | Bug |
| **PS-04** | `decide/task/topic/memory-accept/rollback` gravam no ledger **antes** de `project`+`verify`; falha de verify → exit≠0 com evento já gravado → retry duplica | ALTA | `conv-sync.ps1` | Bug |
| **PS-05** | Ledger preso ao caminho absoluto; ADR-012 (Cloud Agent) não implementado; `.cursor/hooks.json` ignorado pelo git | — | vários | **DECISÃO D-01** |
| **PS-06** | Texto do Cursor viaja como argumento de linha de comando (limite de tamanho; exposição em lista de processos) | MÉDIA | `cursor-hook.ps1`, `conv-sync.ps1`, `conversation-esaa.ps1` | Bug |
| **PS-07** | Custo por hook (reparse do ledger, `verify` com releitura por evento de task, `-contains` em array) | — | `conv-sync.ps1` | **MEDIÇÃO** |
| **PS-08** | `Repair-ActivityContract` reescreve o `activity.jsonl` inteiro (não atômico, sem backup) | MÉDIA | `conv-sync.ps1` | Bug |
| **PS-09** | `pack` duplica o bloco de memória (já no `handoff.md` + de novo em "Decisions") | BAIXA | `conv-sync.ps1` | Bug |
| **PS-10** | `enable-hooks` sobrescreve `.claude/settings.json`; `conv-bootstrap` **pula** arquivo existente e não instala hooks | MÉDIA | `conversation-esaa.ps1`, `conv-bootstrap.ps1` | Bug |
| **PS-11** | `GROK_WORKSPACE_ROOT` tem precedência sobre o local do script (4 scripts) | ALTA | `conv-sync`, `conversation-esaa`, `conv-memory`, `conv-rag` | Bug |
| **PS-12** | `conv-bootstrap` não copia `memory/`; `Copy-Item -Force` sobrescreve `.ps1`; fallback hardcoded `/home/elzobrito/...` | MÉDIA | `conv-bootstrap`, `conv-memory`, `conv-sync` | Bug |
| **PS-13** | `verify` passa **sem** verificar memória quando o motor Node não é encontrado | MÉDIA | `conv-sync.ps1` | Bug |
| **PS-14** | `event_id` de evento curado pode colidir (ts em segundos, sem nonce) → `verify` acusa duplicata | BAIXA | `conv-sync.ps1` | Bug |
| **PS-15** | `context --before` no 1º evento retorna 2 itens errados (range `0..-1`) | BAIXA | `conv-sync.ps1` | Bug |
| **PS-16** | `Quote-CommandPart` / `Quote-HookPart` com `-replace '"','"'` é no-op | BAIXA | `conv-bootstrap`, `conversation-esaa` | Bug |
| **PS-17** | `.gitignore` gerado não cobre `codex-watch.log` e `antigravity-hook.log` | BAIXA | `conv-bootstrap.ps1`, instalador | Bug |
| **PS-18** | Cola PowerShell da memória (sonhar/accept/rollback/reconstruct/fallback) sem teste; `npm test` só roda o instalador | MÉDIA | `conv-test.ps1`, `package.json` | Lacuna de teste |
| **JS-01** | Guard `import.meta.url === \`file://${process.argv[1]}\`` falha no Windows e com espaço/acento | ALTA | `src/memory/adapter/cli.js` | Bug |
| **JS-02** | `scoreConflictRelevance`: `activeTopicIds.has(...) \|\| node.topic_id` é sempre verdadeiro | MÉDIA | `src/memory/adapter/cli.js` | Bug (muda ordem → **D-02**) |
| **JS-03** | Resonance usa `a.session_id`, campo que não existe nos nós do grafo | MÉDIA | `src/memory/**/resonance*` | Bug (pode mudar saída → **D-02**) |
| **JS-04** | `memory.consolidation.accepted` embute proposta + visão ativa + grafo (≤500 nós) → ledger cresce rápido | — | `src/memory/**`, `conv-sync.ps1` | **MEDIÇÃO / D-03** |
| **JS-05** | `npm test` não executa os testes de memória | MÉDIA | `package.json` | Lacuna de teste |
| **JS-06** | `context` com >20 itens limita cada seção a 4 itens e corta linhas em 200 caracteres | — | `src/memory/adapter/cli.js` | **DECISÃO D-04** |
| **DOC-01** | ADR-013 §5 e README afirmam "Conflict F1 = 1.0" e superioridade sobre instrucionista (CDA 0,0) | MÉDIA | ADR-013, README | Doc |
| **DOC-02** | `actor` fixo em `assistant` nos eventos curados (inclusive accept feito por operador) | BAIXA | ADRs, artigo §3.3 | Doc / **D-05** |
| **ART-01** | D1 (FIFO) pode contornar a renormalização real (decisões ativas são sempre `retain`) → atribuição ao ringing pode ser efeito do harness | ALTA | harness | **Verificação** |
| **ART-02** | Afirmação "D1 ≤ 0,03 abaixo de C em 480 e 1.920 fatos" é falsa em 480 fatos/4.096 tokens (0,560 × 1,000) | ALTA | artigo | Texto |
| **ART-03** | Resumo/Abstract/Conclusão omitem o custo do CQ em decisões (0,44→0,34; 0,445→0,355) e dizem "sem perder decisões" | MÉDIA | artigo | Texto |
| **ART-04** | "D2 empata com C em todas as escalas/orçamentos" sem tabela de suporte | MÉDIA | artigo | Texto |
| **ART-05** | "Os primeiros da fila são os melhores" não vale em 48 fatos/512 tokens | MÉDIA | artigo | Texto |
| **ART-06** | "antes do corte" × "antes da filtragem" usados como sinônimos | BAIXA | artigo | Texto |
| **ART-07** | CN não reproduz a saída real do produto (limite de 4 itens/seção, 4.000 caracteres, caminhos `pack`/`context`/bloco 3.200) | ALTA | artigo/harness | Texto + medição |
| **ART-08** | Escalas 48/480/1.920 cruzam limiares de política (50/200/250/500 nós) e isso não é reportado | MÉDIA | artigo | Texto + medição |
| **ART-09** | IDs (`workspace_id` = hash do caminho) mudam entre caminhos; reprodutibilidade de IDs não declarada | BAIXA | artigo §4.3 | Texto + verificação |
| **ART-10** | Fechamento: gerar o artigo v1.3.1 aplicando ART-01…09 e DOC-02 (sem sobrescrever a v1.3) | MÉDIA | artigo | Texto |

---

## 3. Governança de execução (ESAA)

### 3.1 Tarefas

Crie **uma tarefa ESAA por ID** usando o mecanismo do projeto (`conversation-esaa task create` ou o fluxo `.roadmap` vigente — **siga o que o repositório já usa**, não invente). Nome sugerido: `FIX132-<ID>` (ex.: `FIX132-PS-01`). Cada tarefa tem **duas fases** registradas no título/próximo passo: `[V]` verificação e `[C]` correção.

Ciclo obrigatório por tarefa: `claim → (V) evidência → complete(V) → [G1] → (C) patch+testes → complete(C) → review → verify`.

### 3.2 Pistas (lanes) — dono do arquivo, para evitar conflito de edição

Dois agentes **nunca** editam o mesmo arquivo ao mesmo tempo. A Fase 1 (somente leitura) pode rodar toda em paralelo; a Fase 2 respeita as pistas.

| Pista | Dono exclusivo de | IDs (ordem dentro da pista) |
|---|---|---|
| **A — `conv-sync.ps1`** | `.conversation-esaa/bin/conv-sync.ps1` | PS-14 → PS-03 → PS-01 → PS-04 → PS-02 → PS-15 → PS-13 → PS-08 → PS-09 → PS-11(parte conv-sync) → PS-12(fallback em conv-sync) |
| **B — demais `.ps1`** | `conversation-esaa.ps1`, `conv-bootstrap.ps1`, `conv-memory.ps1`, `conv-rag.ps1`, `codex-watch.ps1`, `cursor-hook.ps1` | PS-10 → PS-16 → PS-11(partes B) → PS-12(bootstrap/memory-dir, conv-memory) → PS-17 → PS-02(parte codex-watch) → PS-06(parte hook/CLI, **depois** de PS-01 da pista A) |
| **C — Node** | `src/memory/**`, `src/installer/**`, `package.json` | JS-01 → JS-05 → JS-03 → JS-02 → (JS-04, JS-06 só com decisão) |
| **D — Docs/artigo** | ADRs, README, PRIVACY, artigo | DOC-01 → DOC-02 → ART-* |
| **E — Testes** | `conv-test.ps1`, `tests/**` | PS-18 (consolida e completa os testes escritos nas outras pistas) |

**Dependências cruzadas explícitas**

- `PS-06` depende de `PS-01` (ambos mexem em `Invoke-SyncCursor`).
- `PS-18` depende de PS-04, PS-09, PS-13 (precisa dos comportamentos finais).
- `JS-02`/`JS-03` dependem de **D-02**. `ART-*` que citam números dependem de `ART-01` e, se JS-02/03 forem aplicados, de reexecução do benchmark (fora do escopo; ver ART-07).
- `PS-05`, `JS-04`, `JS-06`, `DOC-02(schema)` ficam **bloqueados** até o humano decidir.

### 3.3 Ondas

| Onda | Conteúdo | Paralelismo |
|---|---|---|
| **W0** | Fase 0 — baseline | 1 agente |
| **W1** | Fase 1 — todos os Passos V (PS, JS, ART) | **todos em paralelo** (só leitura) |
| **G1** | Revisão humana do `01-verification-report.md` | humano |
| **W2a** | Correções pista A, B, C em paralelo (somente `CONFIRMADO`) | 3 agentes |
| **W2b** | Pista D (docs/artigo) e PS-18 (testes) | 2 agentes, depois de W2a |
| **W3** | Regressão total, matriz de plataformas, relatório final | 1 agente |

---

## 4. Fases e cartões

### 4.0 Fase 0 — Linha de base (W0)

Objetivo: provar que o repositório está verde **antes** de qualquer mudança, para que nenhuma falha futura seja confundida com herança.

1. `git status --short` e `git rev-parse HEAD` → gravar em `00-baseline.md`.
2. Versões: `pwsh --version`, `node --version`, sistema operacional.
3. **Hash do ledger real do laboratório** (R4): `Get-FileHash .conversation-esaa/activity.jsonl -Algorithm SHA256` → gravar. Repita no fim (Fase 3).
4. Backup fora do repositório: `Compress-Archive` de `.conversation-esaa/bin`, `src`, `tests`, `package.json` para `$env:TEMP/fix132-backup-pre.zip` (ou `tar` no Linux). Registrar o caminho.
5. Criar o diretório `docs/qa/fix-v1.3.2/` e o arquivo `_helpers.ps1` (Apêndice A).
6. Executar e registrar **contagem de passes/falhas** de cada suíte:
   - `npm test`
   - `pwsh -NoProfile -File .conversation-esaa/bin/conv-test.ps1`
   - testes de memória (localizar: `git ls-files tests | Select-String -Pattern memory`; executar com `node --test <diretório>`)
   - `pwsh -NoProfile -File .conversation-esaa/bin/conv-test-battery.ps1 -SkipLab -SkipEsaa`
7. **Qualquer vermelho → parar (§6.1).**
8. Criar as tarefas ESAA (§3.1).

### 4.1 Fase 1 — Como executar a verificação (W1)

- Execute o **Passo V** de **cada** cartão (PS-*, JS-*, ART-*). Itens `DECISÃO`/`MEDIÇÃO` também têm Passo V.
- Tudo em **somente leitura** em relação ao repositório: use workspaces temporários e cópias em `$env:TEMP`.
- Para cada ID, preencha o bloco do Apêndice B em `01-verification-report.md` e guarde a saída bruta em `evidence/<ID>/`.
- O relatório termina com uma **tabela-resumo** (ID, veredito, 1 linha de evidência, ação liberada).
- Terminada a W1, **pare** e sinalize o Gate G1. Não inicie a Fase 2 sem o aval humano registrado no próprio relatório (`G1: liberado por <nome> em <data>; itens barrados: ...`).

---

### 4.2 Cartões — runtime PowerShell

> Notação: `Sync`, `Cli`, `Invoke-CursorHook`, `New-TestWorkspace`, `Initialize-Ws`, `Read-Ledger`, `Count-Lines` são as funções do **Apêndice A**.

#### PS-01 — Cursor ao vivo: `source_index` fixo esconde turnos

**Evidência (revisão estática):** o hook `cursor-hook.ps1` chama `sync --agent cursor` com `-CursorRole/-CursorPrompt` e **sem** `-CursorSourceIndex`. Em `Invoke-SyncCursor`, o índice cai em `0` (usuário) ou `1` (assistente). O `event_id` inclui o texto, então o **ledger** recebe todos os turnos; porém `Get-WorkspaceEvents` deduplica por `source|source_session_id|source_index|actor` (sem texto), então `context`, `handoff`, `pack` e tópicos enxergam só o 1º turno de cada ator por conversa.

**Passo V — verificar**

```powershell
. docs/qa/fix-v1.3.2/_helpers.ps1
$ws = New-TestWorkspace; Initialize-Ws $ws 'cursor'
$sid = 'ver-ps01'
'A','B','C' | ForEach-Object { Invoke-CursorHook $ws 'beforeSubmitPrompt' @{ conversation_id=$sid; prompt="pergunta $_ distinta" } | Out-Null }
'A','B'     | ForEach-Object { Invoke-CursorHook $ws 'afterAgentResponse' @{ conversation_id=$sid; text="resposta $_ distinta" } | Out-Null }

$led = @(Read-Ledger $ws | Where-Object { $_.source -eq 'cursor' })
"LEDGER   user=$(@($led|Where-Object actor -eq 'user').Count) assistant=$(@($led|Where-Object actor -eq 'assistant').Count)"   # esperado 3 e 2
$led | Select-Object actor, source_index | Format-Table

$ctx = (Cli $ws 'context' @('-Json','-Last','50')).Out | ConvertFrom-Json
$vis = @($ctx | Where-Object { $_.source -eq 'cursor' })
"CONTEXT  user=$(@($vis|Where-Object actor -eq 'user').Count) assistant=$(@($vis|Where-Object actor -eq 'assistant').Count)"
```

Repita com **o mesmo prompt duas vezes** (`'ok'`, `'ok'`) e confira o ledger (mesmo `event_id`?) e o `context`.

**Critério de existência:** `CONFIRMADO` se o ledger tem 3 usuário + 2 assistente **e** o `context` mostra 1 + 1 (todos os `source_index` do ator iguais). `NÃO CONFIRMADO` se o `context` mostra 3 + 2.

**Passo C — corrigir (só se CONFIRMADO + G1)**

1. Em `Invoke-SyncCursor` (caminho ao vivo, quando `$CursorSourceIndex -lt 0`): calcular o índice como **1 + maior `source_index` já gravado no ledger bruto** para `source='cursor'` e `source_session_id=$sessionId` (usar `Read-ActivityEvents`, **não** a visão deduplicada). Contador **único por sessão** (compartilhado entre usuário e assistente). Valor inicial: `0`.
2. A execução já ocorre sob `Invoke-WithPipelineLock`; portanto o cálculo é livre de corrida. **Não** remover o lock nem calcular fora dele.
3. `-CursorSourceIndex` explícito continua valendo. O caminho por `-CursorTranscriptPath` **não muda** (usa o índice de linha do transcript).
4. **Não reescrever o ledger histórico.** Turnos antigos já colapsados continuam colapsados no read model; registrar isso no `02-fix-log.md`.

**Testes (em `conv-test.ps1`, padrão `Assert-True`)**
`cursor_live_turns_keep_distinct_source_index` · `cursor_live_identical_prompts_both_recorded` · `cursor_live_context_shows_all_turns` · `cursor_live_transcript_path_unchanged` (os testes `sync_cursor_*` existentes continuam verdes).

**Aceite:** N turnos distintos no ledger ⇒ N turnos em `context --Json`; dois prompts idênticos ⇒ 2 eventos distintos; nenhum teste existente quebra.
**Riscos:** mistura de hook ao vivo e `stop`+transcript na **mesma** sessão pode duplicar (o instalador não instala `stop`); documentar a limitação no ADR-012.

---

#### PS-02 — Codex: casamento de caminho no Windows e fallback global

**Evidência:** `Find-LatestCodexRollout` (em `conv-sync.ps1` **e** duplicada em `codex-watch.ps1`) faz `-match [regex]::Escape($Root)` nas primeiras 5/8 linhas do JSONL. No JSON, o caminho do Windows aparece com `\\`; o regex procura `\`. Sem casamento, a função devolve o rollout **mais recente de qualquer projeto** (`$fallback`). `Invoke-SyncCodex` não filtra por `cwd`.

**Passo V — verificar**

```powershell
# (a) prova estática, roda em qualquer SO
$root = 'C:\tmp\proj'
$head = '{"type":"session_meta","payload":{"id":"s1","cwd":"C:\\tmp\\proj"}}'
"casa? $($head -match [regex]::Escape($root))"      # False => parte estática CONFIRMADA

# (b) dinâmica (qualquer SO): dois rollouts sintéticos em um HOME falso
$fake = Join-Path ([IO.Path]::GetTempPath()) ('fakehome-'+[guid]::NewGuid().ToString('n'))
$d = Join-Path $fake '.codex/sessions/2026/11/08'; New-Item -ItemType Directory -Force $d | Out-Null
# rollout do projeto OUTRO (mais novo) e do projeto ALVO (mais antigo)
# >>> Antes de escrever os fixtures, inspecione UM rollout real (sem copiar conteúdo) e confirme os nomes dos campos (session_meta/payload.id/payload.cwd).
$ws = New-TestWorkspace; Initialize-Ws $ws 'codex'
$env:HOME = $fake; $env:USERPROFILE = $fake
$out = Sync $ws 'sync-codex' @()                    # SEM -CodexSessionPath
# CONFIRMADO se eventos do rollout "OUTRO" aparecerem no ledger deste workspace
Read-Ledger $ws | Where-Object { $_.source -eq 'codex' } | Select-Object source_path -Unique
```

**Critério de existência:** `CONFIRMADO` se (a) retorna `False` **e/ou** (b) importa evento do rollout de outro `cwd`. No Linux, a parte (a) basta como prova da falha de casamento; (b) prova a contaminação. Se só (a) reproduzir e (b) não, o veredito é `CONFIRMADO` para o casamento e o fallback global fica como **risco documentado** (ainda será corrigido: R-fallback abaixo).

**Passo C — corrigir**

1. Extrair função **pura** `Test-CodexHeadMatchesRoot([string]$HeadText, [string]$Root)`: tenta `ConvertFrom-Json` linha a linha e comparar `payload.cwd` normalizado (`[IO.Path]::GetFullPath`, remover separador final, comparação **case-insensitive no Windows**); se não houver `cwd`, desfazer o escape (`$HeadText -replace '\\\\','\'`, como a função do Claude já faz) e comparar o texto.
2. Usar a função em `conv-sync.ps1` **e** `codex-watch.ps1` (pista B altera o `codex-watch`; mesma lógica, comentário apontando a função irmã).
3. **Remover o fallback global.** Sem rollout do workspace e sem `-CodexSessionPath`: `throw 'Codex rollout for this workspace not found. Pass -CodexSessionPath.'`.
4. Em `Invoke-SyncCodex`, quando o caminho veio por `-CodexSessionPath` explícito, **não** exigir `cwd` (uso manual preservado).

**Testes:** `codex_head_match_windows_escaped_path` (função pura, roda em qualquer SO) · `codex_head_match_posix_path` · `codex_discovery_ignores_other_project_rollout` · `codex_discovery_without_match_fails_closed`.
**Aceite:** nenhum evento de outro projeto entra; `-CodexSessionPath` explícito segue funcionando; `sync_codex_*` existentes verdes.
**Riscos:** quem dependia do fallback agora recebe erro; mensagem precisa dizer como resolver.

---

#### PS-03 — `--SkipIfLocked` com lock órfão

**Evidência:** `Acquire-PipelineLock` retorna `$false` imediatamente se `-SkipIfLocked` **e** o arquivo de lock existe (`Test-Path`), sem tentar abri-lo exclusivamente. Os hooks de Grok/Claude/Cursor passam `--SkipIfLocked`. Um hook morto por timeout pode deixar o arquivo.

**Passo V — verificar**

```powershell
$ws = New-TestWorkspace; Initialize-Ws $ws 'grok'
$lock = Join-Path $ws '.conversation-esaa/run/conversation-esaa.lock'
New-Item -ItemType Directory -Force (Split-Path $lock) | Out-Null
'{"pid":99999999,"command":"orfao","started_at":"2026-01-01T00:00:00-03:00","workspace_root":"'+($ws -replace '\\','\\\\')+'"}' | Set-Content $lock -Encoding utf8
$before = (Get-Item (Join-Path $ws '.conversation-esaa/state.md')).LastWriteTimeUtc
Start-Sleep 1
$r = Sync $ws 'project' @('-SkipIfLocked')
"saida: $($r.Out)"                                   # bug se: 'pipeline lock busy; skip project'
$after = (Get-Item (Join-Path $ws '.conversation-esaa/state.md')).LastWriteTimeUtc
"state.md regenerado? $($after -gt $before)"        # bug se: False
```

**Critério de existência:** `CONFIRMADO` se imprimiu `pipeline lock busy` e `state.md` **não** foi regenerado com um lock órfão (sem processo segurando o stream). `NÃO CONFIRMADO` se reclamou o lock e regenerou.

**Passo C — corrigir**

1. Em `Acquire-PipelineLock`, **remover** o retorno antecipado baseado em `Test-Path`.
2. Fluxo com `-SkipIfLocked`: tentar `CreateNew`; se falhar, tentar `Open` exclusivo; **se o `Open` exclusivo funcionar** ⇒ lock órfão ⇒ reclamar (como já é feito sem a flag) e seguir; **se falhar com IOException** ⇒ lock vivo ⇒ `return $false` **imediatamente** (sem esperar o timeout).
3. Sem `-SkipIfLocked`, o comportamento (espera até `-LockTimeoutSeconds`) não muda.

**Testes:** `skip_if_locked_reclaims_orphan_lock` · `skip_if_locked_returns_busy_when_live_lock_held` (os testes `live_lock_blocks_until_timeout` e `skip_if_locked_exits_zero_when_lock_held` existentes continuam verdes).
**Aceite:** lock órfão não bloqueia hooks; lock vivo continua protegendo; exit 0 em ambos.
**Riscos:** semântica de `FileShare.None` entre processos em Linux é advisory; testar nos dois SOs.

---

#### PS-04 — Gravar no ledger antes de `project`+`verify`

**Evidência:** `decide`, `task`, `topic`, `memory-accept`, `memory-rollback` fazem `Append` e só depois `Invoke-Project` + `Invoke-Verify` dentro do lock. Se `verify` falhar (ex.: hook do Cursor ausente), o comando sai com erro **com o evento já gravado**; o operador repete e duplica a decisão/tarefa (e, no accept, possivelmente a promoção).

**Passo V — verificar**

```powershell
$ws = New-TestWorkspace; Initialize-Ws $ws 'cursor'
# provocar falha de verify SEM tocar no ledger: remover o hook de captura (mesma técnica de conv-test.ps1)
$hp = Join-Path $ws '.cursor/hooks.json'
$h = Get-Content $hp -Raw | ConvertFrom-Json -AsHashtable; $h['hooks']['beforeSubmitPrompt'] = @()
($h | ConvertTo-Json -Depth 10) | Set-Content $hp -Encoding utf8
"verify direto: $((Sync $ws 'verify' @()).Exit)"     # esperado != 0
$n0 = Count-Lines $ws
$r1 = Cli $ws 'decide' @('decisao de teste','-Rationale','r','-Agent','verif')
$n1 = Count-Lines $ws
$r2 = Cli $ws 'decide' @('decisao de teste','-Rationale','r','-Agent','verif')
$n2 = Count-Lines $ws
"exit1=$($r1.Exit) exit2=$($r2.Exit) ledger: $n0 -> $n1 -> $n2"
```

**Critério de existência:** `CONFIRMADO` se `exit≠0` **e** o ledger cresceu em cada tentativa. Para `memory-accept`: só testar **depois** de PS-18 ter fixture de memória; até lá registre `INCONCLUSIVO (dependência)` para essa metade e **verifique por leitura** que `Invoke-MemoryAccept` precede `Invoke-Project/Verify` no mesmo bloco.

**Passo C — corrigir**

1. Capturar o `event_id` do `Append`. Envolver **somente** `Invoke-Project` e `Invoke-Verify` desses comandos em `try/catch`; no erro, guardar a mensagem em `$script:PostCommitError`.
2. Após liberar o lock, se `$script:PostCommitError`: imprimir `COMMITTED event_id=<id>; post-check failed: <mensagem>; do NOT retry this command. Repair: conversation-esaa project; conversation-esaa verify` e `exit 2` (semântica "drift acionável", alinhada ao instalador).
3. `memory-accept`: **antes** de gravar, procurar no ledger um `memory.consolidation.accepted` com o mesmo `proposal_id`; se existir, **não gravar**, devolver o JSON do resultado existente com `already_accepted: true` e `exit 0`.
4. Os comandos `sync-*` **não mudam** (já são idempotentes por `event_id`). O comando `verify` direto continua saindo ≠0 quando falha.

**Testes:** `decide_commit_survives_postcheck_failure` (exit 2, ledger +1, saída contém `COMMITTED`) · `task_create_postcheck_failure_reports_committed` · `memory_accept_idempotent_by_proposal_id` · `verify_command_still_fails_nonzero`.
**Aceite:** nenhuma falha pós-commit produz exit 1 ambíguo; repetir `accept` não cria 2º evento.
**Riscos:** scripts que tratavam qualquer exit≠0 como "não gravou" precisam ler `COMMITTED`; documentar no `installer-cli`/ADR.

---

#### PS-05 — Ledger preso ao caminho / ADR-012 / Cloud Agent  ·  **DECISÃO D-01**

**Evidência:** `verify` falha para evento cujo `workspace_root` difere do atual; `Get-WorkspaceEvents` descarta esses eventos; `workspace_id` (hash do caminho) entra no `proposal_id`. O bootstrap gera hooks do Cursor com `pwsh` absoluto + `-WorkspaceRoot` absoluto, e o `.gitignore` ignora `.cursor/hooks.json`, `activity.jsonl`, `handoff.md`, `state.md`. O ADR-012 promete que um Cloud Agent receba o pack.

**Passo V — verificar (somente isto; sem Passo C)**

```powershell
$a = New-TestWorkspace; Initialize-Ws $a 'cursor'
Invoke-CursorHook $a 'beforeSubmitPrompt' @{ conversation_id='c1'; prompt='turno sintetico' } | Out-Null
$b = $a + '-clone'; Copy-Item $a $b -Recurse
"verify no clone: $((Sync $b 'verify' @()).Out)"          # esperado: 'belongs to another workspace'
"eventos visiveis no clone: $(((Cli $b 'context' @('-Json','-Last','10')).Out | ConvertFrom-Json | Measure-Object).Count)"
# gitignore do workspace gerado
Push-Location $a; git init -q; foreach($f in '.conversation-esaa/activity.jsonl','.conversation-esaa/handoff.md','.conversation-esaa/state.md','.conversation-esaa/decisions.md','.conversation-esaa/tasks.json','.conversation-esaa/topics.json','.conversation-esaa/topics.md','.cursor/hooks.json','.conversation-esaa/memory/active.json'){ "{0,-45} ignorado={1}" -f $f, [bool](git check-ignore $f) }; Pop-Location
Get-Content (Join-Path $a '.cursor/hooks.json')           # procurar caminho absoluto do pwsh e do workspace
(Get-Content (Join-Path $a '.conversation-esaa/topics.json') | ConvertFrom-Json).workspace_root
```

**Entregável:** `decisions/D-01-memo.md` com os fatos medidos (clone quebra? quais read models vazam caminho/texto e não estão no `.gitignore`? hooks são portáveis?) e as opções A/B/C da §5, com custo e risco de cada uma. **Parar.** Nada de código.

---

#### PS-06 — Texto do Cursor passa por argumentos de linha de comando

**Evidência:** `cursor-hook.ps1` monta `-CursorPrompt <texto inteiro>` e invoca `conversation-esaa.ps1` → `conv-sync.ps1` (3 processos `pwsh`). Windows limita a linha de comando a ≈32 mil caracteres; Linux limita **um** argumento a ≈128 KiB. O hook é *fail-open*: falha só vira linha em `cursor-hook.log`. O texto fica visível na lista de processos.

**Passo V — verificar**

```powershell
$ws = New-TestWorkspace; Initialize-Ws $ws 'cursor'
$n0 = Count-Lines $ws
foreach ($len in 20000, 40000, 200000) {
  $txt = 'x' * $len
  Invoke-CursorHook $ws 'afterAgentResponse' @{ conversation_id="len$len"; text=$txt } | Out-Null
  "len=$len ledger+=$((Count-Lines $ws) - $n0)"; $n0 = Count-Lines $ws
}
Get-Content (Join-Path $ws '.conversation-esaa/cursor-hook.log') -Tail 10   # procurar fail_open
```

**Critério de existência:** `CONFIRMADO` se algum tamanho **não** grava no ledger e o log mostra `fail_open`. `INCONCLUSIVO` se tudo gravar (ambiente com limite alto): então registre os limites do SO e rebaixe para risco documentado (exposição em `ps`), sem alterar código.

**Passo C — corrigir** *(depois de PS-01 mesclado — ambos mexem em `Invoke-SyncCursor`)*

1. Novo parâmetro `-CursorPromptFile <caminho>` em `conv-sync.ps1` e em `conversation-esaa.ps1`. Se presente, ler o arquivo (UTF-8) e usá-lo como `$CursorPrompt`.
2. No `cursor-hook.ps1`: gravar o texto em `.conversation-esaa/run/cursor-<guid>.txt` (permissão 0600 em POSIX via `chmod`), passar `-CursorPromptFile`, e **apagar o arquivo em `finally`**. `-CursorPrompt` continua aceito (compatibilidade).
3. O texto **não** pode mais aparecer em nenhum argumento de processo.

**Testes:** `cursor_hook_large_response_roundtrip` (200 000 caracteres gravados íntegros: comparar hash do `text` no ledger) · `cursor_hook_temp_file_removed` · `cursor_hook_args_do_not_contain_text` (inspecionar o vetor de argumentos construído) · `cursor_prompt_arg_still_supported`.
**Aceite:** 200 mil caracteres entram; nenhum `cursor-*.txt` sobra em `run/`; `.gitignore` já cobre `run/*.lock` — adicionar `run/cursor-*.txt` (ver PS-17).

---

#### PS-07 — Custo por hook  ·  **MEDIÇÃO**

**Evidência:** cada `sync` reparseia o `activity.jsonl` várias vezes; `Invoke-Verify` relê **o arquivo inteiro** para cada evento `task.updated/closed`; `Import-Message` usa `-contains` em array (O(n) por mensagem); `Get-WorkspaceEvents` chama `Resolve-Path` por evento. Timeouts dos hooks: 15–20 s.

**Passo V — medir (não corrigir ainda)**

Gerar ledgers sintéticos com `N ∈ {1 000, 5 000, 20 000}` eventos `conversation_turn` + 200 tarefas (`task.created` + `task.updated`) usando um gerador que escreve via `StreamWriter` (Apêndice A, `New-SyntheticLedger`). Para cada N, 3 execuções e **mediana/máximo** de: `project`, `verify`, `sync-cursor` (1 prompt), `pack`.

| N | project | verify | sync-cursor | pack |
|---:|---|---|---|---|
| 1 000 | | | | |
| 5 000 | | | | |
| 20 000 | | | | |

**Limiar para virar correção:** (a) `sync-cursor` com N=20 000 > **10 s** (metade do menor timeout), **ou** (b) `t(20 000)/t(5 000) > 8` em `verify` ou `project` (crescimento superlinear).
Se nenhum limiar for ultrapassado ⇒ veredito `NÃO CONFIRMADO` (o custo é aceitável) e o item **encerra**.

**Passo C (somente se limiar ultrapassado)** — uma otimização por vez, medindo depois de cada uma:
1. `Invoke-Verify`: montar um `HashSet` de `task_id` criados no **primeiro** passe e eliminar a releitura por evento.
2. `Load-SyncState`/`Import-Message`: converter `processed_event_ids` em `HashSet[string]` durante a execução (serializar como array ao salvar).
3. `Get-WorkspaceEvents`: memoizar `Resolve-Path` por valor distinto de `workspace_root`.

**Testes:** saída **idêntica** (hash de `state.md`, `handoff.md`, `tasks.json`, `topics.json` antes/depois, em ledger de 1 000 eventos) + a tabela de tempos depois.
**Aceite:** limiar (a)/(b) atendido; zero diferença de saída.

---

#### PS-08 — `Repair-ActivityContract` reescreve o ledger

**Evidência:** quando encontra evento sincronizado sem `agent_id`/`workspace_root`, a função lê **todas** as linhas, regrava o arquivo inteiro com `WriteAllText` (não atômico, sem backup) e carimba o `workspace_root` atual. Isso contradiz "append-only".

**Passo V — verificar**

```powershell
$ws = New-TestWorkspace; Initialize-Ws $ws 'codex'
$act = Join-Path $ws '.conversation-esaa/activity.jsonl'
# linha legada sintética: tem 'source' mas não tem 'agent_id' nem 'workspace_root'
'{"event_id":"legacy0001","ts":"2026-01-01T00:00:00-03:00","event":"conversation_turn","actor":"user","source":"codex","source_session_id":"s","source_index":0,"summary":"x","text":"x"}' | Add-Content $act -Encoding utf8
$h0 = (Get-FileHash $act).Hash
Sync $ws 'project' @() | Out-Null          # ou qualquer sync-*: dispara o reparo
$h1 = (Get-FileHash $act).Hash
"arquivo reescrito? $($h0 -ne $h1)"; Get-ChildItem (Split-Path $act) -Filter 'activity.jsonl*'   # há backup?
```

**Critério de existência:** `CONFIRMADO` se o hash mudou **e** não existe backup. (A existência da reescrita é o fato; se a equipe considera aceitável, o veredito continua `CONFIRMADO` e a decisão é só o *como* corrigir.)

**Passo C — corrigir**

1. Gravar em arquivo temporário **no mesmo diretório** (`activity.jsonl.tmp-<guid>`) e substituir com `Move-Item -Force` (atômico no mesmo volume).
2. Antes da substituição, criar `activity.jsonl.bak-<UTC yyyymmddThhmmssZ>` (manter só os 3 mais recentes).
3. Mensagem: `repair-activity: normalized N event(s); backup=<caminho>`.
4. Adicionar `activity.jsonl.bak-*` e `*.tmp-*` ao `.gitignore` gerado (PS-17).

**Testes:** `repair_activity_is_atomic_and_backed_up` (arquivo final é JSONL válido; backup tem o hash original; nenhum `.tmp-*` sobra) · `repair_activity_noop_when_clean` (hash inalterado, sem backup).
**Aceite:** zero estado intermediário observável; backup sempre presente após reparo.

---

#### PS-09 — `pack` duplica o bloco de memória

**Evidência:** `Invoke-Project` anexa o markdown da memória ativa ao `handoff.md`. `Invoke-Pack` usa o `handoff.md` inteiro como seção "Handoff" **e** recalcula a memória para preencher "Decisions (active)" ⇒ cada decisão/conflito aparece duas vezes, gastando orçamento.

**Passo V — verificar** *(depende de fixture de memória; use o gerador do Apêndice A/PS-18 com ≥ 5 decisões e `sonhar --accept`)*

```powershell
$pack = (Sync $ws 'pack' @('-BudgetTokens','4000')).Out
$ids = [regex]::Matches($pack, '\b(mem|dec|conf)[-_][A-Za-z0-9]+') | ForEach-Object Value | Group-Object | Where-Object Count -gt 1
$ids | Select-Object Name, Count          # CONFIRMADO se algum ID de memória aparece >= 2 vezes
```

(Ajuste o regex ao formato real de `memory_id`/`conflict_id` observado na saída; registre o formato em `evidence/PS-09/`.)

**Passo C — corrigir**

1. Em `Invoke-Project`, envolver o bloco de memória com marcadores `<!-- conv-esaa:memory:begin -->` / `<!-- conv-esaa:memory:end -->` em `state.md` e `handoff.md`.
2. Em `Invoke-Pack`, remover do `$handoffBody` o trecho entre os marcadores (`(?s)<!-- conv-esaa:memory:begin -->.*?<!-- conv-esaa:memory:end -->`). Handoffs antigos **sem** marcadores continuam funcionando (nada a remover).
3. Não alterar a estimativa de tokens (`⌈bytes UTF-8 / 4⌉`); apenas documentá-la no `installer-cli`/ADR.

**Testes:** `pack_does_not_duplicate_memory_ids` · `handoff_still_contains_memory_block` · `pack_old_handoff_without_markers_unchanged`.
**Aceite:** cada ID de memória aparece **uma** vez no pack; `handoff.md` mantém o bloco.

---

#### PS-10 — `enable-hooks`/`conv-bootstrap` e `settings.json` do Claude

**Evidência:** `conversation-esaa enable-hooks --agent claude` faz `WriteAllText` em `.claude/settings.json` sem mesclar (apaga permissões e outros hooks do usuário). `conv-bootstrap.ps1` faz o oposto: se o arquivo existe e não há `-Force`, **pula** e os hooks não são instalados. O ADR-011 exige "merged, never replaced".

**Passo V — verificar**

```powershell
# 0) descobrir qual caminho o instalador npm realmente usa
git grep -n "SkipAgentIntegrations\|enable-hooks\|settings.json" -- src/installer .conversation-esaa/bin
$ws = New-TestWorkspace; New-Item -ItemType Directory -Force "$ws/.claude" | Out-Null
'{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo meu-hook"}]}]}}' | Set-Content "$ws/.claude/settings.json" -Encoding utf8
# 1) enable-hooks
Initialize-Ws $ws 'claude'      # bootstrap: esperado (bug) 'skip (existe)'
(Get-Content "$ws/.claude/settings.json" -Raw) -match 'conversation-esaa'   # False => hooks NÃO instalados
Cli $ws 'enable-hooks' @('-Agent','claude') | Out-Null
$j = Get-Content "$ws/.claude/settings.json" -Raw
"permissions preservado? $($j -match 'Bash\(ls\)')  meu-hook preservado? $($j -match 'meu-hook')"   # False/False => sobrescreveu
```

**Critério de existência:** `CONFIRMADO` se (bootstrap pula e não instala) **ou** (enable-hooks apaga `permissions`/`meu-hook`). Registre **separadamente** cada metade. No relatório, diga também se o caminho npm (`install`) usa esses scripts ou os adaptadores JS (se só os JS, a gravidade cai para "fallback PowerShell").

**Passo C — corrigir**

1. Função `Merge-ClaudeHooks($Path,$Value)`: lê o JSON existente com `-AsHashtable` (JSON inválido ⇒ **recusar** com erro, como o bootstrap já faz); para cada evento (`UserPromptSubmit`, `Stop`, `PreCompact`) remove apenas as entradas cujo `command` casa `conversation-esaa\.ps1`; acrescenta a nossa; preserva todo o resto (`permissions`, outros hooks, chaves desconhecidas).
2. Usar a função em `enable-hooks` **e** no bootstrap (no bootstrap, no lugar do "pular").
3. Arquivo do Grok (`.grok/hooks/conversation-esaa.json`) é **dedicado ao produto** (nome próprio): pode ser regenerado integralmente; documentar essa distinção.
4. Idempotência: rodar duas vezes ⇒ **uma** entrada nossa por evento.

**Testes:** `enable_hooks_claude_preserves_existing_settings` · `enable_hooks_claude_idempotent_no_duplicate` · `bootstrap_claude_merges_into_existing_settings` · `enable_hooks_claude_refuses_invalid_json`.
**Aceite:** os quatro testes verdes; arquivo do Claude do usuário nunca perde chave.

---

#### PS-11 — `GROK_WORKSPACE_ROOT` com precedência sobre o local do script

**Evidência:** em `conv-sync.ps1` (e `conversation-esaa.ps1`, `conv-memory.ps1`, `conv-rag.ps1`) a resolução do workspace é: parâmetro → **variável `GROK_WORKSPACE_ROOT`** → local do script. Em `conv-sync.ps1` a variável nem passa por `Resolve-Path`. Rodar o `verify` de um projeto A com a variável apontando para B opera em **B**.

**Passo V — verificar**

```powershell
$a = New-TestWorkspace; Initialize-Ws $a 'grok'; $b = New-TestWorkspace; Initialize-Ws $b 'grok'
Invoke-CursorHook $b 'beforeSubmitPrompt' @{ conversation_id='x'; prompt='so existe em B' } | Out-Null  # (use Initialize-Ws $b 'cursor' antes, ou grave um evento de B por qualquer meio sintético)
$env:GROK_WORKSPACE_ROOT = $b
$out = & pwsh -NoProfile -File (Join-Path $a '.conversation-esaa/bin/conversation-esaa.ps1') context -Json -Last 5   # sem -Workspace, rodando o script de A
$out | Select-String 'so existe em B'          # CONFIRMADO se aparecer
Remove-Item Env:GROK_WORKSPACE_ROOT
```

**Passo C — corrigir** (parte `conv-sync.ps1` na pista A; as demais na pista B)

Ordem única nos 4 scripts: **(1)** parâmetro explícito → **(2)** se `$PSScriptRoot` estiver em `<ws>/.conversation-esaa/bin` (o pai do pai tem nome `.conversation-esaa`), usar `<ws>` → **(3)** `GROK_WORKSPACE_ROOT` **somente** se existir e contiver `.conversation-esaa` → **(4)** (só `conv-rag`) `Get-Location`. Sempre `Resolve-Path`.

**Testes:** `workspace_resolution_explicit_param_wins` · `workspace_resolution_prefers_script_location_over_env` · `workspace_resolution_env_used_when_script_outside_workspace` · `workspace_resolution_ignores_env_without_esaa_dir`.
**Riscos:** se existir instalação **global** dos scripts (fora do workspace), a regra (3) preserva o uso da variável — **pergunte ao humano** se esse cenário existe antes de aplicar.

---

#### PS-12 — Bootstrap: `memory/` ausente, `Copy-Item -Force`, fallback hardcoded

**Evidência:** (a) `conv-bootstrap.ps1` copia só `conv-memory.ps1`, não o diretório `memory/` do motor. (b) `Copy-Item -Force` sobrescreve os `.ps1` já instalados. (c) `conv-memory.ps1` **e** `conv-sync.ps1` têm o último fallback `/home/elzobrito/desenvolvimento/conversation-esaa/src/memory/adapter/cli.js`: na máquina do autor ele **mascara** a ausência do motor instalado; em qualquer outra máquina falha.

**Passo V — verificar**

```powershell
git grep -n "elzobrito" -- .conversation-esaa/bin
$ws = New-TestWorkspace; Initialize-Ws $ws 'grok'
Get-ChildItem "$ws/.conversation-esaa/bin" | Select-Object Name                       # há 'memory/'? (CONFIRMA (a) se não)
# (c) prova do mascaramento: use uma CÓPIA do script (nunca o original)
$cp = "$ws/.conversation-esaa/bin/conv-memory.ps1"
(Get-Content $cp -Raw) -replace '(\$cliScript = Resolve-MemoryCliScript)', '$1; Write-Output "ENGINE=$cliScript"' | Set-Content $cp -Encoding utf8
& pwsh -NoProfile -File $cp -WorkspaceRoot $ws -Action status | Select-String 'ENGINE='   # aponta para /home/elzobrito/...? => (c) CONFIRMADO
# (b) o lifecycle protege arquivo modificado? LEIA src/installer/lifecycle/index.js e responda no relatório
```

**Passo C — corrigir**

1. (a) No bootstrap: se existir `$srcBin/memory/adapter/cli.js`, copiar a pasta `memory/` para `$binDir/memory`; senão, se existir `<repo>/src/memory`, copiar dali. Registrar em `Add-Changed`.
2. (c) Remover o caminho absoluto em `conv-memory.ps1` e `conv-sync.ps1`. Ordem final: `CONV_ESAA_MEMORY_CLI` → `bin/memory/adapter/cli.js` → `<repo>/src/memory/adapter/cli.js` (relativo) → erro claro: `Memory-TCG engine not found. Run: conversation-esaa repair`.
3. (b) **Só documentar**, a menos que a leitura do `lifecycle/index.js` mostre que `update/repair` **não** protege arquivo modificado (aí abra item novo e peça decisão).

**Testes:** `bootstrap_installs_memory_engine_dir` · `memory_engine_resolution_order` · `memory_engine_missing_gives_actionable_error` (sem usar o caminho do autor).
**Riscos (declarar no relatório final):** workspaces instalados **antes** e que dependiam do fallback precisam de `repair`.

---

#### PS-13 — `verify` passa sem verificar a memória

**Evidência:** em `Invoke-Verify`, a verificação do Memory-TCG só roda `if ($cliScript -and $nodeCmd)`; se o motor ou o Node não forem encontrados, **nenhum aviso** e a saída é `verify: ok`, mesmo havendo eventos `memory.consolidation.*` no ledger.

**Passo V — verificar** *(use cópia de `conv-sync.ps1` em workspace temporário; troque o caminho absoluto do autor por um inexistente **na cópia**)*

```powershell
# 1) workspace com ledger contendo um evento memory.consolidation.accepted SINTÉTICO válido para as checagens do verify
# 2) cópia de conv-sync.ps1 sem fallback hardcoded e SEM memory/ no bin do temporário
Sync $ws 'verify' @()      # CONFIRMADO se imprimir 'verify: ok' e exit 0
```

**Passo C — corrigir**

No bloco de memória de `Invoke-Verify`: se há eventos `memory.consolidation.*` (ou existe `memory/`) **e** falta o motor ou o `node`:
- comando `verify` explícito ⇒ imprimir `verify: FAILED (memory integrity not verified: engine not found). Repair: conversation-esaa repair` e **exit 2**;
- chamada interna após `sync-*`/`project` ⇒ imprimir `verify: ok (WARNING: memory integrity not verified — engine not found)` e **exit 0** (hooks não podem passar a falhar por isso).
Distinguir pelo valor de `$Command`.

**Testes:** `verify_fails_when_memory_events_and_engine_missing` · `sync_warns_but_succeeds_when_engine_missing` · `verify_ok_without_memory_events_and_without_engine`.

---

#### PS-14 — Colisão de `event_id` em eventos curados  ·  *(prova por construção)*

**Evidência:** `Append-CuratedEvent` calcula o `event_id` por SHA-256 de `evento|raiz|ts|json`, com `ts` em **segundos** e sem nonce. Dois comandos idênticos no mesmo segundo geram o mesmo ID; `verify` acusa `Duplicate event_id`.

**Passo V:** como a janela de 1 s é difícil de acertar, aceite **prova por construção**: (1) cite as linhas da função; (2) escreva um teste que chama a lógica de ID duas vezes com a mesma entrada e mostra IDs idênticos (copie `New-CuratedEventId` para o teste). Veredito `CONFIRMADO (por construção; probabilidade baixa)`.

**Passo C:** incluir `[guid]::NewGuid()` **somente no `payload` do hash** (não gravar o GUID no registro). **Testes:** `curated_event_ids_unique_for_identical_commands`. **Aceite:** 20 `decide` idênticos em loop ⇒ 20 IDs distintos e `verify: ok`.

---

#### PS-15 — `context --before` no primeiro evento

**Evidência:** `$events[$start..($idx - 1)]` com `idx = 0` vira `$events[0..-1]`, que no PowerShell devolve **dois** itens (primeiro e último).

**Passo V:** usando a fixture `tests/fixtures/context/activity.context.jsonl` (ver `conv-test.ps1`), obter o ID do **primeiro** evento do workspace e rodar `context -Before <id> -Last 2 -Json`. `CONFIRMADO` se devolver ≥1 item (o esperado é **0**).
**Passo C:** `if ($idx -eq 0) { $events = @() } else { ... }`. **Teste:** `context_before_first_event_is_empty`. **Aceite:** `context_before_window` existente continua verde.

---

#### PS-16 — `Quote-CommandPart` / `Quote-HookPart` são no-op

**Evidência:** `-replace '"', '"'` troca aspas por aspas. Em Windows `"` não existe em caminhos; em POSIX existe e quebraria o comando do hook.

**Passo V:** `git grep -n "-replace '\"', '\"'"`; teste com caminho sintético contendo `"` (POSIX) para confirmar que o JSON do hook fica malformado/ambíguo. `INCONCLUSIVO` no Windows (não reproduz).
**Passo C:** a função deve **falhar fechado**: `throw "Path contains a double quote, which is not supported: <path>"` quando `$Value.Contains('"')`; senão devolver `'"' + $Value + '"'`. **Teste:** `quote_command_part_rejects_double_quote`.

---

#### PS-17 — `.gitignore` gerado

**Evidência:** a lista do `Merge-Gitignore` cobre `cursor-hook.log` e `run/*.lock`, mas **não** `codex-watch.log`, `antigravity-hook.log`, `run/cursor-*.txt` (PS-06), `activity.jsonl.bak-*` e `*.tmp-*` (PS-08).

**Passo V:** `git check-ignore -v` em cada caminho no workspace gerado (após `git init`). **Passo C:** acrescentar as entradas faltantes (pista B: bootstrap; pista C: lista equivalente no instalador — `git grep -n "cursor-hook.log" -- src`). **Teste:** `gitignore_covers_all_runtime_logs`. **Aceite:** `git status --porcelain` limpo após rodar todos os hooks em workspace temporário com Git.
*(Decisão sobre `decisions.md`, `tasks.json`, `topics.*` fica em D-01.)*

---

#### PS-18 — Lacuna de testes da cola PowerShell da memória

**Evidência:** `conv-test.ps1` não menciona `sonhar`, `memory-accept`, `memory-rollback`, `reconstruct-from-ledger` nem o fallback de contexto. A bateria depende do ledger do autor e de `py -m esaa`.

**Passo V:** `git grep -n -i "sonhar\|memory-accept\|memory-rollback\|reconstruct\|FALLBACK_LEGACY" -- .conversation-esaa/bin/conv-test.ps1 .conversation-esaa/bin/conv-test-battery.ps1` ⇒ `CONFIRMADO` se vazio. Registrar também `git ls-files tests | Select-String memory` (os testes Node existem?).

**Passo C (pista E, por último)** — acrescentar em `conv-test.ps1`, com **skip explícito** (`SKIP  <nome> — node/engine ausente`) se faltar Node ou motor, e fixture sintética de ~12 fatos (decisões, ecos, uma substituição explícita):
`memory_sleep_shadow_does_not_change_active_view` · `memory_accept_appends_exactly_one_event` · `memory_accept_twice_is_idempotent` (PS-04) · `memory_rollback_restores_previous_generation` · `memory_reconstruct_from_ledger_rebuilds_active` · `memory_context_fallback_marker_when_active_tampered` · `memory_verify_detects_tampered_active` · `memory_events_excluded_from_context_events` · `memory_workspace_isolation`.
**Aceite:** todos verdes em Linux; documentados os pulados. A bateria (`conv-test-battery.ps1`) passa a aceitar `-SkipLab` sem depender do ledger do autor (já aceita; **não** alterar o comportamento).


---

### 4.3 Cartões — motor Memory-TCG (Node)

> Antes de editar qualquer arquivo de `src/memory/**`, localize-o com `git ls-files src/memory` e **leia a função inteira**. Os nomes de função abaixo vêm da revisão e devem ser confirmados.

#### JS-01 — Guard de execução da CLI de memória no Windows

**Evidência:** `src/memory/adapter/cli.js` só executa `main()` se `import.meta.url === \`file://${process.argv[1]}\``. No Windows `process.argv[1]` é `C:\...` (a URL é `file:///C:/...`); com espaço/acento a URL vem codificada (`%20`). A comparação falha e o script **sai em silêncio, exit 0, sem saída**.

**Passo V — verificar** (reproduz no Linux com espaço no caminho)

```bash
T="$(mktemp -d)/dir com espaço ç"; mkdir -p "$T"; cp -r src/memory "$T/memory"
WS="$(mktemp -d)"
node "$T/memory/adapter/cli.js" status --workspace "$WS" --json; echo "exit=$?"   # CONFIRMADO se: nenhuma saída
node src/memory/adapter/cli.js status --workspace "$WS" --json; echo "exit=$?"      # controle: deve imprimir JSON
```

No Windows, repetir com `node C:\caminho\src\memory\adapter\cli.js status --workspace <ws> --json`. Se não houver Windows disponível, registrar essa metade como `INCONCLUSIVO (plataforma)`; a metade Linux (espaço/acento) já basta para `CONFIRMADO`.

**Passo C — corrigir**

```js
import { pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';
export function isMainModule(metaUrl, argv1) {
  try { return metaUrl === pathToFileURL(realpathSync(argv1)).href; } catch { return false; }
}
// uso: if (isMainModule(import.meta.url, process.argv[1])) { process.exitCode = await main(); }
```

**Testes (Node, `node --test`):** `cli_runs_when_path_has_space_and_accent` (spawn real, como acima) · `isMainModule_false_when_imported` · `isMainModule_true_via_symlink` (se o SO permitir). **Aceite:** saída JSON no cenário com espaço/acento; no Windows, execução manual registrada no relatório; nenhum teste existente quebra.

---

#### JS-02 — `scoreConflictRelevance`: condição sempre verdadeira  ·  **requer D-02**

**Evidência:** a expressão `activeTopicIds.has(node.topic_id) || node.topic_id` é verdadeira para **qualquer** `topic_id` não vazio; logo o critério "tópico ativo" nunca discrimina e a ordem dos conflitos no `context` ignora esse fator.

**Passo V — verificar**

```js
// teste de caracterização (NÃO commitar como definitivo): importar a função, montar dois nós de conflito
// idênticos exceto por topic_id (um em activeTopicIds, outro fora) e comparar as pontuações.
// CONFIRMADO se as pontuações forem iguais.
```

Registrar também **quantos conflitos mudam de posição** numa fixture de 48 e de 480 fatos se a condição for corrigida (execute com a correção **apenas em cópia temporária**).

**Passo C — corrigir (somente com D-02 aprovada)**

1. Trocar por `activeTopicIds.has(node.topic_id)`.
2. Se D-02 = "bump de política": atualizar `policy_version` conforme o contrato, regenerar *golden files* com justificativa no `02-fix-log.md`.
3. Registrar no artigo (ART-07) que a ordem dos conflitos no produto muda.

**Testes:** `conflict_relevance_prefers_active_topic` · golden de ordem de conflitos atualizado. **Aceite:** só a ordem dos conflitos muda; nenhum outro digest muda.

---

#### JS-03 — Resonance usa `a.session_id` inexistente  ·  **requer D-02**

**Evidência:** em `resonance` (arquivo localizado por `git grep -n "session_id" src/memory`), o código acessa `a.session_id`; os nós do grafo não trazem esse campo.

**Passo V — verificar**

1. Listar os campos reais de um nó de episódio (imprimir `Object.keys(node)` de um grafo gerado numa fixture; salvar em `evidence/JS-03/`).
2. Mostrar **onde** `session_id` é lido e **o que** a expressão avalia (`undefined`), e qual **efeito** isso tem (agrupamento por partição? comparação sempre igual/diferente?). Provar com um teste de caracterização: mesma fixture com 2 sessões distintas ⇒ as relações candidatas mudam ou não?
3. Veredito: `CONFIRMADO` (campo inexistente **e** efeito observável) · `NÃO CONFIRMADO` (campo existe em outra forma/ou efeito nulo).

**Passo C:** **não decidir o conserto.** Escrever `decisions/D-02-memo.md` com: efeito observado, opções (derivar sessão das evidências; remover a condição morta; renomear campo), impacto em digests e custo. Implementar só a opção aprovada.

---

#### JS-04 — Crescimento do ledger por `accept`  ·  **MEDIÇÃO + D-03**

**Evidência:** `memory.consolidation.accepted` embute `proposal`, `active_view` e (até 500 nós) `graph`.

**Passo V — medir**

Para 48, 480 e 1.920 fatos (fixtures do harness): executar `sonhar --accept` e registrar (a) bytes da **linha** do evento no ledger, (b) bytes adicionados após 5 `accept` consecutivos, (c) tempo de `verify` e de `reconstruct-from-ledger` antes/depois.

| Fatos | bytes/accept | bytes após 5 | verify (s) | reconstruct (s) |
|---:|---:|---:|---:|---:|
| 48 | | | | |
| 480 | | | | |
| 1.920 | | | | |

**Limiar:** se um `accept` a 480 fatos passar de **256 KiB** ou `verify` crescer superlinearmente com o nº de `accept`, escrever `D-03-memo.md`. Caso contrário: `NÃO CONFIRMADO` (aceitável), encerrar. **Sem Passo C.**

---

#### JS-05 — `npm test` não executa os testes de memória

**Evidência:** o script `test` do `package.json` lista apenas `tests/installer/all.test.js`, `args.test.js`, `install.test.js`.

**Passo V:** `git ls-files tests` e `Get-Content package.json`; `CONFIRMADO` se existirem testes de memória (`tests/memory/**` ou equivalente) fora do script.
**Passo C:** adicionar `"test:memory": "node --test <diretório-de-testes-de-memória>/"` e fazer `"test"` executar instalador **e** memória (passe **diretório**, não glob, para funcionar no Windows). Se houver workflow de CI no repositório, incluí-lo; se não houver, **não criar** CI (registrar como recomendação).
**Teste/Aceite:** `npm test` agora conta os testes de memória no total (registrar `antes: N / depois: M`); falha deliberada num teste de memória derruba `npm test` (provar e reverter).

---

#### JS-06 — Teto de 4 itens/seção e 200 caracteres/linha no `context`  ·  **DECISÃO D-04**

**Evidência:** quando decisões + conflitos passam de 20, `cmdContext` limita cada seção a 4 itens e corta cada linha em 200 caracteres, mesmo com orçamento de 4.000 caracteres sobrando.

**Passo V — medir**

Fixture com 50 decisões ativas, `sonhar --accept`; depois:
`memory context --json` (padrão 4.000), `conversation-esaa context` (legado), `pack` (padrão).
Tabela: decisões retidas × exibidas × listadas em `omitted_memory_ids`; caracteres usados do orçamento; linhas cortadas.
**Entregável:** `D-04-memo.md` (manter / parametrizar `--max-per-section` / remover). **Sem Passo C.**

---

### 4.4 Cartões — documentação

#### DOC-01 — ADR-013 §5 e README com afirmações superadas

**Passo V:** `git grep -n -i "F1 = 1\|F1=1\|CDA\|instrucionista\|CONV-MTCG-BENCHMARK" -- docs README.md` ⇒ listar arquivo:linha de cada afirmação.
**Passo C:** substituir a afirmação numérica e a de superioridade por: *"Resultados da avaliação sintética exploratória: ver `DC-consolidacao-memoria-agentes-v1.3.1` e o repositório de artefatos (commit `6a2ac1f9e1966403603b2f972453d12cdbbea3c3`). Nessa avaliação, uma baseline instrucionista sensível à autoridade (B′) empata com o RRR completo na revocação de decisões; os ganhos sobre a janela cronológica decorrem da filtragem da visão ativa. A avaliação não é independente."* **Não** inserir números novos que não estejam no artigo. **Aceite:** o `grep` acima não encontra mais as afirmações antigas; o ADR registra a data da revisão.

#### DOC-02 — `actor` fixo e identidade declarada  ·  *(texto; schema só com D-05)*

**Passo V:** `git grep -n "actor = 'assistant'" -- .conversation-esaa/bin/conv-sync.ps1` dentro de `Invoke-Decide/Invoke-TaskCommand/Invoke-TopicCommand/Invoke-MemoryAccept/Invoke-MemoryRollback`.
**Passo C (texto):** nos ADRs/README/artigo §3.3: eventos curados gravam `actor: assistant`; a atribuição vem de `agent_id` **declarado** + `agent_id_source` (`declared` | `unknown` | `legacy_unverified`); **não** há autenticação do executor. **Aceite:** frase presente nos três lugares; nenhuma alteração de código.

---

### 4.5 Cartões — artigo e benchmark

> Regras desta trilha: (i) **não** sobrescrever `DC-...-v1.3.md`; criar `DC-consolidacao-memoria-agentes-v1.3.1.md`; (ii) **nenhum número** do artigo é alterado sem ser **recalculado** a partir de `CONV-RRR-V13-OUTPUT.json` (ou do JSON de saída equivalente, localizado no repositório de artefatos); (iii) toda frase alterada cita a tabela/arquivo de origem no `02-fix-log.md`; (iv) a trilha **não** reexecuta o benchmark, exceto as medições dos cartões ART-01, ART-07, ART-08, ART-09.

#### ART-01 — O braço D1 contorna a renormalização real?  *(verificação decisiva — execute primeiro)*

**Evidência:** na renormalização, toda decisão ativa recebe `retain` mesmo fora da amostra (cobertura 100% de decisões, citada no README). Se isso é verdade no produto, a perda de decisões do **D1** (0,40 a 48 fatos; 0,56 a 480/1.920, antes do corte) não pode vir do ringing do produto — pode vir de um caminho próprio do harness. Nesse caso a frase "a amostragem estratificada retém as decisões antes do corte" **atribui ao ringing um efeito do harness**.

**Passo V — verificar**

1. Localizar o harness: `git grep -il "FAIR-OUTPUT\|ablation\|fifo\|D1" -- .` no produto e no clone de `conversation-esaa-rrr-artifacts`. Registrar o caminho.
2. Ler a implementação do braço D1. Responder, com trecho de código: **(i)** ele chama `renormalize` do produto com um amostrador diferente, ou monta a proposta por conta própria? **(ii)** onde as decisões não amostradas são descartadas?
3. Confirmar a regra do produto: `git grep -n -i "decision" -- src/memory/**/renormalize*` e localizar a condição que impede descartar decisão ativa. Colar as linhas em `evidence/ART-01/`.
4. Instrumentar **uma execução** (seed 11, 48 fatos, em cópia temporária do harness): contar decisões vigentes na saída da renormalização **antes do corte de saída** para C e D1. Esperado pelo artigo: C = 1,00; D1 = 0,40.
5. Rastrear **quais** decisões D1 perde e **por quê** (fora da amostra? fora do grafo? descartadas na renormalização?).

**Veredito:**
- `CONFIRMADO` — o produto retém toda decisão ativa e D1 só perde decisões por um caminho do harness que o produto não tem ⇒ a atribuição do artigo ao ringing é **inválida para o produto**.
- `NÃO CONFIRMADO` — D1 perde decisões por um caminho legítimo do produto (ex.: nós fora da amostra nem entram no grafo) ⇒ o artigo se sustenta; falta explicar o mecanismo.

**Passo C (texto, pista D):** conforme o veredito, reescrever Resumo/Abstract/§3.2/§5.2/§6/§7:
- se `CONFIRMADO`: trocar "ringing é necessário para reter decisões" por "na ablação D1 do harness, a substituição do amostrador por FIFO reduz a retenção; **no produto, decisões ativas são sempre retidas pela regra de renormalização**, portanto o efeito observado depende de como o harness implementa D1" e listar a refação de D1 pelo caminho real como trabalho futuro;
- se `NÃO CONFIRMADO`: acrescentar em §3.2 o mecanismo exato (arquivo/função) pelo qual a amostragem determina a presença da decisão.
**Aceite:** nenhuma frase do artigo atribui ao ringing um efeito que o `evidence/ART-01/` não sustenta.

---

#### ART-02 — "D1 ≤ 0,03 abaixo de C" falsa em 480 fatos / 4.096 tokens

**Passo V:** a partir do JSON de saída, calcular a **mediana entre seeds** da revocação de decisões **pós-corte** para C e D1 nas 9 combinações (fatos ∈ {48, 480, 1.920} × tokens ∈ {512, 1.024, 4.096}) e listar `|C − D1|`. Salvar o script e a tabela em `evidence/ART-02/`. Conferência de sanidade (valores esperados a confirmar pelo script, **não** copiá-los sem calcular): 48 fatos/1.024 → 1,000 × 0,400; 480/4.096 → 1,000 × 0,560 (Tabela 4).
`CONFIRMADO` se alguma combinação tiver `|C − D1| > 0,03` **fora** das que o artigo cita como exceção.
**Passo C:** reescrever a afirmação com condição explícita, p.ex.: *"D1 fica no máximo 0,03 abaixo de C quando a visão ativa de C não cabe no orçamento (480 fatos com até 1.024 tokens; 1.920 fatos em todos os orçamentos). Quando ela cabe (48 fatos; 480 fatos com 4.096 tokens), a diferença chega a 0,60 e 0,44."* — **confirme os limites com a tabela calculada** antes de escrever. Aplicar em Resumo, Abstract, §5.2, §6, §7.

#### ART-03 — Custo do CQ omitido

**Passo V:** com o JSON, calcular para C e CQ, nas 9 combinações: revocação de decisões, F1 de conflitos, precisão, revocação de conflitos. Sanidade (a confirmar): 480/1.024: 0,440 → 0,340; 1.920/4.096: 0,445 → 0,355. `CONFIRMADO` se CQ reduz a revocação de decisões em ≥ 1 combinação **e** o Resumo/Abstract/Conclusão não mencionam isso (ou dizem "sem perder decisões" de forma geral).
**Passo C:** acrescentar meia frase de custo em Resumo e Abstract; na Conclusão, restringir "sem perder decisões" ao cenário em que o JSON mostra revocação igual (480/4.096) e dizer que fora dele há perda; incluir as combinações com perda na Tabela 4 (ou nota).

#### ART-04 — D2 "empata em todas as combinações" sem tabela

**Passo V:** calcular `C − D2` nas 9 combinações (decisões e conflitos). `CONFIRMADO` (o problema de texto) se D2 só aparece na Tabela 1 (1.024 tokens) e a frase cobre "todas".
**Passo C:** se D2 = C nas 9 combinações ⇒ acrescentar coluna D2 na Tabela 2 e manter a frase; senão ⇒ restringir a frase às combinações em que vale.

#### ART-05 — "Os primeiros da fila são os melhores"

**Passo V:** a partir do JSON (ou rerodando só o CQ em 48 fatos/512 tokens, em cópia), listar a precisão dos **k primeiros** conflitos de CQ por escala. Esperado (a confirmar): precisão 1,000 em 480 e 1.920 fatos; 48 fatos/512 tokens com falsos positivos entre os exibidos.
**Passo C:** restringir a frase às escalas em que a precisão dos k primeiros é 1,000 e explicar por que a ordem por `conflict_id` perde qualidade em 48 fatos, **ou** remover a frase.

#### ART-06 — Terminologia "antes do corte" × "antes da filtragem"

**Passo V:** `Select-String -Pattern "antes do corte|antes da filtragem|pré-corte|antes da renormaliza" DC-...-v1.3.md` ⇒ listar ocorrências com seção.
**Passo C:** definir no início da §4: **pré-corte** = depois da renormalização e antes do limite de saída; **pós-corte** = após o limite de saída; o ringing ocorre **antes** da renormalização (não usar "antes da filtragem" como sinônimo). Uniformizar todas as ocorrências.

#### ART-07 — O CN não reproduz a saída real do produto

**Evidência:** o produto tem três caminhos de leitura: `memory context` (4.000 caracteres; com >20 itens, 4 por seção e linhas cortadas em 200 caracteres), `pack` (estimativa ⌈bytes/4⌉ tokens; ordem decisões → conflitos → históricas → assuntos → recorrentes) e o bloco de 3.200 caracteres anexado a `handoff.md`/`state.md`. O CN usa "a ordem" do `cmdContext` **sobre a serialização JSON padronizada** do harness.

**Passo V — medir a saída real (não o ensaio)**

1. No workspace temporário da fixture de **480 fatos** (o harness já monta um; reutilizar) com `sonhar --accept`:
   - `memory context --json` (padrão) ⇒ `D_ctx` = nº de decisões vigentes do gabarito presentes;
   - `pack` (padrão 4.000 tokens estimados) ⇒ `D_pack`;
   - bloco de 3.200 caracteres do `handoff.md` ⇒ `D_handoff`.
2. Revocação = `D_* / total de decisões vigentes`. Registrar a tabela em `evidence/ART-07/`.
3. Comparar com CN (0,440 a 1.024 tokens, 480 fatos) **sem** chamar de equivalente: o orçamento e a serialização são diferentes.

**Passo C (texto):** §4.1 define CN como "ordem de itens do `cmdContext` sob serialização JSON padronizada" e acrescenta um parágrafo "Saída real do produto" com as três revocações medidas; §6 ganha a ameaça "o CN não reproduz o limite por seção nem o formato Markdown". Recomendar (sem executar) um braço **P** (produto real) como trabalho futuro.
**Aceite:** nenhuma frase diz que CN "reproduz a saída de produção" sem a ressalva.

#### ART-08 — Escalas cruzam regimes de política

**Passo V:** para 48, 480 e 1.920 fatos, imprimir (a) nº de nós do grafo, (b) nº de episódios, (c) quais limiares de política são ultrapassados: `> 50` nós (retenção de episódios ressonantes e âncoras), `> 200` (armazenamento frio esparso), `> 250` episódios (ressonância particionada em janelas de 40), `> 500` nós (compactação). **Confirme os valores dos limiares lendo `renormalize`/`resonance`**; se diferirem destes, use os do código e registre a discrepância.
**Passo C:** nova subseção em §6 "Escala e regimes de política" com a tabela (cenário × limiares). Dizer que a comparação entre escalas mistura **tamanho** e **mudança de regime**.

#### ART-09 — Reprodutibilidade de IDs

**Passo V:** rodar `sonhar` (shadow) com a mesma seed na **mesma** fixture em dois diretórios distintos; comparar `workspace_id`, `proposal_id`, `graph_generation_id`, `active_digest` e as métricas. Esperado: IDs dependentes de `workspace_id` diferem; métricas e conteúdo da visão (exceto IDs) coincidem.
**Passo C:** em §4.3, declarar exatamente o que a reprodução preserva (métricas e conteúdo) e o que não preserva (identificadores derivados do caminho).

#### ART-10 — Fechamento do artigo (v1.3.1)

Depois de ART-01…ART-09, produzir `DC-consolidacao-memoria-agentes-v1.3.1.md`:
1. Front matter: `versao: "1.3.1"`; linha nova em *Controle de versões* (data, autoria, descrição objetiva das correções).
2. Aplicar as correções de texto aprovadas.
3. Incluir, onde couber, as ressalvas do produto confirmadas (DOC-02; `Repair-ActivityContract` como exceção a "acrescentável" **se** PS-08 for CONFIRMADO; cola PowerShell sem testes **até** PS-18 fechar).
4. Conferência final automática: `Select-String` para "≤ 0,03", "sem perder decisões", "reproduz a saída de produção", "antes da filtragem" — **cada ocorrência** precisa estar compatível com o `evidence/`.
5. Não alterar front matter de instituição/departamento.
**Aceite:** diff do artigo mostra só trechos ligados a ART-01…09/DOC-02; todo número alterado tem origem calculada em `evidence/`.

---

## 5. Decisões humanas (portões)

O agente **não implementa** itens com decisão pendente. Ele escreve `decisions/D-0x-memo.md` (problema, evidência medida, opções, recomendação, custo de cada uma) e **para**.

| ID | Pergunta | Itens bloqueados |
|---|---|---|
| **D-01** | O ledger (`activity.jsonl`) deve poder chegar ao Cloud Agent do Cursor? Opções: **A)** não — ledger só local; remover do ADR-012 a promessa de pack no Cloud Agent. **B)** exportação redigida e versionada de handoff (`export-handoff`), opt-in. **C)** comando `relocate` que grava evento `workspace.relocated` (append-only) e faz snapshot/verify honrarem a nova raiz. | PS-05 |
| **D-02** | Correções que alterem saída/digest da política (JS-02, JS-03) devem **bump de `policy_version`** (ex.: `rrr-policy.v2`) ou ficar como correção silenciosa? Recomendação do plano: bump + golden files novos + nota no artigo (os resultados publicados passam a ser da política v1). | JS-02, JS-03 |
| **D-03** | Como conter o crescimento do ledger por `accept`? Opções: manter (replay integral), referenciar artefato por digest (perde replay puro), ou compactação periódica por evento de snapshot. | JS-04 |
| **D-04** | O teto de 4 itens/seção e 200 caracteres/linha no `context` é intencional? Manter, parametrizar ou remover? | JS-06 |
| **D-05** | `actor` dos eventos curados: manter `assistant` (e só documentar), ou acrescentar campo `curated_by` (schema novo)? | DOC-02 (parte schema) |

---

## 6. Condições de parada (R12)

Pare, não corrija, e escreva em `03-final-report.md` se qualquer uma ocorrer:

1. O baseline (Fase 0) tem teste vermelho **antes** de qualquer mudança sua.
2. Mais de **um terço** dos problemas dá `NÃO CONFIRMADO` — a premissa da revisão está errada; peça nova análise humana.
3. Uma correção altera hash/digest de golden file e **não** há D-02 aprovada.
4. Você precisaria editar arquivo de outra pista.
5. O hash do `activity.jsonl` real mudou (R4).
6. Um teste de regressão não consegue ficar vermelho antes da correção (o defeito não é o que você achou).

---

## 7. Fase 2 — Como executar as correções (W2a / W2b)

Só entram aqui os IDs com veredito `CONFIRMADO` **e** liberados no G1. Para cada um, na ordem da pista (§3.2):

1. **Claim** da tarefa `[C]`.
2. **Teste primeiro (vermelho):** escrever o(s) teste(s) de regressão do cartão. Rodar. **Tem de falhar** pelo motivo descrito. Salvar a saída em `evidence/<ID>/red.txt`. (Não ficou vermelho ⇒ condição de parada 6.)
3. **Mudança mínima** (R8) nos arquivos da pista. Nenhum arquivo de outra pista.
4. **Verde:** rodar o(s) teste(s) novo(s) ⇒ passam. Salvar em `evidence/<ID>/green.txt`.
5. **Regressão local da pista:** pista A/B ⇒ `conv-test.ps1` inteiro; pista C ⇒ `npm test` (e, depois de JS-05, os de memória). Nenhuma queda de contagem de testes existentes.
6. **Patch:** `git diff -- <arquivos> > docs/qa/fix-v1.3.2/patches/<ID>.patch`.
7. **Log:** bloco do Apêndice B (modelo *fix-log*) em `02-fix-log.md`.
8. **Complete → review → verify** (ESAA). O *reviewer* **não** é o mesmo agente que corrigiu e deve reproduzir o vermelho→verde a partir do patch.

**Ordem de integração entre pistas:** pista A termina `PS-01` antes de a pista B iniciar `PS-06`; pista E (`PS-18`) só começa quando A concluir `PS-04`, `PS-09`, `PS-13`.

**Mudança de comportamento visível ao usuário** (marque no log com `[COMPORTAMENTO]`): PS-02 (erro em vez de fallback), PS-04 (exit 2 com `COMMITTED`), PS-12 (`repair` necessário em workspaces antigos), PS-13 (verify com aviso/erro), PS-16 (erro com aspas no caminho). Todas precisam de nota no `RELEASE.md` **proposta** (texto em `02-fix-log.md`; **não** editar `RELEASE.md` sem autorização — R6).

---

## 8. Fase 3 — Regressão total e fechamento (W3)

1. **Suítes completas** (todas verdes, contagem ≥ baseline): `npm test` · `conv-test.ps1` · testes de memória · `conv-test-battery.ps1 -SkipLab -SkipEsaa`.
2. **Matriz de plataformas** (registrar em `03-final-report.md`):

   | Item | Linux + pwsh 7 | Windows + pwsh 7 |
   |---|---|---|
   | Suítes completas | ✔/✘ | ✔/✘/não executado |
   | PS-02 (caminho `\\`) | teste puro | ✔/✘/não executado |
   | JS-01 (espaço/acento/`C:\`) | ✔/✘ | ✔/✘/não executado |
   | PS-03 (lock) | ✔/✘ | ✔/✘/não executado |

   "Não executado" é resposta válida; **não** declare Windows verificado sem rodar.
3. **R4:** recalcular o SHA-256 do `activity.jsonl` real e comparar com o da Fase 0. Diferente ⇒ parar e reportar.
4. **Higiene:** remover os workspaces temporários criados (`fix132-*`, `fakehome-*`); `git status --short` deve listar **apenas** arquivos previstos nos patches e em `docs/qa/fix-v1.3.2/`.
5. **Relatório final** (`03-final-report.md`): tabela `ID → veredito (Fase 1) → ação (Fase 2) → vermelho/verde → patch`; lista de itens `NÃO CONFIRMADO` com a evidência; lista de decisões pendentes (D-01…D-05) com os memorandos; mudanças de comportamento; riscos residuais; lista de arquivos tocados; o que **não** foi feito (e por quê).
6. **Handoff:** atualizar o estado do projeto **pelo mecanismo ESAA/Conversation vigente** (tarefas `done`, decisões registradas via `decide` se o humano autorizar). Não editar read models.
7. **Não fazer:** commit, push, tag, publicação npm, bump de versão, edição de `RELEASE.md`.

---

## Apêndice A — `_helpers.ps1`

Salvar como `docs/qa/fix-v1.3.2/_helpers.ps1` e usar com `. docs/qa/fix-v1.3.2/_helpers.ps1`. Não usa `Set-StrictMode` (os cartões fazem `Where-Object` em propriedades que podem não existir).

```powershell
#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$script:Repo = (git rev-parse --show-toplevel).Trim()
$script:Bin  = Join-Path $script:Repo '.conversation-esaa/bin'

function New-TestWorkspace {
  $d = Join-Path ([IO.Path]::GetTempPath()) ('fix132-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force $d | Out-Null
  (Resolve-Path $d).Path
}

# Bootstrap do repositório em um workspace temporário (copia os .ps1 atuais do repo para o bin do workspace)
function Initialize-Ws([string]$Ws, [string]$Agents = 'grok,claude,codex,antigravity,cursor') {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Bin 'conv-bootstrap.ps1') -WorkspaceRoot $Ws -Agents $Agents | Out-Null
  if ($LASTEXITCODE) { throw "bootstrap failed ($LASTEXITCODE)" }
}

# conv-sync.ps1 direto
function Sync([string]$Ws, [string]$Command, [string[]]$Extra = @()) {
  $o = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Bin 'conv-sync.ps1') $Command -WorkspaceRoot $Ws @Extra 2>&1
  [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($o | Out-String).Trim() }
}

# CLI pública (conversation-esaa.ps1)
function Cli([string]$Ws, [string]$Command, [string[]]$More = @()) {
  $o = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Bin 'conversation-esaa.ps1') $Command @More -Workspace $Ws 2>&1
  [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($o | Out-String).Trim() }
}

# Hook do Cursor instalado NO workspace (usa a cópia gerada pelo bootstrap)
function Invoke-CursorHook([string]$Ws, [string]$Event, [hashtable]$Payload) {
  $hook = Join-Path $Ws '.conversation-esaa/bin/cursor-hook.ps1'
  ($Payload | ConvertTo-Json -Compress) | & pwsh -NoProfile -ExecutionPolicy Bypass -File $hook -WorkspaceRoot $Ws -Event $Event
}

function Read-Ledger([string]$Ws) {
  $p = Join-Path $Ws '.conversation-esaa/activity.jsonl'
  if (-not (Test-Path $p)) { return @() }
  @(Get-Content $p -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Count-Lines([string]$Ws) { @(Read-Ledger $Ws).Count }

# Ledger sintético para medições (PS-07, JS-04). Nunca use texto real.
function New-SyntheticLedger([string]$Ws, [int]$Turns, [int]$Tasks = 0) {
  $p  = Join-Path $Ws '.conversation-esaa/activity.jsonl'
  $sw = [IO.StreamWriter]::new($p, $false, [Text.UTF8Encoding]::new($false))
  function Hid([string]$s) { [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','').ToLower() }
  try {
    for ($i = 0; $i -lt $Turns; $i++) {
      $actor = if ($i % 2 -eq 0) { 'user' } else { 'assistant' }
      $rec = [ordered]@{
        event_id = (Hid "gen|turn|$i"); ts = '2026-11-08T12:00:00-03:00'; event = 'conversation_turn'
        actor = $actor; agent_id = $(if ($actor -eq 'assistant') { 'codex' } else { $null })
        source = 'codex'; source_session_id = 'gen'; source_path = 'gen'; source_index = $i
        workspace_root = $Ws; summary = "turno sintetico $i"; text = "turno sintetico $i"
      }
      $sw.WriteLine(($rec | ConvertTo-Json -Compress))
    }
    for ($t = 1; $t -le $Tasks; $t++) {
      $tid = 'CONV-{0:D3}' -f $t
      foreach ($ev in 'task.created', 'task.updated') {
        $rec = [ordered]@{
          event_id = (Hid "gen|$ev|$t"); ts = '2026-11-08T12:00:00-03:00'; event = $ev; actor = 'assistant'
          agent_id = 'codex'; workspace_root = $Ws; task_id = $tid; title = "tarefa sintetica $t"
          status = $(if ($ev -eq 'task.created') { 'open' } else { 'in_progress' })
          summary = "$ev $tid"; text = "$ev $tid"
        }
        $sw.WriteLine(($rec | ConvertTo-Json -Compress))
      }
    }
  } finally { $sw.Dispose() }
  Sync $Ws 'project' | Out-Null
}

function Measure-Median([scriptblock]$Block, [int]$Runs = 3) {
  $t = 1..$Runs | ForEach-Object { (Measure-Command { & $Block | Out-Null }).TotalSeconds } | Sort-Object
  [pscustomobject]@{ Median = $t[[int][math]::Floor($t.Count / 2)]; Max = $t[-1] }
}
```

Se `conv-bootstrap.ps1` recusar `-Agents` por algum motivo, usar a forma que `conv-test.ps1` usa (`-Agents cursor`) e registrar o ajuste no relatório.

---

## Apêndice B — Modelos

### B.1 Bloco de verificação (`01-verification-report.md`)

````markdown
### VER-<ID> — <título>
- **Veredito:** CONFIRMADO | NÃO CONFIRMADO | INCONCLUSIVO | DECISÃO | MEDIÇÃO
- **Ambiente:** SO / pwsh --version / node --version / commit (git rev-parse --short HEAD)
- **Comandos executados (copiáveis):**
  ```
  ...
  ```
- **Saída observada (resumo; sem texto de conversa):** ...
- **Se o problema existisse, eu veria:** ...
- **Se NÃO existisse, eu veria:** ...
- **Conclusão:** ...
- **Evidência bruta:** evidence/<ID>/...
- **Ação proposta:** liberar FIX132-<ID>[C] | encerrar | sonda extra: ... | memorando D-0x
````

Tabela-resumo final (obrigatória):

| ID | Veredito | Evidência em 1 linha | Ação |
|---|---|---|---|

### B.2 Bloco de correção (`02-fix-log.md`)

```markdown
### FIX132-<ID>
- **Pista / arquivos:** ...
- **Teste(s) novo(s):** <nomes>
- **Vermelho:** evidence/<ID>/red.txt — <motivo da falha em 1 linha>
- **Mudança:** <o que mudou, em 3 linhas no máximo>
- **Verde:** evidence/<ID>/green.txt
- **Regressão da pista:** <N passes / N falhas antes → depois>
- **Patch:** patches/<ID>.patch
- **[COMPORTAMENTO]:** <sim/não; se sim, texto proposto para RELEASE.md>
- **Riscos residuais:** ...
- **Reviewer:** <agente> reproduziu vermelho→verde? sim/não
```

### B.3 Memorando de decisão (`decisions/D-0x-memo.md`)

```markdown
# D-0x — <pergunta>
## Fatos medidos (com caminho das evidências)
## Opções (A, B, C…) — o que muda, custo, risco, reversibilidade
## Recomendação do agente (1 parágrafo) e por quê
## O que fica bloqueado até a resposta
## Resposta do humano: ______ (data/assinatura)
```

### B.4 Esqueleto do relatório final (`03-final-report.md`)

```markdown
# Relatório final — Conversation ESAA v1.3.2 (rodada de correção)
1. Resumo (3 linhas): quantos itens verificados / confirmados / não confirmados / decisões pendentes
2. Tabela ID → veredito → ação → vermelho/verde → patch
3. Itens NÃO CONFIRMADOS (evidência)
4. Decisões pendentes (D-01…D-05) com links dos memorandos
5. Mudanças de comportamento + texto proposto para RELEASE.md
6. Matriz de plataformas
7. R4: hash do ledger real antes/depois
8. Arquivos tocados (git diff --stat)
9. O que NÃO foi feito e por quê
10. Riscos residuais
```

---

## Apêndice C — Definição de "pronto" (checklist único)

- [ ] `00-baseline.md` existe e o baseline estava 100% verde.
- [ ] `01-verification-report.md` tem **um veredito para cada ID** (nenhum item sem veredito) e a tabela-resumo.
- [ ] G1 registrado (quem liberou, quando, quais itens foram barrados).
- [ ] Para cada correção: vermelho **e** verde registrados; patch gerado; reviewer reproduziu.
- [ ] Nenhum item `NÃO CONFIRMADO` foi alterado.
- [ ] Nenhum item `DECISÃO` foi implementado sem resposta humana; memorandos D-01…D-05 prontos quando aplicável.
- [ ] Nenhuma alteração de política RRR sem D-02.
- [ ] Suítes completas ≥ baseline; matriz de plataformas preenchida com honestidade.
- [ ] SHA-256 do `activity.jsonl` real **idêntico** ao da Fase 0.
- [ ] Artigo `v1.3.1` criado **sem** sobrescrever a `v1.3`; cada número alterado tem origem calculada.
- [ ] ADR-013 §5/README atualizados (DOC-01); DOC-02 aplicado.
- [ ] Workspaces temporários removidos; `git status` só com arquivos previstos.
- [ ] Sem commit, sem push, sem bump, sem edição de `RELEASE.md`.
- [ ] Handoff atualizado pelo mecanismo do projeto.

---

## Apêndice D — Ordem resumida de execução

```
W0  baseline
W1  [paralelo] VER de todos os IDs (PS-01…18, JS-01…06, DOC-01/02, ART-01…09)
    └─ ART-01 primeiro dentro da trilha de artigo
G1  humano libera/barra
W2a [paralelo] A: PS-14 → PS-03 → PS-01 → PS-04 → PS-02 → PS-15 → PS-13 → PS-08 → PS-09 → PS-11* → PS-12*
               B: PS-10 → PS-16 → PS-11* → PS-12* → PS-17 → PS-02* → PS-06 (após PS-01)
               C: JS-01 → JS-05 → JS-03† → JS-02†      († só com D-02)
W2b [paralelo] D: DOC-01 → DOC-02 → ART-02…ART-10   |   E: PS-18 (após PS-04, PS-09, PS-13)
W3  regressão total, matriz, R4, relatório final
```
