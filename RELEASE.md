# Release notes — Conversation ESAA

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
