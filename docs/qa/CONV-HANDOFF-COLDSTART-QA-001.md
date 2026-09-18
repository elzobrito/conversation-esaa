# QA — retomada por handoff

Data: 2026-09-18  
Tarefa: `CONV-HANDOFF-COLDSTART-QA-001`

## Escopo

Validação regressiva do contrato de cold-start, da projeção gerada por
`Invoke-Project` e dos fallbacks de `verify` e `context`. O cenário principal
inclui uma decisão, uma tarefa aberta com `next_step`, um tópico ativo e eventos
recentes.

## Resultados

| Verificação | Resultado |
|---|---|
| Workspace vazio | O handoff informa que nenhum objetivo foi projetado e orienta `context --last 20` |
| Objetivo atual | A tarefa aberta é priorizada e incorpora seu `next_step` |
| Continuidade | Decisão vigente, tópico ativo, tarefa aberta e eventos recentes aparecem no mesmo `handoff.md` |
| Próxima ação | Usa o `next_step` da tarefa aberta; sem tarefa, retoma tópico ativo; sem estado, solicita orientação |
| Tópico identificado | `context --topic-id TOP-001` retorna somente eventos vinculados |
| Tópico inexistente | `context --topic-id TOP-999 --last 20` falha com `Unknown topic_id 'TOP-999'` |
| Paridade de harnesses | `diff AGENTS.md .claude/CLAUDE.md` vazio |
| Suíte do motor | `conv-test.ps1`: 85 testes aprovados, 0 falhas |
| Integridade textual | `git diff --check` aprovado |
| Governança | `python -m esaa --root . verify`: `verify_status: ok` |

## Conclusão

O `handoff.md` passou a funcionar como ponto de entrada para retomada. As
projeções complementares são necessárias apenas quando o resumo explicita uma
lacuna, e `context` permanece uma consulta filtrada. A implementação atende aos
critérios das tarefas de contrato, motor e QA.
