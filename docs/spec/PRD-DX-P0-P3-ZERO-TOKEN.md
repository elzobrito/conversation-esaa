# PRD — Conversation ESAA DX P0–P3 (invariante zero-token)

| Campo | Valor |
|---|---|
| **ID** | CONV-PRD-DX-001 |
| **Produto** | Conversation ESAA (`elzobrito/conversation-esaa`) |
| **Status** | Draft → Ready for implementation backlog |
| **Data** | 2026-09-18 |
| **Autor** | Elzo Brito / Torvaldo |
| **Revisão requerida** | docs |
| **Relacionados** | `docs/plans/v1.2-optional-rag-sqlite.md`, paper ESAA-Conversational, comparação com `akitaonrails/ai-memory` |

---

## 1. Resumo executivo

Evoluir o Conversation ESAA para ser **trivial de instalar**, **útil no cold start**, **consultável por agents** e **portátil**, sem abandonar o modelo event-sourced e **sem gastar tokens de LLM** no caminho feliz (P0–P2).

A captura canônica permanece o **hook de envio de mensagem** (conversa ao vivo). `activity.jsonl` continua como única fonte de verdade; handoff/state/decisions/tasks são projeções determinísticas.

---

## 2. Problema

Hoje o Conversation ESAA já resolve continuidade entre agents com custo zero de modelo, mas a adoção e o cold start ainda exigem ritual demais:

1. **Onboarding frágil** — instalar hooks/watchers por agent é manual e fácil de ficar inconsistente.
2. **Cold start incompleto** — a captura ao vivo existe; o agent *novo* nem sempre recebe um pacote bounded de contexto no início da sessão.
3. **Consulta limitada** — recuperar decisão/tarefa/trecho antigo ainda depende demais de ler markdown/grepar log.
4. **Portabilidade** — dependência forte de PowerShell reduz uso em Linux/mac e em hosts de CI/agents.
5. **Pressão de mercado** — ferramentas como `ai-memory` oferecem handoff cross-vendor “pronto”, mas com consolidação via LLM (custo/latência/opacidade). Precisamos da DX delas **sem** copiar o modelo de gasto de tokens.

### Dor do usuário
Trocar de agent (Cursor ↔ Claude ↔ Codex ↔ Grok) ou abrir sessão fria e ter de **reexplicar** objetivo, decisões e tasks — apesar do log já existir.

---

## 3. Metas

1. Preservar **zero-token** em captura, projeção, verify, context, search e cold-start pack (P0–P2).
2. Tornar install **idempotente** por agent (`cursor|claude|codex|grok|…`).
3. Injetar **handoff bounded** no session-start (somente leitura de projeções).
4. Expor **context/search/MCP fino** sobre o ledger (mutações = append de evento).
5. Entregar **CLI portátil** + **golden tests** de projeção (P2).
6. Só em P3 permitir LLM **opcional** (suggest/compaction), desligável, auditável.

## 4. Não-metas

- Não substituir ESAA-Core (governança de código/`claim`/`complete`).
- Não tornar resumo LLM a fonte de verdade.
- Não editar projeções à mão nem reescrever `activity.jsonl`.
- Não exigir embeddings/RAG no caminho feliz (RAG, se houver, fica opcional e derivado — ver plano v1.2).
- Não competir feature-a-feature com `ai-memory` em UI/multi-host na v1 desta atualização.
- Não gastar tokens do Conversation ESAA para “lembrar”; o custo de *ler* handoff no prompt é do host/agent.

---

## 5. Invariantes (não negociáveis)

### 5.1 Zero-token (caminho feliz)
| Operação | LLM? | Recurso |
|---|---|---|
| Hook de envio → append | Não | CPU + disco |
| `sync` / `project` | Não | CPU + disco |
| `verify` | Não | CPU + disco |
| Cold-start pack | Não | CPU + disco |
| `context` / `search` | Não | CPU + disco (+ índice local) |
| MCP `esaa_*` de leitura/mutação via evento | Não | CPU + disco |
| P3 `suggest` / compaction assistida | **Opcional** | Só se explicitamente ligado |

