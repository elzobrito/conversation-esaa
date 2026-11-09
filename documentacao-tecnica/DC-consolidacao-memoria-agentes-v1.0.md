---
titulo: "Quando agentes precisam consolidar memórias: uma implementação RRR no Conversation ESAA"
tipo: "Artigo científico — estudo de engenharia"
versao: "1.0"
data: "08/11/2026"
autores:
  - "A definir"
status: "Em revisão"
instituicao: "A confirmar"
departamento: "A confirmar"
---

# Quando agentes precisam consolidar memórias: uma implementação RRR no Conversation ESAA

## Resumo

Agentes baseados em modelos de linguagem podem compartilhar um histórico conversacional entre sessões, mas a persistência desse histórico não garante que decisões vigentes, evidências e contradições sejam recuperadas de forma útil. Este artigo apresenta o Memory-TCG, uma extensão do Conversation ESAA que combina memória conversacional baseada em eventos com um ciclo de consolidação inspirado em *ringing, resonance and renormalization* (RRR). A proposta relaciona o armazenamento e o handoff descritos por Santos Filho [1] à hipótese de consolidação selectionista discutida por Haber e Tononi [2]. O ciclo implementado amostra um grafo de memórias, identifica relações e conflitos candidatos e produz uma visão ativa rastreável, preservando o histórico de origem. A implementação é determinística e emprega regras explícitas e similaridade lexical; não reproduz integralmente a dinâmica selectionista proposta em [2]. Uma avaliação sintética exploratória comparou o mecanismo com uma recuperação cronológica, um consolidador local simplificado e ablações, sob limite comum de 1.024 tokens de saída. Nos cenários de 48, 480 e 1.920 fatos, as medianas do recall de decisões vigentes para o RRR completo foram, respectivamente, 1,00, 0,38 e 0,095; as medianas do F1 de conflitos foram 1,00, 0,049 e 0,012. Em seis pares adversariais sem chaves de conflito fornecidas, identificou-se uma das três contradições, sem falsos positivos nos três pares negativos. Os resultados mostram viabilidade de integração e limites concretos de recuperação sob orçamento restrito. As fixtures são pequenas ou repetitivas, os comparadores são simplificados e não houve reprodução independente; portanto, o estudo não demonstra superioridade geral do RRR nem estabelece que agentes necessitem de sono.

**Palavras-chave:** agentes de inteligência artificial; memória conversacional; event sourcing; consolidação de memória; RRR; rastreabilidade.

## Abstract

Language-model agents can share a conversational history across sessions, but persistence alone does not ensure useful retrieval of current decisions, evidence, and contradictions. This paper presents Memory-TCG, an extension of Conversation ESAA that combines event-sourced conversational memory with a consolidation cycle inspired by ringing, resonance, and renormalization (RRR). It relates the continuity and handoff architecture in [1] to the selectionist consolidation hypothesis in [2]. The implemented cycle samples a memory graph, identifies candidate relations and conflicts, and produces a traceable active view while preserving source events. It is deterministic and relies on explicit rules and lexical similarity; it does not fully reproduce the selectionist dynamics proposed in [2]. In an exploratory synthetic evaluation with a common 1,024-token output limit, median current-decision recall for the full RRR cycle was 1.00, 0.38, and 0.095 for 48, 480, and 1,920 facts, respectively; median conflict F1 was 1.00, 0.049, and 0.012. An adversarial set of six pairs without supplied conflict keys yielded one detected contradiction out of three and no false positives among three negative pairs. These findings show both integration feasibility and concrete retrieval limitations under a restricted output budget. Small or repetitive fixtures, simplified baselines, and the absence of independent replication preclude claims of general superiority or proof that agents require sleep.

**Keywords:** artificial intelligence agents; conversational memory; event sourcing; memory consolidation; RRR; traceability.

## Sumário

