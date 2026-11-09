# Revisão do experimento RRR

Os experimentos e relatórios anteriores foram preservados. Esta revisão altera a contabilização de saída e o conjunto de conflitos avaliados; seus números não devem ser comparados diretamente com o relatório anterior como se o método fosse idêntico.

## Desenho

`tests/memory/revision-evaluation.py` executa sete braços em processos separados para 48, 480 e 1.920 fatos sintéticos e seeds 11, 29, 42, 73 e 101. Cada saída é avaliada sob 512, 1.024 e 4.096 tokens `cl100k_base` de `tiktoken==0.12.0`. O custo é a soma dos tokens de cada registro JSON serializado separadamente, com quebra de linha; não inclui overhead de uma API de chat. Um item é incluído se couber, e o percurso continua após itens que não couberem.

- A: janela cronológica simplificada.
- B: atualização local simplificada por chave; não é Mem0.
- C: RRR completo, com ordenação comum por tipo e identificador.
- CP: RRR com amostragem parcial de 56%, mesma ordenação comum.
- CN: RRR completo, com a ordem de itens recuperada do `cmdContext` de produção sem limite de caracteres e reaplicada aos registros JSON padronizados. O conteúdo da serialização não é idêntico ao Markdown de produção. São mantidos itens exibidos que consomem orçamento, inclusive históricos que não contam como ativos.
- D1: ablação da amostragem estratificada, usando seleção FIFO com orçamento parcial.
- D2: ablação de resonance.

Os braços RRR e as ablações usam pares `proposal.unresolved` como candidatos de conflito, incluindo possíveis contradições; falsos positivos são contabilizados. As métricas antes do limite são separadas das métricas na saída. B e os demais braços sem um mecanismo de conflito não emitem pares. A distribuição de sementes não representa amostras independentes da população.

## Oráculo

O oráculo conhece as decisões vigentes do gabarito e ordena registros de decisão sem proveniência por custo crescente. Todos os registros têm o mesmo valor de uma decisão; com custos aditivos, a escolha dos mais baratos maximiza exatamente o número de decisões sob o orçamento. O teste verifica que nenhuma representação de decisão verdadeira de um braço custa menos que o registro do oráculo. Esse teto é condicionado à fixture, à serialização e à contabilização por registro. O oráculo não cobre proveniência, conflitos ou qualidade semântica geral; não é um teto multiobjetivo ou de tokens de mensagens de uma API.

## Saídas e reprodução

`CONV-RRR-REVISION-OUTPUT.json` contém 315 linhas de resultados, com métricas antes e depois do limite, teto do oráculo, contaminação histórica, revocação de proveniência, hashes de saída e custo. As cinco seeds não geram cinco bases diferentes. O ensaio foi repetido: todos os campos determinísticos coincidiram; tempo e RSS variaram e não foram comparados.

```bash
python -m venv .venv-evaluation
.venv-evaluation/bin/pip install -r tests/memory/requirements-evaluation.txt
.venv-evaluation/bin/python tests/memory/revision-evaluation.py resultado.json
python tests/memory/test-revision-result.py
```

O primeiro uso do tokenizador pode baixar seu vocabulário. O teste consulta o relatório versionado local; comparar uma nova execução deve ignorar apenas `elapsed_ms` e `max_rss_kib`. Latência mede a execução do braço, incluindo recuperação da ordem no caso CN; RSS inclui o processo Node. A saída é sintética. A avaliação foi construída e revisada na mesma sessão, sem reprodução independente.

## Fontes locais

- [[conv-rrr-protocolo]] — protocolo e avaliação anterior.
- [[conv-rrr-matriz]] — limites do estudo de caso.
- [[CONV-RRR-REVISION-OUTPUT.json]] — dados da revisão.
