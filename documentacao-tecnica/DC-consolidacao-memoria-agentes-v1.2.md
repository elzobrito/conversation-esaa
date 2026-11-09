---
titulo: "Quando agentes precisam consolidar memórias: uma implementação RRR no Conversation ESAA"
tipo: "Artigo científico — estudo de engenharia"
versao: "1.2"
data: "08/11/2026"
autores:
  - "Elzo Brito dos Santos Filho"
status: "Em revisão"
instituicao: "A confirmar"
departamento: "A confirmar"
---

# Quando agentes precisam consolidar memórias: uma implementação RRR no Conversation ESAA

## Resumo

Agentes baseados em modelos de linguagem podem compartilhar um histórico entre sessões, mas a persistência não assegura a recuperação de decisões vigentes e sua proveniência. Este artigo apresenta o Memory-TCG, extensão do Conversation ESAA que aplica um ciclo de consolidação inspirado em *ringing, resonance and renormalization* (RRR). Relacionamos a memória por eventos de Santos Filho [1] à hipótese selecionista de Haber e Tononi [2], distinguindo-a de uma implementação determinística baseada em regras. Em avaliação sintética exploratória, comparamos recuperação cronológica, duas baselines instrucionistas simplificadas (B, sensível apenas à recência, e B′, sensível à autoridade da decisão), RRR completo e parcial, ordenação de produção e ablações, sob limites de 512, 1.024 e 4.096 tokens e um teto oracular condicionado à representação de decisões. Com 480 fatos e 1.024 tokens, o RRR completo recuperou 0,44 das decisões vigentes, ante 0,06 da baseline cronológica e teto oracular de 0,58; com 4.096 tokens, recuperou todas. Porém B′ e a ablação sem *resonance* empataram com o RRR completo em todas as escalas, e a ablação sem amostragem estratificada ficou a no máximo 0,03 dele: o ganho sobre a janela cronológica decorre da filtragem da visão ativa, não da amostragem nem da ressonância. Antes do corte, o F1 de conflitos do RRR completo foi 0,615 nas três escalas (precisão 0,444, revocação 1,000); depois do corte, com 480 fatos e 1.024 tokens, foi 0,000. As fixtures são repetitivas, os comparadores simplificados e a avaliação não é independente. Os resultados sustentam uma análise de engenharia, não uma afirmação de superioridade do mecanismo selecionista.

**Palavras-chave:** agentes de inteligência artificial; memória conversacional; event sourcing; consolidação de memória; RRR; rastreabilidade.

## Abstract

Language-model agents can share conversational history across sessions, but persistence does not ensure retrieval of current decisions and their provenance. This paper presents Memory-TCG, a Conversation ESAA extension implementing an RRR-inspired consolidation cycle. We relate the event-sourced memory in [1] to the selectionist hypothesis in [2] while distinguishing that hypothesis from a deterministic rule-based implementation. An exploratory synthetic evaluation compares chronological retrieval, two simplified instructionist baselines (recency-only B and authority-aware B′), complete and partial RRR, production ordering, and ablations under 512, 1,024, and 4,096-token limits, with a decision-only oracle ceiling. With 480 facts and 1,024 tokens, full RRR recalled 0.44 of current decisions, versus 0.06 for chronological retrieval and 0.58 for the oracle; with 4,096 tokens it recalled all of them. However, B′ and the no-resonance ablation matched full RRR at every scale, and the FIFO ablation stayed within 0.03: the gain over the chronological window comes from active-view filtering, not from sampling or resonance. Before truncation, full-RRR conflict F1 was 0.615 at all three scales (precision 0.444, recall 1.000); after truncation, with 480 facts and 1,024 tokens, it was 0.000. Repetitive fixtures, simplified baselines, and lack of independent replication limit these findings to an engineering study.

**Keywords:** artificial intelligence agents; conversational memory; event sourcing; memory consolidation; RRR; traceability.

## Sumário

1. Introdução
2. Fundamentos e trabalhos relacionados
3. Arquitetura e implementação
4. Método de avaliação
5. Resultados
6. Discussão e ameaças à validade
7. Conclusão
- Apêndice A — Continuidade observada
- Referências

## Controle de versões

