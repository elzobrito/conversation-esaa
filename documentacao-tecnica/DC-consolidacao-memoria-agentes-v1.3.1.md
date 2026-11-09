---
titulo: "Quando agentes precisam consolidar memórias: o que a consolidação RRR explica, e o que não explica, no Conversation ESAA"
tipo: "Artigo científico — estudo de engenharia"
versao: "1.3.1"
data: "09/11/2026"
autores:
  - "Elzo Brito dos Santos Filho"
status: "Pronto para revisão externa"
instituicao: "CEETEPS — Centro Paula Souza"
departamento: "CGTIC"
---

# Quando agentes precisam consolidar memórias: o que a consolidação RRR explica, e o que não explica, no Conversation ESAA

## Resumo

Agentes baseados em modelos de linguagem podem compartilhar históricos entre sessões, mas persistência não assegura recuperação de decisões vigentes e proveniência. Este estudo de engenharia apresenta o Memory-TCG, extensão do Conversation ESAA inspirada em *ringing, resonance and renormalization* (RRR). Uma avaliação sintética exploratória compara recuperação cronológica, baselines simplificadas sensíveis à recência e à autoridade (B e B′), RRR e variantes sob três orçamentos de saída. Com 480 fatos e 1.024 tokens, RRR completo recuperou 0,44 das decisões vigentes, ante 0,06 da janela cronológica e teto oracular de 0,58; com 4.096 tokens, recuperou todas. B′ e a variante sem *resonance* empataram com RRR completo em revocação de decisões nas nove combinações. O comparador D1 aplica FIFO aos fatos antes da construção do grafo; sua perda de decisões não mede isoladamente o *ringing* do produto. A contribuição isolada do *ringing* para decisões não foi medida. Antes do corte de saída, o F1 de conflitos de RRR completo foi 0,615 nas três escalas; com 480 fatos e 1.024 tokens, caiu a 0,000. Reservar 20% do orçamento para conflitos (CQ) elevou esse F1 a 0,431 com 480 fatos e 1.024 tokens, enquanto a revocação de decisões caiu de 0,44 para 0,34; a 4.096 tokens o F1 chegou a 0,930 sem perda de decisões nesse cenário. A cota reduziu a revocação de decisões em cinco das nove combinações de escala e orçamento. Na sonda de `memory context` com 480 fatos, a saída real exibiu 4 das 50 decisões vigentes (revocação 0,08), contra 0,44 do CN no harness. As fixtures são repetitivas, os comparadores simplificados e a avaliação não foi reproduzida independentemente. Os resultados sustentam uma análise de engenharia, não uma afirmação de superioridade selecionista.

**Palavras-chave:** agentes de inteligência artificial; memória conversacional; event sourcing; consolidação de memória; RRR; rastreabilidade.

## Abstract

Language-model agents can share conversational history across sessions, but persistence does not guarantee retrieval of current decisions and their provenance. This engineering study presents Memory-TCG, a Conversation ESAA extension inspired by ringing, resonance and renormalization (RRR). An exploratory synthetic evaluation compares chronological retrieval, simplified recency- and authority-aware baselines (B and B′), RRR and variants under three output budgets. With 480 facts and 1,024 tokens, full RRR recalled 0.44 of current decisions, versus 0.06 for chronological retrieval and an oracle ceiling of 0.58; with 4,096 tokens it recalled all of them. B′ and the no-resonance variant matched full RRR in decision recall across all nine combinations. Comparator D1 applies FIFO to facts before graph construction; its decision losses do not isolate the product's ringing phase. The isolated contribution of ringing to decision recall was not measured. Before output truncation, full-RRR conflict F1 was 0.615 at all three scales; with 480 facts and 1,024 tokens it fell to 0.000. Reserving 20% of the budget for conflicts (CQ) raised that F1 to 0.431 at 480 facts and 1,024 tokens while decision recall fell from 0.44 to 0.34; at 4,096 tokens F1 reached 0.930 without decision loss in that scenario. The quota reduced decision recall in five of the nine scale–budget combinations. In a 480-fact `memory context` probe, the product displayed 4 of 50 current decisions (recall 0.08), versus 0.44 for CN in the harness. Repetitive fixtures, simplified comparators and lack of independent replication limit these findings to an engineering study.

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

| Versão | Data | Autores | Descrição da alteração |
|---|---|---|---|
| 1.3.1 | 09/11/2026 | Elzo Brito dos Santos Filho | ART-01 a ART-09 e DOC-02: D1 não isola o ringing; coluna D2 na Tabela 2; custo da cota CQ em 5/9 combinações; sonda ART-07 (revocação 0,08 e estouro de orçamento); nós e episódios por escala; ressalvas PS-08 e PS-18; status pronto para revisão externa. |
| 1.3 | 08/11/2026 | Elzo Brito dos Santos Filho | Correção da atribuição de D1 e do ringing (restrita a 480 e 1.920 fatos); tabela de conflitos por orçamento; cota de 20% (CQ); proveniência condicional em nota; artefatos públicos da v1.2/v1.3; título e pergunta de pesquisa alinhados à decomposição de componentes. |
| 1.2 | 08/11/2026 | Elzo Brito dos Santos Filho | Baseline B′ sensível à autoridade; atribuição dos ganhos à filtragem da visão ativa; precisão e revocação de conflitos; proveniência condicional; dispersão de CP antes do corte; conclusão atualizada; correções de forma. |
| 1.1 | 08/11/2026 | Elzo Brito dos Santos Filho | Separação entre métricas antes e depois do corte, oráculo de decisões, três orçamentos, ablações D1/D2, ordem de produção (CN) e diagnóstico da baseline B. |
| 1.0 | 08/11/2026 | Elzo Brito dos Santos Filho | Primeira versão para revisão. |

