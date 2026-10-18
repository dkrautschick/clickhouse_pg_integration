#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Demo 2 - ClickHouse meets PostgreSQL
#   Installs PostgreSQL packages (if missing) and runs a TEMPORARY instance in
#   $WORKDIR (own port, own data directory, no system service touched), then:
#     - reads PostgreSQL live from ClickHouse (postgresql() + PostgreSQL engine)
#     - shows that a plain materialized view does NOT pull from PostgreSQL
#     - builds a local copy with a REFRESHABLE materialized view
#
# Re-runnable: the temporary PostgreSQL and all demo-2 objects are recreated.
# Keys while presenting: [ENTER] run  [s] skip  [c] rest without pauses  [q] quit
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-y|--auto] [--stop] [-h]

  -y, --auto   run everything without pauses (for a dry run)
  --stop       stop ClickHouse and the temporary PostgreSQL at the end
  -h           this help

Needs a NORMAL user (initdb refuses to run as root) with sudo rights for the
package installation. ClickHouse from demo 1 is reused; if it is not running
it is downloaded/started automatically.
EOF
}
STOP_AT_END=0
for a in "$@"; do [ "$a" = "--stop" ] && STOP_AT_END=1; done
parse_common_args "$@"

detect_os
need_cmd curl "install it with your package manager"
if [ "$(id -u)" -eq 0 ]; then die "run this demo as a normal user: PostgreSQL's initdb refuses to run as root"; fi

banner "Demo 2 - ClickHouse meets PostgreSQL" "Temporary PostgreSQL, direct access, materialized views   ($OS_PRETTY)"

# ---- maintenance: clean slate -------------------------------------------------
info "Preparing: making sure ClickHouse is running and removing leftovers of earlier runs..."
ch_start_quiet
chq "CREATE DATABASE IF NOT EXISTS shop;
DROP VIEW  IF EXISTS shop.beer_sales_refresh;
DROP VIEW  IF EXISTS shop.beer_sales_trigger;
DROP TABLE IF EXISTS shop.beer_sales_local;
DROP TABLE IF EXISTS shop.beer_sales_local_trigger;
DROP TABLE IF EXISTS shop.pg_beer_sales;"
pg_cleanup   # stops and deletes a temporary instance of an earlier run

PGURL="'127.0.0.1:$PG_PORT', '$PG_DB', 'beer_sales', '$PG_RO_USER', '$PG_RO_PASSWORD'"
CH_BEER_COLS="beer_name String, country String, liters Float32, sold_at DateTime"

# =============================================================================
step "A temporary PostgreSQL: install the packages (only if missing)"
note "Only the software is installed system-wide. The instance below lives in $PG_DIR."
if pg_find_bin; then
  info "PostgreSQL binaries already present in $PG_BIN - nothing to install."
else
  run "$(pkg_cmd 'postgresql-server postgresql' 'postgresql postgresql-client')"
  pg_find_bin || die "PostgreSQL binaries not found after installation"
fi
run "'$PG_BIN/postgres' --version"

# =============================================================================
step "Create and start a throw-away instance on port $PG_PORT"
run "mkdir -p '$PG_DIR' && '$PG_BIN/initdb' -D '$PG_DIR/data' -U postgres -E UTF8 --auth-local=trust --auth-host=scram-sha-256 >'$PG_DIR/initdb.log' && tail -n 3 '$PG_DIR/initdb.log'"
if [ ! -d "$PG_DIR/data" ]; then die "initdb did not run (step skipped?)"; fi
# log every statement so we can show later what ClickHouse sends to PostgreSQL (quiet prep)
{ echo "log_statement = 'all'"; echo "log_line_prefix = '%u@%d '"; echo "password_encryption = 'scram-sha-256'"; } >>"$PG_DIR/data/postgresql.conf"
run "'$PG_BIN/pg_ctl' -D '$PG_DIR/data' -l '$PG_DIR/pg.log' -o '-p $PG_PORT -k $PG_DIR -c listen_addresses=127.0.0.1' -w start"
run "'$PG_BIN/pg_isready' -h 127.0.0.1 -p $PG_PORT"
pgq "SELECT version()" postgres

# =============================================================================
step "Seed beer data into PostgreSQL ($ROWS_PG rows) and create a read-only user"
pgq "CREATE ROLE $PG_RO_USER LOGIN PASSWORD '$PG_RO_PASSWORD'" postgres
pgq "CREATE DATABASE $PG_DB" postgres
run "'$PG_BIN/psql' -X -q -h '$PG_DIR' -p $PG_PORT -U postgres -d $PG_DB -v rows=$ROWS_PG -f '$HERE/sql/pg_seed.sql'"
pgq "GRANT SELECT ON beer_sales TO $PG_RO_USER"
pgq "SELECT count(*) AS rows, round(sum(liters)::numeric) AS liters, min(sold_at)::date AS first_day, max(sold_at)::date AS last_day FROM beer_sales"

