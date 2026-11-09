# FIX132 PS-07 — perfil e otimização

Referência WIP: `45ed2c8`. Experimentos em workspaces sintéticos; o ledger real não foi usado nos testes. N indica turnos, com 200 tarefas (400 eventos) adicionais. Tempos de relógio de uma execução por cenário; não são medianas nem benchmark controlado.

| Turnos | Versão | reparo | captura + estado | project | verify | total |
|---:|---|---:|---:|---:|---:|---:|
| 0 | anterior | 0,186 s | 0,219 s | 1,704 s | 6,555 s | 9,434 s |
| 0 | candidata | 0,149 s | 0,212 s | 1,431 s | 1,802 s | 4,318 s |
| 1000 | anterior | 0,756 s | 0,875 s | 2,426 s | 16,551 s | 21,339 s |
| 1000 | candidata | 0,637 s | 0,641 s | 2,913 s | 3,965 s | 8,917 s |

A instrumentação separa o corpo da seção sob lock; total inclui processo e trabalho externo ao corpo. Não decompõe isoladamente aquisição do lock, startup de subprocessos, Node ou Resolve-Path. O gargalo observado foi `verify`, que relia e reinterpretava o ledger inteiro para cada atualização ou fechamento de tarefa. A mudança indexa criações uma vez e mantém fallback para comparações legadas com IDs não textuais. Preserva a regra histórica de aceitar criação em qualquer posição do ledger.

Verificação: em um mesmo workspace sintético com 1000 turnos e 200 tarefas, ambas as implementações retornaram `verify: ok` e os hashes de ledger e projeções permaneceram iguais. Três testes dirigidos cobrem identidade numérica e diferenças de caixa, criação posterior, referências ausentes e mensagens de erro para entradas inválidas. Revisão independente comparou oito casos, incluindo esses e `straße`/`STRASSE`. A suíte PowerShell na candidata inicial resultou em 111/1, com a única falha herdada `handoff_includes_recent_events`; a versão revisada também foi testada com os casos dirigidos. A revisão não prova equivalência para todo Unicode ou todos os valores JSON possíveis.

O limiar original de 20.000 turnos não foi medido. A evidência anterior em `/tmp/fix132-evidence/PS-07/verdict.md` registra medianas de 29,330 s (1000) e 75,982 s (5000), mas não substitui a medição de 20.000. Não se conclui que os hooks reais atingem timeout nem que provoquem locks órfãos. A otimização não altera o contrato de locks.