1. Introdução
2. Fundamentos e trabalhos relacionados
3. Arquitetura e implementação
4. Método de avaliação
5. Resultados
6. Discussão e ameaças à validade
7. Conclusão
8. Referências

## Controle de versões

| Versão | Data | Autoria | Descrição |
|---|---|---|---|
| 1.0 | 08/11/2026 | A definir | Primeira versão para revisão. |

## 1. Introdução

O uso de agentes heterogêneos em um mesmo trabalho exige continuidade entre sessões e ferramentas. Uma decisão tomada em uma conversa pode não estar presente na próxima janela de contexto; um resumo antigo pode sobreviver depois de uma mudança de decisão; e uma repetição feita por outro agente pode ser confundida com uma nova evidência. A persistência do texto é necessária para recuperar o histórico, mas a seleção do que apresentar continua sendo um problema distinto.

O ESAA-Conversational aborda a continuidade por meio de um histórico local de eventos e de projeções para handoff [1]. Seu foco é registrar e disponibilizar o estado conversacional entre agentes. Haber e Tononi [2], por sua vez, discutem o custo da plasticidade em sistemas que aprendem continuamente e propõem uma analogia com a consolidação de memória durante o sono. Os autores apresentam como hipótese testável que uma abordagem selectionista de consolidação possa superar alternativas instructionistas à medida que a memória cresce e se torna interconectada.

Este artigo investiga a seguinte questão: **como integrar uma consolidação inspirada em RRR a uma memória conversacional compartilhada, preservando a proveniência e expondo os limites das decisões automáticas?** A resposta é apresentada como estudo de engenharia do Memory-TCG, componente do Conversation ESAA. As contribuições são: (i) um mapeamento entre as fases propostas em [2] e operações implementadas sobre o histórico de [1]; (ii) uma arquitetura com propostas inspecionáveis, promoção explícita e reconstrução a partir de eventos; e (iii) uma avaliação exploratória que inclui resultados favoráveis e falhas de recuperação.

O termo *sonhar* designa aqui um comando de consolidação. Não descreve experiência subjetiva, consciência ou sono biológico de um agente.

## 2. Fundamentos e trabalhos relacionados

### 2.1 Continuidade conversacional baseada em eventos

Em [1], turnos visíveis são capturados por adaptadores e normalizados em um histórico acrescentável. Projeções como `handoff.md`, `state.md`, decisões e tarefas permitem que um agente retome um trabalho sem acesso direto à sessão interna de outro. A captura mecânica é separada da curadoria explícita de decisões e tarefas. O estudo de caso de [1] relata 570 eventos de laboratório e descreve a versão pública 1.1.0; não avalia a extensão Memory-TCG apresentada neste artigo.

Esse modelo fornece uma propriedade central: a visão apresentada a um agente pode ser regenerada a partir de registros de origem. Entretanto, um histórico acrescentável não resolve sozinho a distinção entre informação vigente e obsoleta. Tampouco garante que uma visão limitada por tokens inclua todas as evidências relevantes.

### 2.2 A hipótese RRR

Haber e Tononi [2] descrevem o RRR como uma perspectiva selectionista para consolidação: circuitos são amostrados (*ringing*), sua dinâmica de coerência ou recorrência é avaliada (*resonance*) e conexões são seletivamente enfraquecidas ou preservadas (*renormalization*). Para sistemas digitais, os autores sugerem possibilidades como percorrer traços de memória fora de uma consulta ativa, avaliar alinhamento semântico e reduzir redundâncias. Essas sugestões não constituem uma especificação executável única.

O artigo também prevê que a lógica selectionista possa ter vantagens sobre estratégias instructionistas, nas quais uma operação explícita atualiza cada memória. Essa previsão é uma hipótese empírica, não um resultado demonstrado pelo estudo de engenharia aqui apresentado. A implementação examinada usa políticas programadas e, portanto, não é uma realização completa da competição selectionista descrita em [2].

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