## 1. Introdução

O uso de agentes heterogêneos em um mesmo trabalho exige continuidade entre sessões e ferramentas. Uma decisão tomada em uma conversa pode não estar presente na próxima janela de contexto; um resumo antigo pode sobreviver depois de uma mudança de decisão; e uma repetição feita por outro agente pode ser confundida com uma nova evidência. A persistência do texto é necessária para recuperar o histórico, mas a seleção do que apresentar continua sendo um problema distinto.

O ESAA estabelece a separação entre intenções de agentes e mutações de estado por um orquestrador [3]. O ESAA-Conversational aborda a continuidade por meio de um histórico local de eventos e de projeções para handoff [1]. Seu foco é registrar e disponibilizar o estado conversacional entre agentes. Haber e Tononi [2], por sua vez, discutem o custo da plasticidade em sistemas que aprendem continuamente e propõem uma analogia com a consolidação de memória durante o sono. Os autores apresentam como hipótese testável que uma abordagem selecionista de consolidação possa superar alternativas instrucionistas à medida que a memória cresce e se torna interconectada.

Este artigo investiga a seguinte questão: **como integrar uma consolidação inspirada em RRR a uma memória conversacional compartilhada, preservando a proveniência e expondo os limites das decisões automáticas, e quais componentes explicam os ganhos?** A resposta é apresentada como estudo de engenharia do Memory-TCG, componente do Conversation ESAA. As contribuições são: (i) um mapeamento entre as fases propostas em [2] e operações implementadas sobre o histórico de [1]; (ii) uma arquitetura com propostas inspecionáveis, promoção explícita e reconstrução a partir de eventos; e (iii) uma avaliação exploratória com ablações e uma baseline sensível à autoridade, que mostra quais componentes explicam os ganhos observados e quais não contribuem nesta avaliação.

O termo *sonhar* designa aqui um comando de consolidação. Não descreve experiência subjetiva, consciência ou sono biológico de um agente.

## 2. Fundamentos e trabalhos relacionados

### 2.1 Continuidade conversacional baseada em eventos

Em [1], turnos visíveis são capturados por adaptadores e normalizados em um histórico acrescentável. Projeções como `handoff.md`, `state.md`, decisões e tarefas permitem que um agente retome um trabalho sem acesso direto à sessão interna de outro. A captura mecânica é separada da curadoria explícita de decisões e tarefas. O estudo de caso de [1] relata 570 eventos de laboratório e descreve a versão pública 1.1.0; não avalia a extensão Memory-TCG apresentada neste artigo.

No Conversation ESAA examinado, essa propriedade tem uma exceção operacional: a rotina `Repair-ActivityContract`, no caminho PowerShell de sincronização, reescreve `activity.jsonl` sem cópia de segurança (PS-08). Esse modelo fornece uma propriedade central: a visão apresentada a um agente pode ser regenerada a partir de registros de origem. Entretanto, um histórico acrescentável — mesmo com essa exceção — não resolve sozinho a distinção entre informação vigente e obsoleta. Tampouco garante que uma visão limitada por tokens inclua todas as evidências relevantes.

### 2.2 Outros sistemas de memória

MemGPT [4] organiza memória em níveis para estender o contexto efetivo de modelos. Generative Agents [5] mantém registros de experiências e sintetiza reflexões que alimentam o planejamento. Mem0 [6] propõe extração, atualização e recuperação de memórias conversacionais; as baselines B e B′ deste trabalho são apenas simplificações locais inspiradas na classe de políticas de atualização, sem executar Mem0. Sleep-time Compute [7] desloca processamento de modelos para antes das consultas; o Memory-TCG difere por executar seu ciclo offline sem chamadas a modelos. A hipótese de homeostase sináptica de Tononi e Cirelli [8] fornece o contexto biológico para a discussão de [2], sem implicar equivalência funcional entre cérebro e software.

### 2.3 A hipótese RRR

Haber e Tononi [2] descrevem o RRR como uma perspectiva selecionista para consolidação: circuitos são amostrados (*ringing*), sua dinâmica de coerência ou recorrência é avaliada (*resonance*) e conexões são seletivamente enfraquecidas ou preservadas (*renormalization*). Para sistemas digitais, os autores sugerem possibilidades como percorrer traços de memória fora de uma consulta ativa, avaliar alinhamento semântico e reduzir redundâncias. Essas sugestões não constituem uma especificação executável única.

O artigo também prevê que a lógica selecionista possa ter vantagens sobre estratégias instrucionistas, nas quais uma operação explícita atualiza cada memória. Essa previsão é uma hipótese empírica, não um resultado demonstrado pelo estudo de engenharia aqui apresentado. A implementação examinada usa políticas programadas e, portanto, não é uma realização completa da competição selecionista descrita em [2].

