#!/usr/bin/env bash
# bkdb.sh — sidecar for dumping PostgreSQL / MariaDB / SQLite databases to files,
# with optional Telegram notifications.
#
# Usage: bkdb.sh [cron|once]   (default: cron)
#        bkdb.sh <command...>  runs the command as is, without config checks
set -euo pipefail

# Anything other than our own commands is passed through (e.g. `sh` for debugging).
case "${1:-cron}" in
  cron|once) ;;
  *)         exec "$@" ;;
esac

log() { echo "[$(date -Iseconds)] $*"; }
die() { log "config error: $*"; exit 2; }

# --- secrets from files (docker secrets) -----------------------------------
for v in PGPASSWORD MARIADB_PASSWORD TG_BOT_TOKEN; do
  f="${v}_FILE"
  if [[ -n "${!f:-}" ]]; then
    [[ -r "${!f}" ]] || die "$f=${!f} is not readable"
    export "$v"="$(<"${!f}")"
  fi
done

# --- config -----------------------------------------------------------------
DB_TYPE=${DB_TYPE:-}
readonly OUT_DIR=/backup
SCHEDULE=${SCHEDULE:-0 3 * * *}      # crontab expression, evaluated in $TZ
RUN_ON_START=${RUN_ON_START:-false}
NOTIFY=${NOTIFY:-failure}            # failure | always | never
HOST_LABEL=${HOST_LABEL:-$(hostname)}
# Extra CLI options for pg_dump/pg_dumpall/mariadb-dump, word-split on spaces.
read -r -a EXTRA <<<"${EXTRA_OPTS:-}"
umask "${UMASK:-022}"

case $DB_TYPE in
  postgres) EXT=sql ;;
  mariadb)  EXT=sql
            [[ -n "${MARIADB_HOST:-}" ]] || die "MARIADB_HOST is required for mariadb"
            [[ -n "${MARIADB_USER:-}" ]] || die "MARIADB_USER is required for mariadb" ;;
  sqlite)   EXT=sqlite3
            [[ -n "${SQLITE_PATH:-}" ]] || die "SQLITE_PATH is required for sqlite"
            [[ -f "$SQLITE_PATH" ]]    || die "SQLITE_PATH=$SQLITE_PATH not found" ;;
  *)        die "DB_TYPE must be 'postgres', 'mariadb' or 'sqlite'" ;;
esac
case $NOTIFY in failure|always|never) ;; *) die "NOTIFY must be failure|always|never" ;; esac
KEEP=${KEEP:-3}                      # dumps kept on disk, including the latest
[[ $KEEP =~ ^[1-9][0-9]*$ ]] || die "KEEP must be a positive integer"