| Versão | Data | Autoria | Descrição |
|---|---|---|---|
| 1.0 | 08/11/2026 | Elzo Brito dos Santos Filho | Primeira versão para revisão. |
| 1.1 | 08/11/2026 | Elzo Brito dos Santos Filho | Separação entre métricas antes e depois do corte, oráculo de decisões, três orçamentos, ablações D1/D2, ordem de produção (CN) e diagnóstico da baseline B. |
| 1.2 | 08/11/2026 | Elzo Brito dos Santos Filho | Baseline B′ sensível à autoridade; atribuição dos ganhos à filtragem da visão ativa; precisão e revocação de conflitos; proveniência condicional; dispersão de CP antes do corte; conclusão atualizada; correções de forma. |

## 1. Introdução

O uso de agentes heterogêneos em um mesmo trabalho exige continuidade entre sessões e ferramentas. Uma decisão tomada em uma conversa pode não estar presente na próxima janela de contexto; um resumo antigo pode sobreviver depois de uma mudança de decisão; e uma repetição feita por outro agente pode ser confundida com uma nova evidência. A persistência do texto é necessária para recuperar o histórico, mas a seleção do que apresentar continua sendo um problema distinto.

O ESAA estabelece a separação entre intenções de agentes e mutações de estado por um orquestrador [3]. O ESAA-Conversational aborda a continuidade por meio de um histórico local de eventos e de projeções para handoff [1]. Seu foco é registrar e disponibilizar o estado conversacional entre agentes. Haber e Tononi [2], por sua vez, discutem o custo da plasticidade em sistemas que aprendem continuamente e propõem uma analogia com a consolidação de memória durante o sono. Os autores apresentam como hipótese testável que uma abordagem selecionista de consolidação possa superar alternativas instrucionistas à medida que a memória cresce e se torna interconectada.

Este artigo investiga a seguinte questão: **como integrar uma consolidação inspirada em RRR a uma memória conversacional compartilhada, preservando a proveniência e expondo os limites das decisões automáticas?** A resposta é apresentada como estudo de engenharia do Memory-TCG, componente do Conversation ESAA. As contribuições são: (i) um mapeamento entre as fases propostas em [2] e operações implementadas sobre o histórico de [1]; (ii) uma arquitetura com propostas inspecionáveis, promoção explícita e reconstrução a partir de eventos; e (iii) uma avaliação exploratória com ablações e uma baseline sensível à autoridade, que mostra quais componentes explicam os ganhos observados e quais não contribuem nesta avaliação.

O termo *sonhar* designa aqui um comando de consolidação. Não descreve experiência subjetiva, consciência ou sono biológico de um agente.

## 2. Fundamentos e trabalhos relacionados

### 2.1 Continuidade conversacional baseada em eventos

Em [1], turnos visíveis são capturados por adaptadores e normalizados em um histórico acrescentável. Projeções como `handoff.md`, `state.md`, decisões e tarefas permitem que um agente retome um trabalho sem acesso direto à sessão interna de outro. A captura mecânica é separada da curadoria explícita de decisões e tarefas. O estudo de caso de [1] relata 570 eventos de laboratório e descreve a versão pública 1.1.0; não avalia a extensão Memory-TCG apresentada neste artigo.

Esse modelo fornece uma propriedade central: a visão apresentada a um agente pode ser regenerada a partir de registros de origem. Entretanto, um histórico acrescentável não resolve sozinho a distinção entre informação vigente e obsoleta. Tampouco garante que uma visão limitada por tokens inclua todas as evidências relevantes.

### 2.2 Outros sistemas de memória

MemGPT [4] organiza memória em níveis para estender o contexto efetivo de modelos. Generative Agents [5] mantém registros de experiências e sintetiza reflexões que alimentam o planejamento. Mem0 [6] propõe extração, atualização e recuperação de memórias conversacionais; as baselines B e B′ deste trabalho são apenas simplificações locais inspiradas na classe de políticas de atualização, sem executar Mem0. Sleep-time Compute [7] desloca processamento de modelos para antes das consultas; o Memory-TCG difere por executar seu ciclo offline sem chamadas a modelos. A hipótese de homeostase sináptica de Tononi e Cirelli [8] fornece o contexto biológico para a discussão de [2], sem implicar equivalência funcional entre cérebro e software.

### 2.3 A hipótese RRR

Haber e Tononi [2] descrevem o RRR como uma perspectiva selecionista para consolidação: circuitos são amostrados (*ringing*), sua dinâmica de coerência ou recorrência é avaliada (*resonance*) e conexões são seletivamente enfraquecidas ou preservadas (*renormalization*). Para sistemas digitais, os autores sugerem possibilidades como percorrer traços de memória fora de uma consulta ativa, avaliar alinhamento semântico e reduzir redundâncias. Essas sugestões não constituem uma especificação executável única.