## 3. Arquitetura e implementação

### 3.1 Da conversa ao grafo

O Conversation ESAA mantém `activity.jsonl` como fonte canônica de eventos conversacionais. O arquivo é concebido como acrescentável; a rotina `Repair-ActivityContract` reescreve o ledger sem backup quando o contrato de eventos é considerado inválido (PS-08). Um adaptador cria um snapshot do workspace, identifica seu marco de eventos (*watermark*) e normaliza registros em fatos. O núcleo Memory-TCG constrói um grafo com episódios, decisões, tópicos e tarefas. Cada nó conserva identificadores de evidência; relações derivadas exigem regra e origem identificáveis.

O grafo distingue relações derivadas de relações possíveis. Uma substituição registrada explicitamente pode sustentar a marcação de uma decisão como histórica. Uma associação lexical ou contradição sugerida por heurística permanece candidata; sua pontuação não a transforma automaticamente em fato verificado. Essa separação reduz o risco de converter semelhança textual ou repetição em autoridade.

### 3.2 Mapeamento das três fases

| Fase | Implementação no Memory-TCG | Limite da correspondência |
|---|---|---|
| *Ringing* | Amostragem por tópico e janela temporal, com seed reproduzível e orçamento configurável; o percurso considera relações do grafo. | O procedimento é uma política determinística de amostragem, não uma reprodução de atividade neural espontânea. |
| *Resonance* | Identificação de duplicatas exatas, sobreposição lexical, relações candidatas e alguns conflitos estruturados. | Similaridade lexical não garante equivalência semântica; conflitos fora das regras podem passar despercebidos. |
| *Renormalization* | Proposta de retenção, agrupamento de duplicatas, despriorização, marcação histórica e sinalização de conflitos. | A seleção segue regras explícitas; não gera necessariamente abstrações de alto nível nem demonstra competição emergente. |

O ciclo opera offline, sem chamadas a modelos de linguagem e sem embeddings obrigatórios. Com a mesma entrada, política e seed, a execução é projetada para produzir saída reproduzível. A despriorização atua na visão ativa; não remove fisicamente os eventos do histórico. Na política avaliada, o grafo completo é construído antes da amostragem; a renormalização conserva decisões ativas mesmo quando não estão entre os nós amostrados. A identidade do workspace incorpora seu caminho canônico: o mesmo conteúdo em outro diretório pode gerar identificadores distintos, ainda que as métricas coincidam. Os resultados numéricos deste artigo correspondem à política RRR v1.

### 3.3 Isolamento, promoção e atribuição

Em modo *shadow*, a consolidação gera uma proposta que pode ser inspecionada antes de alterar a memória ativa. Na promoção, o sistema compara o watermark da proposta com o estado corrente; se o histórico avançou, uma proposta defasada é recusada. Uma aceitação gera evento auditável e materializa a visão ativa. O rollback registra outra transição, preservando o histórico e permitindo reconstrução por replay.

Eventos curados registram `actor: assistant`, inclusive quando acionados por um operador; o campo não prova autoria. A identidade declarada é transportada em `agent_id` e classificada por `agent_id_source` como `declared` ou `unknown`; na consulta, alguns registros antigos são marcados `legacy_unverified` sem reescrever o histórico. Os comandos de curadoria aceitam uma identidade de agente declarada. A ausência de identidade é representada como desconhecida; a declaração não autentica o executor. Em eventos históricos, algumas identidades eram preenchidas por valores fixos no programa. Por isso, esses registros não devem ser utilizados isoladamente como prova de autoria. Propostas aceitas podem ser inspecionadas a partir do evento canônico quando seu arquivo *shadow* não estiver disponível; uma proposta não encontrada em nenhuma dessas fontes permanece uma lacuna documental.

## 4. Método de avaliação

### 4.1 Cenários e braços

Foram usadas fixtures sintéticas com 48, 480 e 1.920 fatos, decisões atuais e superadas, ecos, duplicatas e conflitos. As seeds 11, 29, 42, 73 e 101 alteram a amostragem e não representam cinco bases independentes. Os braços são:

- **A** — janela cronológica;
- **B** — política local simplificada que mantém o evento mais recente por tópico e chave, sem distinguir decisão de eco;
- **B′** — política local simplificada que mantém a decisão explícita mais recente por tópico e chave e não permite que um eco a substitua; recebe as mesmas chaves e evidências estruturadas das fixtures e não detecta conflitos;
- **C** — RRR completo com ordenação comum;
- **CP** — RRR com amostragem parcial de 56%;
- **CN** — RRR completo reproduzindo a ordem do `cmdContext` de produção;
- **D1** — comparador do harness que corta fatos por FIFO antes de construir o grafo; não é uma substituição isolada do amostrador no caminho do produto;
- **D2** — RRR sem *resonance*;
- **CQ** — mesmos candidatos de C, com 20% do orçamento reservado para conflitos na ordem canônica da proposta (`conflict_id`).

