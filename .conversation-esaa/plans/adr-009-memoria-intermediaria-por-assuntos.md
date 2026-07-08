# ADR-009 — Camada de Memória Intermediária por Assuntos (Topic Memory Layer)

> **Status:** Proposta detalhada para análise e revisão (por Codex, Grok, outros agentes e humanos).  
> **Data:** 2026-07-08  
> **Contexto:** Discussão no repositório `desenvolvimento/conversation-esaa`.  
> **Objetivo:** Introduzir uma camada intermediária de memória rápida, organizada por assuntos, sem violar os princípios arquiteturais do Conversation ESAA.  
> **Base:** Estado atual do v1.1, ADRs anteriores (especialmente ADR-004), system-design e observações de uso real em workspaces com activity.jsonl grandes.

---

## Resumo Executivo

O Conversation ESAA atual oferece duas formas principais de acesso à memória:

1. **Read models projetados** (`state.md`, `handoff.md`, `decisions.md`, `tasks.json`) — visões consolidadas mas ainda relativamente planas.
2. **Context seletivo** (`context --last`, `--topic`, `--around`) — busca textual sobre o log completo.

Quando uma conversa evolui com múltiplos assuntos paralelos (ex: integração celular, gerenciador de janelas, plano de aula Big Data, configuração de hooks, etc.), tanto os read models quanto as buscas de contexto se tornam ruidosos ou ineficientes.

**Proposta:** Adicionar uma **camada intermediária explícita de memória por assuntos** (chamada internamente de *Topic Memory Layer* ou *Memória Intermediária por Assuntos*).

Características principais:
- Lista rápida de assuntos ativos (barata de ler).
- Cada assunto contém resumo, decisões-chave, ponteiros para eventos no `activity.jsonl`, status e metadados.
- O agente pode primeiro listar os assuntos e depois expandir seletivamente para o log completo quando necessário.
- Totalmente derivada (projeção + curadoria explícita).
- Mantém `activity.jsonl` como única fonte de verdade.
- Compatível com o modelo de projeções descartáveis.

Esta camada atua como "memória de acesso rápido" entre o log frio (`activity.jsonl`) e as projeções de alto nível (state/handoff).

---

## 1. Contexto e Motivação

Agentes de IA trocam de contexto frequentemente. Mesmo com hooks automáticos e projeções, o problema de "entender o que está acontecendo agora" persiste quando:

- A conversa tem vários fios paralelos.
- O log `activity.jsonl` cresce (ex: >1000 eventos, arquivos de 2MB+).
- Um agente frio (ou novo) precisa de overview rápido sem consumir muitos tokens.
- Buscas textuais simples perdem estrutura semântica.

O estado atual força o agente a:
- Ler `state.md` + `handoff.md` (que contêm "últimos 5 eventos" e lista de decisões).
- Ou chamar múltiplas vezes `context --topic "xxx"` (busca linear).
- Ou ler fatias do `activity.jsonl`.

O usuário observou corretamente: **falta uma memória intermediária estruturada por assuntos**.

Isso está alinhado com preocupações já registradas:
- ADR-004 (Horizonte Longo: Snapshot + Decisões + Janela)
- System Design v1/v2 (índices, snapshots)
- README (reconhece que "Topic retrieval is textual, not semantic")

---

## 2. Estado Atual da Recuperação de Contexto

### 2.1 Projeções principais (`Invoke-Project`)

- `state.md`: Objetivo Atual + Decisões + Estado (contagens) + Últimos Eventos (últimos ~5) + Tarefas abertas + Próxima Ação.
- `handoff.md`: Ordem de leitura recomendada + Contrato operacional + Tarefas abertas.
- `decisions.md`: Lista de decisões curadas.
- `tasks.json`: Tarefas conversacionais.

### 2.2 Comando `context` (`Invoke-Context`)

Localizado em `conv-sync.ps1`:
- Suporta: `--agent`, `--last N`, `--before <event_id>`, `--around <event_id>`, `--window`, `--topic <texto>`, `--json`.
- Filtro de tópico: busca substring case-insensitive em campos selecionados (`summary`, `text`, `decision`, `rationale`, `title`, `next_step`).
- Ranking simples por contagem de matches.
- Sem índice persistente.
- Sempre varre eventos filtrados pelo workspace.