O artigo também prevê que a lógica selecionista possa ter vantagens sobre estratégias instrucionistas, nas quais uma operação explícita atualiza cada memória. Essa previsão é uma hipótese empírica, não um resultado demonstrado pelo estudo de engenharia aqui apresentado. A implementação examinada usa políticas programadas e, portanto, não é uma realização completa da competição selecionista descrita em [2].

## 3. Arquitetura e implementação

### 3.1 Da conversa ao grafo

O Conversation ESAA mantém `activity.jsonl` como fonte canônica de eventos conversacionais. Um adaptador cria um snapshot do workspace, identifica seu marco de eventos (*watermark*) e normaliza registros em fatos. O núcleo Memory-TCG constrói um grafo com episódios, decisões, tópicos e tarefas. Cada nó conserva identificadores de evidência; relações derivadas exigem regra e origem identificáveis.

O grafo distingue relações derivadas de relações possíveis. Uma substituição registrada explicitamente pode sustentar a marcação de uma decisão como histórica. Uma associação lexical ou contradição sugerida por heurística permanece candidata; sua pontuação não a transforma automaticamente em fato verificado. Essa separação reduz o risco de converter semelhança textual ou repetição em autoridade.

### 3.2 Mapeamento das três fases

| Fase | Implementação no Memory-TCG | Limite da correspondência |
|---|---|---|
| *Ringing* | Amostragem por tópico e janela temporal, com seed reproduzível e orçamento configurável; o percurso considera relações do grafo. | O procedimento é uma política determinística de amostragem, não uma reprodução de atividade neural espontânea. |
| *Resonance* | Identificação de duplicatas exatas, sobreposição lexical, relações candidatas e alguns conflitos estruturados. | Similaridade lexical não garante equivalência semântica; conflitos fora das regras podem passar despercebidos. |
| *Renormalization* | Proposta de retenção, agrupamento de duplicatas, despriorização, marcação histórica e sinalização de conflitos. | A seleção segue regras explícitas; não gera necessariamente abstrações de alto nível nem demonstra competição emergente. |

O ciclo opera offline, sem chamadas a modelos de linguagem e sem embeddings obrigatórios. Com a mesma entrada, política e seed, a execução é projetada para produzir saída reproduzível. A despriorização atua na visão ativa; não remove fisicamente os eventos do histórico.

### 3.3 Isolamento, promoção e atribuição

Em modo *shadow*, a consolidação gera uma proposta que pode ser inspecionada antes de alterar a memória ativa. Na promoção, o sistema compara o watermark da proposta com o estado corrente; se o histórico avançou, uma proposta defasada é recusada. Uma aceitação gera evento auditável e materializa a visão ativa. O rollback registra outra transição, preservando o histórico e permitindo reconstrução por replay.

Os comandos de curadoria aceitam uma identidade de agente declarada. A ausência de identidade é representada como desconhecida; a declaração não autentica o executor. Em eventos históricos, algumas identidades eram preenchidas por valores fixos no programa. Por isso, esses registros não devem ser utilizados isoladamente como prova de autoria. Propostas aceitas podem ser inspecionadas a partir do evento canônico quando seu arquivo *shadow* não estiver disponível; uma proposta não encontrada em nenhuma dessas fontes permanece uma lacuna documental.

## 4. Método de avaliação

### 4.1 Cenários e braços

Foram usadas fixtures sintéticas com 48, 480 e 1.920 fatos, decisões atuais e superadas, ecos, duplicatas e conflitos. As seeds 11, 29, 42, 73 e 101 alteram a amostragem e não representam cinco bases independentes. Os braços são:

- **A** — janela cronológica;
- **B** — política local simplificada que mantém o evento mais recente por tópico e chave, sem distinguir decisão de eco;
- **B′** — política local simplificada que mantém a decisão explícita mais recente por tópico e chave e não permite que um eco a substitua; recebe as mesmas chaves e evidências estruturadas das fixtures e não detecta conflitos;
- **C** — RRR completo com ordenação comum;
- **CP** — RRR com amostragem parcial de 56%;
- **CN** — RRR completo reproduzindo a ordem do `cmdContext` de produção;
- **D1** — RRR com a amostragem estratificada substituída por FIFO;
- **D2** — RRR sem *resonance*.

