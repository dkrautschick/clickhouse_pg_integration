#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# shellcheck disable=SC2016  # single quotes on purpose: commands are shown with $VARIABLES unexpanded
# Demo 2 (short edition) - ClickHouse meets PostgreSQL in 6 steps, about 8 minutes
#
#   temporary PostgreSQL  ->  read it live  ->  prove the round trip  ->
#   the plain-MV trap  ->  refreshable MV = local copy  ->  timing
#
# Same story as demo2_postgres_federation.sh with fewer pauses and fewer
# columns. Re-runnable: the temporary PostgreSQL and all demo-2 objects are
# recreated. Needs a NORMAL user (initdb refuses root); sudo only for packages.
# Keys: [ENTER] run  [s] skip  [c] rest without pauses  [q] quit
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-y|--auto] [--stop] [-h]

  -y, --auto   no pauses (dry run)
  --stop       stop ClickHouse and the temporary PostgreSQL at the end
EOF
}
STOP_AT_END=0
for a in "$@"; do [ "$a" = "--stop" ] && STOP_AT_END=1; done
parse_common_args "$@"

cd "$HERE" || exit 1   # so that sql/pg_seed.sql works as a relative path
detect_os
need_cmd curl "install it with your package manager"
if [ "$(id -u)" -eq 0 ]; then die "run this demo as a normal user: initdb refuses to run as root"; fi

banner "Demo 2 (short) - ClickHouse meets PostgreSQL" "about 8 minutes   ($OS_PRETTY)"
agenda "A temporary PostgreSQL with beer data" \
       "Path 2: ClickHouse reads PostgreSQL live" \
       "Proof: every query is a round trip" \
       "The trap: a plain materialized view is an insert trigger" \
       "Path 3: a refreshable materialized view = local copy" \
       "Why bother? Timing of the three ways"

info "Preparing: ClickHouse up, leftovers of earlier runs removed ..."
ch_start_quiet
ch_prep "CREATE DATABASE IF NOT EXISTS shop" \
  "DROP VIEW IF EXISTS shop.beer_sales_refresh SYNC" "DROP VIEW IF EXISTS shop.beer_sales_trigger SYNC" \
  "DROP TABLE IF EXISTS shop.beer_sales_local SYNC" "DROP TABLE IF EXISTS shop.beer_sales_local_trigger SYNC" \
  "DROP TABLE IF EXISTS shop.pg_beer_sales SYNC"
pg_cleanup

PGURL="'127.0.0.1:$PG_PORT', '$PG_DB', 'beer_sales', '$PG_RO_USER', '$PG_RO_PASSWORD'"
COLS="beer_name String, country String, liters Float32, sold_at DateTime"

# =============================================================================
step "A temporary PostgreSQL with beer data"
note "Only the packages are system-wide. The instance lives in $PG_DIR on port $PG_PORT."
if pg_find_bin; then
  info "PostgreSQL binaries found in $PG_BIN - nothing to install."
else
  run "$(pkg_cmd 'postgresql-server postgresql' 'postgresql postgresql-client')"
  pg_find_bin || die "PostgreSQL binaries not found after installation"
fi
# every statement is logged so we can show later what ClickHouse sends (quiet prep, written before the first start)
mkdir -p "$PG_DIR"
"$PG_BIN/initdb" -D "$PG_DIR/data" -U postgres -E UTF8 --auth-local=trust --auth-host=scram-sha-256 >"$PG_DIR/initdb.log" 2>&1 || die "initdb failed, see $PG_DIR/initdb.log"
{ echo "log_statement = 'all'"; echo "log_line_prefix = '%u@%d '"; echo "password_encryption = 'scram-sha-256'"; } >>"$PG_DIR/data/postgresql.conf"
note "initdb (own data directory, SCRAM over TCP) is already done, now start and seed it:"
# short names for the commands shown on screen (they point at the PostgreSQL binaries found above)
pg_ctl() { "$PG_BIN/pg_ctl" "$@"; }
psql()   { "$PG_BIN/psql" -X -q -h "$PG_DIR" -p "$PG_PORT" -U postgres "$@"; }
run 'pg_ctl -D "$PG_DIR/data" -l "$PG_DIR/pg.log" -o "-p $PG_PORT -k $PG_DIR -c listen_addresses=127.0.0.1" -w start'
run 'psql -c "CREATE ROLE $PG_RO_USER LOGIN PASSWORD '"'"'$PG_RO_PASSWORD'"'"'" -c "CREATE DATABASE $PG_DB" postgres
psql -d $PG_DB -v rows=$ROWS_PG -f sql/pg_seed.sql
psql -d $PG_DB -c "GRANT SELECT ON beer_sales TO $PG_RO_USER" -c "SELECT count(*) AS rows, round(sum(liters)::numeric) AS liters FROM beer_sales"'