### 2.3 Outros mecanismos

- `sync-state.json`: usado apenas para deduplicação de turnos recebidos (cache de event_ids vistos).
- Sem estrutura de "assuntos", "threads" ou "tópicos" como entidades de primeira classe.

---

## 3. Problemas Identificados

1. **Ausência de visão por assuntos**
   - Não existe forma barata de responder: "Quais são os assuntos ativos agora?"
   - `state.md` mistura tudo em uma lista cronológica curta.

2. **Busca de contexto é ineficiente em escala**
   - Para logs grandes, `--topic` reprocessa o arquivo inteiro a cada chamada.
   - Perde contexto estruturado (um evento pode pertencer a múltiplos assuntos).

3. **Perda de foco em handoff**
   - Agente frio recebe "últimos eventos" sem saber a qual assunto pertencem.
   - Decisões ficam soltas sem agrupamento.

4. **Custo de tokens alto para overview**
   - Para entender o estado, muitas vezes é necessário pedir mais contexto ou ler partes do log.

5. **Dificuldade de navegação**
   - Não há "índice" ou "sumário de tópicos" navegável.

6. **Limitação da abordagem atual de "decisões + tarefas como espinha"**
   - Boa, mas insuficiente quando o usuário trabalha em vários domínios simultaneamente dentro do mesmo workspace.

---

## 4. Proposta: Camada de Memória Intermediária por Assuntos

### Nome sugerido
- Interno: **Topic Memory Layer**
- Artefatos: `topics.json` + `topics.md` (ou `memory.json` / `memory.md`)
- Comando raiz: `conversation-esaa topics` (ou `memory`)

### Conceito

Introduzir um nível intermediário entre:
- `activity.jsonl` (fonte de verdade, completa, append-only)
- Projeções de alto nível (`state.md`, `handoff.md`)

A nova camada:
- Lista de **assuntos** (tópicos/threads/subjects).
- Cada assunto é uma visão compacta com:
  - Identificador estável
  - Título e resumo
  - Decisões e tarefas relacionadas
  - Ponteiros (event_ids) para o log
  - Metadados de tempo e status
- Atualizada por projeção + curadoria explícita.
- Barata para listar ("quais assuntos existem?").
- Permite expandir seletivamente ("me mostre o histórico deste assunto").

### Princípios que devem ser respeitados (invariantes)

- `activity.jsonl` continua sendo a **única fonte de verdade**.
- Todos os artefatos (`topics.json`, `topics.md`, etc.) são **projeções** — nunca editados manualmente.
- Escritas passam por lock de pipeline.
- Workspace isolation total.
- Compatibilidade com `context`, `decide`, `task` e `project`.
- Ordem de leitura recomendada atualizada no `handoff.md`.

---

## 5. Modelo de Dados

### 5.1 `topics.json` (fonte estruturada primária)

```json
{
  "schema_version": "conversation-esaa.topics.v0.1",
  "updated": "2026-07-08T12:30:00-03:00",
  "workspace_root": "/home/elzobrito",
  "topics": [
    {
      "id": "TOP-001",
      "title": "Gerenciador de janelas no Ubuntu",
      "summary": "Usuário precisa de alternativa leve ao Phone Link da Microsoft no Linux. Discussão sobre KDE Connect / GSConnect + scrcpy.",
      "status": "active",
      "created_ts": "2026-07-08T12:02:00-03:00",
      "last_ts": "2026-07-08T12:17:00-03:00",
      "keywords": ["janelas", "wm", "ubuntu", "kdeconnect", "scrcpy", "gerenciador"],
      "key_event_ids": [
        "146a761e08f8048c7c04ef1dde33150f8338cec0aceb16a358391841c2879d8d",
        "..."
      ],
      "related_decisions": ["DEC-0002"],
      "related_tasks": [],
      "source": "curated"
    },
    {
      "id": "TOP-002",
      "title": "Plano de Aula Big Data com Python (PCA-C10)",
      "summary": "Geração de plano de aula e roteiro guiado usando base real de acidentes de trânsito em Recife (2015-2024).",
      "status": "completed",
      "created_ts": "2026-07-07T18:00:00-03:00",
      "last_ts": "2026-07-07T18:40:41-03:00",
      "keywords": ["big-data", "python", "plano-aula", "recife", "acidentes", "PCA"],
      "key_event_ids": ["d8118d8c20d891a2a4a870deb2a81848162ba77cbfe06ce8bab8ecfc54004376"],
      "related_decisions": [],
      "related_tasks": ["PCA-C10"],
      "source": "curated"
    }
  ]
}
```

