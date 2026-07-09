# Plano — Rollout Conversation ESAA v1.1.1 em workspaces existentes

> Data: 2026-07-08
> Escopo: atualizar diretórios sob `/home/elzobrito/desenvolvimento` que já usam `.conversation-esaa/`.
> Build fonte: `conversation-esaa-v1.1.1`
> Artefato: `/home/elzobrito/desenvolvimento/conversation-esaa/dist/conversation-esaa-v1.1.1.zip`
> Checksum: `c3f0e43e24fbdd4d9f03a7716286c815a7368371093dd450d46469e6abc84ef0`

## Objetivo

Atualizar todas as instalações existentes do Conversation ESAA para o runtime
v1.1.1, preservando logs privados, read models locais e estado de sync. O
rollout deve habilitar a Topic Memory Layer (`topics.*`, `context --topic-id`,
`topics list/show/create/update/link/close`) sem apagar histórico.

## Inventário inicial

Comando usado:

```bash
find /home/elzobrito/desenvolvimento -path '*/.conversation-esaa' -type d -print | sort
```

Workspaces encontrados:

| Workspace | Estado atual | Observações |
|---|---|---|
| `/home/elzobrito/desenvolvimento/PCA` | Runtime v1.1 antigo, sem `topics` | Repo Git com mudanças locais não relacionadas. Não atualizar sem backup e sem preservar worktree. |
| `/home/elzobrito/desenvolvimento/centauri-3720` | Runtime v1.1 antigo, sem `topics` | Não é repo Git. Requer backup completo antes de qualquer alteração. |
| `/home/elzobrito/desenvolvimento/consultoria` | Runtime v1.1 antigo, sem `topics` | Repo Git com `.conversation-esaa/tasks.json` modificado e watcher/logs ativos. Parar watcher antes de copiar runtime. |
| `/home/elzobrito/desenvolvimento/conversation-esaa` | Fonte canônica v1.1.1 | Já atualizado. Não precisa migração de runtime; serve como fonte e referência. |

## Invariantes

- Não apagar nem sobrescrever:
  - `.conversation-esaa/activity.jsonl`
  - `.conversation-esaa/sync-state.json`
  - `.conversation-esaa/state.md`
  - `.conversation-esaa/handoff.md`
  - `.conversation-esaa/decisions.md`
  - `.conversation-esaa/tasks.json`
  - `.conversation-esaa/topics.json`
  - `.conversation-esaa/topics.md`
  - `.conversation-esaa/codex-watch.log`
  - `.conversation-esaa/codex-watch.stdout.log`
  - `.conversation-esaa/run/*.pid`
  - `.conversation-esaa/run/*.lock`
- Não editar `activity.jsonl` manualmente.
- Não rodar migração em workspace com watcher ativo.
- Cada workspace deve ter backup próprio antes da cópia.
- Cada workspace deve ser validado isoladamente.

## Arquivos a atualizar por workspace

Copiar do build/fonte canônica para cada workspace:

```text
.conversation-esaa/bin/conversation-esaa.ps1
.conversation-esaa/bin/conv-sync.ps1
.conversation-esaa/bin/conv-bootstrap.ps1
.conversation-esaa/bin/codex-watch.ps1
.conversation-esaa/bin/conv-test.ps1
.conversation-esaa/bin/conv-test-battery.ps1
.conversation-esaa/tests/fixtures/**
.conversation-esaa/plans/adr-009-memoria-intermediaria-por-assuntos.md
.conversation-esaa/plans/v1-1-implementation-plan.md
.conversation-esaa/run/.gitkeep
PRIVACY.md
RELEASE.md
```

Não copiar o pacote inteiro por cima do workspace, porque isso pode introduzir
arquivos de repo (`README.md`, `.roadmap`, `AGENTS.md`, `dist/`) que pertencem
ao repositório `conversation-esaa`, não necessariamente ao projeto de destino.

## Pré-requisitos por workspace

1. Registrar estado Git quando existir:

```bash
git -C <workspace> status --short --branch
```

2. Verificar watcher/processos:

```bash
find <workspace>/.conversation-esaa/run -maxdepth 1 -type f -name '*.pid' -print
```

3. Backup completo:

```bash
ts=$(date +%Y%m%d-%H%M%S)
mkdir -p <workspace>/.conversation-esaa/backups
tar -C <workspace> -czf <workspace>/.conversation-esaa/backups/conversation-esaa-pre-v1.1.1-$ts.tgz .conversation-esaa
```

4. Validar checksum do build fonte:

```bash
cd /home/elzobrito/desenvolvimento/conversation-esaa
sha256sum -c dist/conversation-esaa-v1.1.1.sha256
```

## Procedimento de atualização

Para cada workspace alvo:

