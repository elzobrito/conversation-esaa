# CONV-INSTALL-PUBLISH-003 — publicação do Conversation ESAA 1.3.1

Publicação executada em 2026-09-18 a partir do commit revisado
`483fabf01aaba8bf6c534896d01007d4ff0f413d`, sem alteração de versão.

## Artefato publicado

- Pacote: `conversation-esaa@1.3.1`
- Arquivos no tarball: 24
- Tamanho: 57.254 bytes (260.881 bytes descompactado)
- SHA-256: `7f96631636fd6f924fef4050593bcd66b8500203f251b8073591967e269eeae2`
- npm shasum: `3e2ce201fb80f7157fb19bf691f5fa34eb873b04`
- npm integrity: `sha512-nhsWEzLIgxhfOpnb/aFQPierjD0rjdYIHQcNG3wO9lfSWzn57lMvIKhxs9/bhFeu3gL67ATDhmybGoE4vF4URw==`

O conteúdo empacotado foi inspecionado e não contém event store, projeções de
conversas, SQLite, credenciais ou configuração npm local.

## Evidências de QA

- `npm test`: 23 aprovados, 0 falhas.
- `tests/test-installer-bootstrap.ps1`: `PASS`.
- `tests/test-cli-long-options.ps1`: `ALL PASSED`.
- `.conversation-esaa/bin/conv-test.ps1`: 78 aprovados, 0 falhas.
- `npm view conversation-esaa@1.3.1 version dist.shasum dist.integrity --json`:
  versão e hashes coincidem com o tarball.
- Em workspace limpo, `npx --yes --package conversation-esaa@1.3.1 conversation-esaa --help`:
  exit code 0 e ajuda pública exibida.

## GitHub

- Tag/release: <https://github.com/elzobrito/conversation-esaa/releases/tag/v1.3.1>
- A release aponta para `483fabf01aaba8bf6c534896d01007d4ff0f413d` e contém o tarball.
- Issues GitHub #3 e #4 fechadas com evidência da release.
- Bloqueios ESAA `ISS-CONV-PUBLISH-130-BLOCKED-001` e
  `ISS-CONV-PUBLISH-131-AUTH-001` resolvidos após publicação e autenticação.