### 5.2 `topics.md` (versão legível para handoff)

Formato Markdown amigável para agentes e humanos, com links para event_ids quando possível.

### 5.3 Evolução de `state.md`

Recomenda-se adicionar seção explícita:

```markdown
## Tópicos / Assuntos Ativos

- **TOP-001** — Gerenciador de janelas no Ubuntu (active)
- **TOP-003** — ... 
```

---

## 6. Integração com o Sistema Existente

### Ordem de leitura recomendada (atualizada)

1. `state.md` (incluindo seção de Tópicos)
2. `topics.json` ou `topics.md` (lista rápida de assuntos)
3. `decisions.md` + `tasks.json`
4. `context --topic-id TOP-XXX` ou `context --last`
5. `activity.jsonl` (quando necessário expandir)

### Impacto em `Invoke-Project`

- Adicionar chamada para `Project-TopicsFromEvents` (ou similar).
- Gerar `topics.json` + opcionalmente `topics.md`.
- Atualizar `state.md` e `handoff.md` para referenciar a nova camada.

### Impacto em `Invoke-Context`

- Adicionar suporte a `--topic-id TOP-001` (além de `--topic "texto"`).
- Quando `--topic-id` for usado, usar os `key_event_ids` como base + expansão opcional.

### Relação com `decide` e `task`

- Decisões e tarefas podem referenciar `topic_id`.
- Ao criar decisão/tarefa, permitir `--topic TOP-001`.

---

## 7. Comandos da CLI Propostos

Extensões no `conversation-esaa.ps1` e `conv-sync.ps1`:

```text
conversation-esaa topics list [--status active|completed|all] [--json]
conversation-esaa topics show TOP-001 [--json]
conversation-esaa topics create "Título do assunto" --summary "..." [--events "id1,id2"] [--decision DEC-xxx]
conversation-esaa topics update TOP-001 --add-events "id3" --status completed
conversation-esaa topics close TOP-001 --evidence "..."

# Ou alias mais curto
conversation-esaa memory list
conversation-esaa memory show TOP-001
```

O comando `context` ganha:
- `--topic-id TOP-001`
- `--expand-topic` (para trazer mais eventos relacionados)

---

## 8. Estratégias de População de Tópicos

### 8.1 Curadoria Explícita (recomendada para qualidade)

Agentes (ou humanos) usam comandos `topics create/update` para registrar assuntos importantes.

Vantagens:
- Alta qualidade.
- Alinhado com espírito de `decide` e `task` (curadoria).

### 8.2 Projeção Heurística (suporte inicial)

Durante `project`, analisar eventos recentes + decisões + tarefas e sugerir tópicos por agrupamento simples de palavras-chave ou co-ocorrência.

Pode ser:
- Heurística determinística (contagem de termos, janelas temporais).
- Marcadores opcionais em eventos (`topic_hints`).

### 8.3 Híbrido (melhor caminho)

- Projeção cria rascunhos de tópicos.
- Curadoria (via CLI) promove/refina os tópicos.
- Eventos `topic.*` são emitidos para rastreabilidade.

---

## 9. Eventos no Activity.jsonl (Opcional mas Recomendado)

Para manter rastreabilidade total, sugerimos novos tipos de eventos curados:

- `topic.created`
- `topic.updated`
- `topic.closed`
- `topic.event.linked` (para associar eventos existentes)

Exemplo:

```json
{
  "ts": "...",
  "event": "topic.created",
  "actor": "assistant",
  "agent_id": "grok",
  "workspace_root": "...",
  "topic_id": "TOP-001",
  "title": "...",
  "summary": "...",
  "initial_event_ids": ["..."]
}
```

Isso permite que a projeção de tópicos seja **reconstruível** a partir do log (boa propriedade).

---

## 10. Fluxo de Dados (Textual)

