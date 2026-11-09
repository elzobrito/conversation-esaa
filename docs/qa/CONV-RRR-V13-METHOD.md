# Avaliação adicional para a versão 1.3

Esta avaliação preserva os braços e as métricas da versão 1.2 e acrescenta (i) as contagens de verdadeiros e falsos positivos de conflitos antes do corte e (ii) o braço CQ, uma política de encaixe aplicada à mesma lista de candidatos de C.

CQ reserva 20% do orçamento de tokens para conflitos na ordem canônica da proposta (`conflict_id`). A implementação não exporta um score de confiança por conflito; essa ordem é a mesma que, com 48 fatos e 512 tokens, retém os 4 conflitos verdadeiros e 1 falso positivo (precisão 0,800). O restante do orçamento preenche itens ativos (decisões primeiro); sobra volta a conflitos. CQ não altera a consolidação: só a serialização sob o limite.

Foram mantidos 48, 480 e 1.920 fatos, cinco seeds, limites de 512, 1.024 e 4.096 tokens por registros codificados separadamente e os braços A, B, B′, C, CP, CN, D1 e D2. O relatório `CONV-RRR-V13-OUTPUT.json` contém 405 registros (schema `conv-rrr.v13.v1`).

Antes do corte, C tem F1 de conflitos 0,615 nas três escalas, na mesma proporção: 4 verdadeiros e 5 falsos positivos em 48 fatos, 40 e 50 em 480, 160 e 200 em 1.920 (precisão 0,444, revocação 1,000).

Reprodução: instalar `tests/memory/requirements-evaluation.txt` em ambiente isolado, executar `python tests/memory/v13-evaluation.py <saida.json>` e `python tests/memory/test-v13-result.py`. As seeds alteram a amostragem, não os dados. Tempo e RSS não são determinísticos. A mesma equipe desenhou e executou a avaliação; não houve reprodução independente.