A ordenação comum serializa primeiro as decisões ativas, depois os demais itens ativos e, por último, os conflitos candidatos. CN extrai a ordem integral do caminho de leitura de produção, incluindo itens não ativos que consomem orçamento, mas utiliza a mesma serialização JSON padronizada dos demais braços. É um ensaio da ordem de produção, não da saída Markdown exata. Os candidatos de conflito incluem pares de `proposal.unresolved`, inclusive possíveis contradições; falsos positivos são contados. CQ não altera a consolidação: só a política de encaixe sob o limite. A implementação não exporta um score de confiança por conflito; a ordem usada é a da proposta.

### 4.2 Orçamento e oráculo

Cada braço roda em processo Node separado. Aplicam-se limites de 512, 1.024 e 4.096 tokens `cl100k_base` (`tiktoken` 0.12.0). O custo é a soma dos tokens de registros JSON codificados separadamente, incluindo quebras de linha e excluindo overhead de protocolo de chat. Após um item que não cabe, o adaptador continua examinando os demais.

O oráculo conhece as decisões vigentes e ordena seus registros, com campo de proveniência vazio, pelo menor custo. Como cada decisão tem valor unitário e os custos são aditivos, obtém o número máximo de decisões desse formato sob o orçamento. O oráculo é determinístico e não depende da seed. Verificou-se que, nestes dados, nenhuma representação emitida para uma decisão verdadeira custa menos que a do oráculo. O teto é condicionado à serialização e à fixture: não é teto para conflitos, preservação de proveniência ou objetivos combinados.

### 4.3 Métricas e reprodução

Relatamos revocação de decisões antes e depois do corte; precisão, revocação e F1 dos conflitos; e contaminação histórica, definida como a fração dos registros obsoletos do gabarito exibidos como ativos. A precisão de conflitos é indefinida quando não há predições. A revocação global de proveniência acompanha exatamente a revocação de decisões, porque cada decisão leva consigo suas evidências, e por isso não figura na Tabela 1.

Reportamos valores entre as cinco seeds como mediana [mínimo, máximo]. `elapsed_ms`, pico de RSS, dados individuais e custo de saída estão nos artefatos. Os scripts foram executados duas vezes; no mesmo caminho de workspace, os campos determinísticos e hashes de saída coincidiram; tempo e RSS foram excluídos dessa comparação.

Um conjunto adicional de seis pares passou pelo adaptador real sem chaves de conflito fornecidas: três pares contraditórios e três negativos. Foi produzido pela mesma equipe e é pequeno. O repositório de artefatos [9] (commit `6a2ac1f9e1966403603b2f972453d12cdbbea3c3`) contém código, dados sintéticos, comandos e o relatório `CONV-RRR-V13-OUTPUT.json` (schema `conv-rrr.v13.v1`), incluindo B′, as métricas adicionais da versão 1.2 e a cota CQ. A avaliação não foi reproduzida de forma independente.

> **Nota.** A proveniência condicional é a fração dos IDs de evidência esperados presentes dentro das decisões verdadeiras retornadas, indefinida quando nenhuma decisão verdadeira é retornada. Também registramos a fração dessas decisões que traz todas as suas evidências.

## 5. Resultados

### 5.1 Separação entre consolidação e saída

Antes do limite de saída, C, CN, B′ e D2 retiveram todas as decisões vigentes nas três escalas (revocação 1,000 em todas as seeds); D1 reteve 0,40 em 48 fatos e 0,56 em 480 e 1.920 fatos. O F1 de conflitos de C e CN antes do corte foi 0,615 nas **três escalas**, na mesma proporção: 4 verdadeiros e 5 falsos positivos em 48 fatos, 40 e 50 em 480, 160 e 200 em 1.920 (precisão 0,444, revocação 1,000). Depois do corte, o F1 de conflitos de C é 0,000 nas escalas de 480 e 1.920 fatos sob 1.024 tokens (Tabela 1). Os valores idênticos de revocação pós-corte de C e CP também não estabelecem que produziram a mesma consolidação: antes do corte, CP difere em conflitos (Tabela 3). A proveniência condicional foi 1,000 em todos os casos em que é definida e, neste desenho, não discrimina braços.

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

Os intervalos entre seeds na Tabela 1 são degenerados: após o corte, as cinco seeds produziram exatamente os mesmos valores. Essas cinco seeds não alteraram as métricas exibidas na Tabela 1; a avaliação não demonstra que a seed seja irrelevante em outros dados ou configurações. No braço parcial, a detecção de conflitos antes do corte variou entre seeds (Tabela 3).

**Tabela 2 — Revocação de decisões por orçamento e teto oracular**

| Fatos | Tokens | C: ordem comum | CN: ordem de produção | B′ | D2: sem *resonance* | Oráculo de decisões (determinístico) |
|---:|---:|---:|---:|---:|---:|---:|
| 48 | 512 | 1,000 | 1,000 | 1,000 | 1,000 | 1,000 |
| 48 | 1024 | 1,000 | 1,000 | 1,000 | 1,000 | 1,000 |
| 48 | 4096 | 1,000 | 1,000 | 1,000 | 1,000 | 1,000 |
| 480 | 512 | 0,220 | 0,220 | 0,220 | 0,220 | 0,280 |
| 480 | 1024 | 0,440 | 0,440 | 0,440 | 0,440 | 0,580 |
| 480 | 4096 | 1,000 | 1,000 | 1,000 | 1,000 | 1,000 |
| 1920 | 512 | 0,055 | 0,055 | 0,055 | 0,055 | 0,070 |
| 1920 | 1024 | 0,110 | 0,110 | 0,110 | 0,110 | 0,145 |
| 1920 | 4096 | 0,445 | 0,445 | 0,445 | 0,445 | 0,585 |

