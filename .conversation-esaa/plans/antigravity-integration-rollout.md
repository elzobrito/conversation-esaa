# Plano — integração Google Antigravity

## Objetivo

Adicionar `antigravity` como fonte oficial do Conversation ESAA sem misturar
resultados de ferramentas, raciocínio interno ou conversas de outros workspaces.

## Contrato de captura

- Fonte: `~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`.
- `USER_INPUT`, `status=DONE`, `content` textual: `actor=user`, `agent_id=null`.
- `PLANNER_RESPONSE`, `status=DONE`, `content` textual: `actor=assistant`, `agent_id=antigravity`.
- Ignorar entradas sem texto, tool calls, thinking, resultados de ferramentas,
  checkpoints e histórico injetado.
- Usar `created_at` como timestamp e `step_index` como índice estável.

## Sequência

1. Estender motor e CLI com `sync-antigravity` e `--agent antigravity`.
2. Criar wrapper fail-open que consome o payload JSON do hook via stdin.
3. Mesclar hook nomeado `conversation-esaa` em `.agents/hooks.json`.
4. Adicionar fixture sintética e testes de parsing, dedupe, contexto e falha.
5. Atualizar documentação e manter `AGENTS.md` igual a `.claude/CLAUDE.md`.
6. Validar em workspace temporário.
7. Fazer backup dos motores instalados e copiar apenas `bin/` e hooks públicos;
   nunca substituir `activity.jsonl`, `sync-state.json` ou projeções privadas.
8. Sincronizar uma conversa real, projetar e executar `verify`.

## Rollback

Restaurar os arquivos públicos a partir do backup do rollout. Os dados privados
não entram no conjunto copiado e, portanto, não precisam de rollback.
