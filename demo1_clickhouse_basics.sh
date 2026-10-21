#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Demo 1 - ClickHouse basics
#   download the single binary, start the server, ingest beer data and look
#   under the hood: table engine, parts, granules, files on disk, compression,
#   what a query really reads, server status.
#
# Re-runnable: stops and deletes a previous demo ClickHouse first.
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
  --stop       stop the demo ClickHouse again at the end (default: leave it
               running so demo 2 can use it)
  -h           this help

Config via ./config.env (see config.env.example). KEEP_BINARY=1 skips the
re-download of the ClickHouse binary on re-runs.
EOF
}
STOP_AT_END=0
for a in "$@"; do [ "$a" = "--stop" ] && STOP_AT_END=1; done
parse_common_args "$@"

detect_os
need_cmd curl "install it with: $(pkg_cmd curl curl)"
if [ "$(id -u)" -eq 0 ]; then warn "Running as root works, but a normal user is recommended."; fi

# command prefix as it is shown on screen (custom ports only if configured)
CHC="./clickhouse client"
if [ "$CH_TCP_PORT" != 9000 ]; then CHC="$CHC --port $CH_TCP_PORT"; fi

banner "Demo 1 - ClickHouse basics" "Stop Torturing PostgreSQL: the column-store sidekick, hands on"

# ---- maintenance: start from a clean state ----------------------------------
info "Cleaning up a previous run (server stopped, $CH_DIR removed)..."
ch_cleanup
mkdir -p "$CH_DIR"

# =============================================================================
step "Download: one static binary, no dependencies"
note "Slide 'The quick binary': server, client, local - all in one file."
run "cd '$CH_DIR'"
if [ "$KEEP_BINARY" = 1 ] && [ -x "$CH_BIN" ]; then
  note "KEEP_BINARY=1: the binary of an earlier run is reused, no download."
else
  run 'curl https://clickhouse.com/ | sh'
fi
run 'ls -lh clickhouse'
run './clickhouse --version'

# =============================================================================
step "Start the server (in the background) and wait until it is ready"
note "Everything after '--' is a config override: the built-in minimal config has no query_log/part_log, we switch them on."
CH_START_CMD="./clickhouse server -- \\
    --query_log.database=system --query_log.table=query_log \\
    --part_log.database=system  --part_log.table=part_log"
if [ "$CH_HTTP_PORT" != 8123 ] || [ "$CH_TCP_PORT" != 9000 ]; then CH_START_CMD="$CH_START_CMD \\
    --http_port=$CH_HTTP_PORT --tcp_port=$CH_TCP_PORT"; fi
run "$CH_START_CMD \\
    >server.log 2>&1 & echo \$! >clickhouse.pid"
if [ ! -f clickhouse.pid ]; then die "server was not started (step skipped?)"; fi
printf '%s   waiting for the server ...%s\n' "$DIM" "$RST"
ch_wait_ready || die "server did not come up, see $CH_DIR/server.log"
run "curl -s http://127.0.0.1:$CH_HTTP_PORT/ping"
run "grep -E -m3 'Listening for|Ready for connections' server.log | cut -c1-160"

# =============================================================================
step "Connect: native client and HTTP interface"
note "Two ports: 9000 native protocol (clickhouse-client), 8123 HTTP."
run "$CHC --query \"SELECT version(), uptime() AS uptime_s, currentDatabase()\""
run "echo 'SHOW DATABASES' | curl -s http://127.0.0.1:$CH_HTTP_PORT/ --data-binary @-"
note "default, system and INFORMATION_SCHEMA - the 'system' database is our pg_catalog/pg_stat_* in one."

# =============================================================================
step "Create the beer table: MergeTree with ORDER BY"
note "ORDER BY is the physical sort order and the (sparse) primary index."
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
ORDER BY (country, sold_at);"

# =============================================================================
step "Look at what we created: engine, keys, DDL"
ch "SHOW CREATE TABLE shop.beer_sales FORMAT TSVRaw"
ch "SELECT name, engine, sorting_key, primary_key, partition_key,
       total_rows, data_paths
FROM system.tables
WHERE database = 'shop' AND name = 'beer_sales'
FORMAT Vertical"

# =============================================================================
step "First rows: three Belgian beers = one INSERT = one part"
ch "INSERT INTO shop.beer_sales VALUES
    ('Chimay',              'BE', 12.5, now()),
    ('Leffe bruin',         'BE',  9.0, now()),
    ('St. Bernadus Abt 12', 'BE', 15.0, now());

SELECT * FROM shop.beer_sales;"
note "Every INSERT creates an immutable part. Tiny part = 'Compact' format (all columns in one file)."
ch "SELECT name, active, rows, level, part_type,
       formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = 'shop' AND table = 'beer_sales'
ORDER BY min_block_number"

# =============================================================================
step "Anti-pattern on purpose: many tiny INSERTs = many parts"
note "Batch your inserts (or use async_insert) - every INSERT is a part that must be merged later."
note "To make the effect visible we pause the background merges for a moment:"
ch "SYSTEM STOP MERGES shop.beer_sales"
run "for i in 1 2 3 4 5; do $CHC --query \"INSERT INTO shop.beer_sales VALUES ('Duvel', 'BE', \$i, now())\"; done"
ch "SELECT name, active, rows, level, part_type
FROM system.parts
WHERE database = 'shop' AND table = 'beer_sales'
ORDER BY min_block_number, level"

