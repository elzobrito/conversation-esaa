# Conversation ESAA v1.1 ADRs

> Status: aceito para orientar implementacao v1.1.
> Base: `system-design-conversation-esaa-v1-v2.md`, revisado por Grok e Codex em 2026-06-21.
> Escopo: ferramenta greenfield; sem edicao manual de artefatos gerados, sem legado, sem dual-write e sem compatibilidade obrigatoria com o historico do lab.

## Contexto Geral

O Conversation ESAA e uma especializacao de dominio do ESAA para memoria conversacional compartilhada entre agentes heterogeneos. Ele nao governa execucao de tarefas de engenharia como `.roadmap` ou `esaa-core`; ele governa continuidade, curadoria, handoff, leitura seletiva, auditoria operacional e sincronizacao de conversa.

A v1 atual provou o conceito com `conv-sync.ps1`, `activity.jsonl`, `state.md`, `handoff.md`, `tasks.json`, hooks do Grok/Claude e watcher do Codex. A v1.1 deve transformar o prototipo em ferramenta limpa:

- `activity.jsonl` como unica fonte de verdade.
- `state.md`, `handoff.md`, `decisions.md`, `tasks.json` e indices como read models projetados.
- Escritas sempre via CLI `conversation-esaa`.
- Hooks finos chamando comandos de dominio.
- Contexto paginado por comando, nao por leitura direta do log inteiro.
- Workspace isolation obrigatorio.

---

## ADR-001 — Serializar Escritas Concorrentes

**Status:** Aceito para v1.1

### Problema

Hooks de agentes diferentes podem disparar quase ao mesmo tempo:

- Grok em `UserPromptSubmit`, `Stop` ou `PreCompact`.
- Claude em hooks equivalentes.
- Codex via watcher externo.
- Usuario ou agente rodando `decide`, `task` ou `project` manualmente.

Todos esses caminhos podem tentar escrever em `activity.jsonl` e regenerar `state.md`, `handoff.md`, `tasks.json`, `decisions.md` e `sync-state.json`. Sem serializacao, ha risco de:

- duas linhas JSONL intercaladas;
- cache de dedup salvo antes de uma projecao falhar;
- read model projetado de uma versao intermediaria do log;
- verify passando em um processo enquanto outro ainda escreve;
- truncamento ou sobrescrita de arquivo projetado.

### Decisao

Na v1.1, todo comando que escreve deve adquirir um lockfile de pipeline antes de qualquer mutacao:

```text
conversation-esaa <write-command>
  -> acquire lock
  -> validate input
  -> append event(s)
  -> project read models
  -> verify
  -> save caches, if any
  -> release lock
```

Comandos de escrita incluem:

- `sync`
- `decide`
- `task`
- `snapshot create`
- `redact` quando emitir eventos `redaction.applied`
- qualquer comando futuro que faca append no log

Comandos de leitura (`context`, `handoff`, `verify` em modo read-only) nao precisam bloquear por padrao, mas devem ler arquivos de forma tolerante a lock ativo. Se lerem durante escrita, devem preferir esperar ou reportar `busy` em vez de retornar visao parcial.

### Implementacao v1.1

Usar arquivo:

```text
.conversation-esaa/run/conversation-esaa.lock
```

Conteudo recomendado:

```json
{
  "pid": 12345,
  "command": "sync --agent grok",
  "started_at": "2026-06-21T14:00:00-03:00",
  "workspace_root": "C:\\xampp\\htdocs\\meu-projeto"
}
```

Regras:

1. Se o lock nao existe, criar de forma atomica.
2. Se existe e o processo ainda esta vivo, aguardar ate timeout.
3. Se existe e esta stale, remover com registro em stderr.
4. Se timeout expirar, retornar erro nao-zero.
5. Sempre liberar lock em `finally`.

### Consequencias

**Positivas**

- Corrige o principal risco de concorrencia local.
- Mantem implementacao simples.
- Evita single-writer daemon antes da necessidade real.

**Negativas**

- Serializa todo pipeline, inclusive projecao.
- Um comando travado pode bloquear outros ate timeout.
- Multi-maquina ou sync remoto ainda exigem outro mecanismo.

### Alternativas Rejeitadas

**Single-writer queue na v1.1.**
Rejeitada por adicionar daemon, supervisao e estado operacional antes de necessidade comprovada.

**Append lock-free + projecao diferida.**
Boa arquitetura futura, mas exige garantias de append atomico por plataforma e mudanca maior no runtime atual.

### Criterios de Aceite

