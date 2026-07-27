# Release notes — Conversation ESAA

## v1.3.1 — opções portáveis e instalador convergente

Release de correção do primeiro candidato npm. A publicação pública só deve ser
considerada disponível depois da evidência registrada pela tarefa
`CONV-INSTALL-PUBLISH-002`.

### Correções

- opções GNU da CLI PowerShell funcionam igualmente por `pwsh -File` e pelo
  operador `&` em `pwsh -Command`;
- parâmetros com valor aceitam `--nome valor` e `--nome=valor`, com conversão
  tipada, aliases e erros explícitos;
- o caminho npm usa um único escritor de hooks e converge variantes antigas sem
  remover integrações alheias;
- `conv-bootstrap.ps1` é instalado, registrado no manifesto e participa de
  `status`, `doctor`, `repair`, `update` e `uninstall`;
- `package.json` é a única fonte da versão `1.3.1` para CLI, resultado do
  instalador e manifesto.

```powershell
npx conversation-esaa@1.3.1 install `
  --workspace . `
  --agents grok,claude,codex,antigravity `
  --non-interactive

npx conversation-esaa@1.3.1 doctor --workspace .
```

### Verificação

- matriz Ubuntu/Windows com Node.js 20/22 e PowerShell 7;
- suíte npm, bootstrap, opções longas, motor legado e contratos RAG;
- instalação e upgrade a partir do `.tgz`, incluindo hooks antigos;
- inspeção do tarball para excluir logs, projeções, SQLite, credenciais e
  configuração local;
- `AGENTS.md` e `.claude/CLAUDE.md` byte-idênticos.

---

## v1.3.0 — instalador npm e ciclo de vida

Release candidata validada em Ubuntu e Windows com Node.js 20/22 e
PowerShell 7.

### Instalação principal

```powershell
npx conversation-esaa@1.3.0 install `
  --workspace . `
  --agents grok,claude,codex,antigravity `
  --non-interactive

npx conversation-esaa@1.3.0 doctor --workspace .
```

O pacote aceita seleção repetível com `--agent`, lista com `--agents` ou todos
com `--yes`. O fallback continua disponível por
`.conversation-esaa/bin/conv-bootstrap.ps1`.

### Entregas

| Área | Entrega |
|---|---|
| Installer | CLI Node/npm com `install`, `status`, `doctor`, `update`, `repair` e `uninstall` |
| Agentes | Grok, Claude Code, Codex e Google Antigravity, isolados ou combinados |
| Codex | watcher manual por padrão; serviço de usuário explícito com `--codex-service user` |
| RAG | `off`, `existing` e `managed`; release fixada com SHA-256 |
| Segurança | execução sem shell, validação de ZIP/checksum/schema e rejeição de traversal/symlink |
| Preservação | hooks JSON mesclados; histórico e projeções privadas nunca removidos no uninstall |
| QA | pacote `.tgz` instalado em workspaces limpos; matriz Ubuntu/Windows Node 20/22 |

### Ciclo de vida

```powershell
npx conversation-esaa@1.3.0 status --workspace . --json
npx conversation-esaa@1.3.0 doctor --workspace . --json
npx conversation-esaa@1.3.0 update --workspace . --json
npx conversation-esaa@1.3.0 repair --workspace . --json
npx conversation-esaa@1.3.0 uninstall --workspace . --json
```

`update` e `repair` exigem `--force` para substituir arquivos próprios que
sofreram modificação. `uninstall` preserva o event store, read models,
decisões, tarefas e o diretório RAG.

### RAG e limites

- `--rag off`: padrão, sem RAG;
- `--rag existing`: usa um comando local validado;
- `--rag managed`: baixa `rag-sqlite` v0.1.0 e valida a release publicada;
- Ollama e `embeddinggemma` continuam dependências locais e não são instalados;
- confiança e aprovação dos hooks continuam ações humanas;
- Conversation ESAA não substitui a governança de tarefas do ESAA Core.

### Privacidade e conteúdo do pacote

O tarball publica somente `src/`, scripts públicos em
`.conversation-esaa/bin/`, `LICENSE` e `PRIVACY.md`. Logs, event stores,
projeções, bancos SQLite, credenciais e configurações locais não fazem parte do
pacote.

---

## v1.2.0 (opt-in RAG)

Integração **opcional** com motor externo [rag-sqlite](https://github.com/elzobrito/rag-sqlite)
para busca semântica sobre o histórico. Não embute o motor Python; não substitui
`context`/`topics` determinísticos; não altera `activity.jsonl`.

| Área | Entrega |
|---|---|
| ADR | `docs/architecture/adr-010-optional-rag-sqlite.md` |
| CLI | `rag enable\|status\|refresh\|disable\|disable --purge`, `search` |
| Adapter | `conv-rag.ps1` — export 1 arquivo/evento, worker, search v1 |
| Pipeline | dirty marker assíncrono após project/verify (fail-open) |
| Privacidade | `.conversation-esaa/rag/` gitignored; 0700/0600 no Unix |
| Schema | `conversation-esaa.search.v1` |

**Dependências não instaladas automaticamente:** Python 3.10+, `rag-sqlite` no
PATH, Ollama local (`embeddinggemma` default). URL remota de Ollama é rejeitada.

```powershell
# enable + first index (may take minutes)
conversation-esaa rag enable --workspace /home/elzobrito
conversation-esaa rag refresh --workspace /home/elzobrito
conversation-esaa search "TOP-011 RAG" --workspace /home/elzobrito
```

---

## v1.1.1

Build de manutenção após ADR-009. Pacote **greenfield**: sem histórico de
conversas, `activity.jsonl` vazio após bootstrap.

## Escopo v1.1

| Área | Entrega |
|---|---|
| CLI | `conversation-esaa.ps1` — `init`, `enable-hooks`, `sync`, `project`, `verify`, `context`, `decide`, `task` |
| Motor | `conv-sync.ps1` — lockfile, `workspace_root`, projeções |
| Antigravity | parser `USER_INPUT`/`PLANNER_RESPONSE`, `--agent antigravity` e hooks fail-open |
| Tópicos | `topics list/show/create/update/link/close`, `topics.json`, `topics.md` |
| Contexto | `--last`, `--before`, `--around`, `--agent`, `--topic`, `--topic-id`, `--json` |
| Testes | `conv-test.ps1` e `conv-test-battery.ps1`, incluindo fixture sintética Antigravity |
| Docs | `README.md`, `PRIVACY.md`, `paper/`, `.conversation-esaa/plans/` |

## Verificação

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .conversation-esaa\bin\conv-test-battery.ps1 -SkipLab -SkipEsaa
```

## Privacidade

Leia [PRIVACY.md](PRIVACY.md) antes de publicar seu workspace. Nunca commite `activity.jsonl` ou read models gerados.

## Licença

MIT — veja [LICENSE](LICENSE).