**Nuance:** quando o agent inclui o handoff no contexto do modelo, quem consome token é o **runtime do agent**, não o Conversation ESAA.

### 5.2 Event sourcing
- Fonte de verdade: `activity.jsonl` (append-only).
- Projeções regeneráveis: `handoff.md`, `state.md`, `decisions.md`, `tasks.json`, etc.
- Proibição: editar projeção como se fosse estado canônico.
- `verify` detecta divergência projeção ↔ log.

### 5.3 Captura canônica
- Evento de turno nasce no **hook de envio de mensagem** (user/agent, conforme o harness).
- Session-start **não grava** memória; só **lê** projeções e monta pacote bounded.
- Hook de envio permanece barato (sem rede, sem LLM, sem reindex full síncrono).

### 5.4 Separação de produtos
- Conversation ESAA = memória conversacional / handoff / curadoria explícita.
- ESAA-Core = tarefas de engenharia governadas.
- Não misturar IDs/eventos dos dois stores.

---

## 6. Usuários e cenários

### Personas
- **Operador (Elzo):** multi-agent no Nitro; quer continuidade sem custo de API para memória.
- **Agent frio:** precisa do mínimo para continuar o episódio.
- **Agent quente:** já captura turnos via hook; precisa mutar decisions/tasks de forma auditável.

### Cenários principais
1. **Install em repo limpo** → hooks + bloco AGENTS + `verify` ok em &lt; 2 min.
2. **Mensagem enviada** → evento appendado; projeções atualizáveis sem LLM.
3. **Novo agent / nova sessão** → recebe pacote cold-start ≤ budget; enuncia objetivo atual.
4. **Buscar decisão antiga** → `search`/`context` local encontra sem reexplanação humana.
5. **Desligar P3** → P0–P2 intactos; zero chamada a modelo.

---

## 7. Escopo por fase

## P0 — DX de adoção + cold start bounded

### Objetivo
Install previsível + agent frio útil, sem gastar token.

### Entregáveis
1. `conversation-esaa install --agent <id>` idempotente  
   - Instala/atualiza hook de **message send**  
   - Paths absolutos do workspace  
   - Bloco marcado em `AGENTS.md` (ou equivalente)  
   - `verify` no final com erro acionável  
2. Hook/injector de **session-start** (read-only)  
3. **Cold-start pack** com budget (`--budget-tokens` / `--budget-chars`):  
   - handoff curto  
   - top N decisions vigentes  
   - tasks abertas  
   - últimos K eventos do tópico ativo  
4. `verify` com diagnóstico (qual projeção, por quê, como reparar via `project`)

### Critérios de aceite (P0)
- [ ] Install em workspace limpo &lt; 2 minutos, repetível sem duplicar hooks quebrados.
- [ ] Quebrar hook de propósito → install/`verify` detecta e explica.
- [ ] Agent frio recupera: objetivo atual + ≥1 decisão + tasks abertas, só com pack mecânico.
- [ ] Nenhuma chamada a LLM em telemetria/logs do caminho P0.
- [ ] Session-start não appenda eventos de “memória”.
- [ ] Latência do hook de envio permanece baixa (sem I/O de rede/LLM).

### Fora de P0
MCP, FTS avançado, rewrite da CLI, suggest LLM.

---

## P1 — Consulta agent-friendly + MCP fino

### Objetivo
Consultar e curar o ledger com precisão, ainda zero-token.

### Entregáveis
1. `context` rico: por tópico, task, decision id, janela (`--last`, `--around`, `--before`) + `--json` versionado  
2. `search` FTS local sobre activity + decisions + tasks (índice rebuildável)  
3. MCP mínimo:  
   - `esaa_context`  
   - `esaa_search`  
   - `esaa_decide`  
   - `esaa_task_create|update|close`  
   - `esaa_verify`  
4. `schema_version` nos eventos do hook de envio; extensões não quebram leitores antigos  

