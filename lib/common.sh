#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/common.sh - shared helpers for the demo scripts (source it, don't run it)
#
#   banner / step / note   presentation helpers
#   run  'shell command'   show the command, wait for ENTER, then execute it
#   ch   'SQL'             show the SQL, wait for ENTER, run it in clickhouse-client
#   pgq  'SQL'             same for psql (temporary PostgreSQL of demo 2)
#   ch_* / pg_* / pkg_*    quiet maintenance helpers (start, stop, cleanup, ...)
# -----------------------------------------------------------------------------

if [ -n "${_DEMO_COMMON_LOADED:-}" ]; then return 0; fi
_DEMO_COMMON_LOADED=1

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- configuration: override in ./config.env or in the environment ----------
if [ -f "$DEMO_ROOT/config.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$DEMO_ROOT/config.env"
  set +a
fi
: "${WORKDIR:=$HOME/clickhouse-demo}"      # everything the demos create lives here
: "${CH_DIR:=$WORKDIR/clickhouse}"         # ClickHouse binary + data (server cwd)
: "${PG_DIR:=$WORKDIR/postgres}"           # temporary PostgreSQL instance (demo 2)
: "${CH_HTTP_PORT:=8123}"
: "${CH_TCP_PORT:=9000}"
: "${PG_PORT:=5433}"                       # not 5432: never collide with a real PG
: "${PG_DB:=shop}"
: "${PG_RO_USER:=ro_user}"
: "${PG_RO_PASSWORD:=secret}"              # demo only!
: "${ROWS_CH:=2000000}"                    # bulk rows ingested in demo 1
: "${ROWS_PG:=1000000}"                    # rows seeded into PostgreSQL (demo 2, 3)
: "${DEMO_AUTO:=0}"                        # 1 = no pauses (also: -y / --auto)
: "${AUTO_DELAY:=0}"                       # seconds to sleep between steps in auto mode
: "${KEEP_BINARY:=0}"                      # 1 = keep the downloaded ClickHouse binary on cleanup

CH_BIN="$CH_DIR/clickhouse"
CH_CLIENT_ARGS=(--host 127.0.0.1 --port "$CH_TCP_PORT")   # demo 3 replaces this

# ---- colors -----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; MAG=$'\033[35m'; CYN=$'\033[36m'
else
  RST=''; BOLD=''; DIM=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''
fi

STEP_NO=0

# ---- presentation -----------------------------------------------------------
banner() {
  printf '\n%s%s' "$BOLD" "$MAG"
  printf '=%.0s' $(seq 1 72); printf '\n'
  printf '  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '  %s%s%s\n' "$RST$DIM" "$2" "$BOLD$MAG"; fi
  printf '=%.0s' $(seq 1 72)
  printf '%s\n\n' "$RST"
}
step() {   # step "title"
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s%s-- Step %d: %s --%s\n' "$BOLD" "$BLU" "$STEP_NO" "$1" "$RST"
}
note() {   # note "talking point" ...   (grey, one line per argument)
  local l
  for l in "$@"; do printf '%s   %s%s\n' "$DIM" "$l" "$RST"; done
}
info() { printf '%s%s%s\n' "$GRN" "$*" "$RST"; }
warn() { printf '%s%s%s\n' "$YEL" "$*" "$RST" >&2; }
die()  { printf '%sERROR: %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

# ---- pausing ----------------------------------------------------------------
# Returns 0 = go on and execute, 1 = skip this step.
# Keys: ENTER = run, s = skip, c = run the rest without pauses, q = quit.
wait_key() {
  if [ "$DEMO_AUTO" = 1 ]; then
    if [ "$AUTO_DELAY" != 0 ]; then sleep "$AUTO_DELAY"; fi
    return 0
  fi
  local k=''
  printf '%s   [ENTER] run   [s] skip   [c] run the rest without pauses   [q] quit %s' "$DIM" "$RST"
  if ! IFS= read -r -n1 -s k </dev/tty 2>/dev/null; then DEMO_AUTO=1; echo; return 0; fi
  printf '\r\033[K'
  case "$k" in
    q|Q) printf '\n%sBye.%s\n' "$DIM" "$RST"; exit 0 ;;
    s|S) return 1 ;;
    c|C) DEMO_AUTO=1 ;;
  esac
  return 0
}
_skipped() { printf '%s   (skipped)%s\n' "$DIM" "$RST"; }
_rc_report() { if [ "$1" -ne 0 ]; then printf '%s   (exit code %s)%s\n' "$RED" "$1" "$RST"; fi; return 0; }

