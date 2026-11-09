 Conversation ESAA

**Memória conversacional compartilhada entre agentes de IA** — Grok, Codex, Claude Code, Google Antigravity e Cursor.

Quando você troca de agente ou a janela de contexto acaba, o próximo assistente perde objetivos, decisões e tarefas abertas. O Conversation ESAA captura os turnos visíveis automaticamente (hooks e watchers), grava em um log append-only local e projeta read models compactos para handoff — **sem gastar tokens do LLM na cópia mecânica**.

| | |
|---|---|
| **Versão** | v1.3.1 (instalador npm + RAG opt-in) |
| **Plataforma** | Windows e Linux; Node.js 18+ e PowerShell 7 (`pwsh`) |
| **Licença** | MIT |
| **Privacidade** | [PRIVACY.md](PRIVACY.md) — leia antes de versionar |
| **Agentes** | [AGENTS.md](AGENTS.md) — contrato operacional (idêntico a `.claude/CLAUDE.md`) |
| **RAG opcional** | [ADR-010](docs/architecture/adr-010-optional-rag-sqlite.md) + motor externo [rag-sqlite](https://github.com/elzobrito/rag-sqlite) |
| **Memory-TCG (RRR)** | [ADR-013](docs/architecture/adr-013-memory-tcg-rrr.md) — consolidação determinística em grafo (`off`/`shadow`/promoção explícita) |

---

## Instalação rápida

O pacote **ainda não está no npm** (`npm view conversation-esaa` responde 404).
`npx conversation-esaa@…` não funciona até a publicação. O caminho suportado
hoje é clonar o repositório e chamar a CLI:

```powershell
git clone https://github.com/elzobrito/conversation-esaa
cd conversation-esaa
node src/cli.js install --workspace <projeto> --agents grok,claude,codex,antigravity,cursor --non-interactive
node src/cli.js doctor --workspace <projeto>
```

Também é possível instalar um agente por vez:

```powershell
node src/cli.js install --workspace <projeto> --agent codex --non-interactive
node src/cli.js install --workspace <projeto> --agent claude --non-interactive
```

Use `--yes` no lugar de `--agents` para selecionar todos. O instalador mescla
configurações JSON existentes, não sobrescreve o histórico privado e falha
fechado quando encontra JSON inválido.

---

## O problema e a solução

Cada agente guarda a conversa em logs privados e incompatíveis. Copiar contexto manualmente é caro, incompleto e consome tokens em trabalho puramente mecânico.

O Conversation ESAA trata a memória como **event sourcing**:

```text
agente → hook/watcher → conversation-esaa sync
       → lock → append activity.jsonl → project → verify
       → handoff.md pronto para o próximo agente
```

| Artefato | Função |
|---|---|
| `activity.jsonl` | Fonte de verdade — append-only |
| `handoff.md` / `state.md` | Resumo para agente frio |
| `tasks.json` / `decisions.md` | Tarefas e decisões projetadas |
| `conversation-esaa.ps1` | CLI pública |
| `.conversation-esaa/rag/` (opt-in) | Projeção descartável (corpus + SQLite); nunca fonte canônica |
| `.conversation-esaa/memory/` (opt-in) | Grafo Memory-TCG, propostas RRR (`shadow`/`generations`) e projeção `active.json` |

### Busca semântica opcional

O instalador mantém o RAG desligado por padrão. Os modos são:

| Modo | Comportamento |
|---|---|
| `--rag off` | não instala nem habilita RAG |
| `--rag existing` | valida um `rag-sqlite` já instalado; aceite `--rag-command <path>` |
| `--rag managed` | baixa a release fixada, valida SHA-256 e habilita o adaptador |

```powershell
# a partir do clone deste repositório
node src/cli.js install --workspace <projeto> --agent codex --rag existing --rag-command /caminho/para/rag-sqlite --non-interactive
node src/cli.js install --workspace <projeto> --agent codex --rag managed --non-interactive
```

O RAG requer Python 3.10+, Ollama local e o modelo `embeddinggemma`. Ele é uma
projeção descartável e fail-open: `sync`, `project`, `verify` e `context`
continuam funcionando se o RAG estiver desligado ou indisponível.

### Consolidação periódica Memory-TCG / RRR — Como funciona o sonho e como sonhar

O **Memory-TCG** ([ADR-013](docs/architecture/adr-013-memory-tcg-rrr.md)) é o mecanismo de consolidação periódica de memória em grafo do Conversation ESAA. No vocabulário e na CLI do sistema, **"sonhar" (`conversation-esaa sonhar`, `conversation-esaa dream` ou `conversation-esaa memory sleep|sonhar|dream`)** significa executar offline o ciclo determinístico **RRR** (*Ringing*, *Resonance*, *Renormalization*) sobre o ledger `activity.jsonl`, com **zero chamadas de LLM, zero embeddings obrigatórios e zero acesso à rede**.

Eventos de curadoria gravam `actor: assistant`, inclusive quando acionados por operador; esse campo não comprova quem executou a operação. A escolha do workspace segue esta precedência: `--workspace` explícito; em uma instalação no diretório home, `GROK_WORKSPACE_ROOT` quando definido; caso contrário, a raiz da própria instalação. Uma variável herdada não redireciona silenciosamente uma instalação de projeto para outro workspace. O adaptador RAG chamado diretamente também usa a raiz da instalação por padrão, em vez do diretório corrente. Windows e caminhos por links simbólicos não foram validados nessa alteração.

Para informar o agente de uma operação de curadoria, use `--agent grok`, `--agent codex` ou outro identificador na CLI, inclusive em `memory sleep --accept`, `memory accept`, `memory rollback`, `task` e `topics`. O novo campo `agent_id_source` distingue identidade `declared` de `unknown`; declaração não é autenticação. Eventos antigos de tarefa, tópico e consolidação podem ter recebido uma identidade fixa do programa: seu `agent_id` não é prova de autoria. Para eventos de curadoria que exibe, `context` marca a origem antiga como `legacy_unverified` sem reescrever o histórico; ele não lista eventos `memory.*`.

`memory context --topic-id TOP-001` restringe a leitura aos vínculos explícitos da geração ativa; decisões globais sem vínculo ficam fora. O tópico deve existir na geração consultada e vínculos novos exigem outra consolidação. Compare os watermarks em `memory status`: um histórico que avançou pode conter informações ausentes da geração ativa. Zero conflitos detectados significa apenas que as heurísticas não sinalizaram conflitos.

Em `memory context`, `--max-per-section N` limita cada grupo de itens a um inteiro positivo escolhido pelo operador, sujeito também a `--budget-chars`. Sem a opção, permanecem os limites automáticos existentes (4 para decisões e conflitos em memórias grandes com orçamento de até 5000 caracteres, e limites próprios para outros grupos).

#### Como funciona o sonho (Ciclo RRR)

1. **Snapshot imutável e Watermark:**
   - O sonho lê `activity.jsonl` apenas do `workspace_root` atual, ignora eventos `memory.*` (evitando auto-reforço) e registra o `watermark_event_id` do último evento visto.
2. **Ringing (Amostragem Estratificada):**
   - Seleciona nós de forma determinística (controlada por `--seed`) cobrindo 100% das decisões explícitas (`decision`), tópicos (`TOP-xxx`), tarefas (`CONV-xxx`) e episódios conversacionais distribuídos por tópico e janela temporal (`YYYY-MM-DD`).
3. **Resonance (Ressonância e Fronteiras Epistêmicas):**
   - Separa rigorosamente **arestas derivadas verificadas (`derived_edges`)** — supersessão explícita (`explicit_supersedes`), suporte de decisão (`decision_supported_by_event`), vínculo de tópico (`topic_contains_event`) e duplicatas exatas por digest SHA-256 (`duplicate_exact_content`) — de **arestas candidatas (`possible_edges`)** — similaridade lexical (`possibly_related`) e contradições sem vencedor silencioso (`possibly_contradicts`). Arestas candidatas **nunca** sobrescrevem decisões explícitas.
4. **Renormalization (O que permanece vivo vs. Cold Storage):**
   - **`retain` (Memória Viva):** preserva decisões vigentes, tópicos ativos, tarefas abertas, evidências de decisões e os **assuntos tratados (`CONSOLIDATED_SUBJECT_MATTER`)** — incluindo os episódios substantivos de cada tópico ativo (`TOPIC_SUBJECT_EVIDENCE`), os episódios de maior ressonância temática (`RESONANT_SUBJECT_EPISODE`) e as âncoras recentes de cada janela de tempo (`SUBJECT_WINDOW_ANCHOR`).
   - **`group_exact_duplicates` (Assuntos Recorrentes):** agrupa turnos repetidos preservando todos os `event_id` de origem.
   - **`mark_historical_explicit` (Histórico Superado):** separa decisões explicitamente substituídas (`[HISTORICAL / SUPERSEDED]`) para que nenhum agente confunda decisão antiga com decisão vigente.
   - **`flag_conflict` / `unresolved` (Conflitos sem Vencedor Silencioso):** destaca divergências em aberto (`[UNRESOLVED CONFLICT]`) para revisão explícita.
   - **`deprioritize_in_active_view` (Proposta Esparsa / Cold Storage):** em stores grandes (`> 200` nós), os milhares de turnos rotineiros são contabilizados de forma esparsa (`deprioritized_implicit_count` + `deprioritized_implicit_digest`), mantendo a proposta em disco enxuta (~700 KB mesmo para ~17 mil eventos) sem duplicar o `activity.jsonl`.

#### Se um agente sonhar, todos os outros usufruem

Quando um sonho é promovido (`memory sleep --accept` ou `memory accept`):
- O evento auditável `memory.consolidation.accepted` é gravado em `activity.jsonl` e a visão ativa é materializada em `.conversation-esaa/memory/active.json`.
- O `conv-sync.ps1 project` injeta **automaticamente** a seção **`## Memory-TCG Consolidated Context (Active Generation)`** (contendo decisões vigentes, conflitos em aberto, decisões históricas superadas, tópicos/tarefas e **`### Consolidated Subjects Discussed (Assuntos Tratados)`**) diretamente em:
  - `.conversation-esaa/handoff.md`
  - `.conversation-esaa/state.md`
  - Saídas de `conversation-esaa pack` e `conversation-esaa context`
- Assim, **se o Grok (ou qualquer outro agente) sonhar e aceitar a consolidação, o Claude Code, Codex, Antigravity e Cursor recebem imediatamente os tópicos vivos e os assuntos tratados** assim que abrirem sessão ou lerem o `handoff.md`.

#### Como sonhar (Passo a Passo)

**Opção A — Sonhar e promover imediatamente (recomendado para uso entre agentes):**
Executa o ciclo RRR e promove a proposta no mesmo comando, evitando que um hook de fim de turno avance o `activity.jsonl` antes da promoção (`STALE_PROPOSAL`):

```powershell
# Usando o comando direto 'sonhar' (ou 'memory sleep --accept'):
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sonhar --accept --seed 42 --budget all --workspace $root --json
```

**Opção B — Sonhar em modo `shadow` (inspecionar antes de promover):**
Gera o grafo e a proposta em `.conversation-esaa/memory/shadow/` sem alterar `handoff.md`, `state.md` ou `activity.jsonl`:

```powershell
# 1. Sonhar em shadow (zero mutação na memória ativa)
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory sleep --mode shadow --seed 42 --budget all --workspace $root --json

# 2. Inspecionar a proposta ou comparar o diff contra a geração ativa
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory inspect --proposal-id latest --workspace $root --json
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory diff --proposal-id latest --workspace $root --json

# 3. Promover explicitamente (se o ledger não tiver avançado desde o sleep)
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory accept --proposal-id latest --workspace $root --json
```

> **Nota sobre `STALE_PROPOSAL`:** se novas mensagens entrarem em `activity.jsonl` depois do `memory sleep --mode shadow`, o `memory accept` recusa a proposta defasada por segurança. Basta rodar `memory sleep --accept` (ou um novo `memory sleep` seguido de `memory accept`) alinhado ao head atual.

**Consultas, verificação e rollback:**

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory status --workspace $root --json
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory context --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory context --topic-id TOP-001 --workspace $root --json
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory verify --workspace $root --json
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli memory rollback --generation-id previous --reason "Reverter geração" --workspace $root --json
```

---

## Instalação

### Pré-requisitos

- [Node.js 18+](https://nodejs.org/);
- [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows);
- Git, apenas para o fluxo normal do projeto.

### Caminho suportado hoje: clone + CLI

No diretório deste repositório:

```powershell
node src/cli.js install --workspace <projeto> --agents grok,claude --non-interactive
node src/cli.js status --workspace <projeto>
node src/cli.js doctor --workspace <projeto>
```

Para o Codex, o watcher é manual por padrão. Use
`--codex-service user` somente se quiser que o instalador crie uma unit systemd
de usuário no Linux ou uma Scheduled Task no Windows.

```powershell
node src/cli.js install --workspace <projeto> --agent codex --codex-service user --non-interactive
```

### Após publicação no npm

Quando `npm view conversation-esaa` deixar de devolver 404, o atalho passa a ser:

```powershell
npx conversation-esaa@1.3.1 install --workspace . --agents grok,claude --non-interactive
npx conversation-esaa@1.3.1 doctor --workspace .
```

Até lá, `npx conversation-esaa@…` falha com E404.

### Fallback PowerShell

Use este caminho quando `.conversation-esaa/bin/` já existir no projeto
(após um install pela CLI Node). O bootstrap sozinho grava hooks com o token
`pwsh`; o instalador Node (`node src/cli.js install`) é o writer canônico de
uma entrada por evento.

```powershell
$root = 'C:\caminho\do\seu\projeto'
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File ".\.conversation-esaa\bin\conv-bootstrap.ps1" `
  -WorkspaceRoot $root `
  -Agents codex,claude
```

O fallback pressupõe que `.conversation-esaa/bin/` já está disponível
localmente. O bootstrap cria o event store vazio, instala os scripts e gera
integrações com caminhos absolutos do workspace.

### Compatibilidade de opções PowerShell

A CLI pública aceita as opções GNU documentadas tanto com `pwsh -File` quanto
quando o script é chamado pelo operador `&` dentro de `pwsh -Command`.
Parâmetros com valor aceitam `--nome valor` e `--nome=valor`; switches como
`--json`, `--force` e `--purge` permanecem sem valor. A sintaxe PowerShell
nativa com um hífen continua compatível.

No caminho npm, o bootstrap instala o motor e o adaptador Node é o único
escritor das integrações. Instalações novas ou atualizadas convergem variantes
antigas para um único hook canônico por evento, preservando hooks alheios.
`conv-bootstrap.ps1` também faz parte do runtime registrado no manifesto e do
ciclo `status`/`doctor`/`repair`/`update`/`uninstall`.

### Ativar sync automático

**Grok**

```powershell
$cli = Join-Path $root '.conversation-esaa\bin\conversation-esaa.ps1'
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli enable-hooks --agent grok --workspace $root --trust
```

Depois: adicione o projeto em `~/.grok/trusted-hook-projects` e recarregue `/hooks` → `r`.

**Claude Code** — o bootstrap cria `.claude/settings.json`. Reabra a sessão e aprove os hooks.

Ao executar `enable-hooks` para Claude, mantenha outras edições de `settings.json` suspensas. O comando preserva configurações existentes e verifica alterações antes de substituir o arquivo, mas essa verificação não é uma transação com outros escritores. No Unix, a preservação de permissões exige runtime .NET com `File.GetUnixFileMode` e `File.SetUnixFileMode`; Windows não foi validado para essa alteração.

**Codex** — sem hook nativo; use o watcher:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli enable-hooks --agent codex --workspace $root --watcher
# ou manualmente:
pwsh -NoProfile -ExecutionPolicy Bypass -File "$root\.conversation-esaa\bin\codex-watch.ps1" -WorkspaceRoot $root
```

A seleção automática lê o `cwd` ou as raízes de workspace nos metadados da sessão e não usa um rollout de outro projeto como fallback. Para o workspace global da home, aceita projetos existentes dentro dela; caminhos relativos, com `..` ou links simbólicos abaixo da home não são selecionados automaticamente. Informe `-CodexSessionPath` quando for necessário escolher uma sessão explicitamente. Windows e caminhos UNC não foram validados nesta alteração.

**Google Antigravity** — o bootstrap mescla `conversation-esaa` em
`.agents/hooks.json`. Reinicie a CLI/IDE depois da instalação. Para ativar ou
reparar manualmente:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli enable-hooks --agent antigravity --workspace $root
```

O wrapper usa `conversationId`, `workspacePaths` e `transcriptPath` recebidos
via stdin. Como fallback, lê
`~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`.

**Cursor** — o instalador mescla `sessionStart`, `beforeSubmitPrompt` e
`afterAgentResponse` em `.cursor/hooks.json`. Recarregue os hooks do projeto.
Cloud Agents gerenciados pelo Cursor podem executar hooks de conversa, mas o
ledger e a configuração local de hooks não são transportados automaticamente
para um clone. A continuidade entre workspaces ou na nuvem não é garantida.
`sessionStart` e `pack` só lêem o ledger — não gravam em `activity.jsonl`.
A captura do texto do Cursor usa stdin entre processos, inclusive para mensagens longas. A interface `sync` também aceita `-CursorRole` e `-CursorPromptStdin`; não combine essa opção com `-CursorPrompt`. Como nas versões anteriores, espaços nas extremidades do texto são removidos na importação.
Quando o hook não fornece índice de mensagem, cada entrega é preservada: retries podem criar duplicatas, inclusive para respostas iguais da mesma geração. O `generation_id`, quando disponível, é registrado como metadado, mas não identifica cada resposta individual. Capturas por hook e por transcript sem identidade compartilhada podem coexistir como duplicatas; importações com índice explícito continuam deduplicadas. Eventos antigos diferentes que reutilizavam índices 0/1 voltam a aparecer nas projeções e no snapshot, sem reescrever o ledger. A atribuição de índices ocorre sob o lock existente; a revisão da corrida de liberação desse lock permanece aberta.

```powershell
node src/cli.js install --workspace $root --agent cursor --non-interactive
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli enable-hooks --agent cursor --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli pack --workspace $root --budget-tokens 4000
```

---

## Uso diário

```powershell
$root = 'C:\caminho\do\seu\projeto'
$cli  = Join-Path $root '.conversation-esaa\bin\conversation-esaa.ps1'

# Sincronizar após conversar
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync --agent grok --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync --agent antigravity --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync --agent cursor --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli pack --workspace $root --budget-tokens 4000

# Validar integridade
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli verify --workspace $root

# Ler contexto para handoff (outro agente ou nova sessão)
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli context --agent grok --last 20 --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli context --topic "autenticação" --last 5 --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli context --agent grok --last 5 --json --workspace $root

# Registrar decisão ou tarefa durável
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli decide -Decision "Usar JWT" -Rationale "stateless" --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli task create -Title "Implementar login" --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli task close CONV-001 -Evidence "tests pass" --workspace $root
```

Comandos adicionais: `context --before`, `--around`, `task update`, `project`. Rode `conversation-esaa.ps1 help` para a lista completa.

### Manutenção da instalação

```powershell
# a partir do clone
node src/cli.js status --workspace <projeto> --json
node src/cli.js doctor --workspace <projeto> --json
node src/cli.js update --workspace <projeto> --json
node src/cli.js repair --workspace <projeto> --json
node src/cli.js uninstall --workspace <projeto> --json
```

`update` e `repair` recusam substituir arquivos gerenciados modificados, salvo
com `--force`. `uninstall` remove apenas arquivos próprios intactos, desfaz as
entradas de hooks que reconhece e preserva `activity.jsonl`, projeções, decisões,
tarefas e dados RAG.

---

## Handoff entre agentes

Ao entrar sem contexto suficiente, trocar de agente ou receber um pedido de
retomada, leia primeiro `.conversation-esaa/handoff.md`. Ele é o ponto de
entrada para identificar o objetivo atual e o próximo passo.

Consulte `state.md`, `topics.md` / `topics.json`, `decisions.md` e `tasks.json`
somente quando faltarem, respectivamente, estado recente, assunto ativo,
decisões vigentes ou pendências conversacionais. Se ainda houver lacunas ou
contradições, use `context --last 20`; acrescente `--topic-id TOP-xxx` quando o
tópico estiver identificado e `--agent <id>` somente para restringir por agente.

Se o handoff estiver ausente, vazio ou inconsistente, execute `verify`. Não
edite as projeções à mão; toda escrita passa pela CLI (`sync`, `decide`,
`task`, `topics`, `project`). Após a leitura, enuncie brevemente o objetivo e o
próximo passo, prossiga quando estiverem claros e peça esclarecimento apenas
quando houver uma decisão pendente do usuário.

---

## Privacidade

O `activity.jsonl` grava o **texto literal** das suas conversas. O pacote npm
contém somente runtime e documentação pública; não contém logs, projeções,
bancos locais ou credenciais. O `.gitignore` exclui dados sensíveis gerados,
mas **confira antes de qualquer `git push`**. Detalhes em
[PRIVACY.md](PRIVACY.md).

## Limites operacionais

- O Conversation ESAA é memória e handoff; governança de tarefas
  `claim/complete/review` pertence ao ESAA Core.
- O instalador não configura confiança ou aprova hooks em nome do usuário.
- O Codex não possui hook nativo neste produto; depende do watcher.
- O modo RAG gerenciado requer rede durante a instalação e não instala Ollama.
- Dados privados não devem ser versionados, mesmo quando o `.gitignore` os cobre.

---

## Testes

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test-battery.ps1 -SkipLab -SkipEsaa
```

A bateria inclui as suítes sintéticas de memória quando os testes do repositório estão disponíveis; em instalações sem esses arquivos, informa `SKIP memory_e2e`. Use `-SkipMemory` para omiti-las explicitamente.

---

## Documentação

| Recurso | Conteúdo |
|---|---|
| [PRIVACY.md](PRIVACY.md) | Modelo de privacidade e redação |
| [RELEASE.md](RELEASE.md) | Notas da v1.3.1 e versões anteriores |
| [ADR-013](docs/architecture/adr-013-memory-tcg-rrr.md) | Arquitetura do Memory-TCG e consolidação RRR |
| [Artigo RRR v1.3.1](documentacao-tecnica/DC-consolidacao-memoria-agentes-v1.3.1.md) | Avaliação sintética exploratória, comparadores e limitações; não reproduzida independentemente |
| [CONV-MTCG-BENCHMARK.md](docs/qa/CONV-MTCG-BENCHMARK.md) | Benchmark inicial histórico; interpretações revistas no artigo |
| `.conversation-esaa/plans/` | System design, ADRs, plano de implementação |


---

## Estrutura

```text
seu-projeto/
  LICENSE  README.md  PRIVACY.md
  .conversation-esaa/
    bin/                 # scripts PowerShell
    plans/               # design e ADRs
    tests/fixtures/      # dados sintéticos de teste
    run/.gitkeep
    activity.jsonl       # gerado — não commitar
  .grok/hooks/           # gerado pelo bootstrap
  .claude/settings.json  # gerado pelo bootstrap
  .agents/hooks.json     # hook Google Antigravity gerado/mesclado pelo bootstrap
```

---

## Licença

MIT — veja [LICENSE](LICENSE).
