#!/usr/bin/env bash
# Funções e configuração comuns a todos os comandos do arca. É "sourced", não executado.
#
# Toda a configuração vem de variáveis de ambiente (ver .env.example). Dois remotos do rclone são
# montados aqui, só com variáveis de ambiente (nada de arquivo com credenciais no disco):
#   origem  <- SOURCE_*   o bucket que será copiado (lido; nunca alterado, salvo num restore)
#   arca    <- STORAGE_*  para onde vão as cópias
# Os dois aceitam AWS S3, Cloudflare R2, qualquer compatível com S3, disco local ou qualquer um
# dos ~70 serviços do rclone.

set -o errexit -o nounset -o pipefail

ARCA_VERSION="${ARCA_VERSION:-dev}"

# ------------------------------------------------------------------ log

log() { printf '%s [bucket-arca] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "AVISO: $*" >&2; }
die() {
    log "ERRO: $*" >&2
    exit 1
}

# Lê VAR ou, se existir, o arquivo apontado por VAR_FILE (Docker secrets).
read_secret() {
    local name="$1" file_var="${1}_FILE"
    if [ -n "${!file_var:-}" ]; then
        [ -r "${!file_var}" ] || die "$file_var aponta para um arquivo que não existe: ${!file_var}"
        printf '%s' "$(cat "${!file_var}")"
    else
        printf '%s' "${!name:-}"
    fi
}

# Valor de <PREFIXO>_<NOME> (ex.: opt SOURCE REGION us-east-1).
opt() {
    local name="${1}_${2}"
    printf '%s' "${!name:-${3:-}}"
}

# Chaves de acesso nunca têm espaço, quebra de linha ou aspas: vindos do copiar/colar ou do .env
# (KEY="valor" vira valor COM aspas em vários orquestradores), quebrariam a assinatura da AWS
# ("SignatureDoesNotMatch") sem nenhuma pista.
clean_key() {
    local value
    value="$(printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$value" in \"*\" | \'*\') value="${value:1:${#value}-2}" ;; esac
    printf '%s' "$value"
}

fingerprint() { printf '%s' "$1" | { sha256sum 2> /dev/null || shasum -a 256; } | cut -c1-8; }

is_true() { case "${1:-}" in true | TRUE | True | 1 | yes | sim) return 0 ;; *) return 1 ;; esac }

# Agenda desligada: vazia, "off", "false" ou "não".
schedule_enabled() { case "${1:-}" in "" | off | OFF | false | FALSE | no | nao | não) return 1 ;; *) return 0 ;; esac }

# Nomes aceitos em caminhos vindos da linha de comando (evita "../" e nomes estranhos).
valid_name() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'; }
require_name() { valid_name "$1" || die "nome inválido: '$1' (use letras, números, _ . -)"; }

human_size() {
    awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# ------------------------------------------------------------------ configuração dos trabalhos

# Espelho (diário): sincroniza a origem em <destino>/atual. Com MIRROR_HISTORY=true, o que for
# alterado ou apagado na origem vai antes para <destino>/historico/<data>/ (opção 1); com false, é
# só um espelho (opção 2, para um bucket com versionamento).
MIRROR_SCHEDULE="${MIRROR_SCHEDULE-0 3 * * *}"
MIRROR_HISTORY="${MIRROR_HISTORY:-true}"
MIRROR_COMPARE="${MIRROR_COMPARE:-checksum}"
MIRROR_STORAGE_CLASS="${MIRROR_STORAGE_CLASS-STANDARD}"
MIRROR_MAX_DELETE_PERCENT="${MIRROR_MAX_DELETE_PERCENT:-25}"

# Snapshot (semanal): o bucket inteiro num único .tar(.zst)(.age) em <destino>/snapshots/.
SNAPSHOT_SCHEDULE="${SNAPSHOT_SCHEDULE-0 4 * * 0}"
SNAPSHOT_COMPRESSION="${SNAPSHOT_COMPRESSION:-zstd}"
SNAPSHOT_STORAGE_CLASS="${SNAPSHOT_STORAGE_CLASS-GLACIER_IR}"

# Menos requisições de listagem no S3/R2 (uma a cada 1000 objetos, em vez de uma por pasta).
export RCLONE_FAST_LIST="${RCLONE_FAST_LIST:-true}"

# ------------------------------------------------------------------ remotos (rclone)

STORAGE_PREFIX="${STORAGE_PREFIX:-bucket-backups}"
STORAGE_PREFIX="${STORAGE_PREFIX#/}"
STORAGE_PREFIX="${STORAGE_PREFIX%/}"
SOURCE_PREFIX="${SOURCE_PREFIX:-}"
SOURCE_PREFIX="${SOURCE_PREFIX#/}"
SOURCE_PREFIX="${SOURCE_PREFIX%/}"

# Classe de armazenamento mínima por tier (dias). Apagar antes disso é cobrado como se o arquivo
# tivesse ficado o período inteiro (AWS S3 / R2 IA).
min_days_for_class() {
    case "${1:-}" in
        STANDARD_IA | ONEZONE_IA) echo 30 ;;
        GLACIER_IR | GLACIER) echo 90 ;;
        DEEP_ARCHIVE) echo 180 ;;
        *) echo 0 ;;
    esac
}