show_cmd() { printf '%s$%s %s%s%s\n' "$GRN" "$RST" "$BOLD" "$1" "$RST"; }
show_sql() {   # show_sql "prompt" "SQL"
  printf '%s%s>%s\n' "$GRN" "$1" "$RST"
  printf '%s\n' "$2" | sed "s/^/    ${CYN}/; s/\$/${RST}/"
}

# run 'command'  -> show, pause, execute with eval (so the quoting looks like on a slide)
run() {
  show_cmd "$1"
  wait_key || { _skipped; return 0; }
  eval "$1"; local rc=$?
  _rc_report "$rc"; echo
  return 0
}

# ---- ClickHouse -------------------------------------------------------------
chc() { "$CH_BIN" client "${CH_CLIENT_ARGS[@]}" "$@"; }

# ch 'SQL' [extra clickhouse-client args]  -> show, pause, run
ch() {
  local sql="$1"; shift
  show_sql "clickhouse" "$sql"
  wait_key || { _skipped; return 0; }
  chc --multiquery "$@" --query "$sql"; local rc=$?
  _rc_report "$rc"; echo
  return 0
}
# quiet variants for preparation work (no display, no pause)
chq() { chc --multiquery --query "$1"; }
chv() { chc --format TSVRaw --query "$1"; }   # value(s) to stdout

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
ch_is_up() { curl -fs "http://127.0.0.1:$CH_HTTP_PORT/ping" >/dev/null 2>&1; }

ch_wait_ready() {

  for _ in $(seq 1 90); do
    ch_is_up && return 0
    sleep 1
  done
  return 1
}

