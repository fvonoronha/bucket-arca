#!/usr/bin/env bash
# Teste de ponta a ponta com Docker: gera a imagem e, contra um "S3" de verdade, faz espelho com
# histórico, snapshot cifrado, confere, restaura (numa pasta e de volta na origem) e roda o modo
# agendado (cron). Também testa o destino em disco local.
#
#   tests/integration.sh
#
# Precisa só de Docker. O "S3" é o próprio rclone da imagem (rclone serve s3), com dois buckets:
# "origem" (o que é copiado) e "destino" (para onde vão as cópias).

set -o errexit -o nounset -o pipefail

IMAGE="bucket-arca:test"
NET="barca-test-$$"
S3="barca-s3-$$"
CRON="barca-cron-$$"
WORK="$(mktemp -d)"
PASS=0

cleanup() {
    docker rm -f "$S3" "$CRON" > /dev/null 2>&1 || true
    docker network rm "$NET" > /dev/null 2>&1 || true
    # Os arquivos foram criados pelo root do container.
    docker run --rm -v "$WORK:/work" --entrypoint rm "$IMAGE" -rf /work/storage /work/restore > /dev/null 2>&1 || true
    rm -rf "$WORK" || true
}
trap cleanup EXIT

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; exit 1; }

step "Imagem"
docker build -q --build-arg ARCA_VERSION=test -t "$IMAGE" . > /dev/null
docker run --rm "$IMAGE" version | grep -q "bucket-arca test" || fail "imagem"
ok "imagem gerada"

docker network create "$NET" > /dev/null
docker run -d --name "$S3" --network "$NET" --entrypoint rclone "$IMAGE" \
    serve s3 /data --addr :9000 --auth-key chave,segredo-s3 > /dev/null
sleep 2

# rclone direto no "S3" (para preparar e mexer na origem como a aplicação faria).
s3() {
    docker run --rm -i --network "$NET" -e RCLONE_CONFIG=/dev/null -e RCLONE_CONFIG_M_TYPE=s3 -e RCLONE_CONFIG_M_PROVIDER=Other \
        -e RCLONE_CONFIG_M_ENDPOINT="http://$S3:9000" -e RCLONE_CONFIG_M_ACCESS_KEY_ID=chave \
        -e RCLONE_CONFIG_M_SECRET_ACCESS_KEY=segredo-s3 -e RCLONE_CONFIG_M_FORCE_PATH_STYLE=true \
        --entrypoint rclone "$IMAGE" "$@"
}
put() { printf '%s' "$2" | s3 rcat "m:origem/$1"; }

s3 mkdir m:origem
s3 mkdir m:destino
put capas/a.jpg "capa A versao 1"
put capas/b.jpg "capa B"
put "docs/manual com espaço.pdf" "manual"
ok "origem com 3 arquivos"

docker run --rm --entrypoint age-keygen "$IMAGE" > "$WORK/chave.txt" 2> /dev/null
PUBLIC="$(grep -o 'age1[a-z0-9]*' "$WORK/chave.txt")"
chmod 644 "$WORK/chave.txt"

base_env=(-e SOURCE_PROVIDER=s3 -e SOURCE_ENDPOINT="http://$S3:9000" -e SOURCE_BUCKET=origem
    -e SOURCE_ACCESS_KEY_ID=chave -e SOURCE_SECRET_ACCESS_KEY=segredo-s3
    -e BACKUP_NAME=teste -e BACKUP_ENCRYPTION_RECIPIENTS="$PUBLIC"
    -e MIRROR_STORAGE_CLASS= -e SNAPSHOT_STORAGE_CLASS=)
s3_storage=(-e STORAGE_PROVIDER=s3 -e STORAGE_ENDPOINT="http://$S3:9000" -e STORAGE_BUCKET=destino
    -e STORAGE_PREFIX=backups -e STORAGE_ACCESS_KEY_ID=chave -e STORAGE_SECRET_ACCESS_KEY=segredo-s3)