A ordenação comum serializa primeiro as decisões ativas, depois os demais itens ativos e, por último, os conflitos candidatos. CN extrai a ordem integral do caminho de leitura de produção, incluindo itens não ativos que consomem orçamento, mas utiliza a mesma serialização JSON padronizada dos demais braços. É um ensaio da ordem de produção, não da saída Markdown exata. Os candidatos de conflito incluem pares de `proposal.unresolved`, inclusive possíveis contradições; falsos positivos são contados.

### 4.2 Orçamento e oráculo

Cada braço roda em processo Node separado. Aplicam-se limites de 512, 1.024 e 4.096 tokens `cl100k_base` (`tiktoken` 0.12.0). O custo é a soma dos tokens de registros JSON codificados separadamente, incluindo quebras de linha e excluindo overhead de protocolo de chat. Após um item que não cabe, o adaptador continua examinando os demais.

O oráculo conhece as decisões vigentes e ordena seus registros, com campo de proveniência vazio, pelo menor custo. Como cada decisão tem valor unitário e os custos são aditivos, obtém o número máximo de decisões desse formato sob o orçamento. O oráculo é determinístico e não depende da seed. Verificou-se que, nestes dados, nenhuma representação emitida para uma decisão verdadeira custa menos que a do oráculo. O teto é condicionado à serialização e à fixture: não é teto para conflitos, preservação de proveniência ou objetivos combinados.

### 4.3 Métricas e reprodução

Relatamos revocação de decisões antes e depois do corte; precisão, revocação e F1 dos conflitos; e contaminação histórica, definida como a fração dos registros obsoletos do gabarito exibidos como ativos. A precisão de conflitos é indefinida quando não há predições. A proveniência é medida de forma condicional: a fração dos IDs de evidência esperados presentes **dentro das decisões verdadeiras retornadas**, indefinida quando nenhuma decisão verdadeira é retornada; registramos também a fração dessas decisões que traz todas as suas evidências. A revocação global de proveniência usada na versão anterior acompanhava exatamente a revocação de decisões, porque cada decisão leva consigo suas evidências, e por isso foi retirada da Tabela 1.

Reportamos valores entre as cinco seeds como mediana [mínimo, máximo]. `elapsed_ms`, pico de RSS, dados individuais e custo de saída estão nos artefatos. Os scripts foram executados duas vezes; os campos determinísticos e hashes de saída coincidiram; tempo e RSS foram excluídos dessa comparação.

Um conjunto adicional de seis pares passou pelo adaptador real sem chaves de conflito fornecidas: três pares contraditórios e três negativos. Foi produzido pela mesma equipe e é pequeno. O repositório de artefatos [9] contém código, dados sintéticos, comandos e limitações da versão 1.1; os artefatos da versão 1.2 (B′ e métricas adicionais) estão descritos em `docs/qa/CONV-RRR-V12-METHOD.md`. A avaliação não foi reproduzida de forma independente.

## 5. Resultados

### 5.1 Separação entre consolidação e saída

Antes do limite de saída, C, CN, B′ e D2 retiveram todas as decisões vigentes nas três escalas (revocação 1,000 em todas as seeds); D1 reteve 0,40 em 48 fatos e 0,56 em 480 e 1.920 fatos. O F1 de conflitos de C e CN antes do corte foi 0,615 nas **três escalas**, com 4 verdadeiros e 5 falsos positivos em 48 fatos (precisão 0,444, revocação 1,000); a igualdade entre escalas é consistente com a repetição de padrões das fixtures escaladas. Depois do corte, porém, o F1 de conflitos de C é 0,000 nas escalas de 480 e 1.920 fatos sob 1.024 tokens (Tabela 1). Os valores idênticos de revocação pós-corte de C e CP também não estabelecem que produziram a mesma consolidação: antes do corte, CP difere em conflitos (Tabela 3).

**Tabela 1 — Saída sob 1.024 tokens (valores idênticos nas cinco seeds)**

