# Plano — Rollout Conversation ESAA v1.1.1 em workspaces existentes

> **Revisão:** 2026-07-08 (as-run + inventário completo)  
> **Escopo:** todos os diretórios com `.conversation-esaa/` no host do usuário  
> **Build fonte:** `conversation-esaa-v1.1.1`  
> **Artefato:** `/home/elzobrito/desenvolvimento/conversation-esaa/dist/conversation-esaa-v1.1.1.zip`  
> **Checksum vigente:** ver sempre o arquivo (não confiar só neste markdown):
>
> ```bash
> cat /home/elzobrito/desenvolvimento/conversation-esaa/dist/conversation-esaa-v1.1.1.sha256
> # rebuild 2026-07-08 21:48:
> # 78a2403da07e2b3d3e21f0a3f0b66783424598b7e0b17fb0b61ed5880f3d80bd  dist/conversation-esaa-v1.1.1.zip
> ```
>
> **Hash antigo no plano original (obsoleto):** `c3f0e43e24fbdd4d9f03a7716286c815a7368371093dd450d46469e6abc84ef0`

---

## Objetivo

Atualizar todas as instalações existentes do Conversation ESAA para o runtime
v1.1.1, preservando logs privados, read models locais e estado de sync. O
rollout habilita a Topic Memory Layer (`topics.*`, `context --topic-id`,
`topics list/show/create/update/link/close`) sem apagar histórico.

**Não** é objetivo: curar tópicos de domínio, commitar worktrees, migrar ESAA-Core
(`.roadmap/`), nem copiar `AGENTS.md`/README do produto para projetos consumidores.

---

## Inventário completo (host)

Comandos de descoberta (evitar `find` no `$HOME` inteiro — montagens lentas):

```bash
# Projetos sob desenvolvimento
find /home/elzobrito/desenvolvimento -maxdepth 3 -type d -name '.conversation-esaa' | sort

# Workspace global (home)
ls -d /home/elzobrito/.conversation-esaa
```

### Tabela de workspaces

| # | Workspace (raiz) | Papel | Git | activity (linhas) | Runtime vs fonte canônica | topics.json | Backup pre-v1.1.1 | Watcher | Precisa atualizar? |
|---|------------------|-------|-----|-------------------|---------------------------|-------------|-------------------|---------|--------------------|
| 0 | `/home/elzobrito` | **global** (conversas soltas) | não | ~1894 | **MATCH** (`conv-sync` + CLI) | sim | sim (`…142513.tgz`) | **systemd** `conversation-esaa-codex-watch` (active) | **Não** (já v1.1.1) |
| 1 | `…/desenvolvimento/conversation-esaa` | **fonte canônica** + lab | sim (`main`) | 0 (greenfield seed) | **MATCH** (é a fonte) | sim | n/a | — | **Não** (referência) |
| 2 | `…/desenvolvimento/centauri-3720` | consumidor | **não** | 4 | **MATCH** | sim | sim (`…141925.tgz`) | — | **Não** |
| 3 | `…/desenvolvimento/PCA` | consumidor | sim (`main`, dirty) | 0 | **MATCH** | sim | sim (`…142008.tgz`) | — | **Não** |
| 4 | `…/desenvolvimento/consultoria` | consumidor | sim (`main`, dirty em `.conversation-esaa`) | ~833 | **MATCH** | sim | sim (`…142107.tgz`) | pid `run/codex-watch.pid` | **Não** (runtime ok; ver watcher) |

**Total encontrado neste host:** 5 workspaces com `.conversation-esaa/`.

Critério **MATCH:** `sha256` de  
`…/bin/conv-sync.ps1` e `…/bin/conversation-esaa.ps1`  
iguais aos da fonte  
`/home/elzobrito/desenvolvimento/conversation-esaa/.conversation-esaa/bin/`.

Plans públicos na fonte: **5** `*.md` — consumidores acima reportam **5/5**.

### Fora do inventário (não encontrado)

Não há outros `.conversation-esaa` sob `desenvolvimento` (maxdepth 3) além dos listados.
Se novos projetos forem bootstrapados, rodar de novo o `find` e **incluir na tabela**
antes do próximo rollout.

---

## Status de execução (as-run)

