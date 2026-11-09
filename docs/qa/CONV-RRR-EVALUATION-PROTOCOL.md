# Protocolo de avaliação Memory-TCG — preparação do artigo

Estado: protocolo e resultados locais; as análises adicionais foram definidas durante a investigação e não constituem pré-registro independente.

## Pergunta

Como o ciclo determinístico de consolidação preserva decisões e proveniência e sinaliza conflitos, em comparação com a recuperação cronológica e uma política local simplificada, à medida que crescem memórias sintéticas? O experimento não testa consciência, sono biológico ou a necessidade universal de sono.

## Método

Congelar gerador e gabarito antes de executar. Usar cinco seeds 11, 29, 42, 73 e 101, cenários com 50, 500 e 2.000 eventos e orçamento de saída comparável. Incluir decisões superadas, duplicatas, ecos, conflitos, tópicos múltiplos, mensagens de controle e paráfrases. Avaliar RRR completo, seleção cronológica e política local de substituição por chave, mais ablações das fases. A política local é um simulador, não Mem0. Registrar entradas, versões, comandos e saídas sem dados privados.

Métricas: precisão e recall de decisões e evidências, F1 de conflitos, contaminação histórica, relevância do conteúdo retornado, tempo, pico de memória e tamanho dos artefatos. Publicar valores por cenário e seed, inclusive erros e limites; não descartar falhas. Verificar estabilidade e efeitos do orçamento parcial. As comparações em bases distintas devem esclarecer seus custos e limitações; não inferir causalidade ou significância sem desenho adequado.

## Estudo de caso e privacidade

Confrontar registros de Grok, Codex e Antigravity com eventos e gerações realmente observados. Distinguir autoria declarada de autoria verificável, consolidação aceita de shadow e tópico curado de vínculos explícitos. Dados reais permanecem no workspace privado; a versão a distribuir requer remoção de identificadores e revisão humana de privacidade. Agentes indisponíveis não serão representados como executores reais.

## Gate para redação

Resultados reproduzíveis, regressões e empacotamento aprovados; tabela artigo → implementação → evidência → limite; caso real sanitizado e revisado; afirmações restritas aos dados. A avaliação anterior de 11 e 50 fatos e o comparador local simples são preliminares. A avaliação adicional abaixo permite iniciar a redação como estudo de engenharia com as limitações registradas; não é validação independente nem liberação para publicação.

Revisão do benchmark anterior: `scoreArmResult` penalizava todas as decisões vigentes quando qualquer decisão antiga ou eco aparecia, embora seu comentário mencionasse o mesmo tópico. A métrica foi alterada para penalizar por tópico e ganhou teste específico. Relatórios gerados antes dessa correção não são comparáveis diretamente aos novos; executar novamente e revisar os resultados antes de usar CDA como evidência científica.

Foi executada uma **sondagem exploratória**: `node tests/memory/scale-experiment.js docs/qa/CONV-RRR-SCALE-EXPLORATORY.json`. O arquivo contém 90 medições para 50, 500 e 2.000 fatos e cinco seeds. Na seed 42, o F1 bruto de conflitos do RRR com orçamento completo foi 1 nos três tamanhos; com orçamento de análise de 56%, foi 0, 0,0488 e 0,1714, respectivamente. Há também um recorte adicional de 13 itens por braço, que prioriza decisões e usa vagas restantes para conflitos; esse recorte é uma aproximação grosseira. São cenários sintéticos repetitivos com chaves estruturadas; as seeds variam a amostragem, não os dados. `maxRSS` é máximo acumulado do processo, não custo isolado por braço. Não usar esses dados como demonstração de superioridade em condições equivalentes.

## Avaliação adicional com limite uniforme

`tests/memory/fair-evaluation.py` executa cada braço em um processo Node novo, com saída limitada a 1.024 tokens `cl100k_base` (`tiktoken==0.12.0`), e grava `CONV-RRR-FAIR-OUTPUT.json`. As bases possuem 48, 480 e 1.920 fatos (a sondagem anterior acrescenta preenchimento até 50, 500 e 2.000). A ordenação comum prioriza decisões e depois conflitos. Latência abrange o braço, não a geração da fixture ou tokenização; pico de RSS inclui o runtime. `output_bytes` mede a saída renderizada; `target_decision_share` é uma relevância restrita ao gabarito de decisões, não avaliação semântica geral.

Nas cinco seeds, as medianas para RRR completo foram recall de decisões **1, 0,38 e 0,095** e F1 de conflitos **1, 0,049 e 0,012**, respectivamente para os três tamanhos. O limite de saída e a ordenação influenciam esses valores. As fixtures repetem a mesma estrutura; seeds variam amostragem, não produzem amostras independentes. O comparador instructionista é uma implementação simplificada, não Mem0. Não inferir superioridade generalizada, significância estatística ou desempenho em produção.

Um segundo conjunto sintético, `adversarial-evaluation.js`, percorre o adaptador real sem chaves de conflito fornecidas. Nas cinco seeds e seis pares fixos, foram observados um verdadeiro positivo, dois falsos negativos, três verdadeiros negativos e nenhum falso positivo. As contradições de prazo e TLS passaram despercebidas. O conjunto foi criado pela mesma equipe, é pequeno e não constitui validação independente.

Reprodução: criar ambiente isolado, instalar `tests/memory/requirements-evaluation.txt` e executar `python tests/memory/fair-evaluation.py <arquivo.json>`; executar também `node tests/memory/adversarial-evaluation.js <arquivo.json>`. O primeiro uso de `cl100k_base` pode baixar o vocabulário. Comparar métricas, hashes de contexto e casos; latência e RSS variam entre execuções.

Na repetição local, os 90 resultados coincidiram nos campos determinísticos, incluindo métricas e hashes de contexto; latência e RSS foram excluídos da comparação. A verificação automática dos dois relatórios sintéticos não encontrou caminhos `/home/` nem endereços de e-mail; isso não é garantia geral de anonimização nem substitui revisão humana de privacidade antes de divulgação.

## Referências

**Este documento referencia:** [[conv-rrr-matriz]], [[conv-mtcg-benchmark]], [[conv-adr-013]].

Dados sintéticos: [[CONV-RRR-FAIR-OUTPUT.json]], [[CONV-RRR-ADVERSARIAL.json]], [[CONV-RRR-SCALE-EXPLORATORY.json]].

**Este documento é referenciado por:** [[conv-rrr-matriz]].
