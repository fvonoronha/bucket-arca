<div align="center">

# 🪣 bucket-arca

**Automatic backups of object storage buckets (Cloudflare R2, AWS S3...) to any cloud.<br>Incremental daily mirror, version history and an encrypted snapshot. One container, one `.env`.**

[![CI](https://github.com/fvonoronha/bucket-arca/actions/workflows/ci.yml/badge.svg)](https://github.com/fvonoronha/bucket-arca/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![amd64 | arm64](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-555)](#image)

[Português](README.md)

</div>

---

**Your app stores images, PDFs and attachments in an R2 or S3 bucket... is that bucket backed up?** Usually it isn't: one wrong `DELETE`, a bug that overwrites files, or a leaked key, and it's gone.

bucket-arca copies the bucket **somewhere else** (another cloud, another account, a disk), every day, on its own:

- 🔁 an **incremental mirror**: only what changed is copied, so it's fast and cheap even with millions of files;
- 🕰️ a **history**: before a file in the copy is overwritten or deleted, the old version is kept, so you can get *that* file back from *that* day;
- 📦 a **full snapshot**, encrypted with a public key ([age](https://age-encryption.org)), as a last resort.

Sibling of [🛟 pg-arca](https://github.com/fvonoronha/pg-arca) (PostgreSQL backups): same recipe, same configuration style, and both can share **one backup bucket**.

## Why bucket-arca

- 🔁 **Truly incremental**: compares MD5 straight from the listing; unchanged files are never downloaded or uploaded.
- 🕰️ **Time travel**: `arca versions covers/x.jpg` shows every kept version; `arca restore` brings back the one you want.
- 🔐 **Encrypted snapshot**: public-key age. The server can *lock*, not *open*.
- 🧯 **Safety brakes**: an "empty" source (wrong key or bucket) or a mass deletion makes the mirror **refuse** and alert, instead of wiping your copy.
- ♻️ **Restores never delete**: one file, a folder or everything, into a folder or back into the source bucket.
- 🔔 **Alerts** through [Uptime Kuma](https://github.com/louislam/uptime-kuma) *Push* monitors: `up` on success, `down` on failure. Silence alerts too.
- 🩺 **Fails fast**: checks source, destination, key and schedules when the container starts.
- ☁️ **Any side**: source and destination can be `r2`, `aws`, `s3` (any compatible), `local` or `rclone` (70+ services).

## Quick start

```bash
# 1. Snapshot key: the public one goes in .env, the private one in your password manager
docker run --rm --entrypoint age-keygen ghcr.io/fvonoronha/bucket-arca:latest
```

```env
# 2. .env (R2 -> AWS S3; every option is in .env.example)
SOURCE_PROVIDER=r2
SOURCE_BUCKET=my-app
SOURCE_R2_ACCOUNT_ID=abc123...
SOURCE_ACCESS_KEY_ID=...           # R2 "Object Read only" token
SOURCE_SECRET_ACCESS_KEY=...

STORAGE_PROVIDER=aws
STORAGE_BUCKET=my-backups
STORAGE_REGION=us-east-1
STORAGE_ACCESS_KEY_ID=AKIA...
STORAGE_SECRET_ACCESS_KEY=...

BACKUP_ENCRYPTION_RECIPIENTS=age1...
HEALTHCHECK_URL=https://kuma.example.com/api/push/xxxx
```

```bash
# 3. Run
docker run -d --name bucket-arca --env-file .env ghcr.io/fvonoronha/bucket-arca:latest
docker logs bucket-arca                  # look for "Tudo certo." (all good)
docker exec bucket-arca arca backup      # first backup right now
```

Done: every day at 3 AM the mirror catches up with the bucket, and every Sunday at 4 AM an encrypted snapshot is made.

## How it works

```
s3://my-backups/
├── postgres-backups/                     ← pg-arca
└── bucket-backups/                       ← bucket-arca (STORAGE_PREFIX, created automatically)
    └── production/                       ← BACKUP_NAME
        ├── atual/                        ← mirror: 1:1 copy of the source ("current")
        ├── historico/<date>/             ← old versions of changed/deleted files ("history")
        └── snapshots/production_<date>.tar.zst.age
```

Two independent jobs, each with its own schedule: `MIRROR_SCHEDULE` (default daily 3 AM) and `SNAPSHOT_SCHEDULE` (default Sunday 4 AM). Set either to `off` to pick a strategy: mirror + history, mirror only (with S3 *Versioning*), snapshot only, or both (hybrid, the default).

## Commands

```bash
arca backup                     # run the enabled jobs now
arca mirror [--force]           # mirror now (--force: skip the safety brakes once)
arca snapshot                   # snapshot now
arca list [atual|historico|historico/<date>|snapshots]
arca versions <path>            # every kept copy of a file
arca restore <atual|historico/<date>|snapshot|snapshot/<file>> --to <origem|/folder> [--path <path>] [--yes]
arca verify [mirror|snapshot]   # does the copy match the source? does the snapshot open?
arca prune                      # apply retention (if not using bucket lifecycle rules)
arca check                      # check source, destination, key and schedules
```

`--to origem` restores back into the source bucket (requires `--yes` and a write-capable key passed only on that command). Restoring a snapshot needs the private key: `AGE_IDENTITY='AGE-SECRET-KEY-1...' arca restore snapshot --to /tmp/restore`.

## Retention and security in short

- **Retention** is done by **lifecycle rules** on the destination bucket: expire `bucket-backups/<name>/historico/` after 90 days and `snapshots/` after 91 (`GLACIER_IR` bills a 90-day minimum). **Never expire `atual/`**: the mirror doesn't re-upload unchanged files.
- **Source key: read only.** **Destination key:** can delete only inside `atual/`, so history and snapshots survive a leaked key. The full IAM policy is in the [Portuguese README](README.md#-segurança).
- **Two Kuma Push monitors**: `MIRROR_HEALTHCHECK_URL` (interval 25 h) and `SNAPSHOT_HEALTHCHECK_URL` (7 days + 2 h).

The full documentation (every variable, terminal operations, restore recipes, costs) is in the [Portuguese README](README.md).

## Image

`ghcr.io/fvonoronha/bucket-arca`, amd64 and arm64: `vX.Y.Z` (pinned, for production) and `latest`.

## Contributing

Issues and PRs are welcome, in English or Portuguese. See [CONTRIBUTING.md](CONTRIBUTING.md); every PR runs an end-to-end test you can run locally with `tests/integration.sh`. Security issues: [SECURITY.md](SECURITY.md).

MIT licensed. Built on [rclone](https://rclone.org), [age](https://age-encryption.org) and [zstd](https://facebook.github.io/zstd/).