| Fatos | Braço | Revocação de decisões | Precisão de conflitos | Revocação de conflitos | F1 de conflitos | Contaminação histórica |
|---:|---|---:|---:|---:|---:|---:|
| 48 | A | 0,600 | — | 0,000 | 0,000 | 0,400 |
| 48 | B | 0,000 | — | 0,000 | 0,000 | 0,500 |
| 48 | B′ | 1,000 | — | 0,000 | 0,000 | 0,000 |
| 48 | C | 1,000 | 0,444 | 1,000 | 0,615 | 0,000 |
| 48 | CP | 1,000 | 0,000 | 0,000 | 0,000 | 0,000 |
| 48 | CN | 1,000 | 0,444 | 1,000 | 0,615 | 0,000 |
| 48 | D1 | 0,400 | 0,500 | 0,500 | 0,500 | 0,100 |
| 48 | D2 | 1,000 | — | 0,000 | 0,000 | 0,000 |
| 480 | A | 0,060 | — | 0,000 | 0,000 | 0,040 |
| 480 | B | 0,000 | — | 0,000 | 0,000 | 0,140 |
| 480 | B′ | 0,440 | — | 0,000 | 0,000 | 0,000 |
| 480 | C | 0,440 | — | 0,000 | 0,000 | 0,000 |
| 480 | CP | 0,440 | — | 0,000 | 0,000 | 0,000 |
| 480 | CN | 0,440 | — | 0,000 | 0,000 | 0,000 |
| 480 | D1 | 0,420 | 1,000 | 0,025 | 0,049 | 0,010 |
| 480 | D2 | 0,440 | — | 0,000 | 0,000 | 0,000 |
| 1920 | A | 0,025 | — | 0,000 | 0,000 | 0,020 |
| 1920 | B | 0,000 | — | 0,000 | 0,000 | 0,037 |
| 1920 | B′ | 0,110 | — | 0,000 | 0,000 | 0,000 |
| 1920 | C | 0,110 | — | 0,000 | 0,000 | 0,000 |
| 1920 | CP | 0,110 | — | 0,000 | 0,000 | 0,000 |
| 1920 | CN | 0,110 | — | 0,000 | 0,000 | 0,000 |
| 1920 | D1 | 0,105 | 1,000 | 0,006 | 0,012 | 0,003 |
| 1920 | D2 | 0,110 | — | 0,000 | 0,000 | 0,000 |

“—”: precisão indefinida (nenhum conflito retornado).

Os intervalos entre seeds na Tabela 1 são degenerados: após o corte, as cinco seeds produziram exatamente os mesmos valores. Consequentemente, **a seed não é uma variável relevante para a saída final** nesta avaliação; a amostragem só altera o resultado antes do corte, e apenas no braço parcial (Tabela 3).

A proveniência condicional foi 1,000 em todos os casos em que é definida: toda decisão verdadeira retornada, em qualquer braço exceto B (que não retorna nenhuma), trouxe todas as suas evidências. Neste desenho, portanto, a proveniência não discrimina braços.

**Tabela 2 — Revocação de decisões por orçamento e teto oracular**

| Fatos | Tokens | C: ordem comum | CN: ordem de produção | B′ | Oráculo de decisões (determinístico) |
|---:|---:|---:|---:|---:|---:|
| 48 | 512 | 1,000 | 1,000 | 1,000 | 1,000 |
| 48 | 1024 | 1,000 | 1,000 | 1,000 | 1,000 |
| 48 | 4096 | 1,000 | 1,000 | 1,000 | 1,000 |
| 480 | 512 | 0,220 | 0,220 | 0,220 | 0,280 |
| 480 | 1024 | 0,440 | 0,440 | 0,440 | 0,580 |
| 480 | 4096 | 1,000 | 1,000 | 1,000 | 1,000 |
| 1920 | 512 | 0,055 | 0,055 | 0,055 | 0,070 |
| 1920 | 1024 | 0,110 | 0,110 | 0,110 | 0,145 |
| 1920 | 4096 | 0,445 | 0,445 | 0,445 | 0,585 |

Com 480 fatos e 1.024 tokens, C e CN recuperaram 0,44 das decisões, contra 0,06 em A: cerca de 7,3 vezes o valor da baseline cronológica nesta fixture, e aproximadamente 76% do teto oracular condicionado (0,58). Com 4.096 tokens, a 480 fatos, C, CN e B′ recuperaram todas as decisões, alcançando o oráculo. O oráculo não preserva evidências nem avalia conflitos.

**Tabela 3 — F1 de conflitos de CP antes do corte, por seed (1.024 tokens)**