```
Agente trabalha
  → sync (grava turnos)
  → decide / task / topic create (curadoria)
  → project
       → reconstrói topics.json a partir de:
            - eventos topic.*
            - decisões com topic
            - tarefas com topic
            - heurística sobre turnos recentes
       → atualiza state.md (seção de tópicos)
       → atualiza handoff.md
  → context --topic-id TOP-001
       → usa key_event_ids + expande do activity.jsonl
```

---

## 11. Benefícios Esperados

- **Overview rápido**: listar assuntos sem ler o log.
- **Handoff mais preciso**: agente frio sabe exatamente em quais frentes está trabalhando.
- **Redução de tokens**: contexto seletivo por assunto.
- **Navegação melhor**: ponteiros diretos para eventos relevantes.
- **Evolução natural**: prepara o terreno para snapshots (ADR-004) e índices semânticos futuros.
- **Curadoria incentivada**: reforça o modelo de "decisões e tarefas como espinha".

---

## 12. Trade-offs e Riscos

**Positivos**
- Melhora dramaticamente a usabilidade sem aumentar complexidade do log.
- Mantém determinismo e reconstruibilidade.

**Negativos / Riscos**
- Mais um artefato projetado para manter.
- Risco de divergência se a projeção não for bem implementada.
- Curadoria exige disciplina dos agentes (mesmo problema atual de `decide`/`task`).
- Possível complexidade extra no CLI.
- Se feito de forma ingênua, os tópicos podem se tornar outro "estado inflado".

**Mitigações**
- Tópicos devem ter tamanho limitado (ex: top-K por assunto).
- Sempre oferecer forma de "reprojetar" ou "reindexar".
- Documentar claramente que `topics.json` é derivado.

---

## 13. Considerações de Implementação

### Faseamento sugerido

**Fase 1 — Fundação (baixo risco)**
- Adicionar suporte básico a `topics.json` como projeção simples.
- Atualizar `state.md` com seção de tópicos (usando decisões + tarefas + últimos eventos).
- Adicionar `context --topic-id` (inicialmente mapeando para filtro textual).
- Atualizar handoff.md com a nova ordem de leitura.

**Fase 2 — Curadoria**
- Implementar comandos `topics create/update/close`.
- Emitir eventos `topic.*` no activity.jsonl.
- Suporte a `--topic TOP-xxx` em `decide` e `task`.

**Fase 3 — Projeção mais inteligente + index**
- Melhorar agrupamento heurístico.
- Criar índice auxiliar (ex: dentro de sync-state ou novo `topics-index.json`) para buscas rápidas.
- Melhorar `topics.md`.

**Fase 4 — Avançado**
- Snapshots por tópico.
- Integração com futuras features de semantic index.
- Visualização / export.

### Locais principais de mudança

- `conv-sync.ps1`:
  - `Invoke-Project`
  - Novas funções `Project-Topics*`
  - `Invoke-Context`
  - Novas funções para comandos de tópicos
- `conversation-esaa.ps1`: despachar novos comandos
- `conv-bootstrap.ps1`: criar estrutura inicial vazia para topics
- Testes e fixtures
- README + plans

### Invariantes a preservar

- Lock em todo write path.
- Nunca editar manualmente artefatos gerados.
- Workspace isolation.
- Verify deve validar o novo artefato.

---

## 14. Portabilidade Linux

A introdução desta camada não piora (nem melhora diretamente) a portabilidade, mas é uma boa oportunidade para:

- Tornar o código de projeção mais limpo e testável.
- Documentar claramente os caminhos que dependem de pwsh.
- Considerar, no futuro, uma implementação paralela leve (Python) do núcleo de projeção (`project` + `context` + `topics`).
- Melhorar detecção de ambiente e geração de comandos em hooks.

A camada de memória por assuntos pode ser especialmente útil em Linux, onde os usuários tendem a ter conversas mais longas e experimentais.

---

## 15. Relação com ADRs e Documentos Anteriores

- **ADR-004 (Horizonte Longo)**: Esta proposta é uma concretização parcial da visão "decisões + janela + snapshot". Tópicos servem como "mini-snapshots" por domínio.
- **ADR-005**: Reforça "decisões e tarefas como espinha", adicionando "assuntos" como estrutura de navegação.
- **System Design**: Realiza a ideia de "índices" mencionada.
- **README v1.1**: Evolui o "textual topic retrieval" para algo mais estruturado.
- Não conflita com ESAA-Core (é complementar).