- Dois `sync-*` simultaneos nao corrompem `activity.jsonl`.
- `sync` e `decide` simultaneos terminam em ordem serializada.
- Lock stale e recuperado com timeout seguro.
- `verify` continua `ok` apos teste concorrente.

---

## ADR-002 — Payload de Hook Como Fonte Primaria

**Status:** Aceito para v1.1, com fallback de bootstrap por log nativo

### Problema

A v1 le logs privados de fornecedores:

- `~/.grok/sessions/.../chat_history.jsonl`
- `~/.codex/sessions/.../rollout-*.jsonl`
- `~/.claude/projects/.../<session>.jsonl`

Esses formatos nao sao contratos publicos estaveis. Se mudarem, o sync pode quebrar silenciosamente ou importar dados errados.

Ao mesmo tempo, hooks de agentes frequentemente fornecem payloads mais proximos de um contrato operacional: evento do hook, workspace, sessao, tipo de ciclo de vida e possivelmente conteudo do turno.

### Decisao

O caminho preferencial de ingestao deve ser:

```text
hook payload -> captured turn canonical -> activity.jsonl
```

O log nativo fica como mecanismo de:

- bootstrap inicial;
- recuperacao de turnos perdidos;
- compatibilidade temporaria quando o payload nao contem texto suficiente;
- importacao historica explicitamente solicitada.

O adaptador de cada agente deve normalizar toda fonte em um contrato unico `CapturedTurn` antes de gerar `conversation_turn`.

### Contrato Canonico

```json
{
  "workspace_root": "C:\\xampp\\htdocs\\meu-projeto",
  "source": "grok",
  "source_session_id": "019e...",
  "source_index": 42,
  "actor": "assistant",
  "agent_id": "grok",
  "ts": "2026-06-21T14:00:00-03:00",
  "text": "Visible message text",
  "capture_method": "hook_payload"
}
```

### Consequencias

**Positivas**

- Reduz acoplamento a formatos privados.
- Torna falhas de fonte mais explicitas.
- Facilita testes de contrato por fonte.

**Negativas**

- Nem todo agente entrega payload suficiente.
- Durante v1.1 talvez ainda exista parsing por log para Codex/Grok/Claude.
- Exige distinguir `capture_method`.

### Criterios de Aceite

- Adaptadores possuem testes com fixtures de hook payload e log fallback.
- `sync --agent X` reporta qual fonte foi usada.
- Mudanca de formato de log nao quebra hook payload quando disponivel.
- Importacao historica e comando separado, nao comportamento implicito do hook.

---

## ADR-003 — Auditabilidade Operacional vs Forense

**Status:** Aceito para v1.1

### Problema

O sistema atual oferece auditabilidade operacional:

- quem falou;
- qual agente;
- quando;
- de qual fonte;
- em qual workspace;
- qual evento alimentou uma decisao ou tarefa.

Mas isso nao e o mesmo que auditabilidade forense. Sem hash-chain, assinatura ou anchoring externo, um arquivo local pode ser reescrito sem prova criptografica de adulteracao.

### Decisao

A v1.1 promete auditabilidade operacional, nao forense.

O design deve ser honesto:

```text
v1.1:
  replay, validacao, dedup, proveniencia operacional, workspace isolation

v2:
  hash-chain, snapshot/replay formal, anchoring opcional, perfil conversation no esaa-core
```

Nao implementar hash-chain leve em paralelo se a v2 caminhar para `esaa-core`. Evitar duas implementacoes de integridade forte.

### Consequencias

**Positivas**

- Evita overengineering na v1.1.
- Mantem a promessa tecnica correta.
- Preserva caminho limpo para esaa-core.

**Negativas**

- Nao permite afirmar tamper-evidence forte.
- Paper e README devem usar linguagem precisa.

### Criterios de Aceite

- Documentacao nao confunde replay deterministico com prova de adulteracao.
- `verify` valida schema, duplicatas, workspace e read models.
- Hash-chain fica explicitamente fora de v1.1.

---

## ADR-004 — Horizonte Longo: Snapshot + Decisoes + Janela

**Status:** Aceito para v1.1/v2 faseado

### Problema

Um log completo cresce indefinidamente. Se um agente frio ler o `activity.jsonl` inteiro, o sistema volta ao problema original: gastar contexto com copia mecanica e sofrer lost-in-the-middle.

Por outro lado, truncar o log perde historia e razoes antigas. Resumir por LLM quebra determinismo e reintroduz custo de tokens.

### Decisao

O read path de longo prazo deve combinar:

```text
snapshot duravel
+ decisoes curadas
+ tarefas projetadas
+ janela recente paginada
= contexto suficiente sem ler o log inteiro
```

Na v1.1:

- implementar contexto paginado;
- projetar `decisions.md`;
- projetar `tasks.json`;
- manter snapshot completo fora do escopo ou como comando preparatorio simples.

Na v2:

- snapshot/replay formal;
- possivel integracao com esaa-core.

### Consequencias

**Positivas**

- Mantem fronteira zero-token no caminho mecanico.
- Preserva log completo como trilha fria.
- Evita sumarizacao por LLM como requisito.

**Negativas**

- Exige curadoria de decisoes.
- Snapshot completo fica para depois.

### Criterios de Aceite

- Agente frio consegue ler `handoff.md`, `state.md`, `decisions.md` e `context --last`.
- `context --before` permite paginar para tras.
- `activity.jsonl` nao e leitura padrao do agente.

---

## ADR-005 — Decisoes e Tarefas Como Espinha, Turnos Como Evidencia

**Status:** Aceito para v1.1

### Problema

Turnos verbatim sao ricos, mas volumosos e sensiveis. Para handoff, o valor principal esta em:

- decisoes;
- rationale;
- tarefas;
- estado operacional;
- eventos recentes relevantes.

Se o sistema tratar turnos como espinha principal, ele maximiza privacidade e tamanho. Se tratar apenas decisoes como verdade, pode perder contexto quando agentes deixam de curar.

### Decisao

O modelo de dominio fica:

```text
turnos = evidencia
decisoes = conhecimento duravel
tarefas = continuidade operacional
snapshots = compactacao deterministica
handoff = entrada operacional
```

`activity.jsonl` contem todos os eventos, inclusive turnos. Mas read models centrais devem privilegiar eventos curados:

- `decision.recorded`
- `task.created`
- `task.updated`
- `task.closed`
- `redaction.applied`
- snapshots futuros

`decisions.md` e `tasks.json` sao sempre projetados, nunca editados manualmente.

### Consequencias

**Positivas**

- Diminui dependencia de leitura verbatim.
- Torna handoff mais limpo.
- Ajuda privacidade.

**Negativas**

- Exige comandos de curadoria bons.
- Agentes precisam desenvolver habito de registrar decisoes.

### Criterios de Aceite

- `conversation-esaa decide` emite `decision.recorded`.
- `conversation-esaa task` emite eventos `task.*`.
- `decisions.md` e `tasks.json` sao regenerados por `project`.
- Nenhum agente edita read model manualmente.

---

## ADR-006 — Convergencia Faseada Com ESAA-Core

**Status:** Aceito

### Problema

O `esaa-core` ja oferece event sourcing mais maduro, hash-chain, snapshot/replay e verificacao. Mas seu vocabulario atual e orientado a tarefas de engenharia (`claim`, `complete`, `review`, `task_kind`) e nao a conversa.

Migrar cedo demais pode cristalizar um dominio ainda em validacao.

### Decisao

Manter v1.1 como ferramenta local simples, com CLI de dominio proprio. Considerar v2 sobre `esaa-core` apenas quando:

1. o vocabulario conversacional estiver estavel;
2. houver pelo menos tres capacidades duplicadas claramente com o core;
3. o custo de perfil customizado for justificado;
4. snapshot/replay/hash-chain forem necessidades reais, nao esteticas.

Capacidades candidatas para v2:

- hash-chain;
- snapshot/replay;
- projector formal;
- schemas de eventos versionados;
- migracao para perfil `conversation`.

### Consequencias

**Positivas**

- Evita migracao prematura.
- Mantem foco em valor conversacional.
- Preserva caminho de amadurecimento.

**Negativas**

- v1.1 ainda carrega parte de infraestrutura propria.
- Precisa disciplina para nao recriar todo o core.

### Criterios de Aceite

- v1.1 nao tenta ser `esaa-core`.
- Documentacao deixa claro que esaa-core e backend futuro possivel.
- Hash-chain/snapshot forte nao sao implementados duas vezes.

---

## ADR-007 — Leitura Paginada e Seletiva do Event Store

**Status:** Aceito para v1.1

### Problema

Agentes nao devem consumir `activity.jsonl` inteiro. O log completo e fonte de verdade fria, nao prompt.

O usuario precisa poder dizer:

```text
Codex, leia so as ultimas iteracoes do Grok.
```

Sem carregar conversa do Claude, do Codex, historico antigo ou turnos irrelevantes.