storage_env=("${s3_storage[@]}")
arca() { docker run --rm --network "$NET" "${base_env[@]}" "${storage_env[@]}" -v "$WORK:/work" "$IMAGE" "$@"; }
# Mesmo comando, com a chave PRIVADA (só para abrir snapshots).
arca_key() { docker run --rm --network "$NET" "${base_env[@]}" "${storage_env[@]}" -e AGE_IDENTITY_FILE=/work/chave.txt -v "$WORK:/work" "$IMAGE" "$@"; }
run() { "$@" > "$WORK/out" 2>&1 || { cat "$WORK/out"; fail "$*"; }; }

step "Destino: S3"
run arca check
ok "check"

run arca mirror
grep -q "3 novo(s), 0 alterado(s), 0 removido" "$WORK/out" || { cat "$WORK/out"; fail "primeiro espelho"; }
[ "$(s3 cat "m:destino/backups/teste/atual/capas/a.jpg")" = "capa A versao 1" ] || fail "conteúdo no espelho"
ok "primeiro espelho (3 novos)"

run arca mirror
grep -q "0 novo(s), 0 alterado(s), 0 removido" "$WORK/out" || { cat "$WORK/out"; fail "espelho sem mudanças"; }
ok "sem mudanças, nada copiado"

put capas/a.jpg "capa A versao 2 (maior)"
s3 deletefile m:origem/capas/b.jpg
put capas/c.jpg "capa C"
run arca mirror
grep -q "1 novo(s), 1 alterado(s), 1 removido" "$WORK/out" || { cat "$WORK/out"; fail "espelho com mudanças"; }
HIST="$(s3 lsf --dirs-only m:destino/backups/teste/historico | tr -d '/' | tail -n 1)"
[ "$(s3 cat "m:destino/backups/teste/historico/$HIST/capas/a.jpg")" = "capa A versao 1" ] || fail "versão antiga no histórico"
s3 lsf m:destino/backups/teste/atual/capas | grep -qx b.jpg && fail "b.jpg deveria ter saído de atual"
ok "alterado e apagado foram para historico/$HIST"

run arca versions capas/a.jpg
[ "$(grep -c '/capas/a.jpg$' "$WORK/out")" = "2" ] || { cat "$WORK/out"; fail "versions"; }
ok "versions (atual + histórico)"

run arca list
if ! grep -q "atual: .*3 objeto" "$WORK/out" || ! grep -q "$HIST  2" "$WORK/out"; then cat "$WORK/out"; fail "list"; fi
ok "list (resumo)"

run arca verify mirror
ok "verify mirror"

docker run --rm --network "$NET" "${base_env[@]}" "${storage_env[@]}" -e SOURCE_PREFIX=nao-existe "$IMAGE" mirror > "$WORK/out" 2>&1 &&
    { cat "$WORK/out"; fail "origem vazia deveria ser recusada"; }
grep -q "VAZIA" "$WORK/out" || { cat "$WORK/out"; fail "mensagem da origem vazia"; }
ok "origem vazia: espelho recusado"

run arca snapshot
grep -q "Snapshot concluído: 3 arquivo" "$WORK/out" || { cat "$WORK/out"; fail "snapshot"; }
s3 lsf m:destino/backups/teste/snapshots | grep -q '^teste_.*\.tar\.zst\.age$' || fail "nome do snapshot"
ok "snapshot (.tar.zst.age)"

arca verify snapshot > "$WORK/out" 2>&1 && fail "verify sem a chave privada deveria falhar"
if ! grep -q "defina AGE_IDENTITY" "$WORK/out" || grep -qE "Baixando|tar:|age:" "$WORK/out"; then
    cat "$WORK/out"; fail "sem a chave, deveria parar antes de baixar, só com a mensagem da chave"