---

## 16. Plano de Implementação Sugerido (para Codex ou outro agente)

As tarefas autosuficientes foram formalizadas no plano oficial:

**`.conversation-esaa/plans/v1-1-implementation-plan.md`**

- **Task 10:** Define topics schema and first-class topic events (ADR-009)
- **Task 11:** Implement projection of `topics.json`
- **Task 12:** Generate `topics.md` and integrate into state.md + handoff.md
- **Task 13:** Implement topics CLI commands
- **Task 14:** Extend `context` with `--topic-id` support
- **Task 15:** Update `verify` and add comprehensive tests for topics

Cada tarefa é projetada para ser relativamente autosuficiente (com passos claros, arquivos listados, comandos de verificação e critérios de aceite).

1. Ler este documento + código de `Invoke-Project`, `Invoke-Context`, `Project-TasksFromEvents` e `Project-DecisionsMarkdown`.
2. Ler ADRs relevantes (004, 005, 001) e o `v1-1-implementation-plan.md`.
3. Começar por Task 10 (schema + eventos).
4. Seguir a ordem recomendada atualizada no plano.

---

## 17. Perguntas em Aberto (para análise do Codex)

1. Os tópicos devem ser **primeira classe** (emitir eventos `topic.*`) ou apenas projeção derivada de decisões/tarefas/turnos?
2. Como lidar com tópicos que se sobrepõem (um evento pertence a 2+ tópicos)?
3. Qual o tamanho máximo razoável de `key_event_ids` por tópico?
4. Devemos ter `topic_id` como campo opcional em eventos de turnos (ou só em curadoria)?
5. Nome final dos artefatos: `topics.*` ou `memory.*`?
6. Como versionar o schema (`topics.v0.1`) e fazer migração futura?
7. Devemos oferecer um comando `topics suggest` (heurística) separado de `topics create`?
8. Impacto em privacidade (tópicos podem expor estrutura da conversa)?
9. Como integrar com o watcher do Codex e hooks do Grok/Claude (devem eles sugerir tópicos automaticamente)?
10. Esta camada deve ser obrigatória ou opt-in por workspace?

### 17.1 Revisão Codex — ajustes recomendados para Grok

Codex leu a proposta em 2026-07-08 e recomenda transformar a Fase 1 em um
MVP curado e reconstruível, evitando heurística automática no primeiro passo.
O objetivo é reduzir ambiguidade para implementação e preservar as invariantes
de event sourcing do Conversation ESAA.

**Decisões recomendadas:**

1. **Tópicos devem ser primeira classe desde a Fase 1.**
   - Emitir eventos `topic.created`, `topic.updated`, `topic.closed` e
     `topic.event.linked` no `activity.jsonl`.
   - `topics.json` e `topics.md` continuam sendo projeções descartáveis.
   - Não criar tópicos apenas como inferência efêmera de decisões/tarefas,
     porque isso torna a reconstrução e a auditoria fracas.

2. **Usar `topics.*`, não `memory.*`, como nome de artefato e comando.**
   - `memory` é amplo demais e deve ficar reservado para uma camada futura
     maior, que pode incluir snapshots, índices e retenção.
   - O comando raiz recomendado é `conversation-esaa topics`.

3. **Permitir múltiplos tópicos por evento.**
   - Eventos curados devem aceitar `topic_ids: ["TOP-001", "TOP-002"]`
     quando fizer sentido.
   - Comandos de CLI podem aceitar `--topic TOP-001` repetível ou lista
     separada por vírgula, mas a projeção deve normalizar para array.

4. **Limitar `key_event_ids`.**
   - Recomenda-se limite inicial de 20 eventos-chave por tópico.
   - Para escala, incluir metadados compactos como `event_count`,
     `first_event_id` e `last_event_id`, em vez de tentar carregar todo o
     histórico no read model.

5. **Começar sem `topics suggest` automático.**
   - A heurística deve ficar para Fase 3.
   - Na Fase 1, a qualidade vem de curadoria explícita por agentes/humanos.
   - Hooks e watcher não devem criar tópicos automaticamente; no máximo podem
     sugerir no futuro, sempre com promoção explícita.

