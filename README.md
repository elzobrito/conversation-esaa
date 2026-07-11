 Conversation ESAA

**Memória conversacional compartilhada entre agentes de IA** — Grok, Codex, Claude Code e Google Antigravity.

Quando você troca de agente ou a janela de contexto acaba, o próximo assistente perde objetivos, decisões e tarefas abertas. O Conversation ESAA captura os turnos visíveis automaticamente (hooks e watchers), grava em um log append-only local e projeta read models compactos para handoff — **sem gastar tokens do LLM na cópia mecânica**.

| | |
|---|---|
| **Versão** | v1.1.0 |
| **Plataforma** | Windows + PowerShell 7 (`pwsh`) |
| **Licença** | MIT |
| **Privacidade** | [PRIVACY.md](PRIVACY.md) — leia antes de versionar |
| **Agentes** | [AGENTS.md](AGENTS.md) — contrato operacional (idêntico a `.claude/CLAUDE.md`) |

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

---

## Instalação

**Pré-requisito:** [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)

```powershell
$root = 'C:\caminho\do\seu\projeto'
New-Item -ItemType Directory -Force -Path $root | Out-Null

# Copie .conversation-esaa/ para $root (ou clone este repositório)
pwsh -NoProfile -ExecutionPolicy Bypass -File "$root\.conversation-esaa\bin\conv-bootstrap.ps1" -WorkspaceRoot $root
```

O bootstrap cria `activity.jsonl` **vazio**, instala os scripts e gera hooks com caminhos do **seu** workspace.

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

O `activity.jsonl` grava o **texto literal** das suas conversas. O `.gitignore` já exclui dados sensíveis, mas **confira antes de qualquer `git push`**. Detalhes em [PRIVACY.md](PRIVACY.md).

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
| [RELEASE.md](RELEASE.md) | Notas da v1.1.0 |
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
