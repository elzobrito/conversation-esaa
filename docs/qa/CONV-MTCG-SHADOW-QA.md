# Relatório de QA — Memory-TCG / RRR Shadow Mode (`CONV-MTCG-QA-009`)

**Data:** 2026-11-07  
**Task ESAA:** `CONV-MTCG-QA-009`  
**Modo de Revisão:** `security`  
**Status:** APROVADO (GATE SHADOW VALIDADO)

---

## 1. Escopo da Auditoria

Validação independente do ciclo **Memory-TCG + RRR** em modo `shadow` (tasks `CONV-MTCG-SPEC-001` a `CONV-MTCG-IMPL-008`), cobrindo:
1. Replay lógico e estabilidade determinística por hash (`source_snapshot_id`, `generation_id`, `proposal_id`).
2. Invariante de não-mutação de artefatos canônicos (`activity.jsonl`, `handoff.md`, `state.md`, `decisions.md`, `tasks.json`, `topics.json`).
3. Invariante Zero-Token / Zero-Network (execução sem chaves de API e com proxies inválidos bloqueando tráfego externo).
4. Invariantes TCG de separação de certeza (`derived_edges` vs `possible_edges` vs `boundaries`), proveniência obrigatória (`evidence_event_ids`) e redaction de segredos.
5. Compatibilidade com `rag` desabilitado (`off`) e isolamento de falhas do consolidador em relação ao pipeline principal (`sync`, `project`, `verify`, `context`).

---

## 2. Evidências por Critério de Aceite

### 2.1 Replay Lógico e Estabilidade por Hash
- **Suíte Unitária Node.js (`tests/memory/*.test.js`):** 9/9 testes aprovados (`216.87ms`).
  - `tests/memory/snapshot.test.js`: confirma que `createWorkspaceSnapshot` produz o mesmo `source_snapshot_id` (`sha256`) e `watermark_event_id` para entradas equivalentes NFC/CRLF-normalizadas, filtra eventos de outros workspaces e exclui eventos `memory.*`.
  - `tests/memory/graph.test.js`: confirma que `buildMemoryGraph` gera `generation_id` idêntico independientemente da ordem de inserção dos fatos e falha fechado com `UNSUPPORTED_FACT` / `INTEGRITY_FAILURE` quando invariantes são violados.
  - `tests/memory/ringing.test.js`: confirma que `runRinging` com PRNG Mulberry32 produz subconjunto amostrado idêntico para a mesma `seed` (`42`) e diferente para `seed` distinta (`99`), além de falhar fechado com `LIMIT_EXCEEDED` acima do teto configurado.
  - `tests/memory/resonance.test.js`: confirma que `runResonance` preserva `possible_edges` separados de `derived_edges`, deduplica ecos de agentes (`independent_support_count = 1`) e sinaliza conflitos sem vencedor silencioso.
  - `tests/memory/renormalize.test.js`: confirma que `runRenormalization` emite `proposal_id` idêntico sob replay e restringe ações ao conjunto permitido (`retain`, `group_exact_duplicates`, `deprioritize_in_active_view`, `mark_historical_explicit`, `flag_conflict`).
- **Suíte E2E PowerShell (`tests/test-memory-shadow.ps1`):** 27/27 asserções aprovadas (`exit 0`).
  - Duas execuções consecutivas de `conversation-esaa.ps1 memory sleep --mode shadow --seed 42 --budget all` produziram o mesmo `proposal_id` e o mesmo `graph_generation_id`.
  - Os hashes SHA-256 de `activity.jsonl`, `handoff.md`, `state.md`, `decisions.md`, `tasks.json` e `topics.json` permaneceram **100% inalterados** antes e depois do ciclo `sleep --mode shadow`.
  - Nenhum arquivo `.conversation-esaa/memory/active.json` foi criado em modo `shadow`.

### 2.2 Ausência de Chamadas LLM / Rede e Compatibilidade RAG Off
- **Comando executado:**
  ```bash
  env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u GEMINI_API_KEY -u XAI_API_KEY \
    HTTP_PROXY=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1 NO_PROXY="" \
    node --test tests/memory/snapshot.test.js tests/memory/graph.test.js \
    tests/memory/ringing.test.js tests/memory/resonance.test.js tests/memory/renormalize.test.js
  ```
- **Resultado:** 9/9 testes aprovados sem qualquer tentativa de conexão externa ou leitura de credenciais de provedores LLM.
- **Inspeção estática de `src/memory/**` e `.conversation-esaa/bin/conv-memory.ps1`:** Zero imports de `http`, `https`, `net`, `tls`, `undici` ou `fetch`.
- **Compatibilidade RAG Off:** O workspace de teste opera sem `.conversation-esaa/rag/` configurado (`rag` desabilitado por padrão), e tanto `memory status/sleep/inspect/diff/verify` quanto `conversation-esaa.ps1 project/verify` operam normalmente sem exigir `rag-sqlite`.

### 2.3 Segurança, Privacidade e Hardening
- **Permissões POSIX:** Diretórios em `.conversation-esaa/memory` criados com modo `0700` e artefatos JSON/JSONL com modo `0600`.
- **Anti-symlink:** `assertNoSymlinkChain` bloqueia qualquer symlink na cadeia `.conversation-esaa/activity.jsonl` ou `.conversation-esaa/memory/**` com erro estruturado `UNSAFE_PATH`.
- **Redaction e Telemetria:** Tokens sensíveis (`ghp_SecretToken...`, `TEST-SECRET-DO-NOT-EXPOSE`, `sk_...`, `Bearer ...`) são redigidos como `[REDACTED]` nas propostas e grafos; `.conversation-esaa/memory/logs/runs.jsonl` registra apenas contadores e durações operacionais, sem texto conversacional.
- **Proteção contra Auto-Apply:** `memory sleep --mode auto` é rejeitado com `POLICY_REJECTED` e exit code não-zero.

### 2.4 Resultados das Suítes no Ambiente de Execução
- **Ambiente verificado:** Linux x86_64 (`Node.js v22.23.1`, `PowerShell 7.5.0` em `/home/elzobrito/.local/bin/pwsh`).
- **Resultados consolidados:**
  - `node --test tests/memory/*.test.js` -> **9 passed, 0 failed**
  - `pwsh -NoProfile -File tests/test-memory-shadow.ps1` -> **27 passed, 0 failed**
  - `node --test tests/installer/all.test.js` -> **21 passed, 0 failed**
  - `pwsh -NoProfile -File .conversation-esaa/bin/conv-test.ps1` -> **112 passed, 0 failed**
- **Limitações de plataforma documentadas:** Execução realizada nativamente em Linux com PowerShell 7 (`pwsh`); em Windows, `hardenPrivatePath` delega ACLs ao perfil do usuário local (`process.platform === "win32"` no-op em `chmodSync`), mantendo normalização de fim de linha (`\r\n` -> `\n`) e `workspace_id` canônico por `sha256`.

---

## 3. Decisão de Gate (QA-009)

Todos os invariantes do modo `shadow` foram comprovados sem regressões. **Autorizado o avanço para a Fase 4 (`CONV-MTCG-IMPL-010`: promoção explícita `memory accept`, replay e rollback).**