| Fatos | Seed 11 | Seed 29 | Seed 42 | Seed 73 | Seed 101 | Mediana |
|---:|---:|---:|---:|---:|---:|---:|
| 48 | 0,000 | 0,000 | 0,000 | 0,000 | 0,000 | 0,000 |
| 480 | 0,033 | 0,000 | 0,152 | 0,033 | 0,031 | 0,033 |
| 1920 | 0,047 | 0,023 | 0,081 | 0,008 | 0,039 | 0,039 |

Em CP, a revocação de decisões antes do corte foi 1,000 em todas as seeds; só a detecção de conflitos variou.

### 5.2 Atribuição dos ganhos: as ablações e B′

As ablações mostram que, **na revocação de decisões, ringing e resonance quase não contribuem**:

- D2 (sem *resonance*) empata com C em todas as combinações de escala e orçamento: 1,000, 0,440 e 0,110 sob 1.024 tokens.
- D1 (FIFO no lugar da amostragem estratificada) fica no máximo 0,03 abaixo de C após o corte (0,420 contra 0,440 a 480 fatos e 1.024 tokens; 0,415 contra 0,445 a 1.920 fatos e 4.096 tokens), apesar de reter apenas 0,56 das decisões antes do corte.
- B′, que não executa nenhuma das três fases e apenas impede que um eco substitua a decisão explícita, empata com C em todas as nove combinações da Tabela 2.

O ganho de cerca de 7,3 vezes sobre A, portanto, vem quase todo da **filtragem da visão ativa** — marcação histórica de decisões substituídas e remoção de ecos —, isto é, de regras de renormalização baseadas em autoridade, e não da amostragem nem da ressonância. A contribuição da *resonance* aparece apenas em conflitos, e só antes do corte: D2 tem F1 0,000 antes e depois, enquanto C tem 0,615 antes do corte.

### 5.3 Conflitos sob orçamento

**O F1 cai quando o orçamento aumenta.** Em 48 fatos, C retém, com 512 tokens, 4 conflitos verdadeiros e 1 falso positivo (precisão 0,800, revocação 1,000, F1 0,889); com 1.024 tokens, os mesmos 4 verdadeiros e 5 falsos positivos (precisão 0,444, revocação 1,000, F1 0,615). O orçamento maior não acrescenta conflitos verdadeiros; apenas deixa entrar candidatos de `unresolved` que são falsos positivos.

**Conflitos somem depois do corte nas escalas maiores.** A ordenação serializa todos os itens ativos antes dos conflitos. Em 480 fatos, C mantém 50 decisões e 72 episódios ativos; com 4.096 tokens, esses itens consomem 4.094 tokens e nenhum conflito cabe, embora a revocação de decisões seja 1,000. D1, cuja visão ativa é menor (28 decisões e 50 episódios), deixa espaço e alcança F1 0,506 (precisão 0,468, revocação 0,550) no mesmo cenário. A vantagem de D1 em conflitos após o corte é efeito de ordem e orçamento, não de melhor detecção: antes do corte, o F1 de D1 (0,500) é menor que o de C (0,615).

**C e CN.** As duas ordenações produzem a mesma revocação de decisões em todos os cenários porque ambas serializam as decisões ativas primeiro; os itens não ativos que CN acrescenta entram depois delas. A diferença aparece só no que vem depois: em 48 fatos e 512 tokens, CN gasta orçamento com tópicos e assuntos antes dos conflitos e retém 3 verdadeiros e 5 falsos positivos (F1 0,500), contra 0,889 em C. Com 1.024 tokens, o orçamento comporta tudo e ambos chegam a 0,615. A igualdade na contagem de decisões não implica que as mesmas decisões sejam escolhidas em todos os casos.

### 5.4 Por que B retorna zero

Em cada tópico da fixture escalada, B mantém o evento mais recente de cada chave. O eco episódico posterior substitui a decisão autoritativa: por isso B retorna zero decisões vigentes **antes mesmo do limite de saída**, e sua contaminação histórica após o limite chega a 0,140 em 480 fatos e 1.024 tokens. O comportamento decorre do desenho da baseline, que favorece recência; B′ corrige exatamente esse ponto e passa a empatar com C.

### 5.5 Pares adversariais

As cinco seeds produziram resultados idênticos nos seis pares sem chaves de conflito fornecidas: um verdadeiro positivo, dois falsos negativos, três verdadeiros negativos e nenhum falso positivo. Precisão, revocação e F1 de conflito foram, respectivamente, 1,000, 0,333 e 0,500. Os conflitos de prazo e TLS passaram despercebidos. O conjunto pequeno e produzido pela mesma equipe serve apenas para demonstrar falhas concretas [9].