rcfg() { export "RCLONE_CONFIG_${1}_${2}=$3"; }

# Junta partes de um caminho do rclone, ignorando as vazias ("arca:" + "a" = "arca:a").
join_path() {
    local base="$1" part
    shift
    for part in "$@"; do
        [ -n "$part" ] || continue
        case "$base" in *:) base="$base$part" ;; *) base="${base%/}/$part" ;; esac
    done
    printf '%s' "$base"
}

# Monta o remoto $1 (origem|arca) a partir das variáveis $2_* (SOURCE|STORAGE) e guarda o caminho
# base (bucket/pasta, sem o prefixo) na variável global de nome $3.
setup_remote() {
    local remote="$1" p="$2" out="$3" upper provider bucket key secret path
    upper="$(printf '%s' "$remote" | tr '[:lower:]' '[:upper:]')"
    provider="$(opt "$p" PROVIDER)"
    bucket="$(opt "$p" BUCKET)"
    key="$(clean_key "$(read_secret "${p}_ACCESS_KEY_ID")")"
    secret="$(clean_key "$(read_secret "${p}_SECRET_ACCESS_KEY")")"

    case "$provider" in
        aws | r2 | s3)
            [ -n "$bucket" ] || die "${p}_BUCKET não definido"
            rcfg "$upper" TYPE s3
            # O bucket já existe: não pede permissão de criar/listar buckets (credencial mínima).
            rcfg "$upper" NO_CHECK_BUCKET true
            if [ -n "$key" ] && [ -z "$secret" ]; then
                die "${p}_ACCESS_KEY_ID definida, mas ${p}_SECRET_ACCESS_KEY chegou VAZIA ao container (confira o nome da variável e a ligação \${...} no stack)"
            fi
            if [ -z "$key" ] && [ -n "$secret" ]; then
                die "${p}_SECRET_ACCESS_KEY definida, mas ${p}_ACCESS_KEY_ID chegou VAZIA ao container"
            fi
            if [ -n "$key" ]; then
                # Diagnóstico sem expor nada (usado pelo check): final da access key (identificador,
                # não é segredo), tamanho da secreta e os 8 primeiros caracteres do sha256 dela.
                printf -v "${p}_KEY_INFO" '%s' "access key ...${key: -4} (${#key} caracteres); chave secreta com ${#secret} caracteres, impressão $(fingerprint "$secret")"
                rcfg "$upper" ACCESS_KEY_ID "$key"
                rcfg "$upper" SECRET_ACCESS_KEY "$secret"
            else
                # Sem chaves: usa a credencial do ambiente (perfil IAM da máquina, AWS_*).
                rcfg "$upper" ENV_AUTH true
            fi
            case "$provider" in
                aws)
                    rcfg "$upper" PROVIDER AWS
                    rcfg "$upper" REGION "$(opt "$p" REGION us-east-1)"
                    # Criptografia no próprio S3 ao gravar (só faz diferença no destino).
                    [ "$p" = STORAGE ] && rcfg "$upper" SERVER_SIDE_ENCRYPTION "$(opt "$p" SERVER_SIDE_ENCRYPTION AES256)"
                    ;;
                r2)
                    rcfg "$upper" PROVIDER Cloudflare
                    rcfg "$upper" REGION auto
                    if [ -n "$(opt "$p" ENDPOINT)" ]; then
                        rcfg "$upper" ENDPOINT "$(opt "$p" ENDPOINT)"
                    else
                        [ -n "$(opt "$p" R2_ACCOUNT_ID)" ] || die "Para r2, defina ${p}_R2_ACCOUNT_ID (ou ${p}_ENDPOINT)"
                        rcfg "$upper" ENDPOINT "https://$(opt "$p" R2_ACCOUNT_ID).r2.cloudflarestorage.com"
                    fi
                    ;;
                s3)
                    [ -n "$(opt "$p" ENDPOINT)" ] || die "Para s3 (compatível), defina ${p}_ENDPOINT"
                    rcfg "$upper" PROVIDER "$(opt "$p" S3_PROVIDER Other)"
                    rcfg "$upper" ENDPOINT "$(opt "$p" ENDPOINT)"
                    rcfg "$upper" REGION "$(opt "$p" REGION us-east-1)"
                    is_true "$(opt "$p" FORCE_PATH_STYLE true)" && rcfg "$upper" FORCE_PATH_STYLE true
                    ;;
            esac
            path="${remote}:${bucket}"
            ;;
        local)
            path="$(opt "$p" PATH)"
            [ -n "$path" ] || die "Para local, defina ${p}_PATH (pasta, de preferência um volume)"
            rcfg "$upper" TYPE local
            path="${remote}:${path%/}"
            ;;
        rclone)
            # Qualquer serviço do rclone: o remoto é descrito pelas variáveis RCLONE_CONFIG_<NOME>_*
            # (TYPE e as opções daquele tipo), e <PREFIXO>_PATH é o caminho dentro dele.
            local type_var="RCLONE_CONFIG_${upper}_TYPE"
            [ -n "${!type_var:-}" ] || die "Para rclone, defina RCLONE_CONFIG_${upper}_TYPE e as opções do serviço"
            path="$(opt "$p" PATH)"
            path="${remote}:${path%/}"
            ;;
        "") die "${p}_PROVIDER não definido (aws, r2, s3, local ou rclone)" ;;
        *) die "${p}_PROVIDER inválido: $provider (use aws, r2, s3, local ou rclone)" ;;
    esac
    printf -v "$out" '%s' "$path"
}