Com 480 fatos e 1.024 tokens, C e CN recuperaram 0,44 das decisões, contra 0,06 em A: cerca de 7,3 vezes o valor da baseline cronológica nesta fixture, e aproximadamente 76% do teto oracular condicionado (0,58). Com 4.096 tokens, a 480 fatos, C, CN, B′ e D2 recuperaram todas as decisões, alcançando o oráculo. D2 empata com C nas nove combinações (Tabela 2). O oráculo não preserva evidências nem avalia conflitos.

**Tabela 3 — F1 de conflitos de CP antes do corte, por seed**

| Fatos | Seed 11 | Seed 29 | Seed 42 | Seed 73 | Seed 101 | Mediana |
|---:|---:|---:|---:|---:|---:|---:|
| 48 | 0,000 | 0,000 | 0,000 | 0,000 | 0,000 | 0,000 |
| 480 | 0,033 | 0,000 | 0,152 | 0,033 | 0,031 | 0,033 |
| 1920 | 0,047 | 0,023 | 0,081 | 0,008 | 0,039 | 0,039 |

Em CP, a revocação de decisões antes do corte foi 1,000 em todas as seeds; só a detecção de conflitos variou.

### 5.2 Atribuição dos ganhos: as ablações e B′

A variante D2 isola a ausência de *resonance* neste desenho. D1 usa um corte anterior ao grafo e, portanto, não isola o *ringing* do produto.

- D2 (sem *resonance*) empata com C em **revocação de decisões** nas nove combinações de escala e orçamento (Tabela 2). Esse empate não se aplica ao F1 de conflitos, que é 0,000 em D2.
- D1 aplica FIFO antes de construir o grafo e retém, antes do corte de saída, 0,40 das decisões em 48 fatos e 0,56 em 480 e 1.920, contra 1,000 em C. Após o corte, a diferença é 0,60 em 48 fatos (todos os orçamentos) e 0,44 em 480 fatos e 4.096 tokens; nas combinações restantes de 480 e 1.920 fatos, não ultrapassa 0,03. Como os fatos descartados por D1 nunca entram no grafo, essas diferenças não identificam a contribuição isolada do amostrador do produto.
- B′, que não executa nenhuma das três fases e apenas impede que um eco substitua a decisão explícita, empata com C em todas as nove combinações da Tabela 2.

Nesta fixture, B′ empata com C em revocação de decisões sob orçamento, indicando que a regra sensível à autoridade é suficiente para reproduzir essa métrica nas condições avaliadas. O produto retém decisões ativas no grafo por regra; D1 não mede a contribuição isolada do *ringing*. D2 tem F1 de conflitos 0,000 antes e depois do corte, enquanto C atinge 0,615 antes do corte; essa diferença é restrita ao desenho e às métricas testadas.

### 5.3 Conflitos sob orçamento

**Tabela 4 — Precisão, revocação e F1 de conflitos por orçamento (valores idênticos nas cinco seeds)**

