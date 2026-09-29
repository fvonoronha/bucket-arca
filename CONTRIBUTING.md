# Como contribuir

Obrigado por querer ajudar! Issues e PRs são bem-vindos, em **português ou inglês**.

## Antes de começar

- **Bug?** Abra uma issue com o passo a passo, a versão da imagem (`arca version`), o `SOURCE_PROVIDER` e o `STORAGE_PROVIDER`. **Nunca cole chaves ou o `.env` inteiro.**
- **Ideia nova?** Abra uma issue antes de um PR grande, para combinarmos o caminho.
- **Falha de segurança?** Não abra issue pública: veja [SECURITY.md](SECURITY.md).

## Rodando localmente

Só precisa de Docker:

```bash
tests/integration.sh
```

Esse comando gera a imagem e, contra um S3 de verdade (servido pelo próprio rclone, com um bucket "origem" e um "destino"), testa o espelho (novo, alterado, apagado e o histórico), as travas, o snapshot cifrado, a verificação, a restauração (numa pasta e de volta na origem), o destino em disco local e o modo agendado (cron). É o mesmo teste que o CI roda em cada PR.

Os scripts ficam em `bin/` (`arca` é o comando, `lib.sh` a configuração e as funções comuns). Passe o [shellcheck](https://www.shellcheck.net) antes de enviar:

```bash
shellcheck -x bin/arca bin/lib.sh tests/integration.sh
```

## Regras da casa

- **Bash** simples e legível; comentários explicam o *porquê*.
- Toda configuração nova vira variável de ambiente, **documentada no `.env.example` e no README**.
- **Segurança em primeiro lugar:** nada de credencial em disco, em log ou em linha de comando visível. Falhas nunca podem ser engolidas em silêncio.
- **Nada de apagar sem rede de proteção:** o espelho sempre passa pelas travas, e restaurar nunca apaga.
- **Mudou o comportamento, muda o teste** em `tests/integration.sh`.
- Commits no estilo [Conventional Commits](https://www.conventionalcommits.org/pt-br/): `feat:`, `fix:`, `docs:`, `chore:`...

## Publicando uma versão (mantenedores)

Publique uma *release* no GitHub (tag `vX.Y.Z`). O workflow `Release` gera e publica a imagem (amd64 + arm64) no GHCR com as tags `vX.Y.Z` e `latest`.
