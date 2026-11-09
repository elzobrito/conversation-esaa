# FIX132-BASELINE-RED-01

Emenda E-01 (humano 08/11/2026). Somente leitura. Não corrigido.

## Metadados E-01

| Campo | Valor |
|---|---|
| `git rev-parse --short HEAD` | `baea68d` |
| HEAD full | `baea68d92ec2ab2885e938ea521d50878ffcd766` |
| SHA-256 `conv-sync.ps1` (árvore suja) | `b5034666aa349f62625ce7ab1f43f8257dfb989947f8adad6855a31df25e6caf` |
| SHA-256 `cli.js` (árvore suja) | `31f89e0e7a2b4f14ae12e5ad797eff5af746ba213411ff82bdff27e08eac00de` |
| SHA-256 artigo v1.3 | `3bd6cc0007fdcf50f66f73e21e89718bb86ce6545e194a93dce087e1f032e53a` |
| Ledger real | `2bd12689fc24b8acb4b9911735283a5bfabc23588b80cff0e97209218e2a58a2` (inalterado) |
| Worktree | `/tmp/fix132-head-clean` em HEAD detached, 0 caminhos sujos |
| Árvore suja | não stashed, não modificada por esta tarefa |
| medido em | HEAD limpo (suíte) e árvore suja (reprodução dirigida) |

## Resultado das suítes

| Árvore | Comando | Pass | Fail | Exit | Medido em |
|---|---|---:|---:|---:|---|
| HEAD limpo | `pwsh -NoProfile -File .conversation-esaa/bin/conv-test.ps1` em `/tmp/fix132-head-clean` | 112 | 0 | 0 | HEAD limpo |
| Árvore suja (W0) | mesmo script no repo de trabalho | 111 | 1 | 1 | árvore suja |

Falha da árvore suja: `handoff_includes_recent_events`.

Log HEAD: `/tmp/fix132-head-clean-logs/conv-test.out` (76 s).

## Reprodução dirigida (mesma sequência do assert)

Workspace sintético; `topics create` **sem** `-Agent`, como `conv-test.ps1`.

**HEAD limpo** (`HasGrokMatch=True`):

```
## Eventos recentes
- [...] assistant (codex) — Usar context --agent para handoff seletivo
- [...] assistant (codex) — Implementar context --agent
- [...] assistant (codex) — task.updated CONV-001
- [...] assistant (grok) — Resumo do assunto de teste
```

`topic.created` HEAD: `"agent_id":"grok"` (hardcoded em `Invoke-TopicCommand`).

**Árvore suja** (`HasGrokMatch=False`):

```
## Eventos recentes
- [...] assistant (codex) — Usar context --agent para handoff seletivo
- [...] assistant (unknown) — Implementar context --agent
- [...] assistant (unknown) — task.updated CONV-001
- [...] assistant (unknown) — Resumo do assunto de teste
```

`topic.created` suja: `"agent_id":"unknown"`, `"agent_id_source":"unknown"`.

O heading `## Eventos recentes` existe nas duas árvores. A falha é o regex `assistant \(grok\).*Resumo do assunto de teste`.

## Hunk causal

`git diff HEAD -- .conversation-esaa/bin/conv-sync.ps1` (árvore suja, sem stash):

```
# HEAD
event = 'topic.created'
actor = 'assistant'
agent_id = 'grok'

# árvore suja
event = 'topic.created'
actor = 'assistant'
agent_id = $CuratorAgent    # default param 'unknown'
```

`conversation-esaa.ps1` só encaminha `-CuratorAgent` quando `$Agent` é passado. `conv-test` chama `topics create` sem `-Agent`.

O mesmo hunk altera `task.*` de `'codex'` para `$CuratorAgent` (por isso `assistant (unknown)` nas linhas de tarefa). `decide` continua com `-Agent codex` no teste, então a linha de decisão permanece `(codex)`.

Não é crowding do bloco de memória no handoff: as quatro linhas de eventos recentes estão presentes.

## A causa é a mesma de PS-01 ou PS-09?

**Não (PS-01).** PS-01 é `source_index` 0/1 no caminho ao vivo do Cursor e a chave de `Get-WorkspaceEvents` (`source|source_session_id|source_index|actor`). O assert vermelho usa evento curado `topic.created` (`source=curated`), não turnos Cursor. O hunk causal não toca `source_index`.

**Não (PS-09).** PS-09 é `pack` recolocando o bloco de memória já anexado a `handoff.md`. O assert lê `handoff.md` seção `## Eventos recentes`, não a saída de `pack`.

A causa pertence ao trabalho não commitado de identidade (`$CuratorAgent` / `agent_id_source`), vizinho de DOC-02/D-05. **Não corrigir nesta fase** (E-01 item 6): entra no G1 como item próprio vermelho → verde.

## O que não foi feito

- `git stash` (proibido)
- alteração da árvore suja
- `git bisect` (desnecessário: HEAD verde, suja vermelha)
- correção de `BASELINE-RED-01`
