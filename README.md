<div align="center">

# 🪣 bucket-arca

**Backup automático de buckets (Cloudflare R2, AWS S3...) para qualquer nuvem.<br>Espelho diário incremental, histórico de versões e snapshot cifrado. Um container, um `.env`.**

[![CI](https://github.com/fvonoronha/bucket-arca/actions/workflows/ci.yml/badge.svg)](https://github.com/fvonoronha/bucket-arca/actions/workflows/ci.yml)
[![Licença: MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-blue.svg)](LICENSE)
[![amd64 | arm64](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-555)](#-imagem)

[**Começar**](#-em-1-minuto) · [Como funciona](#-como-funciona) · [Pelo terminal](#%EF%B8%8F-operando-pelo-terminal-do-container) · [Restaurar](#%EF%B8%8F-restaurar) · [Segurança](#-segurança) · [English](README.en.md)

</div>

---

**Seu app guarda imagens, PDFs e anexos num bucket da R2 ou do S3... e esse bucket tem backup?** Na maioria das vezes, não: um `DELETE` errado, um bug que sobrescreve arquivos ou uma credencial vazada, e já era.

O bucket-arca copia o bucket para **outro lugar** (outra nuvem, outra conta, um disco), todo dia, sozinho:

- 🔁 um **espelho incremental**: só o que mudou é copiado, então é rápido e barato mesmo com milhões de arquivos;
- 🕰️ um **histórico**: antes de sobrescrever ou apagar algo da cópia, a versão antiga é guardada, para você recuperar *aquele* arquivo *daquele* dia;
- 📦 um **snapshot completo**, cifrado com chave pública ([age](https://age-encryption.org)), como último recurso.

Irmão do [🛟 pg-arca](https://github.com/fvonoronha/pg-arca) (backup de PostgreSQL): mesma receita, mesmo jeito de configurar, e os dois podem dividir o **mesmo bucket de backups**.

## ✨ Por que o bucket-arca

|  |  |
| --- | --- |
| 🔁 **Incremental de verdade** | Compara por MD5 direto da listagem: não baixa nem envia o que não mudou. |
| 🕰️ **Volta no tempo** | `arca versions capas/x.jpg` mostra cada versão guardada; `arca restore` traz a que você quiser de volta. |
| 🔐 **Snapshot cifrado** | age com chave pública. O servidor consegue *trancar*, não *abrir*. |
| 🧯 **Travas contra desastre** | Origem "vazia" (credencial ou bucket errado) ou remoções em massa? O espelho **recusa** e avisa, em vez de esvaziar a sua cópia. |
| ♻️ **Restaurar nunca apaga** | Um arquivo, uma pasta ou tudo, numa pasta ou de volta no bucket de origem. Nada no destino é apagado. |
| 🔔 **Avisa quando falha** | Monitor *Push* do [Uptime Kuma](https://github.com/louislam/uptime-kuma): `up` no sucesso, `down` na falha. E o silêncio também avisa. |
| 🩺 **Falha cedo** | Ao subir, confere origem, destino, chave e agenda. Erro aparece na hora, não às 3h da manhã. |
| ☁️ **Qualquer lado** | Origem e destino: `r2`, `aws`, `s3` (qualquer compatível: B2, Wasabi, MinIO...), `local` ou `rclone` ([70+ serviços](https://rclone.org/overview/)). |

## 🚀 Em 1 minuto

**1. Gere a chave do snapshot** (a pública vai no `.env`; a privada, no seu cofre de senhas):

```bash
docker run --rm --entrypoint age-keygen ghcr.io/fvonoronha/bucket-arca:latest
# Public key: age1...              <- BACKUP_ENCRYPTION_RECIPIENTS
# AGE-SECRET-KEY-1...              <- guarde bem guardado. NÃO vai no servidor.
```

**2. Crie o `.env`** (exemplo: R2 → AWS S3; todas as opções em [`.env.example`](.env.example)):

```env
SOURCE_PROVIDER=r2
SOURCE_BUCKET=meu-app
SOURCE_R2_ACCOUNT_ID=abc123...
SOURCE_ACCESS_KEY_ID=...           # token R2 "Object Read only"
SOURCE_SECRET_ACCESS_KEY=...

STORAGE_PROVIDER=aws
STORAGE_BUCKET=meus-backups
STORAGE_REGION=us-east-1
STORAGE_ACCESS_KEY_ID=AKIA...
STORAGE_SECRET_ACCESS_KEY=...

BACKUP_ENCRYPTION_RECIPIENTS=age1...
HEALTHCHECK_URL=https://kuma.exemplo.com/api/push/xxxx
```

**3. Suba:**

```bash
docker run -d --name bucket-arca --env-file .env ghcr.io/fvonoronha/bucket-arca:latest
docker logs bucket-arca                  # confira o "Tudo certo."
docker exec bucket-arca arca backup      # quer o primeiro backup agora?
```

Pronto: todo dia às 3h o espelho acompanha o bucket, e todo domingo às 4h sai um snapshot cifrado. 🎉

<details>
<summary><b>Com docker compose</b></summary>

```yaml
services:
  bucket-arca:
    image: ghcr.io/fvonoronha/bucket-arca:latest
    env_file: .env
    restart: unless-stopped
```

</details>

<details>
<summary><b>No Docker Swarm / Portainer</b> (ao lado do pg-arca, no mesmo bucket)</summary>

```yaml
services:
  bucket-arca:
    image: ghcr.io/fvonoronha/bucket-arca:v1.0.0
    environment:
      SOURCE_PROVIDER: r2
      SOURCE_BUCKET: ${R2_BUCKET_NAME}
      SOURCE_R2_ACCOUNT_ID: ${R2_ACCOUNT_ID}
      SOURCE_ACCESS_KEY_ID: ${R2_BACKUP_ACCESS_KEY_ID}
      SOURCE_SECRET_ACCESS_KEY: ${R2_BACKUP_SECRET_ACCESS_KEY}
      STORAGE_PROVIDER: aws
      STORAGE_BUCKET: meus-backups          # o mesmo do pg-arca
      STORAGE_PREFIX: bucket-backups        # o pg-arca usa postgres-backups
      STORAGE_REGION: us-east-1
      STORAGE_ACCESS_KEY_ID: ${AWS_ACCESS_ID}
      STORAGE_SECRET_ACCESS_KEY: ${AWS_ACCESS_KEY}
      BACKUP_NAME: producao
      MIRROR_SCHEDULE: "0 3 * * *"
      SNAPSHOT_SCHEDULE: "0 4 * * 0"
      BACKUP_ENCRYPTION_RECIPIENTS: ${AGE_PUBLIC_KEY}
      MIRROR_HEALTHCHECK_URL: https://kuma.exemplo.com/api/push/${KUMA_ESPELHO}
      SNAPSHOT_HEALTHCHECK_URL: https://kuma.exemplo.com/api/push/${KUMA_SNAPSHOT}
      TZ: America/Sao_Paulo
    deploy:
      replicas: 1            # SEMPRE 1: duas réplicas = dois backups ao mesmo tempo
      restart_policy:
        condition: any
        delay: 10s
```

Não precisa de rede nem de volume: ele só fala com a origem e o destino pela internet.

</details>

## 🧭 Como funciona

Dois trabalhos independentes, cada um com a sua agenda:

```
                 ┌───────────── espelho (todo dia, 3h) ────────────┐
                 │  copia só novos/alterados; a versão antiga do    │
 origem (R2) ────┤  que foi alterado/apagado vai para historico/    ├──► destino (S3)
 só leitura      │                                                  │
                 ├──────── snapshot (domingo, 4h) ──────────────────┤
                 │  baixa tudo → tar → zstd → age → um arquivo      │
                 └──────────────────────────────────────────────────┘
```

No destino, tudo fica debaixo de `STORAGE_PREFIX` (padrão `bucket-backups/`), numa pasta com o `BACKUP_NAME`. Não precisa criar nada antes: no S3 as "pastas" são só o começo do nome dos arquivos e aparecem sozinhas no primeiro envio. Por isso o bucket-arca e o pg-arca convivem no mesmo bucket:

```
s3://meus-backups/
├── postgres-backups/                     ← do pg-arca
└── bucket-backups/                       ← do bucket-arca
    └── producao/                         ← BACKUP_NAME
        ├── atual/                        ← espelho: cópia 1:1 da origem
        │   ├── capas/a.jpg
        │   └── docs/manual.pdf
        ├── historico/
        │   ├── 20261001T060000Z/         ← quando o espelho viu a mudança (UTC)
        │   │   └── capas/a.jpg           ← a versão de ANTES da alteração
        │   └── 20261003T060000Z/
        │       └── capas/b.jpg           ← apagado da origem; esta é a última versão
        └── snapshots/
            └── producao_20261004T070000Z.tar.zst.age
```

<details>
<summary><b>O espelho, passo a passo</b></summary>

1. Lista a origem. Se não conseguir, falha. Se ela estiver **vazia** e a cópia não, **recusa** (proteção contra credencial ou bucket errado).
2. Roda `rclone sync origem → atual/`, comparando por MD5 (`MIRROR_COMPARE=checksum`), que vem na própria listagem: nenhuma requisição por arquivo.
3. Com `MIRROR_HISTORY=true`, todo arquivo que seria sobrescrito ou apagado em `atual/` é antes **movido** para `historico/<data>/` (no S3, uma cópia dentro do próprio servidor: não passa pela sua rede).
4. Se for remover mais que `MIRROR_MAX_DELETE_PERCENT` dos arquivos da cópia (mínimo 10), para e falha.
5. Mostra o resumo (`+` novo, `~` alterado, `-` removido) e avisa o Kuma.

</details>

<details>
<summary><b>O snapshot, passo a passo</b></summary>

1. Lista a origem e confere se há espaço em `TMPDIR` (≈ 2x o tamanho da origem).
2. Baixa todos os arquivos, empacota (`tar`), comprime (`zstd`) e cifra (`age`).
3. Envia um único arquivo para `snapshots/`, na classe `SNAPSHOT_STORAGE_CLASS` (padrão `GLACIER_IR`).
4. Avisa o Kuma.

Imagens e PDFs já vêm comprimidos, então o `zstd` quase não reduz o tamanho deles. Ele serve para o resto (texto, JSON, SVG) e custa pouco. `SNAPSHOT_COMPRESSION=none` desliga.

</details>

### As 4 estratégias

Tudo liga e desliga pelo `.env`. **O padrão é a híbrida (4).**

| # | Estratégia | `MIRROR_SCHEDULE` | `MIRROR_HISTORY` | `SNAPSHOT_SCHEDULE` | Para quem |
| --- | --- | --- | --- | --- | --- |
| 1 | Espelho + histórico | `0 3 * * *` | `true` | `off` | Recuperar arquivos soltos gastando pouco |
| 2 | Espelho + versionamento do S3 | `0 3 * * *` | `false` | `off` | Quem prefere o *Versioning* (e o *Object Lock*) do S3 |
| 3 | Só snapshot | `off` | - | `0 3 * * *` | Quem quer um arquivo único cifrado por dia (guarda N cópias inteiras) |
| **4** | **Híbrida** ⭐ | `0 3 * * *` | `true` | `0 4 * * 0` | **Espelho diário barato + snapshot semanal cifrado** |

<details>
<summary><b>Estratégia 2: o que ligar no S3</b></summary>

Ligue o *Bucket Versioning* (S3 → bucket → *Properties*) e uma regra de ciclo de vida *"Permanently delete noncurrent versions"* depois de N dias no prefixo. O S3 guarda as versões antigas sozinho; para recuperar uma, use o console da AWS ou `rclone --s3-versions` / `--s3-version-at`. Contra quem tiver a credencial, ligue também o *Object Lock* (só dá na criação do bucket).

</details>

## 🧰 Comandos

```bash
arca backup                     # roda agora os trabalhos ligados (espelho e/ou snapshot)
arca mirror [--force]           # espelho agora (--force: ignora as travas uma vez)
arca snapshot                   # snapshot agora
arca list [atual|historico|historico/<data>|snapshots]   # o que está guardado
arca versions <caminho>         # todas as cópias guardadas de um arquivo
arca restore <fonte> --to <origem|/pasta> [--path <caminho>] [--yes]
arca verify [mirror|snapshot]   # a cópia bate com a origem? o snapshot abre?
arca prune                      # aplica a retenção (se não usar regra do bucket)
arca check                      # confere origem, destino, chave e agendas
```

No container: `docker exec <container> arca <comando>`, ou `docker run --rm --env-file .env ghcr.io/fvonoronha/bucket-arca:latest <comando>`.

## 🖥️ Operando pelo terminal do container

O container já tem todas as variáveis (origem, destino, chaves), então **basta digitar `arca ...`**. No Portainer: *Containers* → o container do bucket-arca → **Console** → *Connect* (`/bin/sh` ou `/bin/bash`). Pela linha de comando: `docker exec -it <container> bash`.

Tudo o que é leitura (`list`, `versions`, `verify mirror`, `check`) é seguro a qualquer hora. Um espelho manual enquanto o agendado roda é recusado pela trava (`Já existe um mirror em andamento`).

### Conferir se está tudo bem

```bash
arca check                 # acessa a origem? grava no destino? chave e agendas ok?
arca list                  # resumo: arquivos no espelho, datas do histórico, snapshots
arca verify mirror         # tudo o que está na origem está igual na cópia?
```

```
2026-10-05 10:12:01 [bucket-arca] Cópias em arca:meus-backups/bucket-backups/producao
atual:      812 objeto(s), 96.3 MB
historico:  (data: arquivos arquivados)
  20261001T060000Z  1
  20261003T060000Z  4
snapshots:
    96102233  2026-10-04 04:00:12  producao_20261004T070000Z.tar.zst.age
```

`verify mirror` pode acusar diferenças em arquivos enviados à origem depois do último espelho: é normal, eles entram no próximo.

### Ver o que está guardado

```bash
arca list atual                         # todos os arquivos do espelho (tamanho, data, caminho)
arca list historico                     # as datas que têm versões antigas
arca list historico/20261003T060000Z    # o que foi guardado naquela data
arca list snapshots                     # os snapshots
arca versions capas/livro-123.jpg       # cada cópia guardada deste arquivo
```

### Rodar um backup agora

```bash
arca backup        # espelho + snapshot (os que estiverem ligados)
arca mirror        # só o espelho
arca snapshot      # só o snapshot
```

A saída do espelho lista cada mudança:

```
  + capas/livro-900.jpg        ← novo
  ~ capas/livro-123.jpg        ← alterado (a versão antiga foi para o histórico)
  - docs/antigo.pdf            ← apagado da origem (a última versão foi para o histórico)
Espelho concluído: 812 objeto(s), 96.3 MB; 1 novo(s), 1 alterado(s), 1 removido(s) em 3s
```

### Quando uma trava dispara

- **`a origem está VAZIA e a cópia tem N objeto(s): recusado`**: confira as credenciais e o nome do bucket. Se o bucket foi mesmo esvaziado de propósito: `arca mirror --force`.
- **`mais remoções do que MIRROR_MAX_DELETE_PERCENT permite`**: alguém (ou algo) apagou muita coisa. O que já foi removido até o limite está no histórico, então nada se perdeu. Confira a origem; se estiver certo: `arca mirror --force`.

### Restaurar pelo terminal

Veja [Restaurar](#%EF%B8%8F-restaurar) logo abaixo. Duas coisas que o serviço agendado **não tem**, de propósito, e que você passa só no comando:

| Para... | Passe no comando | Por quê |
| --- | --- | --- |
| Restaurar **na origem** | `SOURCE_ACCESS_KEY_ID=... SOURCE_SECRET_ACCESS_KEY=... arca restore ... --to origem --yes` | A credencial do dia a dia é só de leitura. Crie um token R2 *Object Read & Write* temporário e apague depois. |
| Abrir um **snapshot** (`restore snapshot`, `verify snapshot`) | `AGE_IDENTITY='AGE-SECRET-KEY-1...' arca ...` | A chave privada nunca fica no servidor. |

Os valores ficam só naquele comando (não ficam salvos no container). Para tirar da tela depois, feche o console.

## ♻️ Restaurar

```
arca restore <fonte> --to <destino> [--path <caminho>] [--yes]
```

| Parte | Valores |
| --- | --- |
| `<fonte>` | `atual` (o espelho) · `historico/<data>` (as versões guardadas naquela data) · `snapshot` (o mais novo) · `snapshot/<arquivo>` |
| `--to` | `origem` (o próprio bucket de origem; exige `--yes`) ou uma pasta absoluta no container (ex.: `/tmp/restore`) |
| `--path` | Só um arquivo ou uma pasta, relativo à raiz do bucket. Aceita curingas: `capas/*.jpg` |

Restaurar **nunca apaga** nada no destino: só cria ou sobrescreve arquivos de mesmo nome.

**"Um arquivo foi alterado ou apagado por engano":**

```bash
arca versions capas/livro-123.jpg
#        48213  2026-10-01 03:00:02  atual/capas/livro-123.jpg
#        51002  2026-09-28 03:00:01  historico/20261001T060000Z/capas/livro-123.jpg   <- a de antes

SOURCE_ACCESS_KEY_ID=... SOURCE_SECRET_ACCESS_KEY=... \
  arca restore historico/20261001T060000Z --path capas/livro-123.jpg --to origem --yes
```

**"Perdi o bucket inteiro":**

```bash
SOURCE_ACCESS_KEY_ID=... SOURCE_SECRET_ACCESS_KEY=... arca restore atual --to origem --yes
```

**"Quero o bucket como estava numa semana específica":**

```bash
arca list snapshots
AGE_IDENTITY='AGE-SECRET-KEY-1...' arca restore snapshot/producao_20261004T070000Z.tar.zst.age --to /tmp/restore
ls -R /tmp/restore                          # confira
# se estiver certo, mande para a origem (com a credencial de escrita):
SOURCE_ACCESS_KEY_ID=... SOURCE_SECRET_ACCESS_KEY=... AGE_IDENTITY='AGE-SECRET-KEY-1...' \
  arca restore snapshot/producao_20261004T070000Z.tar.zst.age --to origem --yes
```

Para tirar uma pasta restaurada do container para a sua máquina: `docker cp <container>:/tmp/restore ./restore`, no nó onde ele roda.

**Abrir um snapshot sem o bucket-arca** (só precisa de `age`, `zstd` e `tar`):

```bash
age -d -i chave.txt producao_20261004T070000Z.tar.zst.age | zstd -d | tar -x -C ./restore
```

> O snapshot guarda o conteúdo e o nome dos arquivos. Ao restaurar um snapshot para um bucket, o `Content-Type` é deduzido pela extensão (o que basta para imagens e PDFs). Restaurar de `atual/` ou do histórico preserva o `Content-Type` original.

## 🗓️ Retenção: regras de ciclo de vida

Os antigos saem **por regra do bucket de destino**, não pelo bucket-arca: assim a credencial do backup nem precisa poder apagar histórico e snapshots. Na AWS: S3 → bucket → *Management* → *Lifecycle rules* → *Create lifecycle rule*. Para 90 dias de histórico (troque `producao` pelo seu `BACKUP_NAME`):

| Regra | Prefixo | Ação |
| --- | --- | --- |
| Histórico | `bucket-backups/producao/historico/` | *Expire current versions of objects*: **90 dias** |
| Snapshots | `bucket-backups/producao/snapshots/` | *Expire current versions of objects*: **91 dias** (o `GLACIER_IR` cobra no mínimo 90) |
| Uploads pela metade | `bucket-backups/` | *Delete incomplete multipart uploads*: 7 dias |

> 🛑 **Nunca crie uma regra de expiração que pegue `atual/`** (por exemplo, uma regra só com o prefixo `bucket-backups/`). O espelho **não reenvia** o que não mudou: um arquivo que está lá há 90 dias sumiria da cópia e só voltaria se mudasse na origem.

A contagem do histórico começa quando o espelho **detectou** a mudança (a data da pasta): uma versão antiga fica disponível por 90 dias depois de ter sido substituída.

Prefere que o bucket-arca apague? Use `HISTORY_RETENTION_DAYS` e `SNAPSHOT_RETENTION_DAYS` (e dê à credencial permissão de apagar nesses prefixos). Os `SNAPSHOT_KEEP_MIN` snapshots mais novos nunca são apagados, mesmo que velhos.

## 🔐 Segurança

**1. Origem só de leitura.** Na R2: *R2* → *Manage R2 API Tokens* → *Create API token* → **Object Read only**, restrito ao bucket. Nem um bug nem uma invasão do servidor de backup conseguem alterar os arquivos da aplicação.

**2. Destino sem poder apagar o que importa.** A política de IAM abaixo só deixa apagar dentro de `atual/` (o espelho precisa disso para acompanhar a origem). Histórico e snapshots **não podem ser apagados** com essa credencial; saem só pela regra de ciclo de vida.

É uma política de **IAM** (IAM → *Policies* → *Create policy* → JSON), anexada a um usuário só para backups. Não cole na *Bucket policy*: lá o JSON exige `Principal`. Troque `MEU-BUCKET`, `bucket-backups` (`STORAGE_PREFIX`) e `producao` (`BACKUP_NAME`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LerEGravarAsCopias",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::MEU-BUCKET/bucket-backups/*"
    },
    {
      "Sid": "ApagarSoNoEspelho",
      "Effect": "Allow",
      "Action": "s3:DeleteObject",
      "Resource": "arn:aws:s3:::MEU-BUCKET/bucket-backups/producao/atual/*"
    },
    {
      "Sid": "Listar",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::MEU-BUCKET"
    }
  ]
}
```

> **Por que o `ListBucket` sem restrição de prefixo?** Quando o rclone pergunta por um arquivo que não existe, a AWS só responde 404 se a credencial puder listar o bucket; com o `ListBucket` condicionado a um prefixo, ela responde **403** e a operação falha. O custo: a credencial vê os **nomes** dos outros arquivos do bucket (não o conteúdo).
>
> **Usando o mesmo usuário do pg-arca?** Basta acrescentar os dois primeiros blocos acima à política que ele já tem (e tirar a condição de prefixo do `ListBucket`).

O `check` tenta apagar um arquivo de teste fora de `atual/`; com essa política, mostra um aviso. É esperado.

**3. Snapshot cifrado com chave pública.** O servidor só tem a chave pública. A privada fica no seu cofre e aparece só na hora de restaurar. Pode listar mais de uma chave pública em `BACKUP_ENCRYPTION_RECIPIENTS` (separadas por vírgula), por exemplo a sua e a de um segundo responsável.

**4. Espelho e histórico** ficam como os arquivos são (sem age, para restaurar um arquivo sem precisar da chave), protegidos pela criptografia do próprio S3 (`STORAGE_SERVER_SIDE_ENCRYPTION=AES256`, padrão), pela política acima e pelo bucket privado (*Block all public access*).

**5. Chaves por arquivo.** Toda chave aceita a forma `_FILE` (Docker secrets): `SOURCE_SECRET_ACCESS_KEY_FILE=/run/secrets/r2`.

## 🔔 Uptime Kuma

Crie **dois monitores do tipo *Push*** e use a URL de cada um:

| Monitor | Variável | *Heartbeat Interval* |
| --- | --- | --- |
| Espelho (diário) | `MIRROR_HEALTHCHECK_URL` | `90000` s (25 h: um dia + folga) |
| Snapshot (semanal) | `SNAPSHOT_HEALTHCHECK_URL` | `612000` s (7 dias + 2 h) |

O bucket-arca manda `status=up` no sucesso e `status=down` na falha, com um resumo em `msg` (ex.: `812 objeto(s), 96.3 MB; 3 novo(s), 0 alterado(s), 0 removido(s) em 4s`). Se o container parar, o push não chega e o Kuma marca *down* sozinho.

Com uma URL só (`HEALTHCHECK_URL`) os dois avisam no mesmo monitor, mas aí o espelho diário "esconde" um snapshot que parou de rodar.

## 💰 Quanto custa

Um bucket de ~100 MB com poucas mudanças por dia, na estratégia híbrida, na AWS: **alguns centavos de dólar por mês**, somando tudo. A R2 não cobra para baixar (egress) e a AWS não cobra para receber, então ler o bucket inteiro toda semana custa só as requisições, que cabem na faixa gratuita da R2.

| Onde | Classe | Por quê |
| --- | --- | --- |
| `atual/` e `historico/` | `STANDARD` (`MIRROR_STORAGE_CLASS`) | Muitos arquivos pequenos: `STANDARD_IA` cobra no mínimo 128 KB por objeto e 30 dias. |
| `snapshots/` | `GLACIER_IR` (`SNAPSHOT_STORAGE_CLASS`) | ~6x mais barato que o Standard e restaura na hora. |

`DEEP_ARCHIVE` é ainda mais barato, mas cobra no mínimo 180 dias e precisa ser "descongelado" na AWS (12 a 48 h) antes de restaurar ou verificar. Com 90 dias de retenção, não compensa.

## ⚙️ Configuração

Tudo por variável de ambiente, cada uma comentada no [`.env.example`](.env.example).

<details open>
<summary><b>Origem (<code>SOURCE_*</code>) e destino (<code>STORAGE_*</code>)</b></summary>

As duas aceitam as mesmas opções; troque o prefixo.

| Variável | Padrão | O que faz |
| --- | --- | --- |
| `*_PROVIDER` | (obrigatória) | `r2`, `aws`, `s3` (qualquer compatível), `local` ou `rclone` |
| `*_BUCKET` | - | Nome do bucket (`r2`, `aws`, `s3`) |
| `*_ACCESS_KEY_ID` / `*_SECRET_ACCESS_KEY` | - | Credencial (aceitam `_FILE`). Sem elas, usa a do ambiente (perfil IAM, `AWS_*`) |
| `*_R2_ACCOUNT_ID` | - | `r2`: ID da conta Cloudflare |
| `*_ENDPOINT` | - | `s3`: URL do serviço (`r2`: substitui o endpoint montado pelo ID da conta) |
| `*_REGION` | `us-east-1` | `aws`/`s3`: região do bucket |
| `*_S3_PROVIDER` / `*_FORCE_PATH_STYLE` | `Other` / `true` | `s3`: provedor no rclone (`Minio`, `Wasabi`...) e estilo de endereço |
| `*_PATH` | - | `local`: pasta. `rclone`: caminho dentro do remoto |
| `SOURCE_PREFIX` | vazio | Copiar só uma pasta da origem |
| `STORAGE_PREFIX` | `bucket-backups` | Pasta das cópias no destino (criada sozinha) |
| `STORAGE_SERVER_SIDE_ENCRYPTION` | `AES256` | `aws`: criptografia no S3 (`AES256` ou `aws:kms`) |
| `BACKUP_NAME` | nome do bucket de origem | Pasta desta cópia no destino (e prefixo dos snapshots) |

Com `rclone`, o remoto é descrito pelas variáveis do próprio rclone: `RCLONE_CONFIG_ORIGEM_*` (origem) e `RCLONE_CONFIG_ARCA_*` (destino). Ex.: `RCLONE_CONFIG_ARCA_TYPE=sftp`, `RCLONE_CONFIG_ARCA_HOST=...`, `STORAGE_PATH=/backups`.

</details>

<details open>
<summary><b>Espelho</b></summary>

| Variável | Padrão | O que faz |
| --- | --- | --- |
| `MIRROR_SCHEDULE` | `0 3 * * *` | Quando rodar (cron: minuto hora dia mês dia-da-semana). `off` desliga |
| `MIRROR_HISTORY` | `true` | Guardar a versão antiga de alterados/apagados em `historico/<data>/` |
| `MIRROR_COMPARE` | `checksum` | Como detectar mudança: `checksum` (MD5), `modtime` (uma requisição por arquivo no S3) ou `size` |
| `MIRROR_STORAGE_CLASS` | `STANDARD` | Classe de `atual/` e `historico/` (vazio = padrão do bucket) |
| `MIRROR_MAX_DELETE_PERCENT` | `25` | Recusa se for remover mais que N% da cópia (mínimo 10 arquivos). `0` desliga |
| `HISTORY_RETENTION_DAYS` | `0` | Apagar datas do histórico com mais de N dias (`0` = regra do bucket) |
| `MIRROR_HEALTHCHECK_URL` | `HEALTHCHECK_URL` | Monitor *Push* deste trabalho |

</details>

<details open>
<summary><b>Snapshot</b></summary>

| Variável | Padrão | O que faz |
| --- | --- | --- |
| `SNAPSHOT_SCHEDULE` | `0 4 * * 0` | Quando rodar (padrão: domingo, 4h). `off` desliga |
| `SNAPSHOT_COMPRESSION` | `zstd` | `zstd`, `zstd:N` (1-19), `gzip`, `gzip:N` (1-9) ou `none` |
| `SNAPSHOT_STORAGE_CLASS` | `GLACIER_IR` | Classe do snapshot (vazio = padrão do bucket) |
| `BACKUP_ENCRYPTION_RECIPIENTS` | - | Chave(s) pública(s) age. Vazio = snapshot sem criptografia (com aviso) |
| `SNAPSHOT_RETENTION_DAYS` / `SNAPSHOT_KEEP_MIN` | `0` / `3` | Retenção pelo bucket-arca e piso |
| `TMPDIR` | `/tmp` | Pasta de trabalho: precisa de ≈ 2x o tamanho da origem livre |
| `SNAPSHOT_HEALTHCHECK_URL` | `HEALTHCHECK_URL` | Monitor *Push* deste trabalho |

</details>

<details open>
<summary><b>Geral</b></summary>

| Variável | Padrão | O que faz |
| --- | --- | --- |
| `TZ` | `America/Sao_Paulo` | Fuso das agendas (os nomes de pastas e arquivos são sempre em UTC) |
| `BACKUP_ON_STARTUP` | `false` | Rodar os trabalhos ligados assim que o container sobe |
| `HEALTHCHECK_URL` | - | Monitor *Push* para os trabalhos sem URL própria |
| `AGE_IDENTITY` / `AGE_IDENTITY_FILE` | - | Chave **privada**: só no comando de restaurar/verificar um snapshot, nunca no serviço |
| `RCLONE_*` | - | Qualquer opção do rclone, ex.: `RCLONE_TRANSFERS=8`, `RCLONE_BWLIMIT=10M` |

</details>

## ⚠️ Bom saber

- **Granularidade diária.** O histórico guarda o que o espelho encontrou em cada execução: um arquivo criado e apagado entre dois espelhos não é copiado. Precisa de mais? Rode o espelho mais vezes (`0 */6 * * *`).
- **O snapshot baixa tudo** para `TMPDIR` antes de empacotar. Com um bucket grande, monte um volume ali.
- **Espelho e snapshot podem rodar ao mesmo tempo** (travas separadas); dois espelhos, não.
- **No Swarm, sempre `replicas: 1`.**

## 🐳 Imagem

`ghcr.io/fvonoronha/bucket-arca`, para amd64 e arm64:

| Tag | Uso |
| --- | --- |
| `v1.0.0` | Versão fixa, para produção previsível |
| `latest` | Última versão |

Base Alpine, com `rclone`, `age`, `zstd`, `tar` e `curl`. Fora do Docker, basta ter esses programas e o Bash: `bin/arca help`.

## 🤝 Contribua

O projeto é aberto e contribuições são muito bem-vindas: bugs, ideias, documentação, novos exemplos. Leia o [CONTRIBUTING.md](CONTRIBUTING.md). Todo PR passa por um teste de ponta a ponta (espelho, histórico, travas, snapshot, restauração e cron contra um S3 de verdade), que você roda localmente com `tests/integration.sh`.

Achou uma falha de segurança? Relate em privado, como explica o [SECURITY.md](SECURITY.md).

## 💙 Créditos

Irmão do [pg-arca](https://github.com/fvonoronha/pg-arca). Feito sobre ombros de gigantes: [rclone](https://rclone.org), [age](https://age-encryption.org) e [zstd](https://facebook.github.io/zstd/).

Licença [MIT](LICENSE): use, modifique e compartilhe.