### Critérios de aceite (P1)
- [ ] Mutação via MCP = append de evento + project; nunca write direto em projeção.
- [ ] `verify` verde após mutações MCP.
- [ ] Busca encontra decisão/tarefa por frase-chave sem LLM.
- [ ] Hook de envio não faz reindex full síncrono (index async ou no `project`).
- [ ] Contrato JSON documentado (≤ 1 página).

---

## P2 — Portabilidade + golden tests

### Objetivo
Mesmo log/projeções em Linux/mac/Windows sem ritual frágil.

### Entregáveis
1. CLI portátil (binário C/Rust/Go **ou** distribuição single-file no `PATH`); pwsh pode permanecer como referência Windows  
2. Formato on-disk estável; migrações explícitas `vN→vN+1`  
3. Golden tests: fixture de log → artefatos esperados no CI  
4. Contrato de testes do message-send hook (payload mínimo, idempotência, falha segura)  
5. Política operacional de privacidade (gitignore, redaction básica no append, o que não versionar)

### Critérios de aceite (P2)
- [ ] Clonar workspace noutra máquina + install → `verify` ok.
- [ ] CI com goldens; mudança acidental de projector quebra o teste.
- [ ] Documentação do payload do hook como API estável.
- [ ] Continua zero-token.

---

## P3 — Inteligência opcional (curadoria)

### Objetivo
Sugestões úteis **sem** corromper o ledger; default = desligado.

### Entregáveis
1. `suggest-decisions` / `suggest-tasks` (somente propostas)  
2. Aceite explícito → `decide` / `task create` com `source=suggestion`  
3. Decay/arquivo via eventos (`task.archived`), nunca delete silencioso  
4. Compaction como evento `compaction.created` + ponteiros; raw log permanece  
5. Telemetria local leve do hook (latência, rejects de schema) — sem SaaS obrigatório  

### Critérios de aceite (P3)
- [ ] Com LLM off, P0–P2 100% funcionais.
- [ ] Toda sugestão aceita tem trilha suggestion → event → projection.
- [ ] Compaction não apaga history; `verify` fecha.
- [ ] Nenhuma “auto-memory” silenciosa.

---

## 8. Requisitos funcionais (consolidados)

| ID | Requisito | Fase |
|---|---|---|
| FR-01 | Hook de message-send é a captura canônica de turno | P0 |
| FR-02 | `install --agent` idempotente com verify | P0 |
| FR-03 | Session-start injeta pack bounded read-only | P0 |
| FR-04 | Budget configurável do cold-start pack | P0 |
| FR-05 | `context` filtrável + JSON estável | P1 |
| FR-06 | `search` FTS local rebuildável | P1 |
| FR-07 | MCP fino sem bypass do event store | P1 |
| FR-08 | Eventos versionados (`schema_version`) | P1 |
| FR-09 | CLI portátil / PATH único | P2 |
| FR-10 | Golden tests de projeção no CI | P2 |
| FR-11 | Suggest/compaction opcionais e auditáveis | P3 |

## 9. Requisitos não funcionais

| ID | Requisito |
|---|---|
| NFR-01 | Zero chamada a LLM em P0–P2 (caminho feliz e defaults) |
| NFR-02 | Hook de envio não bloqueia o send do usuário por falha de índice/rede |
| NFR-03 | `verify` &lt; poucos segundos em workspaces típicos de dev |
| NFR-04 | Isolamento por `workspace_root` |
| NFR-05 | Segredos: redaction básica; não versionar activity sensível sem política |
| NFR-06 | Determinismo: mesmo log ⇒ mesmas projeções (goldens) |
| NFR-07 | Separação estrita Conversation ESAA ↔ ESAA-Core |

---

## 10. UX / CLI (esboço de superfície)

```text
conversation-esaa install --agent cursor|claude|codex|grok [--workspace PATH]
conversation-esaa verify [--workspace PATH]
conversation-esaa project [--workspace PATH]
conversation-esaa context [--topic T] [--task ID] [--last N] [--budget N] [--json]
conversation-esaa search "query" [--json]
conversation-esaa decide "..." [--rationale ...]
conversation-esaa task create|update|close ...
# P3 opcional
conversation-esaa suggest decisions|tasks [--apply]   # apply só com confirmação
```