### Decisao

Implementar comando `context` com filtros deterministas:

```powershell
conversation-esaa context --last 30
conversation-esaa context --before evt_120 --last 50
conversation-esaa context --around evt_123 --window 10
conversation-esaa context --agent grok --last 20
conversation-esaa context --topic "workspace"
conversation-esaa context --decision ADR-007
```

`context --agent <agent_id>` e o primeiro entregavel de valor visivel:

```powershell
conversation-esaa context --agent grok --last 20
```

Ele retorna eventos do workspace atual associados a:

- `agent_id=<agent_id>`
- ou `source=<agent_id>`

mantendo ordem cronologica e metadados suficientes para handoff.

### Formato de Saida

Formato inicial recomendado: Markdown legivel, deterministico:

```markdown
# Context Window

workspace: C:\xampp\htdocs\meu-projeto
filter: agent=grok
count: 20

## Events

- [2026-06-21T14:30:29-03:00] assistant/grok evt_abc
  Summary...
```

Opcionalmente `--json` retorna JSON.

### Consequencias

**Positivas**

- Materializa memoria navegavel.
- Reduz tokens e ruido.
- Ajuda handoff seletivo entre agentes.

**Negativas**

- Precisa indice ou leitura eficiente em logs grandes.
- `--topic` textual pode perder sinonimos.

---

## ADRs Futuros / Em Discussão

- **ADR-009** — Camada de Memória Intermediária por Assuntos (Topic Memory Layer)
  Proposta detalhada de uma memória de acesso rápido organizada por tópicos/assuntos.
  Local: `adr-009-memoria-intermediaria-por-assuntos.md`
  Objetivo: permitir listar assuntos de forma barata antes de expandir para o `activity.jsonl`.
  Status: Em análise (pronta para revisão por Codex e outros agentes).

Consulte o arquivo dedicado para o texto completo da proposta.

### Criterios de Aceite

- `context --agent grok --last 20` retorna no maximo 20 eventos do Grok.
- Resultado respeita `workspace_root`.
- Ordenacao e deterministica.
- `--before` e `--around` funcionam por `event_id`.
- `--topic` usa busca textual deterministica, sem embeddings na v1.1.

---

## ADR-008 — Workspace Isolation Como Invariante

**Status:** Aceito para v1.1

### Problema

O lab mostrou contaminacao conceitual: eventos sobre `ESAA-dashboard` apareceram no contexto do `esaa-conversational-lab`. Mesmo sem quebrar `verify`, isso reduz confianca no handoff.

Memoria compartilhada so e util se for claramente por workspace.

### Decisao

Todo evento novo deve carregar:

```json
{
  "workspace_root": "C:\\xampp\\htdocs\\meu-projeto"
}
```

Todo comando deve operar dentro de um workspace explicito ou deterministico:

```powershell
conversation-esaa sync --agent grok --workspace C:\xampp\htdocs\meu-projeto
conversation-esaa context --agent grok --workspace C:\xampp\htdocs\meu-projeto
```

Adaptadores devem rejeitar transcripts cujo cwd/projeto nao corresponda ao workspace alvo. `verify` deve alertar ou falhar quando evento novo nao possuir `workspace_root` ou quando `workspace_root` nao bater com `--workspace`.

Como ferramenta greenfield, eventos antigos do lab sem `workspace_root` nao precisam migrar para publicacao. O bootstrap publico deve sair com log vazio.

### Consequencias

**Positivas**

- Impede contexto de outro projeto no handoff.
- Torna `context` confiavel.
- Permite multiplos projetos na mesma maquina.

**Negativas**

- Exige atualizar event schema e fixtures.
- Exige regras por adaptador para mapear sessao ao workspace.

### Criterios de Aceite

- Eventos novos sem `workspace_root` falham no `verify`.
- `sync` rejeita transcript de outro workspace.
- `context` filtra por workspace antes de qualquer outro filtro.
- Bootstrap cria workspace limpo e validavel.

---

## Decisao de Sequenciamento

As ADRs devem ser implementadas nesta ordem:

1. ADR-008: `workspace_root` obrigatorio.
2. ADR-001: lockfile.
3. ADR-007: `context --last`, `--before`, `--around`, `--agent`.
4. ADR-005: `decide`, `task`, `decisions.md`, `tasks.json`.
5. ADR-002: evoluir adaptadores para payload de hook quando disponivel.
6. ADR-004: preparar snapshot sem tornar requisito.
7. ADR-003 e ADR-006: manter como limites de v1.1 e ponte para v2.
