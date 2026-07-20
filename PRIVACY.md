# Aviso de Privacidade — Conversation ESAA

> **Resumo em uma linha:** esta ferramenta grava o **texto literal** das suas
> conversas com agentes de IA em arquivos locais. Trate `.conversation-esaa/`
> como dado sensível.

## O que é gravado

O `conv-sync.ps1` lê os logs nativos dos agentes (Grok, Codex, Claude Code e Google Antigravity) e
copia o **conteúdo visível** das mensagens — suas perguntas e as respostas dos
assistentes — para:

| Arquivo | Conteúdo |
|---|---|
| `.conversation-esaa/activity.jsonl` | Texto **completo** de cada turno (campo `text`), mais um resumo de 200 caracteres. |
| `.conversation-esaa/state.md` | Resumos dos últimos eventos (texto das conversas). |
| `.conversation-esaa/handoff.md` | Estado projetado, incluindo trechos de conversa. |
| `.conversation-esaa/sync-state.json` | Apenas hashes de deduplicação (sem texto). |
| `.conversation-esaa/rag/` (opt-in v1.2) | Corpus Markdown derivado de eventos, SQLite de embeddings, logs e locks. **Projeção descartável** — não é fonte canônica. |

## O que **não** é gravado

Por design, o sync **pula**: raciocínio interno (`thinking`/reasoning),
saídas de ferramentas (`tool_use`/`tool_result`), prompts de sistema,
contexto de ambiente e sub-agentes (sidechains). No Antigravity, entram apenas
`USER_INPUT` e `PLANNER_RESPONSE` textual com `status=DONE`; respostas que
contêm somente `tool_calls` são ignoradas. Só entra texto visível da conversa.

## Riscos

- **Vazamento por commit.** Se você versionar e publicar este diretório, estará
  publicando suas conversas inteiras. O [`.gitignore`](.gitignore) já exclui os
  arquivos de dados, mas **confira antes de qualquer `git push`**.
- **Segredos coladados na conversa.** Se você colou uma senha, token ou chave
  numa mensagem, ela está no `activity.jsonl` em texto puro. Limpe a linha
  correspondente e rode `verify`.
- **Dados de terceiros.** Conversas podem conter nomes, e-mails e caminhos de
  máquina. Considere isso antes de compartilhar o arquivo.

## Recomendações

1. **Nunca** commite `activity.jsonl`, `state.md`, `handoff.md`,
   `sync-state.json` ou o diretório **`.conversation-esaa/rag/`** em repositório
   público (o `.gitignore` cuida disso). O RAG duplica trechos de conversa em
   embeddings e corpus local; trate com o mesmo rigor de credenciais.
2. Antes de compartilhar o lab, rode uma revisão por segredos no
   `activity.jsonl`.
3. Mantenha o diretório `.conversation-esaa/` com as mesmas permissões que você
   daria a um arquivo de credenciais.
4. Para apagar um turno: remova a linha do `activity.jsonl`, rode
   `conversation-esaa project` e depois `verify` (o `sync-state.json` é
   reconstruído a partir do log).

## Modelo v1.1 (append-only + export)

- **`activity.jsonl` é a fonte de verdade local** — append-only via CLI
  (`sync`, `decide`, `task`). Não há edição manual no fluxo público.
- **Redação não muta o log local.** Exportações públicas devem usar um
  derivado redigido ou log vazio (bootstrap greenfield); o arquivo local
  permanece intacto até você editar explicitamente.
- **Read models** (`state.md`, `handoff.md`, `tasks.json`, `decisions.md`)
  são projetados e podem ser regenerados com `project`.

---

**EN — one line:** This tool records the **verbatim text** of your AI
conversations into local files under `.conversation-esaa/`. Never commit that
data to a public repository; see [`.gitignore`](.gitignore). It skips hidden
reasoning, tool output, and system prompts — only visible conversation text is
stored.