Os comandos de curadoria aceitam uma identidade de agente declarada. A ausência de identidade é representada como desconhecida; a declaração não autentica o executor. Em eventos históricos, algumas identidades eram preenchidas por valores fixos no programa. Por isso, esses registros não devem ser utilizados isoladamente como prova de autoria. Propostas aceitas podem ser inspecionadas a partir do evento canônico quando seu arquivo shadow não estiver disponível; uma proposta não encontrada em nenhuma dessas fontes permanece uma lacuna documental.

### 3.4 Continuidade observada

Em um uso real, uma decisão de handoff foi registrada, uma geração aceita a reteve e um segundo agente relatou ter lido a decisão e a geração. A evidência mostra uma sequência de compartilhamento, mas o campo de autoria da promoção histórica não permite identificar seu executor com segurança. Em outro tópico curado, três eventos foram vinculados explicitamente; a geração ativa anteriormente consultada precedia esses vínculos. Um teste isolado adicional reproduziu a passagem entre três identidades declaradas. Esse teste valida o fluxo com dados sintéticos; não comprova uma execução controlada por três modelos reais.

## 4. Método de avaliação

### 4.1 Escopo e braços

A avaliação utilizou fixtures sintéticas locais com decisões atuais e superadas, ecos, duplicatas e conflitos. Foram comparados: A, recuperação cronológica simplificada; B, política local simplificada de atualização por chave; C, ciclo RRR completo; CP, RRR com amostragem parcial; D1, ablação da amostragem estratificada por uma seleção FIFO; e D2, ablação da fase de *resonance*. O braço B é um simulador e não corresponde a uma avaliação do produto Mem0 ou de qualquer outra implementação externa.

Os cenários continham 48, 480 e 1.920 fatos. Foram usadas cinco seeds: 11, 29, 42, 73 e 101. As seeds modificam a amostragem; não criam cinco conjuntos independentes de dados. Cada braço foi executado em processo Node separado. Um adaptador comum ordenou decisões antes de outros itens, em ordem lexical de identificadores, e colocou os conflitos em seguida. A saída foi limitada a 1.024 tokens, contados com `cl100k_base` e `tiktoken` 0.12.0. O limite é comum, mas a ordenação, o formato de saída e os conteúdos disponíveis em cada braço influenciam os resultados.

### 4.2 Métricas e reprodução

O recall de decisões mede a fração de decisões vigentes do gabarito presente na saída. O F1 de conflitos combina precisão e recall dos pares contraditórios previstos. Também foram registrados precisão de decisões, contaminação histórica, preservação de proveniência, quantidade de tokens e bytes de saída, tempo de execução e pico de memória do processo. O tempo mede o braço avaliado, sem incluir a geração da fixture ou a tokenização; o pico de memória inclui o runtime. A fração de decisões-alvo retornadas é uma medida restrita ao gabarito e não equivale a uma avaliação geral de relevância semântica.

Os scripts, parâmetros e relatórios sintéticos estão registrados no protocolo [[conv-rrr-protocolo]]. Uma segunda execução das 90 combinações reproduziu os campos determinísticos, inclusive métricas e hashes do contexto; tempos e memória foram excluídos dessa comparação. As análises adicionais foram definidas durante a investigação e não constituem pré-registro independente.

### 4.3 Conjunto adversarial

Um conjunto separado de seis pares foi processado pelo adaptador de snapshot sem fornecer chaves de conflito. Três pares foram rotulados como contraditórios e três como não contraditórios. Os exemplos incluem escolha de banco de dados, prazo de retenção e versão de TLS. O conjunto é pequeno e foi elaborado pela mesma equipe que examinou a implementação; seu papel é revelar falhas concretas, não estimar desempenho populacional.

## 5. Resultados

### 5.1 Saída limitada a 1.024 tokens

