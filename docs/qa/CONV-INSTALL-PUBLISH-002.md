# CONV-INSTALL-PUBLISH-002 — evidência de bloqueio de autenticação

A descrição da tarefa manda reportar o blocker sem publicar ou taguear se a autenticação npm estiver ausente.

## Checagens (2026-08-25)

- `npm whoami` → `ENEEDAUTH` / `need auth This command requires you to be logged in.`
- `npm view conversation-esaa@1.3.1` → 404 (`conversation-esaa@*` not in registry).
- `gh release view v1.3.1` no repositório conversation-esaa → release not found.
- Issue aberta: `ISS-CONV-PUBLISH-131-AUTH-001` (high) — npm authentication is required to publish conversation-esaa 1.3.1.
- Versão local revisada: `package.json` = 1.3.1.

Nenhum tarball foi publicado, nenhum tag `v1.3.1` foi criado, issues GitHub 3/4 não foram fechadas por publicação pública.

Retomada: autenticar `npm adduser`/`npm login`, repetir whoami, então republicar via nova tarefa (esta fica encerrada como blocker reportado).
