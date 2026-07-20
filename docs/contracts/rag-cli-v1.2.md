# Contrato CLI — Conversation ESAA RAG (v1.2)

## Comandos

```text
conversation-esaa rag enable [--workspace PATH] [--command PATH]
  [--base-url URL] [--model NAME] [--timeout SECONDS]

conversation-esaa rag status [--workspace PATH] [--json]
conversation-esaa rag refresh [--workspace PATH] [--force]
conversation-esaa rag disable [--workspace PATH] [--purge]

conversation-esaa search "consulta" [--workspace PATH]
  [--top-k N] [--min-score F] [--json]
```

Defaults de search: `top_k=5`, `min_score=0.25`.

## Protocolo do processo `rag-sqlite` (adaptador)

O adaptador (`conv-rag.ps1`) invoca `rag-sqlite` capturando **stdout e stderr em streams separados**.

| Campo | Regra |
|-------|--------|
| stdout | Única fonte de payload; deve ser JSON válido |
| stderr | Diagnóstico local; **nunca** é concatenado ao payload nem reemitido integralmente na API pública |
| exit 0 | Sucesso somente se JSON com `ok=true` |
| exit 2 | Sucesso **somente** para index vazio: `schema_version=rag_sqlite.index.v1`, `ok=true`, `totals.files=0` |
| outros exits | `RagCommandFailed` |
| stdout vazio / JSON inválido | `RagProtocolError` |
| JSON com `ok=false` | `RagCommandFailed` |

Erros públicos tipados (sem dump de stdout/stderr):

| type | Quando |
|------|--------|
| `RagProtocolError` | stdout vazio ou não-JSON |
| `RagCommandFailed` | exit não permitido, ou `ok=false` |
| `RagUnavailable` | RAG desabilitado / binário ausente |
| `RagNotReady` | sem geração utilizável |
| `WorkerBusy` | lock do worker ocupado |
| `PermissionHardeningFailed` | falha de chmod no endurecimento Unix (v1.2 hotfix) |

### Exit codes públicos do adaptador / CLI

| Ação | Sucesso | Falha |
|------|---------|-------|
| `rag enable` / `rag refresh` / `rag disable` / `rag status` | 0 | **1** (erro tipado em JSON com `--json`) |
| `search` | 0 | **2** (sempre JSON `conversation-esaa.search.v1` com `ok=false`) |
| `worker` / `schedule` | 0 | 0 fail-open (não bloqueia sync/project/hooks) |

### Enable

1. Resolve `rag-sqlite` via PATH ou `--command` (grava path absoluto).
2. Valida `rag-sqlite schema query`.
3. Exige Ollama loopback (`127.0.0.1`, `localhost`, `::1`).
4. Executa **todos** os `config set*` com sucesso **antes** de publicar `config.json`.
5. Falha parcial **não** substitui configuração válida pré-existente.
6. Configura DB em `.conversation-esaa/rag/index.sqlite` com:
   - `index_root` = corpus
   - `allowed_hosts` = `127.0.0.1,localhost,::1`
   - `allow_symlinks` = false
   - `vector_backend` = auto
   - `embedding_provider` = ollama
   - `embedding_model` default `embeddinggemma`
7. Marca enabled e agenda refresh (dirty marker).

### Refresh

- Export + `rag-sqlite index --sync --prune` (`--force` → `reindex --force` quando aplicável).
- Sucesso: atualiza `state.json` (`activity_lines`, `last_generation_id`, limpa dirty se estável).
- Falha: **preserva** `activity_lines` / geração anterior, mantém/restaura dirty marker, grava `last_error` tipado, retorna `ok=false` e exit **1**.

### Disable

- Default: `enabled=false`, preserva rag/.
- `--purge`: remove `.conversation-esaa/rag/` reconstruível.

### Search

- Schema: `conversation-esaa.search.v1`
- Hits dedupe por `event_id`
- Snippet untrusted; metadados reidratados de `activity.jsonl`
- `stale:true` se dirty ou lag > 0 com geração válida
- Sem índice / indisponível: erro tipado (`RagNotReady` / `RagUnavailable` / `RagProtocolError` / `RagCommandFailed`) e exit **2**

## Layout em disco

```text
.conversation-esaa/rag/
  config.json
  index.sqlite
  corpus/<prefix2>/<event_id>.md
  manifest.json
  dirty.marker
  worker.lock
  logs/worker.log
  state.json
```

Unix: diretórios `0700`, arquivos regulares `0600` (recursivo, sem seguir symlinks). Gitignored por completo (`.conversation-esaa/rag/`).