# =============================================================================
step "Bulk ingest: $ROWS_CH rows generated inside ClickHouse"
note "INSERT ... SELECT from numbers(): beers, countries, volumes and timestamps of the last 90 days."
ch "INSERT INTO shop.beer_sales
WITH [('Chimay','BE'), ('Leffe bruin','BE'), ('Duvel','BE'), ('Pilsner Urquell','CZ'),
      ('Budvar','CZ'), ('Koelsch','DE'), ('Weizen','DE'), ('Guinness','IE'),
      ('Heineken','NL'), ('Estrella Damm','ES'), ('Samuel Adams','US'), ('Moretti','IT')] AS beers,
     beers[1 + cityHash64(number) % length(beers)] AS b
SELECT
    b.1,
    b.2,
    round(0.3 + (cityHash64(number, 7) % 2400) / 100, 1),
    now() - toIntervalSecond(cityHash64(number, 3) % (90 * 86400))
FROM numbers($ROWS_CH);

SELECT count() AS rows, formatReadableSize(sum(liters) * 4) AS liters_raw FROM shop.beer_sales;" --time

# =============================================================================
step "Background merges: parts get combined, old parts disappear"
ch "SELECT name, active, level, rows, part_type, formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = 'shop' AND table = 'beer_sales'
ORDER BY min_block_number, level"
note "Now let the merges run again (and force a final merge for the demo):"
ch "SYSTEM START MERGES shop.beer_sales;
OPTIMIZE TABLE shop.beer_sales FINAL;

SELECT name, active, level, rows, part_type, formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = 'shop' AND table = 'beer_sales'
ORDER BY active DESC, min_block_number, level"
note "One big active part; the merged source parts stay around as inactive and are deleted after a few minutes."
ch "SYSTEM FLUSH LOGS;

SELECT event_type, part_name, merge_reason, rows, formatReadableSize(size_in_bytes) AS size
FROM system.part_log
WHERE database = 'shop' AND table = 'beer_sales' AND event_type IN ('MergeParts')
ORDER BY event_time"

# =============================================================================
step "How it is stored on disk: a part is a directory"
PART="$(chv "SELECT path FROM system.parts WHERE database='shop' AND table='beer_sales' AND active ORDER BY rows DESC LIMIT 1")"
ch "SELECT name, part_type, rows, marks, path
FROM system.parts
WHERE database = 'shop' AND table = 'beer_sales' AND active
ORDER BY rows DESC LIMIT 1
FORMAT Vertical"
run "ls -lh '$PART'"
run "echo -n 'rows in this part: '; cat '$PART/count.txt'; echo; head -n 8 '$PART/columns.txt'"
note "*.bin = compressed column data, *.mrk2 / *.cmrk2 = marks (offsets per granule),"
note "primary.idx (newer versions: primary.cidx) = 1 key per granule. Exact file names vary by version."

# =============================================================================
step "Granules and compression"
ch "SELECT name, value
FROM system.merge_tree_settings
WHERE name IN ('index_granularity', 'index_granularity_bytes', 'min_bytes_for_wide_part')"
ch "SELECT name, rows, marks, round(rows / marks) AS rows_per_granule,
       formatReadableSize(primary_key_bytes_in_memory) AS primary_idx_in_ram
FROM system.parts
WHERE database = 'shop' AND table = 'beer_sales' AND active"
ch "SELECT name, type,
       formatReadableSize(data_uncompressed_bytes) AS uncompressed,
       formatReadableSize(data_compressed_bytes)   AS compressed,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'shop' AND table = 'beer_sales'"
note "Similar values sit next to each other, so columns compress very well (country: tiny)."

# =============================================================================
step "Queries: what does ClickHouse really read?"
ch "SELECT country, round(sum(liters)) AS liters, count() AS sales
FROM shop.beer_sales
GROUP BY country
ORDER BY liters DESC"
ch "EXPLAIN indexes = 1
SELECT sum(liters) FROM shop.beer_sales WHERE country = 'DE'"
note "PrimaryKey: Granules x/y - the sparse index skips most granules for WHERE country = 'DE'."
ch "SELECT sum(liters) FROM shop.beer_sales;
SELECT sum(liters) FROM shop.beer_sales WHERE country = 'DE';
SELECT sum(liters) FROM shop.beer_sales WHERE beer_name = 'Guinness';"
ch "SYSTEM FLUSH LOGS;

SELECT substring(query, 1, 68) AS query, read_rows,
       formatReadableSize(read_bytes) AS read_bytes, query_duration_ms AS ms
FROM system.query_log
WHERE type = 'QueryFinish' AND query LIKE 'SELECT sum(liters)%'
ORDER BY event_time DESC LIMIT 3"
note "country is the first ORDER BY column -> few granules. beer_name is not in the key -> a scan (but only of ONE column)."

# =============================================================================
step "Status: what is the server doing?"
ch "SELECT metric, value
FROM system.metrics
WHERE metric IN ('Query', 'Merge', 'PartsActive', 'MemoryTracking', 'TCPConnection', 'HTTPConnection')
ORDER BY metric"
ch "SELECT event, value
FROM system.events
WHERE event IN ('Query', 'SelectQuery', 'InsertQuery', 'InsertedRows', 'MergedRows', 'Merge')
ORDER BY event"
ch "SELECT name, path, formatReadableSize(free_space) AS free, formatReadableSize(total_space) AS total
FROM system.disks"

# =============================================================================
step "Bonus: the same binary as clickhouse-local (no server needed)"
run "$CHC --query \"SELECT * FROM shop.beer_sales ORDER BY rand() LIMIT 1000 FORMAT CSVWithNames\" > beer.csv"
run "./clickhouse local --query \"SELECT country, count() AS sales FROM file('beer.csv', CSVWithNames) GROUP BY country ORDER BY sales DESC\""

echo
info "Demo 1 finished. The server keeps running for demo 2 (stop it with ./cleanup.sh)."
if [ "$STOP_AT_END" = 1 ]; then ch_stop; info "Server stopped."; fi