| Fatos | Tokens | Braço | Precisão | Revocação | F1 | VP | FP | FN | Tokens usados | Revocação de decisões |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 48 | 512 | C | 0,800 | 1,000 | 0,889 | 4 | 1 | 0 | 512 | 1,000 |
| 48 | 1024 | C | 0,444 | 1,000 | 0,615 | 4 | 5 | 0 | 572 | 1,000 |
| 48 | 4096 | C | 0,444 | 1,000 | 0,615 | 4 | 5 | 0 | 572 | 1,000 |
| 48 | 512 | CN | 0,375 | 0,750 | 0,500 | 3 | 5 | 1 | 504 | 1,000 |
| 48 | 1024 | CN | 0,444 | 1,000 | 0,615 | 4 | 5 | 0 | 892 | 1,000 |
| 48 | 4096 | CN | 0,444 | 1,000 | 0,615 | 4 | 5 | 0 | 892 | 1,000 |
| 48 | 512 | D1 | 0,500 | 0,500 | 0,500 | 2 | 2 | 2 | 276 | 0,400 |
| 48 | 1024 | D1 | 0,500 | 0,500 | 0,500 | 2 | 2 | 2 | 276 | 0,400 |
| 48 | 4096 | D1 | 0,500 | 0,500 | 0,500 | 2 | 2 | 2 | 276 | 0,400 |
| 48 | 512 | CQ | 0,571 | 1,000 | 0,727 | 4 | 3 | 0 | 503 | 1,000 |
| 48 | 1024 | CQ | 0,444 | 1,000 | 0,615 | 4 | 5 | 0 | 572 | 1,000 |
| 48 | 4096 | CQ | 0,444 | 1,000 | 0,615 | 4 | 5 | 0 | 572 | 1,000 |
| 480 | 512 | C | — | 0,000 | 0,000 | 0 | 0 | 40 | 506 | 0,220 |
| 480 | 1024 | C | — | 0,000 | 0,000 | 0 | 0 | 40 | 1.012 | 0,440 |
| 480 | 4096 | C | — | 0,000 | 0,000 | 0 | 0 | 40 | 4.094 | 1,000 |
| 480 | 512 | CN | — | 0,000 | 0,000 | 0 | 0 | 40 | 506 | 0,220 |
| 480 | 1024 | CN | — | 0,000 | 0,000 | 0 | 0 | 40 | 1.012 | 0,440 |
| 480 | 4096 | CN | — | 0,000 | 0,000 | 0 | 0 | 40 | 4.086 | 1,000 |
| 480 | 512 | D1 | — | 0,000 | 0,000 | 0 | 0 | 40 | 500 | 0,200 |
| 480 | 1024 | D1 | 1,000 | 0,025 | 0,049 | 1 | 0 | 39 | 1.024 | 0,420 |
| 480 | 4096 | D1 | 0,468 | 0,550 | 0,506 | 22 | 25 | 18 | 4.089 | 0,560 |
| 480 | 512 | CQ | 1,000 | 0,125 | 0,222 | 5 | 0 | 35 | 504 | 0,180 |
| 480 | 1024 | CQ | 1,000 | 0,275 | 0,431 | 11 | 0 | 29 | 1.019 | 0,340 |
| 480 | 4096 | CQ | 0,870 | 1,000 | 0,930 | 40 | 6 | 0 | 4.085 | 1,000 |
| 1920 | 512 | C | — | 0,000 | 0,000 | 0 | 0 | 160 | 506 | 0,055 |
| 1920 | 1024 | C | — | 0,000 | 0,000 | 0 | 0 | 160 | 1.012 | 0,110 |
| 1920 | 4096 | C | — | 0,000 | 0,000 | 0 | 0 | 160 | 4.094 | 0,445 |
| 1920 | 512 | CN | — | 0,000 | 0,000 | 0 | 0 | 160 | 506 | 0,055 |
| 1920 | 1024 | CN | — | 0,000 | 0,000 | 0 | 0 | 160 | 1.012 | 0,110 |
| 1920 | 4096 | CN | — | 0,000 | 0,000 | 0 | 0 | 160 | 4.094 | 0,445 |
| 1920 | 512 | D1 | — | 0,000 | 0,000 | 0 | 0 | 160 | 506 | 0,055 |
| 1920 | 1024 | D1 | 1,000 | 0,006 | 0,012 | 1 | 0 | 159 | 1.024 | 0,105 |
| 1920 | 4096 | D1 | — | 0,000 | 0,000 | 0 | 0 | 160 | 4.093 | 0,415 |
| 1920 | 512 | CQ | 1,000 | 0,031 | 0,061 | 5 | 0 | 155 | 504 | 0,045 |
| 1920 | 1024 | CQ | 1,000 | 0,069 | 0,129 | 11 | 0 | 149 | 1.019 | 0,085 |
| 1920 | 4096 | CQ | 1,000 | 0,288 | 0,447 | 46 | 0 | 114 | 4.094 | 0,355 |

“—”: precisão indefinida (nenhum conflito retornado). CQ aplica a C uma cota de 20% para conflitos.

**O F1 cai quando o orçamento aumenta, se a fila inteira de conflitos cabe.** Em 48 fatos, C retém, com 512 tokens, 4 conflitos verdadeiros e 1 falso positivo (precisão 0,800, revocação 1,000, F1 0,889); com 1.024 tokens, os mesmos 4 verdadeiros e 5 falsos positivos (precisão 0,444, revocação 1,000, F1 0,615). O orçamento maior não acrescenta conflitos verdadeiros; apenas deixa entrar candidatos de `unresolved` que são falsos positivos. Nesse cenário, o trecho inicial contém os quatro verdadeiros e um falso positivo; a observação não estabelece uma ordenação universal.

**Conflitos somem depois do corte nas escalas maiores, na ordenação que os coloca por último.** Em 480 fatos, C mantém 50 decisões e 72 episódios ativos; com 4.096 tokens, esses itens consomem 4.094 tokens e nenhum conflito cabe, embora a revocação de decisões seja 1,000 (Tabela 4). D1, cuja visão ativa é menor (28 decisões e 50 episódios), deixa espaço e alcança F1 0,506 (precisão 0,468, revocação 0,550) no mesmo cenário. A vantagem de D1 em conflitos após o corte é efeito de ordem e orçamento, não de melhor detecção: antes do corte, o F1 de D1 (0,500) é menor que o de C (0,615).

**A cota de 20% (CQ) recupera conflitos sem reabrir a consolidação.** Com 480 fatos e 4.096 tokens, CQ mantém a revocação de decisões em 1,000 e eleva o F1 de conflitos de 0,000 para 0,930 (40 verdadeiros e 6 falsos positivos, precisão 0,870): o recorte cai sobre episódios, não sobre decisões, porque a serialização das ativas já coloca as decisões primeiro. Com 1.024 tokens, o F1 sobe de 0,000 para 0,431 (11 verdadeiros e 0 falsos positivos, precisão 1,000), e a revocação de decisões cai de 0,440 para 0,340. Com 512 tokens, o padrão se repete em menor escala (F1 0,222, precisão 1,000; revocação de decisões 0,180 contra 0,220). Em 1.920 fatos e 4.096 tokens, CQ obtém F1 0,447 (46 verdadeiros e 0 falsos positivos) e revocação de decisões 0,355, contra 0,445 de C. A cota troca episódios — e, sob orçamento apertado, algumas decisões — por conflitos que estavam no início da fila. Em 48 fatos e 512 tokens, CQ é pior que C (F1 0,727 contra 0,889), porque o orçamento já comportava os verdadeiros e a cota antecipa falsos positivos.