| Item | Estado |
|------|--------|
| Rollout mecânico bin/plans (2026-07-08, ex. `T-CONV-ESAA-UPDATE-001`) | **Concluído** nos 5 workspaces |
| Fix verify legado (`rationale` vazio em `decision.recorded`) | **Concluído** no motor canônico e copiado |
| Rebuild dist + novo SHA-256 (2026-07-08 ~21:48) | **Concluído** (zip renovado; workspaces já estavam no motor da árvore fonte) |
| Unit systemd home: path absoluto `~/.local/bin/pwsh` | **Concluído** (não reabrir) |
| Curadoria de tópicos de domínio por workspace | **Fora de escopo** (global já tem TOP-*; apps a critério) |
| Commit das mudanças nos repos PCA/consultoria | **Não feito** (proposital) |

### Checklist (estado)

- [x] Confirmar checksum do build `v1.1.1` (arquivo `dist/*.sha256` atual)
- [x] Backup + update + `project`/`verify`/`topics` — **centauri-3720**
- [x] Backup + update + validação — **PCA**
- [x] Backup + update + validação — **consultoria**
- [x] Backup + update + validação — **home global** `/home/elzobrito`
- [x] Fonte canônica `conversation-esaa` alinhada
- [ ] (Opcional) Conferir se `consultoria` `codex-watch.pid` ainda aponta processo vivo; reiniciar se bin mudou em memória
- [ ] (Opcional) `systemctl --user restart conversation-esaa-codex-watch` após futuros updates do home
- [ ] (Opcional) Reportar/commitar worktrees sujos nos projetos — **humano**

**Conclusão operacional:** nenhum workspace listado **precisa** de nova cópia de runtime
neste momento. Este plano permanece como **procedimento padrão** para:

1. Novos workspaces com `.conversation-esaa` desatualizado  
2. Próximo release (v1.1.2+)  
3. Re-sync se a fonte canônica mudar de novo  

---

## Invariantes

Não apagar nem sobrescrever:

- `.conversation-esaa/activity.jsonl`
- `.conversation-esaa/sync-state.json`
- `.conversation-esaa/state.md`
- `.conversation-esaa/handoff.md`
- `.conversation-esaa/decisions.md`
- `.conversation-esaa/tasks.json`
- `.conversation-esaa/topics.json`
- `.conversation-esaa/topics.md`
- `.conversation-esaa/codex-watch.log` / `codex-watch.stdout.log` / `codex-hook.log`
- `.conversation-esaa/run/*.pid` / `*.lock`
- `.conversation-esaa/backups/**`

Regras:

- Não editar `activity.jsonl` manualmente.
- Não rodar migração com watcher ativo (pidfile **ou** unit systemd do mesmo workspace).
- Cada workspace: backup próprio antes da cópia.
- Cada workspace: validação isolada.
- **Não** copiar o zip inteiro por cima do projeto (evita `README`/`AGENTS`/`dist`/`.roadmap` do produto em apps alheios).
- **Não** copiar `AGENTS.md` / `.claude/CLAUDE.md` para consumidores — contrato fica no **repo** `conversation-esaa`.

---

## Arquivos a atualizar por workspace (cópia seletiva)

Fonte canônica:

```text
SRC=/home/elzobrito/desenvolvimento/conversation-esaa
```

### Runtime (obrigatório)

```text
.conversation-esaa/bin/*.ps1
.conversation-esaa/tests/fixtures/**
.conversation-esaa/plans/*.md          # todos os plans públicos
.conversation-esaa/run/.gitkeep
```

Opcional no home apenas (se existir na fonte ou só no home):

```text
.conversation-esaa/bin/codex-hook-sync.sh
```

### Docs de privacidade/release (recomendado **dentro** do data dir)

```text
# Preferir:
$DST/.conversation-esaa/PRIVACY.md
$DST/.conversation-esaa/RELEASE.md

# Evitar poluir a raiz de PCA/consultoria com arquivos do produto Conversation ESAA.
# Exceção: o próprio repo conversation-esaa já tem PRIVACY.md/RELEASE.md na raiz.
```

### Não copiar

