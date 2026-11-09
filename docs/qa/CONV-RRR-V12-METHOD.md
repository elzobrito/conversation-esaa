# Avaliação adicional para a versão 1.2

Esta avaliação preserva os artefatos anteriores e adiciona B′, uma baseline instrucionista simplificada que escolhe a decisão explícita mais recente por tópico e chave e não permite que um eco a substitua. B′ recebe as mesmas chaves e evidências estruturadas das fixtures e não detecta conflitos. Não representa Mem0 nem prova qualquer hipótese sobre uma classe inteira de sistemas.

Foram mantidos 48, 480 e 1.920 fatos, cinco seeds, limites de 512, 1.024 e 4.096 tokens por registros codificados separadamente e os demais braços de [[conv-rrr-metodo-revisado]]. O relatório `CONV-RRR-V12-OUTPUT.json` contém 360 registros, incluindo precisão e revocação de conflitos; zero predições resulta em precisão indefinida (`null`).

A revocação condicional de proveniência divide os IDs de evidência corretos pelo total esperado somente para as decisões verdadeiras retornadas. É indefinida quando nenhuma decisão verdadeira é retornada. A fração de decisões retornadas com todas as evidências também é registrada. Nas fixtures examinadas, cada decisão verdadeira retornada conserva todas as suas evidências: a métrica condicional é 1 em todos os casos em que é definida. A antiga revocação global de proveniência acompanha a de decisões e não fornece evidência independente neste desenho.

Em 48 fatos, para C, o orçamento de 512 tokens retém 4 conflitos verdadeiros e 1 falso positivo (precisão 0,800, revocação 1,000); 1.024 tokens retêm os mesmos 4 verdadeiros e 5 falsos positivos (precisão 0,444, revocação 1,000). O F1, portanto, cai apesar de maior cobertura.

Reprodução: instalar `tests/memory/requirements-evaluation.txt` em ambiente isolado, executar `python tests/memory/v12-evaluation.py <saida.json>` e `node --test tests/memory/authority-baseline.test.js`. As seeds alteram a amostragem, não os dados. Tempo e RSS não são determinísticos. A mesma equipe desenhou e executou a avaliação; não houve reprodução independente.

## Referências

**Este documento referencia:** [[conv-rrr-metodo-revisado]], [[conv-rrr-matriz]], [[CONV-RRR-V12-OUTPUT.json]].

**Este documento é referenciado por:** [[consolidacao-memoria-agentes]].