**C e CN.** As duas ordenações produzem a mesma revocação de decisões em todos os cenários porque ambas serializam as decisões ativas primeiro; os itens não ativos que CN acrescenta entram depois delas. A diferença aparece só no que vem depois: em 48 fatos e 512 tokens, CN gasta orçamento com tópicos e assuntos antes dos conflitos e retém 3 verdadeiros e 5 falsos positivos (F1 0,500), contra 0,889 em C. Com 1.024 tokens, o orçamento comporta tudo e ambos chegam a 0,615. A igualdade na contagem de decisões não implica que as mesmas decisões sejam escolhidas em todos os casos.

### 5.4 Por que B retorna zero

Em cada tópico da fixture escalada, B mantém o evento mais recente de cada chave. O eco episódico posterior substitui a decisão autoritativa: por isso B retorna zero decisões vigentes **antes mesmo do limite de saída**, e sua contaminação histórica após o limite chega a 0,140 em 480 fatos e 1.024 tokens. O comportamento decorre do desenho da baseline, que favorece recência; B′ corrige exatamente esse ponto e passa a empatar com C.

### 5.5 Pares adversariais

As cinco seeds produziram resultados idênticos nos seis pares sem chaves de conflito fornecidas: um verdadeiro positivo, dois falsos negativos, três verdadeiros negativos e nenhum falso positivo. Precisão, revocação e F1 de conflito foram, respectivamente, 1,000, 0,333 e 0,500. Os conflitos de prazo e TLS passaram despercebidos. O conjunto pequeno e produzido pela mesma equipe serve apenas para demonstrar falhas concretas [9].

### 5.6 Evidência funcional

Testes Node exercitaram modo *shadow*, rejeição de proposta defasada, promoção, rollback, replay, recuperação de proposta a partir do ledger, consulta por tópico, a baseline B′ e instalação em ambiente isolado. A parte em PowerShell que liga a memória ao ledger (`conv-memory.ps1` e a bateria `conv-test*.ps1`) não cobre sonho, aceitação nem rollback (PS-18). Esses testes não comprovam atualização da instalação global nem revisão independente.

## 6. Discussão e ameaças à validade

O Memory-TCG mostra que é possível integrar as três etapas nomeadas no RRR a uma memória conversacional compartilhada sem substituir o histórico de origem. O snapshot e o watermark permitem avaliar uma versão estável da memória; a promoção explícita torna a mudança da visão ativa auditável; e a separação entre arestas verificadas e candidatas evita que uma sugestão lexical se torne automaticamente uma decisão autoritativa.

**O que explica os resultados.** A recuperação de decisões sob orçamento neste experimento é compatível com a **filtragem por autoridade** na visão ativa quando as chaves são explícitas: B′ obtém a mesma revocação do RRR completo em todas as escalas. O comparador FIFO de D1 exclui fatos antes da construção do grafo, ao passo que o caminho do produto conserva decisões ativas por regra; a contribuição isolada do *ringing* para decisões não foi medida. No desenho avaliado, retirar *resonance* não alterou a revocação de decisões; alterou a detecção de conflitos antes do corte. Nas escalas maiores, essa diferença não aparece depois do corte quando os conflitos são serializados após os itens ativos.

A cota de 20% para conflitos na ordem da proposta altera o F1 observado: com 480 fatos e 4.096 tokens, CQ mantém a revocação de decisões em 1,000 e leva o F1 de conflitos de 0,000 a 0,930 (Tabela 4). Nos cenários de 480 fatos com 512 ou 1.024 tokens e nos de 1.920 fatos, a cota recupera conflitos com precisão 1,000 e reduz a revocação de decisões; essa precisão não se generaliza aos cenários de 48 fatos. A ordenação usada é a da proposta (`conflict_id`), não um score de confiança exportado; em 48 fatos e 512 tokens, a precisão foi 0,800 em C e 0,571 em CQ, sem demonstrar que o início da fila seja sempre o melhor. Um campo explícito de confiança permanece não testado.

**A previsão de [2] não foi testada.** O empate entre B′ e C não refuta nem confirma a hipótese selecionista: as fixtures fornecem chaves estruturadas e relações explícitas de substituição, condição em que uma regra instrucionista é suficiente por construção. A vantagem prevista em [2] diz respeito a memórias grandes e interconectadas, sem chaves explícitas, que este desenho não representa. Além disso, a implementação avaliada é determinística e baseada em regras, não uma competição selecionista.

**Correspondência parcial com [2].** A amostragem reproduzível substitui uma exploração estocástica aberta; a ressonância usa regras e sobreposição lexical, não uma avaliação geral de significado; e a renormalização é uma seleção determinada por política. Essas escolhas favorecem inspeção e replay, mas não demonstram que a relevância emerge de competição entre memórias. O estudo tampouco mede alteração de pesos de um modelo ou aprendizado contínuo dos seus parâmetros.