```text
activity.jsonl, sync-state.json, state.md, handoff.md, decisions.md,
tasks.json, topics.json, topics.md, logs, run/*.pid, backups/,
README.md, AGENTS.md, .claude/, dist/, .roadmap/, src/ de apps
```

---

## Pré-requisitos por workspace

1. **Git** (se repo):

```bash
git -C <workspace> status --short --branch
```

2. **Watchers**

```bash
# pidfiles locais
find <workspace>/.conversation-esaa/run -maxdepth 1 -type f -name '*.pid' -print

# home global (systemd)
systemctl --user status conversation-esaa-codex-watch.service --no-pager
```

3. **Backup**

```bash
ts=$(date +%Y%m%d-%H%M%S)
mkdir -p <workspace>/.conversation-esaa/backups
tar -C <workspace> -czf \
  <workspace>/.conversation-esaa/backups/conversation-esaa-pre-v1.1.1-$ts.tgz \
  .conversation-esaa
```

4. **Checksum do build** (se usar o zip; a cópia preferencial é da árvore fonte)

```bash
cd /home/elzobrito/desenvolvimento/conversation-esaa
sha256sum -c dist/conversation-esaa-v1.1.1.sha256
```

5. **pwsh** no Linux deste host:

```bash
PWSH=/home/elzobrito/.local/bin/pwsh
# Nunca assumir /usr/bin/pwsh no unit systemd
```

---

## Procedimento de atualização (quando `needs_update=yes`)

Para cada workspace **alvo** (não a fonte, salvo re-sync interno):

```bash
SRC=/home/elzobrito/desenvolvimento/conversation-esaa
DST=<workspace>
PWSH=/home/elzobrito/.local/bin/pwsh

# 0) Parar watcher se for o workspace afetado
#    - pidfile: kill conforme política do projeto
#    - home: systemctl --user stop conversation-esaa-codex-watch.service

# 1) Backup (obrigatório)

# 2) Runtime
mkdir -p "$DST/.conversation-esaa/bin" \
         "$DST/.conversation-esaa/tests" \
         "$DST/.conversation-esaa/plans" \
         "$DST/.conversation-esaa/run"

cp -a "$SRC/.conversation-esaa/bin/." "$DST/.conversation-esaa/bin/"
# se o destino NÃO deve ganhar scripts só-do-home, remover o que não se aplica
# (ex.: não apagar codex-hook-sync.sh no home se já existia)

rm -rf "$DST/.conversation-esaa/tests/fixtures"
cp -a "$SRC/.conversation-esaa/tests/fixtures" "$DST/.conversation-esaa/tests/"

cp -a "$SRC/.conversation-esaa/plans/." "$DST/.conversation-esaa/plans/"
touch "$DST/.conversation-esaa/run/.gitkeep"

cp "$SRC/PRIVACY.md" "$DST/.conversation-esaa/PRIVACY.md"
cp "$SRC/RELEASE.md" "$DST/.conversation-esaa/RELEASE.md"

# 3) Projeção + validação
"$PWSH" -NoProfile -ExecutionPolicy Bypass \
  -File "$DST/.conversation-esaa/bin/conversation-esaa.ps1" project --workspace "$DST"
"$PWSH" -NoProfile -ExecutionPolicy Bypass \
  -File "$DST/.conversation-esaa/bin/conversation-esaa.ps1" verify --workspace "$DST"
"$PWSH" -NoProfile -ExecutionPolicy Bypass \
  -File "$DST/.conversation-esaa/bin/conversation-esaa.ps1" topics list --workspace "$DST"

# 4) Reiniciar watcher se aplicável
#    home: systemctl --user start conversation-esaa-codex-watch.service
```

### Critérios de sucesso

- `verify: ok`
- `.conversation-esaa/topics.json` e `topics.md` existem (podem estar vazios de assuntos)
- `state.md` contém seção de tópicos
- `handoff.md` lista `topics.json / topics.md` na ordem de leitura
- `sha256` de `conv-sync.ps1` / `conversation-esaa.ps1` = fonte canônica

---

## Tratamento de falhas esperadas

### `verify` falha por contrato legado

**Não** editar `activity.jsonl` à mão.

Casos já vistos:

