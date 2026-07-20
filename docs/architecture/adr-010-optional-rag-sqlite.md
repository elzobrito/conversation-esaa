# ADR-010 — Incorporação opcional do rag-sqlite (Conversation ESAA v1.2)

**Status:** Aceito  
**Data:** 2026-07-20  
**Fonte:** [docs/plans/v1.2-optional-rag-sqlite.md](../plans/v1.2-optional-rag-sqlite.md)

## Contexto

O Conversation ESAA tem projeção determinística (`project`/`context`/`topics`) e
busca textual limitada. O piloto com `rag-sqlite` + Ollama `embeddinggemma` +
sqlite-vec mostrou busca semântica útil sobre o histórico sem alterar o event store.

## Decisão

1. **Opt-in v1.2:** `conversation-esaa rag enable` habilita o adaptador.
2. **Motor externo:** reutilizar `rag-sqlite` no PATH (ou `--command`); **não**
   embutir cópia do motor Python no produto.
3. **Projeção descartável:** `.conversation-esaa/rag/` (corpus, SQLite, manifesto,
   locks, logs). Nunca escreve em `activity.jsonl` nem substitui `verify`.
4. **Export canônico:** um Markdown por `event_id` derivado só de `activity.jsonl`.
   Não indexar `state.md` / `handoff.md` / decisões / tópicos (duplicariam eventos).
5. **Ollama local only:** `http://127.0.0.1` / `localhost` / `::1`; modelo default
   `embeddinggemma`. URL remota → rejeição na v1.2.
6. **Atualização assíncrona:** após `project`+`verify` bem-sucedidos, dirty marker +
   worker one-shot (debounce 10s). Hooks não executam embeddings.
7. **Search:** `conversation-esaa search` → JSON `conversation-esaa.search.v1`.
   Hits reidratados do `activity.jsonl` por `event_id`. Sem geração →
   `RagNotReady` / `RagUnavailable` (sem fallback textual silencioso).
8. **Fail-open no pipeline:** sync/project/verify/decide/task/topic funcionam
   com RAG ausente ou quebrado. `verify` não consulta rede RAG.

## Consequências

- Dependências opcionais: Python 3.10+, `rag-sqlite`, Ollama local, opcionalmente sqlite-vec.
- Índice por workspace; stores congelados não são reativados automaticamente.
- Ampliação de superfície de testes e diagnóstico; privacidade reforçada (0700/0600, gitignore).

## Alternativas rejeitadas

| Alternativa | Motivo da rejeição |
|-------------|-------------------|
| Embutir embeddings no lock de sync | Aumenta latência do hook e risco de falha do pipeline principal |
| Indexar read models | Duplica relevância e quebra 1:1 com event_id |
| Substituir `context --topic` | Perde caminho offline determinístico |
| Ollama remoto na v1.2 | Amplia superfície de segurança e privacidade |

## Contratos relacionados

- CLI: [docs/contracts/rag-cli-v1.2.md](../contracts/rag-cli-v1.2.md)
- Schema: [docs/contracts/conversation-esaa.search.v1.schema.json](../contracts/conversation-esaa.search.v1.schema.json)