# =============================================================================
step "Path 2: ClickHouse reads PostgreSQL directly - the postgresql() table function"
note "No copy, no pipeline: ClickHouse connects to PostgreSQL at query time."
ch "DESCRIBE TABLE postgresql($PGURL)"
ch "SELECT * FROM postgresql($PGURL) ORDER BY sold_at DESC LIMIT 5"
ch "SELECT country, round(sum(liters)) AS liters
FROM postgresql($PGURL)
GROUP BY country ORDER BY liters DESC LIMIT 5" --time

# =============================================================================
step "Make it permanent: a table with ENGINE = PostgreSQL"
ch "CREATE TABLE shop.pg_beer_sales ($CH_BEER_COLS)
ENGINE = PostgreSQL($PGURL)"
ch "SHOW CREATE TABLE shop.pg_beer_sales FORMAT TSVRaw"
note "Note the password is hidden in the DDL output. In real life: named collections, read-only role, a replica."
ch "SELECT count() AS rows, round(sum(liters)) AS liters FROM shop.pg_beer_sales"

# =============================================================================
step "Proof: every query goes to PostgreSQL (live data, but a round trip)"
pgq "INSERT INTO beer_sales VALUES ('Kwak', 'BE', 33.0, now()), ('Orval', 'BE', 20.0, now())"
ch "SELECT count() AS rows_now FROM shop.pg_beer_sales"
note "Two new rows in PostgreSQL are visible immediately. This is what PostgreSQL logged for ClickHouse:"
run "grep -E '$PG_RO_USER@' '$PG_DIR/pg.log' | grep -E 'COPY|SELECT' | tail -n 3 | cut -c1-190"
note "ClickHouse only asks for the COLUMNS it needs - but aggregation happens in ClickHouse, so every row travels."

# =============================================================================
step "Careful with the terms: a plain MATERIALIZED VIEW is an insert trigger"
note "In ClickHouse it fires on INSERTs into its source table - not on changes inside PostgreSQL."
ch "CREATE TABLE shop.beer_sales_local_trigger ($CH_BEER_COLS)
ENGINE = MergeTree ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW shop.beer_sales_trigger
TO shop.beer_sales_local_trigger AS
SELECT * FROM shop.pg_beer_sales;"
pgq "INSERT INTO beer_sales VALUES ('Westvleteren 12', 'BE', 33.0, now())"
ch "SELECT count() AS rows_in_local_copy FROM shop.beer_sales_local_trigger"
note "Zero rows: nothing pushes PostgreSQL changes into this view. We need a PULL."

# =============================================================================
step "The pull: a REFRESHABLE materialized view builds a local copy"
ch "CREATE TABLE shop.beer_sales_local ($CH_BEER_COLS)
ENGINE = MergeTree ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW shop.beer_sales_refresh
REFRESH EVERY 10 SECOND
TO shop.beer_sales_local AS
SELECT * FROM shop.pg_beer_sales;"
ch "SYSTEM WAIT VIEW shop.beer_sales_refresh;

SELECT count() AS rows_in_local_copy FROM shop.beer_sales_local;"
ch "SELECT view, status, last_success_time, next_refresh_time, read_rows, written_rows, exception
FROM system.view_refreshes
WHERE database = 'shop'
FORMAT Vertical"
note "Freshness = refresh interval. Every refresh replaces the target atomically (APPEND mode adds instead)."

step "New rows in PostgreSQL arrive with the next refresh"
pgq "INSERT INTO beer_sales VALUES ('Rochefort 10', 'BE', 20.0, now()), ('Achel Blond', 'BE', 20.0, now()), ('Orval', 'BE', 20.0, now())"
ch "SELECT count() AS postgres_rows FROM shop.pg_beer_sales;
SELECT count() AS local_copy_rows FROM shop.beer_sales_local;"
ch "SYSTEM REFRESH VIEW shop.beer_sales_refresh;
SYSTEM WAIT VIEW shop.beer_sales_refresh;

SELECT count() AS local_copy_rows FROM shop.beer_sales_local;"
note "(Without SYSTEM REFRESH VIEW it simply happens within 10 seconds.)"

# =============================================================================
step "Why bother with a local copy? Same question, three places"
run "'$PG_BIN/psql' -X -q -h '$PG_DIR' -p $PG_PORT -U postgres -d $PG_DB -c '\\timing on' -c 'SELECT country, round(sum(liters)::numeric) AS liters FROM beer_sales GROUP BY country ORDER BY liters DESC LIMIT 3'"
ch "SELECT country, round(sum(liters)) AS liters FROM shop.pg_beer_sales GROUP BY country ORDER BY liters DESC LIMIT 3" --time
ch "SELECT country, round(sum(liters)) AS liters FROM shop.beer_sales_local GROUP BY country ORDER BY liters DESC LIMIT 3" --time
note "PostgreSQL: row store, full scan. ClickHouse via PG engine: still pulls every row over the wire. Local copy: column store."

echo
info "Demo 2 finished. ClickHouse and the temporary PostgreSQL keep running (./cleanup.sh removes them)."
if [ "$STOP_AT_END" = 1 ]; then
  pg_cleanup; ch_stop; info "Everything stopped."
fi