A Tabela 1 apresenta as medianas das cinco execuções por cenário. Os dados detalhados, incluindo os demais braços e métricas, estão em [[CONV-RRR-FAIR-OUTPUT.json]].

**Tabela 1 — Medianas de recall de decisões e F1 de conflitos**

| Fatos | Braço | Recall de decisões | F1 de conflitos |
|---:|---|---:|---:|
| 48 | A — cronológico | 0,600 | 0,000 |
| 48 | B — atualização local simplificada | 0,000 | 0,000 |
| 48 | C — RRR completo | 1,000 | 1,000 |
| 48 | CP — RRR parcial | 1,000 | 0,000 |
| 480 | A — cronológico | 0,060 | 0,000 |
| 480 | B — atualização local simplificada | 0,000 | 0,000 |
| 480 | C — RRR completo | 0,380 | 0,049 |
| 480 | CP — RRR parcial | 0,380 | 0,049 |
| 1.920 | A — cronológico | 0,025 | 0,000 |
| 1.920 | B — atualização local simplificada | 0,000 | 0,000 |
| 1.920 | C — RRR completo | 0,095 | 0,012 |
| 1.920 | CP — RRR parcial | 0,095 | 0,012 |

No menor cenário, o RRR completo preservou todas as decisões avaliadas e identificou os pares de conflito presentes no gabarito. A amostragem parcial manteve o recall de decisões, mas não apresentou os conflitos esperados. Nos cenários maiores, o recall e o F1 do RRR completo caíram sob o limite de saída. A priorização comum de decisões antes de conflitos contribui para essa pressão sobre a apresentação de conflitos; a tabela não isola o efeito do orçamento de outros efeitos de implementação e seleção.

Uma sondagem anterior, sem controle equivalente de tokens, gerou dados para 50, 500 e 2.000 fatos. Ela é útil para diagnóstico, mas suas saídas de tamanhos diferentes não permitem comparação direta de qualidade entre braços. Seus resultados não devem ser combinados com os da Tabela 1 como se integrassem um único experimento.

### 5.2 Pares adversariais

Nas cinco seeds, o conjunto adversarial produziu um verdadeiro positivo, dois falsos negativos, três verdadeiros negativos e nenhum falso positivo. O conflito de banco reconhecido pelas regras foi sinalizado; os conflitos expressos como prazos de retenção e versões de TLS não foram detectados. Para os seis pares, a precisão de conflito observada foi 1,00, o recall foi 0,33 e o F1 foi 0,50. Com apenas três exemplos positivos, esses valores são descritivos e mudariam consideravelmente com poucos casos adicionais. Os registros estão em [[CONV-RRR-ADVERSARIAL.json]].

### 5.3 Evidência funcional

Os testes locais cobriram, entre outros comportamentos, isolamento do modo shadow, reprodução determinística, rejeição de propostas defasadas, promoção, rollback, replay, recuperação de proposta a partir do ledger e filtragem por tópico. A instalação do pacote e sua preservação de dados privados durante reparo, atualização e remoção também foram exercitadas em workspaces isolados. Esses testes sustentam propriedades funcionais nos cenários executados; não equivalem a uma avaliação científica independente ou a uma atualização da instalação operacional global.

## 6. Discussão e ameaças à validade

O Memory-TCG mostra que é possível integrar as três etapas nomeadas no RRR a uma memória conversacional compartilhada sem substituir o histórico de origem. O snapshot e o watermark permitem avaliar uma versão estável da memória; a promoção explícita torna a mudança da visão ativa auditável; e a separação entre arestas verificadas e candidatas evita que uma sugestão lexical se torne automaticamente uma decisão autoritativa.

A correspondência com [2] é, porém, parcial. A amostragem reproduzível substitui uma exploração estocástica aberta; a ressonância usa regras e sobreposição lexical, não uma avaliação geral de significado; e a renormalização é uma seleção determinada por política. Essas escolhas favorecem inspeção e replay, mas não demonstram que a relevância emerge de competição entre memórias. O estudo tampouco mede alteração de pesos de um modelo ou aprendizado contínuo dos seus parâmetros.

