#!/usr/bin/env bash
# Integration tests: builds the image, starts the database servers from
# compose.yml and runs bkdb against them — dumps, restore round-trips,
# rotation, failures, config errors and the cron mode.
#
# Usage: test/run.sh   (needs docker with the compose plugin)
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=bkdb:test
NET=bkdb-test   # network name from compose.yml
PG_PW=secret
MARIA_PW=" p#a\\ss\"w'd "   # must match init/mariadb.sql

compose() { docker compose -f compose.yml "$@"; }

WORK=$(mktemp -d)
cleanup() {
  docker rm -f bkdb-test-cron bkdb-test-start >/dev/null 2>&1 || true
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  # Dumps are written by root in the container; delete them the same way.
  docker run --rm -v "$WORK:/w" "$IMAGE" find /w -mindepth 1 -delete >/dev/null 2>&1 || true
  rmdir "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# --- harness --------------------------------------------------------------------
PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok    $*"; }
fail() {
  FAIL=$((FAIL + 1)); echo "  FAIL  $*"
  if [[ -s $WORK/log ]]; then sed 's/^/        | /' "$WORK/log"; fi
}
check() { local d=$1; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
section() { echo; echo "== $*"; }

# bkdb OUT [docker-run options...] -- CMD... : run the image with OUT as /backup.
# Output goes to $WORK/log; returns the container's exit code.
# api.telegram.org points to localhost, so notifications fail fast and offline.
bkdb() {
  local out=$1 opts=()
  shift
  while [[ $1 != -- ]]; do opts+=("$1"); shift; done
  shift
  mkdir -p "$out"
  docker run --rm --network "$NET" --add-host api.telegram.org:127.0.0.1 \
    -v "$out:/backup" "${opts[@]}" "$IMAGE" "$@" >"$WORK/log" 2>&1
}

# expect CODE DESC bkdb-args... : run bkdb and check its exit code.
expect() {
  local code=$1 d=$2 rc=0
  shift 2
  bkdb "$@" || rc=$?
  if (( rc == code )); then ok "$d"; else fail "$d (exit $rc, want $code)"; fi
}

log_has()  { grep -q -- "$1" "$WORK/log"; }
no_tmp()   { ! compgen -G "$1/.*.tmp" >/dev/null; }
has_footer() { tail -n 5 "$1" | grep -q -- "$2"; }
eq() { [[ $1 == "$2" ]] || { echo "        got '$1', want '$2'"; return 1; }; }

# sq DIR SQL : query DIR/vw.sqlite3 (or another file via SQ_FILE) using the image's sqlite3.
sq() { docker run --rm -v "$1:/d" "$IMAGE" sqlite3 "/d/${SQ_FILE:-vw.sqlite3}" "$2"; }

wait_for() {
  local secs=$1 i
  shift
  for (( i = 0; i < secs; i++ )); do "$@" && return 0; sleep 1; done
  return 1
}

# --- setup ----------------------------------------------------------------------
echo "building $IMAGE"
docker build -q -t "$IMAGE" .. >/dev/null
echo "starting database servers"
compose up -d --wait --quiet-pull >/dev/null 2>&1 || { compose ps; compose logs --tail 30; exit 1; }

printf '%s' "$PG_PW" >"$WORK/pg_pw"
printf '%s' "$MARIA_PW" >"$WORK/maria_pw"
chmod 644 "$WORK/pg_pw" "$WORK/maria_pw"

PG=(-e DB_TYPE=postgres -e PGHOST=pg -e PGUSER=postgres)
MARIA=(-e DB_TYPE=mariadb -e MARIADB_HOST=maria)

# --- general ----------------------------------------------------------------------
section general
expect 0 "non-bkdb command passes through without config" "$WORK/x" -- true

# --- postgres ---------------------------------------------------------------------
section postgres
out=$WORK/pg
expect 0 "pg_dumpall: exit 0" "$out" "${PG[@]}" -e NAME=cluster -e PGPASSWORD=$PG_PW -- once
check "pg_dumpall: completion footer" has_footer "$out/cluster.sql" 'cluster dump complete'
compose exec -T pg-restore psql -U postgres -q -o /dev/null <"$out/cluster.sql" >/dev/null 2>&1 || true
check "pg_dumpall: restored data" eq "$(compose exec -T pg-restore psql -U postgres -d app -tAc 'SELECT x FROM t')" 42
check "pg_dumpall: restored role" eq "$(compose exec -T pg-restore psql -U postgres -tAc "SELECT count(*) FROM pg_roles WHERE rolname = 'approle'")" 1

expect 0 "PG_DB + PGPASSWORD_FILE: exit 0" "$out" "${PG[@]}" -e NAME=app -e PG_DB=app \
  -e PGPASSWORD_FILE=/run/pw -v "$WORK/pg_pw:/run/pw:ro" -- once
check "PG_DB: completion footer" has_footer "$out/app.sql" 'PostgreSQL database dump complete'
compose exec -T pg-restore createdb -U postgres single
compose exec -T pg-restore psql -U postgres -d single -q -o /dev/null <"$out/app.sql" >/dev/null 2>&1 || true
check "PG_DB: restored data" eq "$(compose exec -T pg-restore psql -U postgres -d single -tAc 'SELECT x FROM t')" 42

sum=$(sha256sum "$out/cluster.sql")
expect 1 "wrong password: exit 1" "$out" "${PG[@]}" -e NAME=cluster -e PGPASSWORD=wrong -- once
check "wrong password: error reported" log_has 'password authentication failed'
check "wrong password: previous dump kept" eq "$(sha256sum "$out/cluster.sql")" "$sum"
check "wrong password: no rotation" eq "$(ls "$out")" "$(printf 'app.sql\ncluster.sql')"
check "wrong password: no temp file" no_tmp "$out"

expect 1 "unreachable server: exit 1" "$out" "${PG[@]}" -e NAME=cluster -e PGHOST=nowhere \
  -e PGCONNECT_TIMEOUT=3 -e PGPASSWORD=$PG_PW -- once
check "unreachable server: previous dump kept" eq "$(sha256sum "$out/cluster.sql")" "$sum"

# --- mariadb ----------------------------------------------------------------------
section mariadb
out=$WORK/maria
maria_q() { compose exec -T maria-restore mariadb -uroot -proot -N -e "$1"; }

expect 0 "all databases: exit 0" "$out" "${MARIA[@]}" -e NAME=all -e MARIADB_USER=root \
  -e MARIADB_PASSWORD=root -- once
check "all databases: completion footer" has_footer "$out/all.sql" '^-- Dump completed'
compose exec -T maria-restore mariadb -uroot -proot <"$out/all.sql"
check "all databases: restored data" eq "$(maria_q 'SELECT x FROM app.t')" 42

expect 0 "MARIADB_DB, tricky password from file: exit 0" "$out" "${MARIA[@]}" -e NAME=app \
  -e MARIADB_USER=u -e MARIADB_DB=app -e MARIADB_PASSWORD_FILE=/run/pw \
  -v "$WORK/maria_pw:/run/pw:ro" -- once
maria_q 'DROP DATABASE app'
compose exec -T maria-restore mariadb -uroot -proot <"$out/app.sql"
check "MARIADB_DB: restored data" eq "$(maria_q 'SELECT x FROM app.t')" 42

expect 1 "wrong password: exit 1" "$out" "${MARIA[@]}" -e NAME=app -e MARIADB_USER=u \
  -e MARIADB_DB=app -e 'MARIADB_PASSWORD= p' -- once
check "wrong password: error reported" log_has 'Access denied'
check "wrong password: no temp file" no_tmp "$out"

# --- sqlite + rotation --------------------------------------------------------------
section "sqlite + rotation"
data=$WORK/sqlite-data out=$WORK/sqlite
mkdir -p "$data"
SQLITE=(-e DB_TYPE=sqlite -e NAME=vw -e SQLITE_PATH=/data/db.sqlite3 -v "$data:/data")
SQ_FILE=db.sqlite3 sq "$data" 'PRAGMA journal_mode = WAL; CREATE TABLE t (x int); INSERT INTO t VALUES (1);' >/dev/null

for i in 1 2 3 4; do
  if (( i > 1 )); then SQ_FILE=db.sqlite3 sq "$data" "INSERT INTO t VALUES ($i)"; fi
  expect 0 "run $i (KEEP=3): exit 0" "$out" "${SQLITE[@]}" -- once
done
check "KEEP=3: three files" eq "$(ls "$out")" "$(printf 'vw.sqlite3\nvw.sqlite3.1\nvw.sqlite3.2')"
check "latest is newest"   eq "$(sq "$out" 'SELECT max(x) FROM t')" 4
check ".1 is previous"     eq "$(SQ_FILE=vw.sqlite3.1 sq "$out" 'SELECT max(x) FROM t')" 3
check ".2 is the one before" eq "$(SQ_FILE=vw.sqlite3.2 sq "$out" 'SELECT max(x) FROM t')" 2
check "copy is not in WAL mode" eq "$(sq "$out" 'PRAGMA journal_mode')" delete

SQ_FILE=db.sqlite3 sq "$data" 'INSERT INTO t VALUES (5)'
expect 0 "KEEP=1: exit 0" "$out" "${SQLITE[@]}" -e KEEP=1 -- once
check "KEEP=1: only latest left" eq "$(ls "$out")" vw.sqlite3
check "KEEP=1: latest is newest" eq "$(sq "$out" 'SELECT max(x) FROM t')" 5

SQ_FILE=db.sqlite3 sq "$data" 'INSERT INTO t VALUES (6)'
expect 0 "back to KEEP=3: exit 0" "$out" "${SQLITE[@]}" -- once
check "back to KEEP=3: two files" eq "$(ls "$out")" "$(printf 'vw.sqlite3\nvw.sqlite3.1')"

bad=$WORK/sqlite-bad
mkdir -p "$bad"
echo "not a database" >"$bad/db.sqlite3"
sum=$(sha256sum "$out/vw.sqlite3")
expect 1 "corrupt database: exit 1" "$out" "${SQLITE[@]/"$data"/"$bad"}" -- once
check "corrupt database: previous dump kept" eq "$(sha256sum "$out/vw.sqlite3")" "$sum"
check "corrupt database: no rotation" eq "$(ls "$out")" "$(printf 'vw.sqlite3\nvw.sqlite3.1')"
check "corrupt database: no temp file" no_tmp "$out"

expect 0 "telegram unreachable: run still ok" "$out" "${SQLITE[@]}" -e NOTIFY=always \
  -e TG_BOT_TOKEN=123:abc -e TG_CHAT_ID=1 -- once
check "telegram unreachable: warning logged" log_has 'warning: telegram notification failed'

# --- config errors -------------------------------------------------------------------
section "config errors (exit 2)"
out=$WORK/cfg
expect 2 "DB_TYPE missing" "$out" -- once
expect 2 "DB_TYPE unknown" "$out" -e DB_TYPE=oracle -- once
expect 2 "KEEP=0" "$out" "${SQLITE[@]}" -e KEEP=0 -- once
expect 2 "NAME with a slash" "$out" "${SQLITE[@]}" -e NAME=a/b -- once
expect 2 "NOTIFY unknown" "$out" "${SQLITE[@]}" -e NOTIFY=sometimes -- once
expect 2 "mariadb without host" "$out" -e DB_TYPE=mariadb -e MARIADB_USER=u -- once
expect 2 "sqlite file missing" "$out" -e DB_TYPE=sqlite -e SQLITE_PATH=/nope.sqlite3 -- once
expect 2 "unreadable *_FILE" "$out" "${PG[@]}" -e PGPASSWORD_FILE=/nope -- once
expect 2 "invalid SCHEDULE" "$out" "${SQLITE[@]}" -e 'SCHEDULE=61 * * * *' -- cron
check "nothing written" eq "$(ls -A "$out")" ""

# --- cron mode -----------------------------------------------------------------------
section "cron mode (supercronic)"
out=$WORK/cron
mkdir -p "$out"
ok_runs() { (( $(docker logs "$1" 2>&1 | grep -c '] ok: ') >= $2 )); }

# 7-field expression = every 2 seconds; jobs only succeed if the env reaches them.
docker run -d --name bkdb-test-cron --network "$NET" -v "$out:/backup" "${SQLITE[@]}" \
  -e NAME=cron -e 'SCHEDULE=*/2 * * * * * *' "$IMAGE" >/dev/null
check "scheduled runs succeed repeatedly" wait_for 30 ok_runs bkdb-test-cron 2
docker stop -t 30 bkdb-test-cron >/dev/null
check "docker stop: exit code 0" eq "$(docker inspect -f '{{.State.ExitCode}}' bkdb-test-cron)" 0
check "dump file written" test -s "$out/cron.sqlite3"

docker run -d --name bkdb-test-start --network "$NET" -v "$out:/backup" "${SQLITE[@]}" \
  -e NAME=start -e SCHEDULE=@yearly -e RUN_ON_START=true "$IMAGE" >/dev/null
check "RUN_ON_START dumps immediately" wait_for 20 test -s "$out/start.sqlite3"
docker stop -t 30 bkdb-test-start >/dev/null

# --- summary -----------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
