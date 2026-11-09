# Matriz preliminar de evidências para o artigo

Estado: **apto para iniciar a redação como estudo de engenharia**, restrito às evidências e limitações descritas; não há demonstração de superioridade científica geral nem autorização de publicação.

| Origem | Afirmação verificável | Evidência local | Limite |
|---|---|---|---|
| ESAA-Conversational, arXiv:2606.23752v1 | Captura e projeções oferecem continuidade entre agentes; o artigo descreve a versão 1.1.0. | PDF fornecido; histórico e projeções do produto. | O estudo no artigo não valida o Memory-TCG posterior. |
| Haber e Tononi, *Do agents need to sleep?* | Os autores propõem consolidação RRR e a hipótese de vantagem de uma abordagem selectionista em escala. | PDF fornecido, páginas 2–3. | É proposta e previsão falsificável; o artigo não fornece algoritmo digital completo. |
| Ringing | Amostragem estratificada e percursos determinísticos com seed e orçamento. | `src/memory/core/ringing.js`; testes de ringing. | Com orçamento parcial, a cobertura é limitada; não explora todas as combinações. |
| Resonance | Comparações lexicais e regras produzem associações e conflitos candidatos separados de relações verificadas. | `src/memory/core/resonance.js`; testes de resonance. | Heurísticas não são compreensão semântica; a ausência de alerta não prova ausência de conflito. |
| Renormalization | Uma proposta preserva decisões e evidência, agrupa duplicatas e desprioriza registros na visão ativa. | `src/memory/core/renormalize.js`; testes de renormalização. | Não apaga o ledger nem realiza abstração semântica geral ou prova competição emergente. |
| Compartilhamento | O handoff pode apresentar a geração aceita a leitores diferentes. | Testes de leitura e replay em workspaces isolados. | O identificador de agente é declarado, não autenticado; eventos antigos de curadoria tinham valores fixos. |
| Avaliação sintética | Uma comparação local limitou todos os braços a 1.024 tokens e mediu cenários de 48, 480 e 1.920 fatos; um conjunto adversarial testou seis pares. | `CONV-RRR-FAIR-OUTPUT.json`, `CONV-RRR-ADVERSARIAL.json`; [[conv-rrr-protocolo]]. | Templates repetidos, mesmo autor dos testes, comparador simplificado e conjunto adversarial pequeno; não provam superioridade geral nem desempenho real. |

## Handoff entre agentes: limite de atribuição

O relato do Grok descreve um sonho shadow cuja proposta original não foi encontrada no caminho consultado. A geração ativa posterior contém o tópico curado da radionovela. Ambos são observações situadas e não demonstram, por si, o conteúdo completo da proposta histórica nem a autoria real de eventos antigos com `agent_id` fixo. O estudo detalhado deve usar fonte privada, evidências verificáveis e revisão de privacidade antes de qualquer divulgação.

Há também um turno atribuído a Antigravity que relata ter lido o handoff registrado pelo Grok e a geração aceita que o incorporou. O evento de decisão e o watermark da geração são verificáveis no ledger; a identidade de quem promoveu a geração permanece limitada pelo preenchimento fixo do campo nos eventos antigos. Isso constitui evidência de leitura entre agentes no histórico, sem demonstrar experimento controlado nem autenticar a autoria da promoção.

Na verificação local, `memory inspect` encontrou a proposta aceita `4aa7caba…`: ela retém a decisão `26a48773…` e sua evidência; o evento de aceitação relata `agent_id=codex`, agora apresentado como `legacy_unverified`. O turno atribuído a Antigravity descreve ter lido essa decisão e geração. A proposta shadow inicial `76e98598…` não foi encontrada nem como arquivo nem em evento de aceitação consultável. Os identificadores abreviados acima são âncoras técnicas locais, não prova de anonimização suficiente para publicação.

## Caso sanitizado para redação

Em um uso real, um agente registrou uma decisão de handoff, uma geração aceita reteve a decisão e um segundo agente relatou ter lido ambos. O evento de aceitação antigo tem autoria não verificável; a sequência não é um experimento controlado. Outro tópico curado recebeu três vínculos explícitos de eventos, mas a geração ativa consultada precedia esses vínculos. Um teste isolado adicional simulou a passagem entre três identidades declaradas; ele não comprova execução de três modelos reais.

O parágrafo acima omite conteúdo de conversas, nomes de projetos, caminhos privados e hashes. A conferência automatizada de padrões não substitui revisão humana de privacidade antes de qualquer divulgação. A tabela, os artefatos locais com identificadores abreviados e os dados originais não devem ser publicados sem essa revisão.

## Limitações e trabalho futuro

O protocolo registra os resultados completos e suas limitações. Ampliar a diversidade de dados, testar baselines competitivos e obter reprodução independente são necessários antes de afirmar desempenho generalizável. A ausência da proposta shadow original não foi corrigida por inferência. A instalação operacional e a geração ativa não foram atualizadas com o checkout nesta avaliação.

## Referências

**Este documento referencia:** [[conv-rrr-protocolo]], [[conv-mtcg-benchmark]], [[conv-adr-013]].

**Este documento é referenciado por:** [[conv-rrr-protocolo]].