Os resultados dependem dos cenários e do mecanismo de apresentação. As fixtures escaladas repetem padrões e fornecem chaves estruturadas de conflito, enquanto o conjunto sem essas chaves tem apenas seis pares. O limite de 1.024 tokens é real para o tokenizador escolhido, mas outros modelos podem usar tokenizadores e janelas diferentes. A ordem que prioriza decisões afeta quanto espaço sobra para conflitos. O braço B é uma baseline local simplificada; compará-lo com o RRR não demonstra que o mecanismo superaria um sistema instructionista completo. As cinco seeds não devem ser tratadas como cinco amostras independentes de tarefas reais.

O caso de continuidade entre agentes é observacional. O histórico preserva o relato de leitura e a geração que reteve uma decisão, mas não autentica a autoria de uma promoção antiga. O teste de três identidades é sintético. A proposta shadow inicial mencionada no histórico não foi encontrada nas fontes consultadas; sua ausência não autoriza reconstruir ou atribuir conteúdo específico a ela. Dados reais, identificadores e trechos conversacionais exigem revisão humana de privacidade antes de divulgação.

As próximas avaliações devem incluir conjuntos independentes e mais diversos, conflitos expressos sem chaves, múltiplos orçamentos e ordenações, além de baselines externas adequadamente configuradas. Uma reprodução independente e uma avaliação de tarefas reais seriam necessárias para sustentar conclusões mais gerais. A existência de um marcador de conflito ausente ou de uma verificação estrutural bem-sucedida não prova que toda a memória está livre de contradições.

## 7. Conclusão

O Conversation ESAA fornece a base de continuidade e rastreabilidade; o Memory-TCG acrescenta uma consolidação offline inspirada nas três fases RRR. A combinação permite gerar, inspecionar, aceitar e reverter uma visão ativa sem apagar os eventos de origem. Trata-se de uma implementação operacional do **mapeamento de engenharia** entre as ideias dos dois artigos, com diferenças explícitas em relação à hipótese selectionista.

Nos cenários avaliados, a consolidação preservou decisões e detectou conflitos no caso sintético menor, mas a recuperação caiu sob um limite de saída fixo à medida que o número de fatos aumentou. Os casos adversariais também revelaram contradições não detectadas. Esses achados justificam investigar a consolidação de memória como componente de sistemas multiagentes, sem concluir que a hipótese geral de Haber e Tononi foi comprovada ou que agentes tenham experiência de sonhar.

## 8. Referências

[1] SANTOS FILHO, Elzo Brito dos. **ESAA-Conversational: An Event-Sourced Memory Layer for Continuity, Handoff, and Curation Across Heterogeneous LLM Coding Agents**. [arXiv:2606.23752v1](https://arxiv.org/abs/2606.23752v1), 2026. DOI: [10.48550/arXiv.2606.23752](https://doi.org/10.48550/arXiv.2606.23752).

[2] HABER, Ido; TONONI, Giulio. **Do agents need to sleep?** [arXiv:2611.02216v2](https://arxiv.org/abs/2611.02216v2), 2026. DOI: [10.48550/arXiv.2611.02216](https://doi.org/10.48550/arXiv.2611.02216).

### Artefatos locais de apoio

- [[conv-adr-013]] — decisões arquiteturais do Memory-TCG.
- [[conv-rrr-protocolo]] — método, comandos, resultados e limites da avaliação.
- [[conv-rrr-matriz]] — vínculo entre afirmações e evidências disponíveis.
- [[CONV-RRR-FAIR-OUTPUT.json]] e [[CONV-RRR-ADVERSARIAL.json]] — relatórios sintéticos.

**Referenciado por:** índice de artefatos do projeto; nenhuma publicação externa realizada.
