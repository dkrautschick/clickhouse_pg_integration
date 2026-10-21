#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Demo 1 (short edition) - ClickHouse in 7 steps, about 8 minutes
#
#   download + start  ->  table  ->  ingest  ->  merges  ->  on disk  ->
#   what a query reads  ->  server status
#
# Same story as demo1_clickhouse_basics.sh, but every step bundles related
# queries into ONE pause and prints only the columns you talk about.
# Re-runnable: stops and deletes a previous demo ClickHouse first.
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
  --stop       stop ClickHouse at the end (default: keep it for demo 2)

KEEP_BINARY=1 skips the 850 MB re-download on re-runs.
EOF
}
STOP_AT_END=0
for a in "$@"; do [ "$a" = "--stop" ] && STOP_AT_END=1; done
parse_common_args "$@"

detect_os
need_cmd curl "install it with: $(pkg_cmd curl curl)"
if [ "$(id -u)" -eq 0 ]; then warn "Running as root works, but a normal user is recommended."; fi

CHC="./clickhouse client"
if [ "$CH_TCP_PORT" != 9000 ]; then CHC="$CHC --port $CH_TCP_PORT"; fi

banner "Demo 1 (short) - ClickHouse in 7 steps" "about 8 minutes, one pause per idea"
agenda "Download the binary and start the server" \
       "Create the table (MergeTree + ORDER BY)" \
       "Ingest: tiny INSERTs vs. one bulk INSERT" \
       "Merges: parts get combined in the background" \
       "On disk: a part, its granules, compression" \
       "What does a query really read?" \
       "Is it healthy? Server status"

info "Cleaning up a previous run ..."
ch_cleanup
mkdir -p "$CH_DIR"

# =============================================================================
step "Download the binary and start the server"
note "One static binary is server, client and clickhouse-local."
if [ "$KEEP_BINARY" = 1 ] && [ -x "$CH_BIN" ]; then
  note "KEEP_BINARY=1: the binary of an earlier run is reused, no download."
  run "cd '$CH_DIR' && ls -lh clickhouse && ./clickhouse --version"
else
  run "cd '$CH_DIR' && curl https://clickhouse.com/ | sh"
fi
note "After '--' come config overrides: we switch on query_log and part_log (off in the built-in minimal config)."
CH_START_CMD="./clickhouse server -- \\
    --query_log.database=system --query_log.table=query_log \\
    --part_log.database=system  --part_log.table=part_log"
if [ "$CH_HTTP_PORT" != 8123 ] || [ "$CH_TCP_PORT" != 9000 ]; then
  CH_START_CMD="$CH_START_CMD \\
    --http_port=$CH_HTTP_PORT --tcp_port=$CH_TCP_PORT"
fi
run "$CH_START_CMD \\
    >server.log 2>&1 & echo \$! >clickhouse.pid"
if [ ! -f clickhouse.pid ]; then die "server was not started (step skipped?)"; fi
ch_wait_ready || die "server did not come up, see $CH_DIR/server.log"
ch "SELECT version() AS version, uptime() AS uptime_s, currentDatabase() AS db"

# =============================================================================
step "Create the table"
note "ORDER BY is the physical sort order AND the sparse primary index."
ch_prep "DROP TABLE IF EXISTS shop.beer_sales SYNC"   # re-runnable step
ch "CREATE DATABASE IF NOT EXISTS shop;

CREATE TABLE shop.beer_sales
(
    beer_name String,
    country   String,
    liters    Float32,
    sold_at   DateTime
)
ENGINE = MergeTree
ORDER BY (country, sold_at);

SELECT name, engine, sorting_key, primary_key
FROM system.tables WHERE database = 'shop' AND name = 'beer_sales'"

# =============================================================================
step "Ingest: tiny INSERTs vs. one bulk INSERT"
note "Every INSERT creates an immutable part. We pause the merges to make that visible."
ch "SYSTEM STOP MERGES shop.beer_sales;

INSERT INTO shop.beer_sales VALUES ('Chimay',      'BE', 12.5, now());
INSERT INTO shop.beer_sales VALUES ('Leffe bruin', 'BE',  9.0, now());
INSERT INTO shop.beer_sales VALUES ('Duvel',       'BE', 15.0, now());

