# Release v1.1.1 — Conversation ESAA

Build de manutenção após ADR-009. Pacote **greenfield**: sem histórico de
conversas, `activity.jsonl` vazio após bootstrap.

## Escopo

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