# =============================================================================
step "Path 2: ClickHouse reads PostgreSQL live"
note "No copy, no pipeline: ClickHouse connects at query time. First the one-off table function ..."
ch "SELECT country, round(sum(liters)) AS liters, count() AS sales
FROM postgresql($PGURL)
GROUP BY country ORDER BY liters DESC LIMIT 5" --time
note "... then a permanent mapping with ENGINE = PostgreSQL (the password is hidden in SHOW CREATE TABLE):"
ch_prep "DROP TABLE IF EXISTS shop.pg_beer_sales SYNC"
ch "CREATE TABLE shop.pg_beer_sales ($COLS)
ENGINE = PostgreSQL($PGURL);

SHOW CREATE TABLE shop.pg_beer_sales FORMAT TSVRaw;
SELECT count() AS rows FROM shop.pg_beer_sales"

# =============================================================================
step "Proof: every query is a round trip"
pgq "INSERT INTO beer_sales VALUES ('Kwak', 'BE', 33.0, now()), ('Orval', 'BE', 20.0, now())"
ch "SELECT count() AS rows_now FROM shop.pg_beer_sales"
note "The two new rows are visible immediately. This is what PostgreSQL logged for ClickHouse:"
run 'grep "$PG_RO_USER@" "$PG_DIR/pg.log" | grep -E "COPY|SELECT" | tail -n 2 | cut -c1-170'
note "Only the needed COLUMNS are requested, but the aggregation happens in ClickHouse: every row travels."

# =============================================================================
step "The trap: a plain materialized view is an insert trigger"
note "In ClickHouse it fires on INSERTs into its source table - not on changes inside PostgreSQL."
ch_prep "DROP VIEW IF EXISTS shop.beer_sales_trigger SYNC" "DROP TABLE IF EXISTS shop.beer_sales_local_trigger SYNC"
ch "CREATE TABLE shop.beer_sales_local_trigger ($COLS)
ENGINE = MergeTree ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW shop.beer_sales_trigger
TO shop.beer_sales_local_trigger AS
SELECT * FROM shop.pg_beer_sales"
pgq "INSERT INTO beer_sales VALUES ('Westvleteren 12', 'BE', 33.0, now())"
ch "SELECT count() AS rows_in_the_copy FROM shop.beer_sales_local_trigger"
note "Zero rows: nothing pushes PostgreSQL changes into it. We need a PULL."

# =============================================================================
step "Path 3: a refreshable materialized view = local copy"
note "REFRESH EVERY lets ClickHouse pull on its own schedule - no cron, no Airflow."
ch_prep "DROP VIEW IF EXISTS shop.beer_sales_refresh SYNC" "DROP TABLE IF EXISTS shop.beer_sales_local SYNC"
ch "CREATE TABLE shop.beer_sales_local ($COLS)
ENGINE = MergeTree ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW shop.beer_sales_refresh
REFRESH EVERY 10 SECOND
TO shop.beer_sales_local AS
SELECT * FROM shop.pg_beer_sales;

SYSTEM WAIT VIEW shop.beer_sales_refresh;
SELECT count() AS rows_in_the_copy FROM shop.beer_sales_local"
pgq "INSERT INTO beer_sales VALUES ('Rochefort 10', 'BE', 20.0, now()), ('Achel Blond', 'BE', 20.0, now()), ('Orval', 'BE', 20.0, now())"
ch "SELECT count() AS postgres_rows FROM shop.pg_beer_sales;
SELECT count() AS copy_before_refresh FROM shop.beer_sales_local;

SYSTEM REFRESH VIEW shop.beer_sales_refresh;
SYSTEM WAIT VIEW shop.beer_sales_refresh;
SELECT count() AS copy_after_refresh FROM shop.beer_sales_local;

SELECT status, last_success_time, next_refresh_time
FROM system.view_refreshes WHERE database = 'shop'"
note "(Without SYSTEM REFRESH VIEW the new rows arrive within 10 seconds anyway. By default each refresh replaces the target atomically.)"

# =============================================================================
step "Why bother? Timing of the three ways"
run 'psql -d $PG_DB -c "\timing on" -c "SELECT country, round(sum(liters)::numeric) AS liters FROM beer_sales GROUP BY country ORDER BY liters DESC LIMIT 3"'
ch "SELECT country, round(sum(liters)) AS liters FROM shop.pg_beer_sales   GROUP BY country ORDER BY liters DESC LIMIT 3;
SELECT country, round(sum(liters)) AS liters FROM shop.beer_sales_local GROUP BY country ORDER BY liters DESC LIMIT 3" --time
note "Times are printed after each result: PostgreSQL scan, ClickHouse via the PG engine (pulls every row), local columnar copy."

recap "ClickHouse can read PostgreSQL live (postgresql() / ENGINE = PostgreSQL): no pipeline, but a round trip per query." \
      "A plain MATERIALIZED VIEW is an insert trigger - it never sees changes made inside PostgreSQL." \
      "A refreshable MV pulls on a schedule INSIDE ClickHouse and keeps a fast, local, columnar copy." \
      "Freshness = refresh interval; for continuous streaming see Kafka/CDC (path 4) or the platform integrations (path 5)."
if [ "$STOP_AT_END" = 1 ]; then pg_cleanup; ch_stop; info "Everything stopped."; else info "ClickHouse and the temporary PostgreSQL keep running (./cleanup.sh removes them)."; fi