# PIDs of clickhouse servers whose working directory is $CH_DIR (never touches a system service)
ch_pids() {
  local p
  for p in $(pgrep -f 'clickhouse(-| )server' 2>/dev/null); do
    if [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$CH_DIR" ]; then echo "$p"; fi
  done
}
ch_stop() {
  local p
  if [ -f "$CH_DIR/clickhouse.pid" ]; then
    p="$(cat "$CH_DIR/clickhouse.pid")"
    if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; fi
  fi
  for p in $(ch_pids); do kill "$p" 2>/dev/null; done
  for _ in $(seq 1 40); do
    if [ -z "$(ch_pids)" ] && ! ch_is_up; then break; fi
    sleep 0.5
  done
  for p in $(ch_pids); do kill -9 "$p" 2>/dev/null; done
  return 0
}
# remove the demo ClickHouse (server stopped, data deleted; binary kept if KEEP_BINARY=1)
ch_cleanup() {
  ch_stop
  [ -d "$CH_DIR" ] || return 0
  if [ "$KEEP_BINARY" = 1 ] && [ -x "$CH_BIN" ]; then
    find "$CH_DIR" -mindepth 1 -maxdepth 1 ! -name clickhouse -exec rm -rf {} +
  else
    rm -rf "$CH_DIR"
  fi
}
ch_download() {   # quiet download of the single binary (used when a demo needs it implicitly)
  mkdir -p "$CH_DIR"
  [ -x "$CH_BIN" ] && return 0
  ( cd "$CH_DIR" && curl -fsSL https://clickhouse.com/ | sh >/dev/null 2>&1 ) || die "could not download ClickHouse"
}
ch_server_args() {   # config overrides after '--': enable query_log/part_log (+ ports if non-default)
  printf -- '-- --query_log.database=system --query_log.table=query_log --part_log.database=system --part_log.table=part_log'
  if [ "$CH_HTTP_PORT" != 8123 ] || [ "$CH_TCP_PORT" != 9000 ]; then
    printf -- ' --http_port=%s --tcp_port=%s' "$CH_HTTP_PORT" "$CH_TCP_PORT"
  fi
}
ch_start_quiet() {
  ch_is_up && return 0
  if port_in_use "$CH_HTTP_PORT"; then
    die "port $CH_HTTP_PORT is in use by something that is not our demo ClickHouse (set CH_HTTP_PORT / CH_TCP_PORT in config.env)"
  fi
  ch_download
  # shellcheck disable=SC2046
  ( cd "$CH_DIR" && nohup ./clickhouse server $(ch_server_args) >server.log 2>&1 & echo $! >clickhouse.pid )
  ch_wait_ready || die "ClickHouse did not come up, see $CH_DIR/server.log"
}

# ---- packages / OS ----------------------------------------------------------
# shellcheck disable=SC2034
detect_os() {
  OS_ID="unknown"; OS_PRETTY="unknown"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release; OS_ID="${ID:-unknown}"; OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
  fi
  if [ -z "${PKG_MGR:-}" ]; then   # can be forced in config.env: PKG_MGR=dnf|yum|apt
    if   command -v dnf     >/dev/null 2>&1; then PKG_MGR=dnf
    elif command -v yum     >/dev/null 2>&1; then PKG_MGR=yum
    elif command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt
    else PKG_MGR=""; fi
  fi
  SUDO=""; if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
}
# pkg_cmd "<rpm package names>" "<deb package names>"  -> prints the install command for this OS
pkg_cmd() {
  case "$PKG_MGR" in
    dnf|yum) echo "$SUDO $PKG_MGR install -y $1" ;;
    apt)     echo "$SUDO apt-get update -qq && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $2" ;;
    *)       die "no supported package manager found (need dnf, yum or apt-get)" ;;
  esac
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed ($2)"; }

# ---- PostgreSQL (demo 2 / 3) -----------------------------------------------
pg_find_bin() {   # sets PG_BIN to the directory with initdb/pg_ctl/psql
  PG_BIN=""
  if command -v pg_ctl >/dev/null 2>&1; then
    PG_BIN="$(dirname "$(readlink -f "$(command -v pg_ctl)")")"
  else
    PG_BIN="$(find /usr/lib/postgresql /usr/pgsql-* -maxdepth 2 -name bin -type d 2>/dev/null | sort -V | tail -n1)"
  fi
  [ -n "$PG_BIN" ] && [ -x "$PG_BIN/pg_ctl" ]
}
# psql against the temporary instance: unix socket in $PG_DIR, superuser 'postgres' (trust)
pgc() { "$PG_BIN/psql" -X -q -h "$PG_DIR" -p "$PG_PORT" -U postgres "$@"; }
pgq() {   # pgq 'SQL' [db]  -> show, pause, run
  local sql="$1" db="${2:-$PG_DB}"
  show_sql "psql ($db)" "$sql"
  wait_key || { _skipped; return 0; }
  pgc -d "$db" -c "$sql"; local rc=$?
  _rc_report "$rc"; echo
  return 0
}
pg_is_up() { [ -f "$PG_DIR/data/postmaster.pid" ] && "$PG_BIN/pg_ctl" -D "$PG_DIR/data" status >/dev/null 2>&1; }
pg_cleanup() {
  if pg_find_bin && [ -d "$PG_DIR/data" ]; then
    "$PG_BIN/pg_ctl" -D "$PG_DIR/data" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$PG_DIR"
}

# ---- argument handling shared by the demos ---------------------------------
parse_common_args() {
  local a
  for a in "$@"; do
    case "$a" in
      -y|--auto) DEMO_AUTO=1 ;;
      -h|--help) usage; exit 0 ;;
    esac
  done
}
trap 'printf "\n%sInterrupted.%s\n" "$YEL" "$RST"; exit 130' INT