# Monta os dois remotos e define:
#   SRC  caminho da origem (bucket[/SOURCE_PREFIX])
#   DST  pasta base das cópias (bucket/STORAGE_PREFIX/BACKUP_NAME)
setup_storage() {
    local src_base dst_base
    setup_remote origem SOURCE src_base
    setup_remote arca STORAGE dst_base
    # shellcheck disable=SC2034 # SRC e DST são usadas em bin/arca
    SRC="$(join_path "$src_base" "$SOURCE_PREFIX")"
    # Nome desta cópia nas pastas do destino (útil com vários buckets no mesmo destino).
    BACKUP_NAME="${BACKUP_NAME:-${SOURCE_BUCKET:-bucket}}"
    require_name "$BACKUP_NAME"
    # shellcheck disable=SC2034
    DST="$(join_path "$dst_base" "$STORAGE_PREFIX" "$BACKUP_NAME")"
    # Sem arquivo de config: tudo vem do ambiente.
    export RCLONE_CONFIG=/dev/null
}

# O destino aceita classe de armazenamento (tier)?
dst_has_classes() { case "${STORAGE_PROVIDER:-}" in aws | r2 | s3) return 0 ;; *) return 1 ;; esac }

rc() { rclone --retries 5 --low-level-retries 10 --stats 0 "$@"; }

# rclone gravando no destino com a classe $1 (vazia = padrão do bucket).
rc_class() {
    local class="$1"
    shift
    if [ -n "$class" ] && dst_has_classes; then
        RCLONE_CONFIG_ARCA_STORAGE_CLASS="$class" rc "$@"
    else
        rc "$@"
    fi
}

# Número de objetos e bytes de um caminho: "N B". Falha se não conseguir listar.
size_of() {
    local json
    json="$(rc size --json "$1")" || return 1
    printf '%s %s\n' "$(printf '%s' "$json" | grep -o '"count":[0-9]*' | cut -d: -f2)" \
        "$(printf '%s' "$json" | grep -o '"bytes":[0-9]*' | cut -d: -f2)"
}

# Mesmo, mas "0 0" se a pasta ainda não existe (destino no primeiro backup).
count_objects() { size_of "$1" 2> /dev/null || echo "0 0"; }

# ------------------------------------------------------------------ criptografia (age)

# Chave(s) pública(s) age: só cifram. A chave privada NÃO fica no servidor; é usada só na
# restauração (AGE_IDENTITY / AGE_IDENTITY_FILE).
encryption_enabled() { [ -n "${BACKUP_ENCRYPTION_RECIPIENTS:-}" ]; }