6. **`context --topic-id` deve resolver por vínculo, não por busca textual.**
   - Primeiro ler `topics.json` e coletar `key_event_ids`/eventos vinculados.
   - Depois expandir janela no `activity.jsonl` quando `--expand-topic` ou
     `--window` forem usados.
   - `--topic "texto"` permanece como busca textual legada.

7. **`verify` deve validar o novo contrato.**
   - Validar schema version.
   - Validar unicidade de IDs `TOP-NNN`.
   - Validar status permitido (`active`, `paused`, `completed`, `archived`).
   - Validar `workspace_root`.
   - Validar referências órfãs a eventos, decisões e tarefas quando possível.
   - Validar que projeções `topics.json`/`topics.md` são reconstruíveis a
     partir do event store.

8. **A camada deve ser obrigatória quando o workspace for projetado.**
   - `project` deve gerar `topics.json` vazio quando não houver tópicos.
   - Isso mantém o handoff previsível e evita comportamento opt-in difícil de
     explicar para agentes frios.

### 17.2 MVP ajustado recomendado

Para implementação inicial, Grok deve considerar este escopo mínimo:

1. Definir schema `conversation-esaa.topics.v0.1`.
2. Implementar eventos `topic.created`, `topic.updated`, `topic.closed` e
   `topic.event.linked`.
3. Implementar projeção determinística `topics.json`.
4. Implementar `topics.md` simples para leitura humana/agentes.
5. Atualizar `state.md` com seção "Tópicos / Assuntos Ativos".
6. Atualizar `handoff.md` com ordem de leitura incluindo `topics.md`.
7. Implementar CLI:
   - `topics list [--status active|paused|completed|archived|all] [--json]`
   - `topics show TOP-001 [--json]`
   - `topics create "Título" --summary "..."`
   - `topics update TOP-001 --summary "..." --status active`
   - `topics link TOP-001 --events "id1,id2"`
   - `topics close TOP-001 --evidence "..."`
8. Implementar `context --topic-id TOP-001`.
9. Atualizar `verify`.
10. Adicionar testes de projeção, CLI e validação.

### 17.3 Riscos adicionais identificados por Codex

- **Inflação de estado:** tópicos podem virar outro read model grande. Mitigar
  com limites explícitos e resumos curtos.
- **IDs instáveis:** nunca derivar `TOP-NNN` de ordem heurística; o ID deve vir
  do evento curado ou de alocação determinística no write path.
- **Ambiguidade de status:** `active`, `paused`, `completed` e `archived`
  cobrem melhor o ciclo real do que apenas `active/completed`.
- **Privacidade operacional:** `topics.md` torna a estrutura da conversa mais
  visível. Documentar que é projeção local e respeita isolamento de workspace.
- **Migração futura:** se o schema mudar, `verify` deve aceitar versão conhecida
  e falhar fechado para versões desconhecidas, com mensagem acionável.

---

## 18. Apêndice: Exemplos de Uso

**Exemplo de handoff para agente frio:**

```
Leia nesta ordem:
1. state.md (visão geral + seção de Tópicos)
2. topics.json (lista completa de assuntos com resumos)
3. topics show TOP-001 (detalhes + decisões)
4. context --topic-id TOP-001 --last 10
5. activity.jsonl (se precisar de evidência completa)
```

**Comando para registrar novo assunto:**

```powershell
pwsh -File .conversation-esaa/bin/conversation-esaa.ps1 topics create `
  "Gerenciador de janelas no Ubuntu" `
  --summary "Alternativa a Phone Link usando KDE Connect + scrcpy" `
  --events "146a76...,d76642..." `
  --workspace /home/elzobrito
```

---

## Status Final deste Documento

Este é um documento de **proposta detalhada**. O objetivo é que Codex (ou outro agente) leia este arquivo completo, analise a viabilidade, sugira refinamentos no schema/comandos/estratégias, identifique riscos não listados e proponha um plano de implementação concreto (possivelmente como PRs ou tarefas).

**Próximos passos recomendados após análise:**
- Revisão por Codex
- Decisão sobre Fase 1 (escopo mínimo viável)
- Implementação incremental com testes
- Validação em workspace real (ex: `/home/elzobrito`)

---

*Documento gerado para análise colaborativa. Todo o design deve respeitar os princípios de event sourcing, projeções derivadas e isolamento de workspace do Conversation ESAA.*