| Sintoma | Mitigação |
|---------|-----------|
| `decision.recorded` com `rationale` vazio | Motor v1.1.1+ aceita string vazia; copiar `conv-sync.ps1` novo |
| Evento sem `workspace_root` | Preferir repair auditável no motor se existir; senão hotfix no verify + re-cópia do bin |
| Fonte greenfield sem `activity.jsonl` | Seed vazio só no repo canônico; consumidores não devem apagar o log |

Comando hipotético (só se implementado na CLI):

```text
conversation-esaa repair activity-contract --workspace <path>
```

### Watcher ativo

| Workspace | Ação |
|-----------|------|
| consultoria | Inspecionar `run/codex-watch.pid`; parar processo antes de copiar bins |
| home | `systemctl --user stop conversation-esaa-codex-watch.service` |

### Unit com `/usr/bin/pwsh`

Regra (já corrigida no home): path absoluto de  
`/home/elzobrito/.local/bin/pwsh` + `ConditionPathExists`.  
Ver `AGENTS.md` §10 do repo canônico.

### Git dirty

Não fazer commit automático. Reportar arquivos tocados (`bin/`, plans, PRIVACY local).

---

## Ordem recomendada (próximo rollout)

1. **`/home/elzobrito`** (global) — maior impacto operacional; systemd  
2. **`centauri-3720`** — piloto sem Git  
3. **`PCA`** — Git com mudanças locais não relacionadas  
4. **`consultoria`** — watcher/logs + histórico maior  
5. **`conversation-esaa`** — só se o motor na árvore de trabalho divergir do que se quer publicar; é a fonte  

---

## Plano de rollback

```bash
# Parar watchers primeiro (pid ou systemd)

latest=$(ls -t <workspace>/.conversation-esaa/backups/conversation-esaa-pre-v1.1.1-*.tgz | head -n 1)
rm -rf <workspace>/.conversation-esaa
tar -C <workspace> -xzf "$latest"

PWSH=/home/elzobrito/.local/bin/pwsh
"$PWSH" -NoProfile -ExecutionPolicy Bypass \
  -File <workspace>/.conversation-esaa/bin/conversation-esaa.ps1 verify --workspace <workspace> \
  || "$PWSH" -NoProfile -ExecutionPolicy Bypass \
       -File <workspace>/.conversation-esaa/bin/conv-sync.ps1 verify -WorkspaceRoot <workspace>
```

---

## Como decidir se um workspace “precisa ser atualizado”

```bash
SRC=/home/elzobrito/desenvolvimento/conversation-esaa/.conversation-esaa/bin
for DST_ROOT in \
  /home/elzobrito \
  /home/elzobrito/desenvolvimento/centauri-3720 \
  /home/elzobrito/desenvolvimento/PCA \
  /home/elzobrito/desenvolvimento/consultoria \
  /home/elzobrito/desenvolvimento/conversation-esaa
do
  echo "== $DST_ROOT =="
  for f in conv-sync.ps1 conversation-esaa.ps1; do
    s=$(sha256sum "$SRC/$f" | awk '{print $1}')
    d=$(sha256sum "$DST_ROOT/.conversation-esaa/bin/$f" 2>/dev/null | awk '{print $1}')
    if [ "$s" = "$d" ]; then echo "  $f OK"; else echo "  $f NEEDS UPDATE"; fi
  done
done
```

Incluir na lista qualquer novo path retornado por:

```bash
find /home/elzobrito/desenvolvimento -maxdepth 3 -type d -name '.conversation-esaa'
```

---

## Fora de escopo

- Commitar mudanças nos repositórios de destino  
- Publicar release além do zip local em `dist/`  
- Migrar `.roadmap` / ESAA-Core dos projetos  
- Criar tópicos de domínio em cada workspace (curadoria explícita pós-update)  
- Instalar PowerShell em `/usr/bin`  

---

## Histórico de revisões do plano

| Data | Mudança |
|------|---------|
| 2026-07-08 (original) | Inventário 4 workspaces sob `desenvolvimento`; checksum `c3f0e43e…` |
| 2026-07-08 (revisão) | + workspace global home; status as-run; checksum `78a2403d…`; cópia seletiva aprimorada; falhas reais (`rationale`, systemd/`pwsh`); tabela “precisa atualizar?”; critério MATCH por sha256 |
