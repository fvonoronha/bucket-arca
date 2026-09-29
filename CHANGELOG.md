# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versões seguem [SemVer](https://semver.org/lang/pt-BR/).

## [1.0.0] - 2026-09-29

Primeira versão.

- Espelho incremental agendado (`rclone sync`) do bucket de origem para `<destino>/atual`, com histórico opcional: o que for alterado ou apagado na origem vai antes para `historico/<data>/`.
- Snapshot completo agendado: o bucket inteiro num `.tar.zst` cifrado com age, com a classe de armazenamento configurável (padrão `GLACIER_IR`).
- Os dois trabalhos com agenda própria e ligáveis/desligáveis: só espelho com histórico, só espelho (para bucket com versionamento), só snapshot, ou os dois (híbrido).
- Travas do espelho: recusa rodar com a origem vazia ou se for remover mais que `MIRROR_MAX_DELETE_PERCENT` da cópia (`--force` passa por cima).
- Comandos `list`, `versions`, `restore` (numa pasta ou de volta na origem, nunca apagando nada), `verify`, `prune` e `check`.
- Origem e destino: Cloudflare R2, AWS S3, qualquer compatível com S3, disco local ou qualquer serviço do rclone.
- Aviso ao fim de cada trabalho para o monitor "Push" do Uptime Kuma (um monitor por trabalho, se quiser).
