# bkdb

A tiny sidecar container that dumps a PostgreSQL, MariaDB or SQLite database to a file on a cron schedule and tells you on Telegram when something goes wrong.

It is meant to sit next to an app in its `docker-compose.yml`. Your file-level backup tool (restic, borg, kopia, …) then just picks up the dump directory — it never needs database credentials or access to the Docker socket.

## Features

- **Atomic writes** — dumps go to a temp file and are renamed on success. A failed run never overwrites the previous good dump.
- **Local rotation** — the last `KEEP` dumps (default 3) stay on disk, so you can roll back a day without touching your backup tool.
- **Verification** — PostgreSQL and MariaDB dumps must end with the tool's completion footer (so a truncated dump is never accepted); SQLite copies pass `PRAGMA integrity_check`.
- **Dedup-friendly output** — plain, uncompressed SQL with no timestamps in the body, so backup tools with deduplication store only what changed. SQLite is written to a fresh, compacted database file with `VACUUM INTO`; restoring is a file copy.
- **Telegram notifications** — on failure (default), on every run, or never.
- **Secrets from files** — `*_FILE` variants for Docker secrets.

## Build

```bash
docker build -t bkdb .                             # pg_dump 17
docker build --build-arg PG_MAJOR=16 -t bkdb:16 .
```

`pg_dump` must be the **same or newer** major version as the server — pg_dump 17 can dump servers 9.2–17. Check which `postgresqlNN-client` packages the Alpine base provides if you need another version.

## Configuration

### General