### 5.6 Evidência funcional

Testes locais exercitaram modo *shadow*, rejeição de proposta defasada, promoção, rollback, replay, recuperação de proposta a partir do ledger, consulta por tópico, a baseline B′ e instalação em ambiente isolado. Não comprovam atualização da instalação global nem revisão independente.

## 6. Discussão e ameaças à validade

O Memory-TCG mostra que é possível integrar as três etapas nomeadas no RRR a uma memória conversacional compartilhada sem substituir o histórico de origem. O snapshot e o watermark permitem avaliar uma versão estável da memória; a promoção explícita torna a mudança da visão ativa auditável; e a separação entre arestas verificadas e candidatas evita que uma sugestão lexical se torne automaticamente uma decisão autoritativa.

**O que explica os resultados.** A principal leitura da avaliação é que a recuperação de decisões sob orçamento depende da **filtragem por autoridade** na visão ativa. Uma baseline instrucionista simples que distingue decisão de eco (B′) obtém a mesma revocação do RRR completo em todas as escalas, e as ablações D1 e D2 ficam a no máximo 0,03 dele. Nesta avaliação, *ringing* e *resonance* não contribuem para a revocação de decisões; a *resonance* contribui apenas para a detecção de conflitos antes do corte, e essa contribuição se perde depois do corte nas escalas maiores porque os conflitos são serializados após os itens ativos. Uma ordenação que reserve orçamento para conflitos é, portanto, um ajuste de engenharia mais promissor do que alterar a amostragem.

**A previsão de [2] não foi testada.** O empate entre B′ e C não refuta nem confirma a hipótese selecionista: as fixtures fornecem chaves estruturadas e relações explícitas de substituição, condição em que uma regra instrucionista é suficiente por construção. A vantagem prevista em [2] diz respeito a memórias grandes e interconectadas, sem chaves explícitas, que este desenho não representa. Além disso, a implementação avaliada é determinística e baseada em regras, não uma competição selecionista.

**Correspondência parcial com [2].** A amostragem reproduzível substitui uma exploração estocástica aberta; a ressonância usa regras e sobreposição lexical, não uma avaliação geral de significado; e a renormalização é uma seleção determinada por política. Essas escolhas favorecem inspeção e replay, mas não demonstram que a relevância emerge de competição entre memórias. O estudo tampouco mede alteração de pesos de um modelo ou aprendizado contínuo dos seus parâmetros.

**Ameaças à validade.** As fixtures escaladas repetem padrões e fornecem chaves estruturadas de conflito, o que provavelmente explica a igualdade do F1 pré-corte entre escalas e os intervalos degenerados entre seeds; o conjunto sem chaves tem apenas seis pares. O limite de tokens é real para o tokenizador escolhido, mas outros modelos podem usar tokenizadores e janelas diferentes. O oráculo calcula somente um teto para decisões, sem custo de proveniência. B e B′ são baselines locais simplificadas; nenhuma delas representa Mem0 ou sistemas instrucionistas completos. As cinco seeds não devem ser tratadas como cinco amostras independentes de tarefas reais. A métrica de proveniência condicional foi 1,000 sempre que definida e não discrimina braços neste desenho. A mesma equipe desenhou, executou e revisou a avaliação.

O caso de continuidade entre agentes é observacional e está no Apêndice A. A autoria de uma promoção antiga não é verificável e o teste de três identidades é sintético. Dados reais e trechos conversacionais exigem revisão humana de privacidade antes de divulgação.

As próximas avaliações devem incluir conjuntos independentes e mais diversos, conflitos expressos sem chaves, memórias interconectadas sem relações explícitas de substituição — o regime em que [2] prevê vantagem selecionista —, ordenações que reservem orçamento para conflitos e baselines externas adequadamente configuradas. Uma reprodução independente e uma avaliação de tarefas reais seriam necessárias para sustentar conclusões mais gerais. A existência de um marcador de conflito ausente ou de uma verificação estrutural bem-sucedida não prova que toda a memória está livre de contradições.

## 7. Conclusão

O Conversation ESAA fornece a base de continuidade e rastreabilidade; o Memory-TCG acrescenta uma consolidação offline inspirada nas três fases RRR. A combinação permite gerar, inspecionar, aceitar e reverter uma visão ativa sem apagar os eventos de origem. Trata-se de uma implementação operacional do **mapeamento de engenharia** entre as ideias dos dois artigos, com diferenças explícitas em relação à hipótese selecionista.