fi
docker run --rm --network "$NET" "${base_env[@]}" "${storage_env[@]}" -e AGE_IDENTITY="$(grep -v '^#' "$WORK/chave.txt" | sed 's/AGE-SECRET-KEY-1./AGE-SECRET-KEY-1Q/')" "$IMAGE" verify snapshot > "$WORK/out" 2>&1 &&
    fail "verify com a chave errada deveria falhar"
ok "sem a chave privada (ou com a errada) não abre, com mensagem clara"
run arca_key verify snapshot
grep -q "3 arquivo" "$WORK/out" || { cat "$WORK/out"; fail "verify snapshot"; }
ok "verify snapshot"

run arca_key restore snapshot --to /work/restore/snap
[ "$(cat "$WORK/restore/snap/capas/a.jpg")" = "capa A versao 2 (maior)" ] || fail "conteúdo restaurado do snapshot"
[ -f "$WORK/restore/snap/docs/manual com espaço.pdf" ] || fail "arquivo com espaço no nome"
ok "restore do snapshot numa pasta"

arca restore "historico/$HIST" --path capas/b.jpg --to origem > "$WORK/out" 2>&1 && fail "restaurar na origem sem --yes deveria falhar"
ok "restaurar na origem exige --yes"
run arca restore "historico/$HIST" --path capas/b.jpg --to origem --yes
[ "$(s3 cat m:origem/capas/b.jpg)" = "capa B" ] || fail "b.jpg de volta na origem"
[ "$(s3 cat m:origem/capas/a.jpg)" = "capa A versao 2 (maior)" ] || fail "--path não deveria tocar em a.jpg"
ok "restore de um arquivo do histórico de volta na origem"

run arca restore atual --path capas --to /work/restore/atual
if [ ! -f "$WORK/restore/atual/capas/c.jpg" ] || [ -e "$WORK/restore/atual/docs" ]; then fail "restore --path de pasta"; fi
ok "restore de uma pasta do espelho"

for i in $(seq 1 12); do put "lote/$i.txt" "arquivo $i"; done
run arca mirror
s3 delete m:origem/lote
arca mirror > "$WORK/out" 2>&1 && { cat "$WORK/out"; fail "12 remoções (limite 10) deveriam ser recusadas"; }
grep -q "MIRROR_MAX_DELETE_PERCENT" "$WORK/out" || { cat "$WORK/out"; fail "mensagem do limite de remoções"; }
run arca mirror --force
[ "$(s3 lsf -R --files-only m:destino/backups/teste/atual/lote 2> /dev/null | wc -l | tr -d ' ')" = "0" ] || fail "--force"
ok "remoções em massa: recusadas, e --force libera"

step "Destino: disco local"
storage_env=(-e STORAGE_PROVIDER=local -e STORAGE_PATH=/work/storage)
run arca check
run arca backup
[ -f "$WORK/storage/bucket-backups/teste/atual/capas/b.jpg" ] || fail "espelho local"
compgen -G "$WORK/storage/bucket-backups/teste/snapshots/teste_*.tar.zst.age" > /dev/null || fail "snapshot local"
ok "backup (espelho + snapshot) em disco"

step "Modo agendado (cron)"
storage_env=("${s3_storage[@]}")
docker run -d --name "$CRON" --network "$NET" "${base_env[@]}" "${storage_env[@]}" \
    -e MIRROR_SCHEDULE="* * * * *" -e SNAPSHOT_SCHEDULE=off -e BACKUP_NAME=cron "$IMAGE" > /dev/null
for _ in $(seq 1 90); do
    docker logs "$CRON" 2>&1 | grep -q "Espelho concluído" && break
    sleep 2
done
docker logs "$CRON" 2>&1 | grep -q "Espelho concluído" || { docker logs "$CRON"; fail "o cron não rodou o espelho"; }
docker logs "$CRON" 2>&1 | grep -q "Snapshot agendado" && fail "snapshot deveria estar desligado"
ok "o cron rodou o espelho sozinho (ambiente repassado ao job)"

printf '\n\033[32m%s verificações passaram\033[0m\n' "$PASS"