| Variable | Default | Description |
|---|---|---|
| `DB_TYPE` | — | `postgres`, `mariadb` or `sqlite` (required) |
| `NAME` | `$DB_TYPE` | Output file name: `/backup/$NAME.sql` or `/backup/$NAME.sqlite3` |
| `SCHEDULE` | `0 3 * * *` | Crontab expression, evaluated in `TZ`; `@daily` etc. also work |
| `TZ` | `UTC` | e.g. `Europe/Berlin` |
| `RUN_ON_START` | `false` | Also dump once right after the container starts |
| `KEEP` | `3` | Number of dumps kept on disk, including the latest (see [Rotation](#rotation)) |
| `EXTRA_OPTS` | — | Extra options for `pg_dump` / `pg_dumpall` / `mariadb-dump`, space-separated |
| `UMASK` | `022` | Permissions of created dump files |

### PostgreSQL

Standard libpq variables: `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` (or `PGPASSWORD_FILE`).

| Variable | Description |
|---|---|
| `PG_DB` | If set, dump only this database with `pg_dump` (no roles). Otherwise the whole cluster, including roles, with `pg_dumpall`. |

### MariaDB

| Variable | Default | Description |
|---|---|---|
| `MARIADB_HOST` | — | required |
| `MARIADB_PORT` | `3306` | |
| `MARIADB_USER` | — | required |
| `MARIADB_PASSWORD` / `MARIADB_PASSWORD_FILE` | — | passed to `mariadb-dump` via a private option file, never on the command line |
| `MARIADB_DB` | — | If set, dump only this database. Otherwise `--all-databases`. |

Dumps use `--single-transaction --routines --events --triggers`, so InnoDB tables are consistent without locking.

The bundled client is MariaDB 11.x, which requires TLS by default. If the server has no TLS configured, the dump fails with *"SSL is required, but the server does not support it"* — set `EXTRA_OPTS=--skip-ssl` (fine inside a private Docker network).

### SQLite

| Variable | Description |
|---|---|
| `SQLITE_PATH` | Path to the database file inside the container (required) |

The copy is made with `VACUUM INTO`: a consistent snapshot even while the app is writing, compacted (free pages dropped) and in rollback-journal mode, so it is a self-contained single file.

Mount the app's data directory **read-write**: in WAL mode a reader needs access to the `-shm` file.

### Notifications

| Variable | Default | Description |
|---|---|---|
| `TG_BOT_TOKEN` / `TG_BOT_TOKEN_FILE` | — | Bot token; no token = no notifications |
| `TG_CHAT_ID` | — | Chat to send to |
| `NOTIFY` | `failure` | `failure`, `always` or `never` |
| `HOST_LABEL` | container hostname | Prefix in messages, e.g. `homeserver/immich` |

Failure messages include the last part of the tool's error output.

## Rotation

The latest dump always has the plain name; older ones get a numeric suffix, logrotate-style. With `KEEP=3`:

```
immich.sql      # latest
immich.sql.1    # previous run
immich.sql.2    # the one before
```

On each successful run the files shift by one and the oldest is deleted. `immich.sql` never disappears, even mid-rotation, so a backup job running at the same moment always sees a complete file. Failed runs don't rotate anything. `KEEP=1` keeps only the latest dump.

Renamed files cost nothing extra in deduplicating backup tools — only disk space on the host.

## Scheduling

Scheduling is done by [supercronic](https://github.com/aptible/supercronic): the container's environment is passed to every run, a run is skipped if the previous one is still going, and `docker stop` waits for a running dump to finish (raise `stop_grace_period` for large databases). Run output goes to `docker logs`.

All output lands in `/backup` inside the container — mount a host directory or volume there.

## Commands

| Command | |
|---|---|
| `cron` (default) | Run on `SCHEDULE` until stopped |
| `once` | Dump once and exit: `0` ok, `1` dump failed, `2` configuration error |

Manual run: `docker compose run --rm db-dump once`

## Examples

Shared notification settings in one file, e.g. `/opt/bkdb/common.env`:

```env
TG_BOT_TOKEN=123456:ABC...
TG_CHAT_ID=123456789
HOST_LABEL=homeserver
TZ=Europe/Berlin
```

### PostgreSQL — Immich

Variable names match Immich's standard `.env`.

```yaml
  db-dump:
    image: bkdb
    restart: unless-stopped
    depends_on: [database]
    env_file: /opt/bkdb/common.env
    environment:
      DB_TYPE: postgres
      NAME: immich
      PGHOST: database
      PGUSER: ${DB_USERNAME}
      PGPASSWORD: ${DB_PASSWORD}
      SCHEDULE: "30 2 * * *"
    volumes:
      - /srv/backup/immich:/backup
```

### MariaDB

```yaml
  db-dump:
    image: bkdb
    restart: unless-stopped
    depends_on: [db]
    env_file: /opt/bkdb/common.env
    environment:
      DB_TYPE: mariadb
      NAME: app
      MARIADB_HOST: db
      MARIADB_USER: root
      MARIADB_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      SCHEDULE: "30 2 * * *"
    volumes:
      - /srv/backup/app:/backup
```

Dumping all databases needs a user with global read privileges (root is simplest). For a single database, set `MARIADB_DB` and use the app's own user.

### SQLite — Vaultwarden

```yaml
  db-dump:
    image: bkdb
    restart: unless-stopped
    env_file: /opt/bkdb/common.env
    environment:
      DB_TYPE: sqlite
      NAME: vaultwarden
      SQLITE_PATH: /data/db.sqlite3
      SCHEDULE: "30 2 * * *"
    volumes:
      - ./vw-data:/data
      - /srv/backup/vaultwarden:/backup
```

For Vaultwarden, also back up `attachments/`, `sends/`, `rsa_key*` and `config.json` from the data directory.

## Monitoring freshness

If the sidecar dies or hangs, the dump file simply stops changing. Have your backup job refuse to run when a dump is older than a day:

```sh
! find /srv/backup \( -name '*.sql' -o -name '*.sqlite3' \) -mmin +1500 | grep .
```

The command exits non-zero and prints the stale files if any are found. Rotated copies (`*.sql.1`, …) don't match the patterns, so only the latest dumps are checked.

## Restore

**PostgreSQL** — restore into a container running the **same image** as production (for Immich this is mandatory because of its vector extensions):

```bash
docker compose stop immich-server
docker exec -i immich_postgres psql -U postgres < /srv/backup/immich/immich.sql
```

Immich's restore guide additionally rewrites `search_path`:

```bash
sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" immich.sql \
  | docker exec -i immich_postgres psql -U postgres
```

If pg_dump is newer than the server, you may see harmless errors such as `unrecognized configuration parameter "transaction_timeout"`; psql continues past them.

**MariaDB**:

```bash
docker exec -i app_db sh -c 'mariadb -u root -p"$MYSQL_ROOT_PASSWORD"' < /srv/backup/app/app.sql
```

**SQLite** — stop the app and put the file back:

```bash
docker compose stop vaultwarden
cp /srv/backup/vaultwarden/vaultwarden.sqlite3 vw-data/db.sqlite3
rm -f vw-data/db.sqlite3-wal vw-data/db.sqlite3-shm
docker compose start vaultwarden
```

Test a restore at least once — a backup you've never restored from is a hope, not a backup.