SELECT name, rows, part_type FROM system.parts
WHERE database = 'shop' AND table = 'beer_sales' AND active ORDER BY name"
note "3 INSERTs = 3 parts. Now $ROWS_CH rows in one statement (generated inside ClickHouse):"
ch "INSERT INTO shop.beer_sales
WITH [('Chimay','BE'), ('Leffe bruin','BE'), ('Duvel','BE'), ('Pilsner Urquell','CZ'),
      ('Budvar','CZ'), ('Koelsch','DE'), ('Weizen','DE'), ('Guinness','IE'),
      ('Heineken','NL'), ('Estrella Damm','ES'), ('Samuel Adams','US'), ('Moretti','IT')] AS beers,
     beers[1 + cityHash64(number) % length(beers)] AS b
SELECT b.1, b.2,
       round(0.3 + (cityHash64(number, 7) % 2400) / 100, 1),
       now() - toIntervalSecond(cityHash64(number, 3) % (90 * 86400))
FROM numbers($ROWS_CH);

SELECT name, rows, part_type, formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = 'shop' AND table = 'beer_sales' AND active ORDER BY rows" --time

# =============================================================================
step "Merges: parts get combined in the background"
note "Batch your inserts: a part per INSERT means a lot of merge work (and 'Too many parts')."
ch "SYSTEM START MERGES shop.beer_sales;
OPTIMIZE TABLE shop.beer_sales FINAL;

SELECT name, active, level, rows, part_type
FROM system.parts WHERE database = 'shop' AND table = 'beer_sales'
ORDER BY active DESC, min_block_number"
note "One big active part. The merged source parts stay as inactive for a few minutes, then they are deleted."

# =============================================================================
step "On disk: a part, its granules, compression"
PART="$(chv "SELECT path FROM system.parts WHERE database='shop' AND table='beer_sales' AND active ORDER BY rows DESC LIMIT 1")"
run "ls -lh '$PART'"
note "*.bin = compressed column data, *.mrk2/*.cmrk2 = marks, primary.idx/.cidx = one key per granule (names vary by version)."
ch "SELECT name AS part, rows, marks AS granules, round(rows / marks) AS rows_per_granule,
       formatReadableSize(primary_key_bytes_in_memory) AS index_in_ram
FROM system.parts WHERE database = 'shop' AND table = 'beer_sales' AND active;

SELECT name AS column,
       formatReadableSize(data_uncompressed_bytes) AS raw,
       formatReadableSize(data_compressed_bytes)   AS compressed,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns WHERE database = 'shop' AND table = 'beer_sales'"

# =============================================================================
step "What does a query really read?"
ch "EXPLAIN indexes = 1
SELECT sum(liters) FROM shop.beer_sales WHERE country = 'DE'"
note "Granules x/y: the sparse index skips most of the table when the WHERE hits the ORDER BY key."
ch "SELECT sum(liters) FROM shop.beer_sales;
SELECT sum(liters) FROM shop.beer_sales WHERE country = 'DE';
SELECT sum(liters) FROM shop.beer_sales WHERE beer_name = 'Guinness';

SYSTEM FLUSH LOGS;
SELECT multiIf(query LIKE '%country%', 'WHERE country (in the key)',
               query LIKE '%beer_name%', 'WHERE beer_name (not in key)',
               'no WHERE (everything)') AS query_kind,
       read_rows, formatReadableSize(read_bytes) AS read_bytes, query_duration_ms AS ms
FROM system.query_log
WHERE type = 'QueryFinish' AND query LIKE 'SELECT sum(liters)%'
ORDER BY event_time DESC LIMIT 3"
note "Compare read_rows / read_bytes: only the needed columns are read, and a filter on the key skips granules on top."

# =============================================================================
step "Is it healthy? Server status"
ch "SELECT metric, value FROM system.metrics
WHERE metric IN ('Query', 'Merge', 'PartsActive', 'MemoryTracking', 'TCPConnection')
ORDER BY metric;

SELECT event, value FROM system.events
WHERE event IN ('InsertedRows', 'SelectQuery', 'MergedRows', 'Merge') ORDER BY event;

SELECT name, formatReadableSize(free_space) AS free, formatReadableSize(total_space) AS total
FROM system.disks"

recap "ClickHouse is one binary: download, start, query - no installer needed." \
      "A table is a pile of sorted, immutable PARTS; merges keep their number small." \
      "ORDER BY is the index: a sparse key per granule (about 8,192 rows) lets queries skip data." \
      "Columns are stored and compressed separately, so a query reads only the columns it needs." \
      "Next: demo 2 connects this to PostgreSQL."
if [ "$STOP_AT_END" = 1 ]; then ch_stop; info "Server stopped."; else info "ClickHouse keeps running for demo 2 (./cleanup.sh stops it)."; fi