NAME=${NAME:-$DB_TYPE}
[[ $NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "NAME may contain only [A-Za-z0-9._-]"
[[ -d $OUT_DIR && -w $OUT_DIR ]] || die "$OUT_DIR must be a writable directory (mount a volume there)"

# --- telegram -----------------------------------------------------------------
notify() {
  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || return 0
  curl -fsS --max-time 15 -o /dev/null \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    || log "warning: telegram notification failed"
}

# --- dumpers ------------------------------------------------------------------
# Each dumper writes to $1 and must return non-zero on any failure.
# (Explicit && chains: `set -e` is disabled inside functions called from `if`.)

# check_footer FILE LINES PATTERN — a dump that exits 0 but lacks the tool's
# completion footer is truncated; say so, since the tool printed nothing.
check_footer() {
  tail -n "$2" "$1" | grep -q "$3" ||
    { echo "dump is incomplete: completion footer '$3' not found" >&2; return 1; }
}

dump_postgres() {
  local tmp=$1
  if [[ -n "${PG_DB:-}" ]]; then
    pg_dump --clean --if-exists "${EXTRA[@]}" -d "$PG_DB" >"$tmp" &&
      check_footer "$tmp" 5 'PostgreSQL database dump complete'
  else
    pg_dumpall --clean --if-exists "${EXTRA[@]}" >"$tmp" &&
      check_footer "$tmp" 5 'PostgreSQL database cluster dump complete'
  fi
}

# Option-file value: quoted so '#' isn't a comment and edge spaces survive;
# backslash, double quote and newline escaped (MariaDB unescapes them).
cnf_value() {
  local v=${1//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//$'\n'/\\n}
  printf '"%s"' "$v"
}

dump_mariadb() {
  local tmp=$1 cnf rc
  # Password goes through a private option file, not argv or environment.
  cnf=$(mktemp) || return 1
  chmod 600 "$cnf"
  {
    echo "[client]"
    echo "host=$(cnf_value "$MARIADB_HOST")"
    echo "port=$(cnf_value "${MARIADB_PORT:-3306}")"
    echo "user=$(cnf_value "$MARIADB_USER")"
    if [[ -n "${MARIADB_PASSWORD:-}" ]]; then echo "password=$(cnf_value "$MARIADB_PASSWORD")"; fi
  } >"$cnf"

  local target=(--all-databases)
  if [[ -n "${MARIADB_DB:-}" ]]; then target=(--databases "$MARIADB_DB"); fi

  mariadb-dump --defaults-extra-file="$cnf" \
      --single-transaction --routines --events --triggers \
      --skip-dump-date "${EXTRA[@]}" "${target[@]}" >"$tmp" &&
    check_footer "$tmp" 3 '^-- Dump completed'
  rc=$?
  rm -f "$cnf"
  return $rc
}

dump_sqlite() {
  local tmp=$1 check
  # VACUUM INTO writes a consistent, compacted copy; the target must not exist.
  rm -f "$tmp" || return 1
  sqlite3 "$SQLITE_PATH" ".timeout 30000" "VACUUM INTO '$tmp';" || return 1
  [[ -s "$tmp" ]] || { echo "VACUUM INTO produced an empty file" >&2; return 1; }
  check=$(sqlite3 "$tmp" 'PRAGMA integrity_check;') || return 1
  [[ $check == ok ]] || { echo "integrity_check: $check" >&2; return 1; }
}

# --- rotation ----------------------------------------------------------------
# Latest dump is always $out; older ones are $out.1 (newest) .. $out.$((KEEP-1)).
# $out never disappears: it is hard-linked to $out.1, then atomically replaced.
publish() {
  local tmp=$1 out=$2 f n i
  for f in "$out".*; do
    [[ -e $f ]] || continue
    n=${f##*.}
    [[ $n =~ ^[0-9]+$ ]] || continue
    (( n < KEEP - 1 )) || rm -f "$f"
  done
  for (( i = KEEP - 2; i >= 1; i-- )); do
    if [[ -e "$out.$i" ]]; then mv -f "$out.$i" "$out.$((i + 1))"; fi
  done
  if (( KEEP > 1 )) && [[ -e $out ]]; then ln -f "$out" "$out.1"; fi
  mv -f "$tmp" "$out"
}

# --- one run -----------------------------------------------------------------
run_once() {
  local out="$OUT_DIR/$NAME.$EXT" tmp="$OUT_DIR/.$NAME.$EXT.tmp"
  local err start size msg
  err=$(mktemp)
  start=$(date +%s)
  log "dumping $NAME ($DB_TYPE)"

  if "dump_$DB_TYPE" "$tmp" 2>"$err"; then
    publish "$tmp" "$out"
    size=$(du -h "$out" | cut -f1)
    log "ok: $out ($size, $(( $(date +%s) - start ))s)"
    if [[ $NOTIFY == always ]]; then notify "✅ $HOST_LABEL/$NAME: dump ok, $size"; fi
    rm -f "$err"
    return 0
  fi

  rm -f "$tmp"
  msg=$(tail -c 1500 "$err")
  rm -f "$err"
  log "FAILED: ${msg:-unknown error}"
  if [[ $NOTIFY != never ]]; then
    notify "❌ $HOST_LABEL/$NAME: dump failed, keeping previous dump
${msg:-unknown error}"
  fi
  return 1
}

# --- main ----------------------------------------------------------------------
if [[ ${1:-cron} == once ]]; then run_once; exit; fi

self=$(readlink -f "$0")
crontab=$(mktemp)
printf '%s %q once\n' "$SCHEDULE" "$self" >"$crontab"
supercronic -test "$crontab" >/dev/null 2>&1 || die "SCHEDULE='$SCHEDULE' is not a valid cron expression"

log "started: $NAME ($DB_TYPE), schedule '$SCHEDULE' ${TZ:-UTC}, keep $KEEP -> $OUT_DIR/$NAME.$EXT"
if [[ $RUN_ON_START == true ]]; then run_once || true; fi

# supercronic: passes our environment to jobs, never runs a job twice in
# parallel, and on SIGTERM waits for a running dump before exiting.
# Full path: as PID 1 it re-executes itself via argv[0] to reap zombies, and a
# bare "supercronic" there fails with "fork exec: no such file or directory".
exec "$(command -v supercronic)" -passthrough-logs "$crontab"