Cold-start pack (artefato ou stdout do session-start):

```text
# cold-start v1 — mechanical, no LLM
## Handoff
...
## Decisions (active)
...
## Open tasks
...
## Recent events (topic=...)
...
```

---

## 11. Modelo de dados (alto nível)

```text
message-send hook
      │  append event (schema_version, role, text/meta, ts, agent_id, ...)
      ▼
activity.jsonl  ─────────────── fonte canônica
      │
      ├─ project (determinístico, zero-token)
      │     ├─ handoff.md
      │     ├─ state.md
      │     ├─ decisions.md
      │     └─ tasks.json
      │
      ├─ index FTS (derivado, rebuildável)     [P1]
      │
      └─ session-start pack (read-only, budget) [P0]
```

Curadoria explícita (`decide`, `task_*`) também só via append.

---

## 12. Métricas de sucesso

| Métrica | Alvo qualitativo |
|---|---|
| Tempo até agent frio enunciá objetivo atual | Queda clara vs baseline atual |
| Reexplanações de decisão já tomada | Redução sustentada |
| Sessões com `verify` ok | → ~100% nos workspaces ativos |
| Latência do hook de envio | Sem regressão perceptível |
| Chamadas LLM atribuídas ao Conversation ESAA em P0–P2 | **0** |
| Install limpa bem-sucedida | &lt; 2 min |

---

## 13. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Pack cold-start estourar contexto do host | Budget estrito + ordenação por prioridade |
| Hook lento atrapalhar UX de chat | Append mínimo síncrono; index/project async |
| Pressão para “igualar ai-memory” com auto-resumo | Invariante zero-token no PRD/CI (smoke: sem API keys) |
| Drift Conversation vs Core | Docs + boundaries; stores separados |
| Contaminação de segredos no log | Redaction + PRIVACY.md + gitignore |
| Reescrever CLI e quebrar schema | Goldens + `schema_version` + migrate explícito |

---

## 14. Plano de rollout

1. Aprovar este PRD (review docs).  
2. Abrir backlog ESAA: `CONV-DX-P0-*`, `CONV-DX-P1-*`, `CONV-DX-P2-*`, `CONV-DX-P3-*`.  
3. Implementar P0 → validar no Nitro com multi-agent real.  
4. P1 em paralelo a um agent piloto com MCP.  
5. P2 quando P0 estável (portabilidade sem mudar contrato).  
6. P3 apenas após métricas de P0/P1.

---

## 15. Open questions

1. Lista fechada de `--agent` na v1 do install (mínimo: cursor, claude, codex, grok)?  
2. Unidade do budget do pack: tokens estimados vs caracteres?  
3. Onde materializar o pack: arquivo `.conversation-esaa/cold-start.md`, stdout do hook, ou ambos?  
4. CLI alvo preferida em P2: Rust, Go ou C (alinhado ao interesse de reescrita em C)?  
5. MCP: servidor standalone vs subcomando `conversation-esaa mcp serve`?

---

## 16. Decisão de produto (resumo)

O Conversation ESAA **não** vai virar um wiki semântico pago em tokens. Vai ficar excelente em:

- capturar a conversa **ao vivo** (hook de envio),
- projetar handoff **determinístico**,
- instalar e recuperar contexto **sem LLM**,
- só então, opcionalmente, sugerir curadoria (P3).

Isso é a vantagem sustentável frente a `ai-memory`: continuidade **barata, auditável e previsível**.

---

## 17. Apêndice — Mapeamento vs ai-memory (inspiração, não cópia)

| Ideia boa no ai-memory | Como entra aqui |
|---|---|
| Install one-shot multi-client | P0 `install --agent` |
| Handoff no início da sessão | P0 cold-start pack mecânico |
| Query/MCP | P1 FTS + MCP fino |
| Cross-harness polish | P1–P2 contratos de hook |
| Consolidação LLM | Só P3 opcional, nunca canônica |