```bash
src=/home/elzobrito/desenvolvimento/conversation-esaa
dst=<workspace>

mkdir -p "$dst/.conversation-esaa/bin"
mkdir -p "$dst/.conversation-esaa/tests"
mkdir -p "$dst/.conversation-esaa/plans"
mkdir -p "$dst/.conversation-esaa/run"

cp "$src/.conversation-esaa/bin/conversation-esaa.ps1" "$dst/.conversation-esaa/bin/"
cp "$src/.conversation-esaa/bin/conv-sync.ps1" "$dst/.conversation-esaa/bin/"
cp "$src/.conversation-esaa/bin/conv-bootstrap.ps1" "$dst/.conversation-esaa/bin/"
cp "$src/.conversation-esaa/bin/codex-watch.ps1" "$dst/.conversation-esaa/bin/"
cp "$src/.conversation-esaa/bin/conv-test.ps1" "$dst/.conversation-esaa/bin/"
cp "$src/.conversation-esaa/bin/conv-test-battery.ps1" "$dst/.conversation-esaa/bin/"

rm -rf "$dst/.conversation-esaa/tests/fixtures"
cp -a "$src/.conversation-esaa/tests/fixtures" "$dst/.conversation-esaa/tests/"

cp "$src/.conversation-esaa/plans/adr-009-memoria-intermediaria-por-assuntos.md" "$dst/.conversation-esaa/plans/"
cp "$src/.conversation-esaa/plans/v1-1-implementation-plan.md" "$dst/.conversation-esaa/plans/"
touch "$dst/.conversation-esaa/run/.gitkeep"

cp "$src/PRIVACY.md" "$dst/PRIVACY.md"
cp "$src/RELEASE.md" "$dst/RELEASE.md"
```

## Projeção e validação

Depois da cópia:

```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File <workspace>/.conversation-esaa/bin/conversation-esaa.ps1 project --workspace <workspace>
pwsh -NoProfile -ExecutionPolicy Bypass -File <workspace>/.conversation-esaa/bin/conversation-esaa.ps1 verify --workspace <workspace>
pwsh -NoProfile -ExecutionPolicy Bypass -File <workspace>/.conversation-esaa/bin/conversation-esaa.ps1 topics list --workspace <workspace>
```

Critérios de sucesso:

- `verify: ok`
- `.conversation-esaa/topics.json` gerado
- `.conversation-esaa/topics.md` gerado
- `state.md` contém `## Tópicos / Assuntos Ativos`
- `handoff.md` inclui `topics.json / topics.md` na ordem de leitura

## Tratamento de falhas esperadas

### `verify` falha por evento legado sem `workspace_root`

Não editar `activity.jsonl` manualmente. Abrir hotfix específico para expor um
comando explícito de reparo, por exemplo:

```text
conversation-esaa repair activity-contract --workspace <workspace>
```

Esse comando deve reutilizar `Repair-ActivityContract` de forma auditável, sem
rodar sync mecânico nem puxar novas conversas.

### `consultoria` tem watcher ativo

Antes de atualizar:

```bash
find /home/elzobrito/desenvolvimento/consultoria/.conversation-esaa/run -maxdepth 1 -type f -name '*.pid' -print
```

Se houver processo ativo, parar o watcher de forma explícita antes da cópia.
Depois da validação, reiniciar o watcher com o runtime novo.

### Workspace com mudanças Git

Não fazer commit automático. O rollout deve deixar as alterações visíveis no
worktree do projeto e reportar exatamente quais arquivos mudaram.

## Ordem recomendada

1. `centauri-3720`
   - Menor superfície Git, bom piloto.
   - Exige backup porque não é repo Git.

2. `PCA`
   - Atualizar depois do piloto.
   - Preservar mudanças locais já existentes.

3. `consultoria`
   - Atualizar por último por causa de watcher/logs e runtime mais sensível.

4. `conversation-esaa`
   - Sem atualização de runtime; apenas referência canônica.

## Plano de rollback

Para cada workspace:

```bash
latest=$(ls -t <workspace>/.conversation-esaa/backups/conversation-esaa-pre-v1.1.1-*.tgz | head -n 1)
rm -rf <workspace>/.conversation-esaa
tar -C <workspace> -xzf "$latest"
```

Depois:

```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File <workspace>/.conversation-esaa/bin/conversation-esaa.ps1 verify --workspace <workspace>
```

Se o rollback não tiver `conversation-esaa.ps1`, usar o comando legado
`conv-sync.ps1 verify`.

## Checklist de execução

- [ ] Confirmar checksum do build `v1.1.1`.
- [ ] Criar backup em `centauri-3720`.
- [ ] Atualizar runtime em `centauri-3720`.
- [ ] Rodar `project`, `verify`, `topics list` em `centauri-3720`.
- [ ] Criar backup em `PCA`.
- [ ] Atualizar runtime em `PCA`.
- [ ] Rodar `project`, `verify`, `topics list` em `PCA`.
- [ ] Parar watcher em `consultoria`, se ativo.
- [ ] Criar backup em `consultoria`.
- [ ] Atualizar runtime em `consultoria`.
- [ ] Rodar `project`, `verify`, `topics list` em `consultoria`.
- [ ] Reiniciar watcher em `consultoria`, se aplicável.
- [ ] Reportar status final por workspace.

## Fora de escopo

- Commitar mudanças nos repositórios de destino.
- Publicar novo build.
- Migrar `.roadmap` ou governança ESAA formal dos projetos.
- Criar tópicos de domínio em cada workspace; isso deve ser feito depois da
  atualização, com curadoria explícita.