encrypt_stream() {
    local args=() recipient
    for recipient in $(printf '%s' "$BACKUP_ENCRYPTION_RECIPIENTS" | tr ',' ' '); do
        args+=(-r "$recipient")
    done
    age "${args[@]}"
}

# Arquivo com a identidade (chave privada) para decifrar.
identity_file() {
    if [ -n "${AGE_IDENTITY_FILE:-}" ]; then
        [ -r "$AGE_IDENTITY_FILE" ] || die "AGE_IDENTITY_FILE não encontrado: $AGE_IDENTITY_FILE"
        printf '%s' "$AGE_IDENTITY_FILE"
    elif [ -n "${AGE_IDENTITY:-}" ]; then
        local file="$WORK_DIR/identity.txt"
        (umask 077 && printf '%s\n' "$AGE_IDENTITY" > "$file")
        printf '%s' "$file"
    else
        die "Snapshot cifrado: defina AGE_IDENTITY ou AGE_IDENTITY_FILE (a chave PRIVADA) para abrir"
    fi
}

# ------------------------------------------------------------------ compressão do snapshot

# SNAPSHOT_COMPRESSION: zstd | zstd:N (1-19) | gzip | gzip:N (1-9) | none
compression_ext() {
    case "$SNAPSHOT_COMPRESSION" in
        zstd*) echo .zst ;;
        gzip*) echo .gz ;;
        none) echo "" ;;
        *) die "SNAPSHOT_COMPRESSION inválido: $SNAPSHOT_COMPRESSION (zstd, zstd:N, gzip, gzip:N ou none)" ;;
    esac
}

compress_stream() {
    local level="${SNAPSHOT_COMPRESSION#*:}"
    [ "$level" != "$SNAPSHOT_COMPRESSION" ] || level=""
    case "$SNAPSHOT_COMPRESSION" in
        zstd*) zstd -q -T0 "-${level:-3}" ;;
        gzip*) gzip "-${level:-6}" ;;
        none) cat ;;
    esac
}

# Descompressão pelo nome do arquivo.
decompress_stream() {
    case "$1" in
        *.zst) zstd -q -d ;;
        *.gz) gzip -d ;;
        *) cat ;;
    esac
}

# ------------------------------------------------------------------ arquivos de trabalho e trava

new_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/arca.XXXXXX")"
    chmod 700 "$WORK_DIR"
    LOCK_DIR=""
    trap 'rm -rf "$WORK_DIR" ${LOCK_DIR:+"$LOCK_DIR"}' EXIT
}

# Trava por diretório (portável), uma por trabalho: impede dois espelhos (ou dois snapshots) ao
# mesmo tempo (cron + manual). Espelho e snapshot podem rodar juntos.
acquire_lock() {
    local dir="${TMPDIR:-/tmp}/arca-$1.lock"
    if ! mkdir "$dir" 2> /dev/null; then
        die "Já existe um $1 em andamento (trava em $dir). Se não houver, apague a pasta."
    fi
    LOCK_DIR="$dir"
}

# Espaço livre (bytes) na pasta de trabalho.
free_bytes() { df -Pk "${TMPDIR:-/tmp}" | awk 'NR == 2 { print $4 * 1024 }'; }

# ------------------------------------------------------------------ aviso (Uptime Kuma push etc.)

# Chamado ao fim de cada trabalho com status=up|down&msg=... (formato do monitor "Push" do Uptime
# Kuma). $1 = mirror|snapshot: usa MIRROR_HEALTHCHECK_URL / SNAPSHOT_HEALTHCHECK_URL e, sem elas,
# HEALTHCHECK_URL. Falha no aviso nunca derruba o backup.
notify() {
    local job="$1" status="$2" message="$3" url_var url
    url_var="$(printf '%s' "$job" | tr '[:lower:]' '[:upper:]')_HEALTHCHECK_URL"
    url="${!url_var:-${HEALTHCHECK_URL:-}}"
    [ -n "$url" ] || return 0
    local sep='?'
    case "$url" in *\?*) sep='&' ;; esac
    local encoded
    encoded="$(printf '%s' "$message" | sed 's/%/%25/g; s/ /%20/g; s/&/%26/g; s/?/%3F/g; s/=/%3D/g; s/#/%23/g; s/+/%2B/g')"
    curl -fsS -m 15 --retry 3 -o /dev/null "${url}${sep}status=${status}&msg=${encoded}" ||
        warn "não foi possível chamar o aviso ($url_var / HEALTHCHECK_URL)"
}
