 Conversation ESAA

**Memória conversacional compartilhada entre agentes de IA** — Grok, Codex, Claude Code e Google Antigravity.

Quando você troca de agente ou a janela de contexto acaba, o próximo assistente perde objetivos, decisões e tarefas abertas. O Conversation ESAA captura os turnos visíveis automaticamente (hooks e watchers), grava em um log append-only local e projeta read models compactos para handoff — **sem gastar tokens do LLM na cópia mecânica**.

| | |
|---|---|
| **Versão** | v1.3.1 (instalador npm + RAG opt-in) |
| **Plataforma** | Windows e Linux; Node.js 18+ e PowerShell 7 (`pwsh`) |
| **Licença** | MIT |
| **Privacidade** | [PRIVACY.md](PRIVACY.md) — leia antes de versionar |
| **Agentes** | [AGENTS.md](AGENTS.md) — contrato operacional (idêntico a `.claude/CLAUDE.md`) |
| **RAG opcional** | [ADR-010](docs/architecture/adr-010-optional-rag-sqlite.md) + motor externo [rag-sqlite](https://github.com/elzobrito/rag-sqlite) |

---

## Instalação rápida

No diretório do projeto, selecione os agentes e deixe o instalador configurar
runtime, hooks, watcher e manifesto:

```powershell
npx conversation-esaa@1.3.1 install `
  --workspace . `
  --agents grok,claude,codex,antigravity `
  --non-interactive

npx conversation-esaa@1.3.1 doctor --workspace .
```

Também é possível instalar um agente por vez:

```powershell
npx conversation-esaa@1.3.1 install --workspace . --agent codex --non-interactive
npx conversation-esaa@1.3.1 install --workspace . --agent claude --non-interactive
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

### Busca semântica opcional

O instalador mantém o RAG desligado por padrão. Os modos são:

| Modo | Comportamento |
|---|---|
| `--rag off` | não instala nem habilita RAG |
| `--rag existing` | valida um `rag-sqlite` já instalado; aceite `--rag-command <path>` |
| `--rag managed` | baixa a release fixada, valida SHA-256 e habilita o adaptador |

```powershell
npx conversation-esaa@1.3.1 install `
  --workspace . `
  --agent codex `
  --rag existing `
  --rag-command /caminho/para/rag-sqlite `
  --non-interactive

# ou instalação gerenciada da release fixada
npx conversation-esaa@1.3.1 install --workspace . --agent codex --rag managed --non-interactive
```

O RAG requer Python 3.10+, Ollama local e o modelo `embeddinggemma`. Ele é uma
projeção descartável e fail-open: `sync`, `project`, `verify` e `context`
continuam funcionando se o RAG estiver desligado ou indisponível.

---

## Instalação

### Pré-requisitos

- [Node.js 18+](https://nodejs.org/);
- [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows);
- Git, apenas para o fluxo normal do projeto.

### Caminho recomendado: npx

```powershell
npx conversation-esaa@1.3.1 install --workspace . --agents grok,claude --non-interactive
npx conversation-esaa@1.3.1 status --workspace .
npx conversation-esaa@1.3.1 doctor --workspace .
```

Para o Codex, o watcher é manual por padrão. Use
`--codex-service user` somente se quiser que o instalador crie uma unit systemd
de usuário no Linux ou uma Scheduled Task no Windows.

```powershell
npx conversation-esaa@1.3.1 install `
  --workspace . `
  --agent codex `
  --codex-service user `
  --non-interactive
```

### Fallback PowerShell

Use este caminho para desenvolvimento a partir de um clone ou quando npm/npx
não estiver disponível:

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

**Codex** — sem hook nativo; use o watcher:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli enable-hooks --agent codex --workspace $root --watcher
# ou manualmente:
pwsh -NoProfile -ExecutionPolicy Bypass -File "$root\.conversation-esaa\bin\codex-watch.ps1" -WorkspaceRoot $root
```

**Google Antigravity** — o bootstrap mescla `conversation-esaa` em
`.agents/hooks.json`. Reinicie a CLI/IDE depois da instalação. Para ativar ou
reparar manualmente:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli enable-hooks --agent antigravity --workspace $root
```

O wrapper usa `conversationId`, `workspacePaths` e `transcriptPath` recebidos
via stdin. Como fallback, lê
`~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`.

---

## Uso diário

```powershell
$root = 'C:\caminho\do\seu\projeto'
$cli  = Join-Path $root '.conversation-esaa\bin\conversation-esaa.ps1'

# Sincronizar após conversar
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync --agent grok --workspace $root
pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync --agent antigravity --workspace $root

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
npx conversation-esaa@1.3.1 status --workspace . --json
npx conversation-esaa@1.3.1 doctor --workspace . --json
npx conversation-esaa@1.3.1 update --workspace . --json
npx conversation-esaa@1.3.1 repair --workspace . --json
npx conversation-esaa@1.3.1 uninstall --workspace . --json
```

`update` e `repair` recusam substituir arquivos gerenciados modificados, salvo
com `--force`. `uninstall` remove apenas arquivos próprios intactos, desfaz as
entradas de hooks que reconhece e preserva `activity.jsonl`, projeções, decisões,
tarefas e dados RAG.

---

## Handoff entre agentes

Quando um agente novo entra no projeto, leia nesta ordem:

1. `.conversation-esaa/handoff.md`
2. `.conversation-esaa/state.md`
3. `.conversation-esaa/decisions.md`
4. `.conversation-esaa/tasks.json`

**Regra:** não edite esses arquivos à mão. Toda escrita passa pela CLI (`sync`, `decide`, `task`).

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

---

## Documentação

| Recurso | Conteúdo |
|---|---|
| [PRIVACY.md](PRIVACY.md) | Modelo de privacidade e redação |
| [RELEASE.md](RELEASE.md) | Notas da v1.3.1 e versões anteriores |
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