**Ameaças à validade.** As fixtures escaladas repetem padrões e fornecem chaves estruturadas de conflito, o que provavelmente explica a igualdade do F1 pré-corte entre escalas e os intervalos degenerados entre seeds; o conjunto sem chaves tem apenas seis pares. O limite de tokens é real para o tokenizador escolhido, mas outros modelos podem usar tokenizadores e janelas diferentes. O oráculo calcula somente um teto para decisões, sem custo de proveniência. B e B′ são baselines locais simplificadas; nenhuma delas representa Mem0 ou sistemas instrucionistas completos. As cinco seeds não devem ser tratadas como cinco amostras independentes de tarefas reais. A métrica de proveniência condicional foi 1,000 sempre que definida e não discrimina braços neste desenho. CQ usa a ordem canônica da proposta, não um score aprendido. A mesma equipe desenhou, executou e revisou a avaliação.

O caso de continuidade entre agentes é observacional e está no Apêndice A. A autoria de uma promoção antiga não é verificável e o teste de três identidades é sintético. Dados reais e trechos conversacionais exigem revisão humana de privacidade antes de divulgação.

Os limiares de escala da política também mudam o caminho executado. Cada fato da fixture vira um nó; fatos não são nós de antemão. A escala de 48 fatos produz 48 nós (38 episódios e 10 decisões) e **não** ultrapassa o limiar de 50 nós, nem o de 200 nós, nem a janela lexical de 250 episódios. A de 480 fatos produz 480 nós (380 episódios e 100 decisões) e ultrapassa os limiares de 50 e 200 nós e a janela de 250 episódios. A de 1.920 fatos produz 1.920 nós (1.520 episódios e 400 decisões) e também aciona a compactação acima de 500 nós, sem reduzir o grafo nessa fixture.

Uma sonda sintética adicional de 480 fatos construiu uma visão ativa com o adaptador e consultou `memory context`, sem aceitação real nem pack. Com orçamento solicitado de 3.200 caracteres foram exibidas 4 das 50 decisões vigentes (revocação 0,08) e 4 conflitos; 295 itens foram omitidos. No harness, CN recupera 0,44 das decisões no mesmo cenário a 1.024 tokens. O Markdown final teve 3.235 caracteres, incluindo o aviso de omissões: o produto estoura o orçamento pedido quando insere esse aviso. Essa sonda não mede o pack final; CN modela ordem e serialização da avaliação, e seus números não são medidas diretas do Markdown de produção.

As próximas avaliações devem incluir conjuntos independentes e mais diversos, conflitos expressos sem chaves, memórias interconectadas sem relações explícitas de substituição — o regime em que [2] prevê vantagem selecionista —, um score de confiança por conflito e baselines externas adequadamente configuradas. Uma reprodução independente e uma avaliação de tarefas reais seriam necessárias para sustentar conclusões mais gerais. A existência de um marcador de conflito ausente ou de uma verificação estrutural bem-sucedida não prova que toda a memória está livre de contradições.

## 7. Conclusão

O Conversation ESAA fornece a base de continuidade e rastreabilidade; o Memory-TCG acrescenta uma consolidação offline inspirada nas três fases RRR. A combinação permite gerar, inspecionar, aceitar e reverter uma visão ativa sem apagar os eventos de origem. Trata-se de uma implementação operacional do **mapeamento de engenharia** entre as ideias dos dois artigos, com diferenças explícitas em relação à hipótese selecionista.

Nos cenários avaliados, o RRR completo reteve todas as decisões vigentes antes do corte e, sob 1.024 tokens a 480 fatos, recuperou 0,44 delas — cerca de 7,3 vezes a janela cronológica e 76% do teto oracular —, chegando à recuperação completa com 4.096 tokens. Nesta avaliação, B′ mostra que uma regra sensível à autoridade reproduz essa revocação nas fixtures com chaves explícitas; a contribuição isolada do *ringing* para decisões não foi medida; a variante sem *resonance* empatou em revocação de decisões nas nove combinações (Tabela 2). A *resonance* melhora a detecção de conflitos antes do corte, mas, com a ordenação que os coloca por último, eles são descartados pelo orçamento nas escalas maiores. Reservar 20% do orçamento para a fila de conflitos recupera esses pares — com 480 fatos e 4.096 tokens, sem perder decisões; em cinco das nove combinações, a cota reduz a revocação de decisões. Na sonda de `memory context` com 480 fatos, a saída real recuperou 0,08 das decisões vigentes, contra 0,44 do CN. Os casos adversariais revelaram contradições não detectadas. Esses achados justificam investigar a consolidação de memória como componente de sistemas multiagentes e, especificamente, a ordenação sob orçamento, sem concluir que a hipótese de Haber e Tononi foi testada ou comprovada, nem que agentes tenham experiência de sonhar.

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

[9] SANTOS FILHO, Elzo Brito dos. **RRR Memory Consolidation: Synthetic Evaluation Artifacts**. Código e dados sintéticos, commit `6a2ac1f9e1966403603b2f972453d12cdbbea3c3`, 2026. [Repositório público e instruções de reprodução](https://github.com/elzobrito/conversation-esaa-rrr-artifacts/tree/6a2ac1f9e1966403603b2f972453d12cdbbea3c3).
