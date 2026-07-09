# AGENTS.md — Conversation ESAA

> **Contrato único para todos os harnesses.**  
> Este arquivo e `.claude/CLAUDE.md` são **idênticos**. Qualquer mudança deve
> atualizar os dois (no commit: `diff AGENTS.md .claude/CLAUDE.md` vazio).  
> Em divergência com skills ou resumos locais, **este contrato do repo prevalece**
> para o produto Conversation ESAA.

## 1. O que é / o que não é

| | |
|---|---|
| **É** | Memória conversacional + handoff entre agentes (event sourcing de turnos) |
| **Não é** | Runtime de tarefas de código (claim/complete/review) — isso é **ESAA-Core** |
| **Versão** | v1.1.x |
| **CLI** | PowerShell 7 (`pwsh`) — `conversation-esaa.ps1` / `conv-sync.ps1` |

## 2. Harness

Grok (`AGENTS.md`), Claude Code (`.claude/CLAUDE.md`), Codex e outros devem
seguir as **mesmas** regras, paths, CLI e fail-closed.

Mecanismos de **captura** (hooks vs watcher) diferem; o **contrato operacional** não.

## 3. Paths

| Papel | Path |
|-------|------|
| Repo do produto | este repositório (`conversation-esaa`) |
| Workspace global (conversas soltas) | `~/.conversation-esaa/` sob o home do usuário |
| Workspace de projeto | `<projeto>/.conversation-esaa/` |
| CLI pública | `.conversation-esaa/bin/conversation-esaa.ps1` |
| Motor | `conv-sync.ps1`, `conv-bootstrap.ps1`, `codex-watch.ps1` |

Não trate o diretório de **dados** (`~/.conversation-esaa/`) como o repo do produto.
Não copie este `AGENTS.md` para data dirs no bootstrap/rollout.

## 4. Fontes de verdade — não editar à mão

```text
hook/watcher → sync → lock → append activity.jsonl → project → verify → handoff
```

| Artefato | Papel | Edição manual |
|----------|--------|----------------|
| `activity.jsonl` | event store (append-only) | **proibida** |
| `state.md`, `handoff.md`, `decisions.md`, `tasks.json`, `topics.md` | projeções | **proibida** |
| `topics.json` | memória por assuntos | só via CLI `topics` |
| `sync-state.json` | dedupe (reconstruível) | não editar |
| `bin/`, `plans/`, README, PRIVACY, RELEASE | código/docs do produto | ok **neste repo** |

## 5. Handoff — ordem para agente frio

1. `handoff.md`
2. `state.md`
3. `topics.md` / `topics.json`
4. `decisions.md`
5. `tasks.json`
6. Se precisar: `context --agent <id> --last N` ou `--topic-id TOP-xxx`

Não reconstruir contexto lendo o `activity.jsonl` inteiro sem filtro.

## 6. CLI canônica

```powershell
$root = '<workspace-com-.conversation-esaa>'
$cli  = Join-Path $root '.conversation-esaa/bin/conversation-esaa.ps1'
$pwsh = if (Test-Path "$HOME/.local/bin/pwsh") { "$HOME/.local/bin/pwsh" } else { 'pwsh' }

& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli verify  -Workspace $root
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync    --agent grok  -Workspace $root
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync    --agent codex -Workspace $root
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli sync    --agent claude -Workspace $root
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli project -Workspace $root
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli context --last 20 -Workspace $root
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli decide  "..." -Workspace $root
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli task create "..." -Workspace $root
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $cli topics list -Workspace $root
```

Detalhes de install/hooks: [README.md](README.md).

## 7. Captura por agente

| Agente | Mecanismo |
|--------|-----------|
| Grok | hooks + projeto em trusted-hook-projects; recarregar hooks após mudar trust |
| Claude | hooks em `.claude/settings.json` (aprovação no projeto) |
| Codex | `codex-watch.ps1` (poll) e/ou unit systemd user — sem hook nativo |

## 8. Topics (ADR-009)

- Criar / atualizar / linkar / fechar **somente** via `topics`.
- Assuntos = memória intermediária; **não** substituem decisions/tasks.
- Fechar tópicos resolvidos com evidence; manter `active` só fios vivos.
- Linkar `event_id` quando houver evidência útil no log.

## 9. Regras duras (fail closed)

1. Não editar `activity.jsonl` nem read models à mão.
2. Não tratar `.conversation-esaa` como `.roadmap`.
3. Não inventar histórico nem “consertar” o log com editor.
4. Em dúvida: `verify` e parar.
5. Segredos colados na conversa ficam em texto puro — ver [PRIVACY.md](PRIVACY.md).
6. Mudança em `bin/`: não apagar estado privado dos workspaces; rollout só de motor/docs públicas (`bin/`, `plans/`, PRIVACY, RELEASE).

## 10. Operação Linux — unit do codex-watch (regra, não reabrir fix)

Lição já aplicada no ambiente do usuário (item codex-watch / opção A):

- Unit típico: `~/.config/systemd/user/conversation-esaa-codex-watch.service`
- systemd **não** usa o `PATH` do shell interativo.
- **Nunca** `ExecStart=/usr/bin/pwsh` se o install for user-local.
- Use path **absoluto** do `pwsh` real, ex.: `/home/<user>/.local/bin/pwsh`
- Recomendado: `ConditionPathExists=` no mesmo path; `Restart=on-failure` (evitar loop agressivo)
- **Não** “consertar” com `ln -s` em `/usr` nem segundo install só pelo path

## 11. Privacidade e git

**Versionar:** `bin/`, `plans/`, docs públicas, fixtures sintéticas, este contrato.

**Não versionar:** `activity.jsonl`, `handoff.md`, `state.md`, `sync-state.json` com conversas reais.

## 12. Checklist ao mudar o motor

- [ ] `verify` em workspace de teste
- [ ] testes relevantes (`conv-test*`) se `conv-sync` mudou
- [ ] compat com legado (ex.: `rationale` vazio em decisões antigas)
- [ ] README/RELEASE se CLI ou schema mudou
- [ ] `diff AGENTS.md .claude/CLAUDE.md` → vazio

## 13. ESAA-Core neste repo (somente `.roadmap/`)

Se o trabalho for **governança de implementação** neste repositório (tarefas de código):

- CLI: `python -m esaa --root .`
- Ciclo: `todo` → `claim` → `complete` → `review` → `done`
- Não editar `.roadmap/activity.jsonl` nem projeções à mão
- Emitir intenção válida; Orchestrator é single writer
- **Não misturar** com `conversation_turn` / `topics` / `decide` do Conversation ESAA
- Contratos canônicos: `.roadmap/AGENT_CONTRACT.yaml`, `ORCHESTRATOR_CONTRACT.yaml`, `RUNTIME_POLICY.yaml`

Conversation ESAA e ESAA-Core **coexistem**; domínios separados.