Nos cenários avaliados, o RRR completo reteve todas as decisões vigentes antes do corte e, sob 1.024 tokens a 480 fatos, recuperou 0,44 delas — cerca de 7,3 vezes a janela cronológica e 76% do teto oracular —, chegando à recuperação completa com 4.096 tokens. As ablações e a baseline B′ mostram, porém, que esse ganho se deve à filtragem da visão ativa por autoridade, não à amostragem nem à ressonância. A ressonância melhora a detecção de conflitos antes do corte, mas, com a ordenação atual, os conflitos são descartados pelo orçamento nas escalas maiores; e os casos adversariais revelaram contradições não detectadas. Esses achados justificam investigar a consolidação de memória como componente de sistemas multiagentes e, especificamente, a ordenação sob orçamento, sem concluir que a hipótese de Haber e Tononi foi testada ou comprovada, nem que agentes tenham experiência de sonhar.

## Apêndice A — Continuidade observada

Em um uso real, uma decisão de handoff foi registrada, uma geração aceita a reteve e um segundo agente relatou ter lido a decisão e a geração. A evidência mostra uma sequência de compartilhamento, mas o campo de autoria da promoção histórica não permite identificar seu executor com segurança. Em outro tópico curado, três eventos foram vinculados explicitamente; a geração ativa anteriormente consultada precedia esses vínculos. Um teste isolado adicional reproduziu a passagem entre três identidades declaradas. Esse teste valida o fluxo com dados sintéticos; não comprova uma execução controlada por três modelos reais.

## Referências

[1] SANTOS FILHO, Elzo Brito dos. **ESAA-Conversational: An Event-Sourced Memory Layer for Continuity, Handoff, and Curation Across Heterogeneous LLM Coding Agents**. [arXiv:2606.23752v1](https://arxiv.org/abs/2606.23752v1), 2026. DOI: [10.48550/arXiv.2606.23752](https://doi.org/10.48550/arXiv.2606.23752).

[2] HABER, Ido; TONONI, Giulio. **Do agents need to sleep?** [arXiv:2611.02216v2](https://arxiv.org/abs/2611.02216v2), 2026. DOI: [10.48550/arXiv.2611.02216](https://doi.org/10.48550/arXiv.2611.02216).

[3] SANTOS FILHO, Elzo Brito dos. **ESAA: Event Sourcing for Autonomous Agents in LLM-Based Software Engineering**. [arXiv:2602.23193v1](https://arxiv.org/abs/2602.23193v1), 2026.

[4] PACKER, Charles et al. **MemGPT: Towards LLMs as Operating Systems**. [arXiv:2310.08560v2](https://arxiv.org/abs/2310.08560v2), 2024.

[5] PARK, Joon Sung et al. **Generative Agents: Interactive Simulacra of Human Behavior**. [arXiv:2304.03442v2](https://arxiv.org/abs/2304.03442v2), 2023.

[6] CHHIKARA, Prateek et al. **Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory**. [arXiv:2504.19413v1](https://arxiv.org/abs/2504.19413v1), 2025.

[7] LIN, Kevin et al. **Sleep-time Compute: Beyond Inference Scaling at Test-time**. [arXiv:2504.13171v1](https://arxiv.org/abs/2504.13171v1), 2025.

[8] TONONI, Giulio; CIRELLI, Chiara. **Sleep and the price of plasticity: from synaptic and cellular homeostasis to memory consolidation and integration**. *Neuron*, v. 81, n. 1, p. 12–34, 2014. [DOI: 10.1016/j.neuron.2013.12.025](https://doi.org/10.1016/j.neuron.2013.12.025).

[9] SANTOS FILHO, Elzo Brito dos. **RRR Memory Consolidation: Synthetic Evaluation Artifacts**. Código e dados sintéticos, commit `2e5caeb556fe5833889993fd045fe0689fc24b78`, 2026. [Repositório público e instruções de reprodução](https://github.com/elzobrito/conversation-esaa-rrr-artifacts/tree/2e5caeb556fe5833889993fd045fe0689fc24b78).

**Este documento referencia:** [[conv-rrr-metodo-revisado]], [[conv-rrr-v12-metodo]], [[CONV-RRR-V12-OUTPUT.json]], [[conv-rrr-matriz]].
