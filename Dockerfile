FROM alpine:3.24

ARG ARCA_VERSION=dev

LABEL org.opencontainers.image.title="bucket-arca" \
      org.opencontainers.image.description="Backup agendado de um bucket (Cloudflare R2, AWS S3, compatíveis) para outro armazenamento: espelho incremental com histórico e snapshots cifrados" \
      org.opencontainers.image.source="https://github.com/fvonoronha/bucket-arca" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${ARCA_VERSION}"

# rclone: fala com S3, R2, qualquer compatível com S3 e ~70 outros serviços.
# age: criptografia com chave pública (o servidor só cifra; decifrar exige a chave privada).
# tar (GNU) + zstd/gzip: o snapshot.
RUN apk add --no-cache bash rclone age curl tzdata ca-certificates tar zstd gzip

ENV ARCA_VERSION=${ARCA_VERSION} \
    TZ=America/Sao_Paulo \
    TMPDIR=/tmp

COPY bin/ /usr/local/lib/arca/
RUN chmod 755 /usr/local/lib/arca/arca && ln -s /usr/local/lib/arca/arca /usr/local/bin/arca

# Só faz sentido no modo agendado (cron, o padrão): confere se o crond está vivo.
HEALTHCHECK --interval=5m --timeout=10s CMD pgrep crond > /dev/null || exit 1

ENTRYPOINT ["arca"]
CMD ["cron"]
