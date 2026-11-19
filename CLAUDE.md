# bkdb

Sidecar container that dumps one PostgreSQL / MariaDB / SQLite database to `/backup` on a cron schedule, keeps the last `KEEP` dumps, and notifies via Telegram. A separate file-level backup tool (restic etc.) picks up the dump directory — bkdb never deals with backup repos, and the backup tool never needs DB credentials or the Docker socket. That separation is the reason this project exists; don't erode it.

The owner (Art) talks to you in Russian. Code, comments, README and commit messages are in English.

## Files

- `bkdb.sh` — the whole program (bash). Installed as `/usr/local/bin/bkdb.sh`.
- `Dockerfile` — Alpine 3.24 + bash, coreutils, curl, tzdata, supercronic, sqlite, mariadb-client (11.8), `postgresql${PG_MAJOR}-client` (build arg, default 18 — the newest the base offers; bump base and default together).
- `.github/workflows/ci.yml` — on PRs and pushes: shellcheck + `test/run.sh` against Postgres 16 and 18; on push to `main` after tests: multi-arch (amd64 + arm64, via QEMU) build pushed to `ghcr.io/artss/bkdb:latest`. Only `:latest` is published — no per-PG-major tags (Art's decision).
- `README.md` — user-facing docs. Keep it in sync with every behaviour/env change.

## How it works

- `bkdb cron` (default CMD): validates config, optionally runs once (`RUN_ON_START`), writes a one-line crontab `"$SCHEDULE" bkdb once` and `exec`s `supercronic -passthrough-logs`. Supercronic passes env to jobs, skips overlapping runs, waits for a running job on SIGTERM.
- `bkdb once`: one dump. Exit codes: `0` ok, `1` dump failed, `2` config error.
- Each run: dump to hidden temp `/backup/.NAME.EXT.tmp` → verify → `publish()` rotation → notify.
- Rotation (logrotate-style): latest is always `NAME.EXT`, older are `NAME.EXT.1` … `NAME.EXT.(KEEP-1)`. `NAME.EXT` must never be missing, even mid-rotation: it is hard-linked to `.1`, then atomically replaced with `mv`. Failed runs rotate nothing. Extra files beyond `KEEP` are deleted (handles lowering `KEEP`).

## Design decisions (deliberate — don't "fix" without asking)

- **Plain uncompressed SQL** for Postgres/MariaDB, no dates in the body (`--skip-dump-date`): the downstream backup tool deduplicates. Never add gzip or `-Fc`.
- **Verification by footer**: Postgres dump must end with `PostgreSQL database [cluster ]dump complete`, MariaDB with `-- Dump completed`. This catches truncated dumps that exit 0.
- **SQLite via `VACUUM INTO`** (not `.backup`, not file copy): consistent, compacted, non-WAL standalone file; then `PRAGMA integrity_check` on the copy.
- **Postgres**: `pg_dumpall` by default (includes roles), `pg_dump -d $PG_DB` if set. Connection only via standard libpq env (`PGHOST`, `PGUSER`, `PGPASSWORD`…). pg_dump must be ≥ server major → `PG_MAJOR` build arg.
- **MariaDB**: password goes into a `mktemp` option file (mode 600, removed after) passed with `--defaults-extra-file` — never argv or `MYSQL_PWD`. Values are double-quoted and escaped (`cnf_value`): unquoted, `#` starts a comment and edge spaces are stripped. `--single-transaction --routines --events --triggers`. Client 11.x requires TLS by default; users set `EXTRA_OPTS=--skip-ssl` for non-TLS servers.
- **Secrets**: `PGPASSWORD_FILE`, `MARIADB_PASSWORD_FILE`, `TG_BOT_TOKEN_FILE` supported.
- **Output dir is hardcoded `/backup`**, not configurable — it's internal to the container.
- **Telegram failures never fail the run** (logged as warning). `NOTIFY=failure|always|never`.
- **Scheduling via supercronic**, not busybox crond (crond drops the environment).

## Bash conventions

- `set -euo pipefail`, must pass `shellcheck` with no warnings.
- `set -e` is **disabled inside functions called from `if`** — dumpers (`dump_<type>`) are called that way, so every step in them needs explicit `|| return 1` / `&&`. Don't rely on errexit there.
- A new DB type = a `dump_<type>` function writing to `$1` and returning non-zero on any failure, plus a `case` entry in config validation (extension + required vars), README section, CLAUDE.md line.
- Config errors → `die` (exit 2) at startup, before anything runs.

## Testing

`test/run.sh` (≈75 s, needs only Docker with compose) builds the image as `bkdb:test`, starts `test/compose.yml` — `pg` (postgres:`$PG_VERSION`, default 16 — older than the bundled pg_dump, like real setups; CI also runs 18) and `maria` (mariadb:11) seeded from `test/init/`, plus empty `pg-restore` / `maria-restore` — and runs the real container against them:
- dump + restore round-trip: `pg_dumpall` (data + roles), `PG_DB`, MariaDB all databases and `MARIADB_DB`; `*_FILE` secrets; MariaDB password ` p#a\ss"w'd `
- failures (wrong password, unreachable server, corrupt SQLite) → exit 1, previous dump byte-identical, no rotation, no temp file
- rotation: KEEP=3, shrink to 1, grow back; SQLite copy integrity and non-WAL mode
- Telegram unreachable (`api.telegram.org` mapped to localhost) → warning only, exit 0
- config errors → exit 2, nothing written; passthrough of other commands
- cron mode as PID 1: a 7-field `SCHEDULE` (every 2 s) proves jobs run repeatedly with the env, `docker stop` exits 0; `RUN_ON_START`

Not covered: `docker stop` waiting for a long-running dump, actual Telegram delivery.

Every behaviour change gets a test there. Before committing: `docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:stable /mnt/bkdb.sh /mnt/test/run.sh` and `test/run.sh`.

## Roadmap

- Optional ideas, not requested yet: healthcheck based on last successful run; versioned or `sha-` tags for pinning.

## Context

Used on Art's home server next to Immich (Postgres), Firefly III (Postgres) and Vaultwarden (SQLite), with restic picking up the dumps. Downstream backup tool checks freshness with `find /srv/backup \( -name '*.sql' -o -name '*.sqlite3' \) -mmin +1500` — rotated `*.sql.1` files intentionally don't match that pattern; keep the naming scheme compatible.