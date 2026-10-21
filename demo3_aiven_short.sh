#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes on purpose: commands are shown with $VARIABLES unexpanded
# -----------------------------------------------------------------------------
# Demo 3 (short edition) - the same on the Aiven platform, 5 steps, about 8 minutes
# (+ an optional Kafka step with --kafka)
#
#   create services  ->  seed PostgreSQL  ->  one integration  ->
#   query PostgreSQL from ClickHouse  ->  refreshable local copy
#
# Run `./demo3_aiven_short.sh prepare` before the talk: the first service
# creation takes 10+ minutes. prepare / cleanup / status are handled by
# demo3_aiven.sh. Options: --kafka, --terraform, --recreate, -y.
# Needs: avn (pip install aiven-client), jq, psql, AIVEN_PROJECT, a login.
# Keys: [ENTER] run  [s] skip  [c] rest without pauses  [q] quit
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/aiven.sh
. "$HERE/lib/aiven.sh"

usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; }

for a in "$@"; do
  case "$a" in
    prepare|cleanup|status) exec "$HERE/demo3_aiven.sh" "$@" ;;   # long-running / maintenance commands live there
    --terraform) MODE=terraform ;;
    --kafka)     WITH_KAFKA=1 ;;
    --recreate)  RECREATE=1 ;;
  esac
done
parse_common_args "$@"
detect_os
cd "$HERE" || exit 1

banner "Demo 3 (short) - Aiven platform" "about 8 minutes, mode: $MODE, project: ${AIVEN_PROJECT:-?}"
if [ "$WITH_KAFKA" = 1 ]; then
  agenda "Create the services" "Seed PostgreSQL" "One integration: PostgreSQL into ClickHouse" "Query PostgreSQL from ClickHouse" "A refreshable, replicated local copy" "Bonus: Kafka into ClickHouse"
else
  agenda "Create the services" "Seed PostgreSQL" "One integration: PostgreSQL into ClickHouse" "Query PostgreSQL from ClickHouse" "A refreshable, replicated local copy"
fi

preflight
psql() { "$PSQL" "$@"; }   # short name for the commands shown on screen
if [ "$RECREATE" = 1 ]; then terminate_services; fi
reset_demo_objects

KAFKA_NAME_PART=""; if [ "$WITH_KAFKA" = 1 ]; then KAFKA_NAME_PART=" $AIVEN_KAFKA_NAME"; fi

# =============================================================================
step "Create the services"
if [ "$MODE" = terraform ]; then
  tf_env
  note "Services AND integrations as code: $TF_DIR/main.tf"
  run "terraform -chdir=terraform init -input=false && terraform -chdir=terraform apply -input=false -auto-approve"
else
  note "One command per service. Existing services are reused, so this is fast when prepared."
  run "avn service create $AIVEN_PG_NAME -t pg         --plan $AIVEN_PG_PLAN --cloud $AIVEN_CLOUD --no-fail-if-exists
avn service create $AIVEN_CH_NAME -t clickhouse --plan $AIVEN_CH_PLAN --cloud $AIVEN_CLOUD --no-fail-if-exists$(
  if [ "$WITH_KAFKA" = 1 ]; then printf '\navn service create %s -t kafka        --plan %s --cloud %s --no-fail-if-exists' "$AIVEN_KAFKA_NAME" "$AIVEN_KAFKA_PLAN" "$AIVEN_CLOUD"; fi)"
  run "avn service wait $AIVEN_PG_NAME $AIVEN_CH_NAME$KAFKA_NAME_PART
avn service list --format '{service_name}  {service_type}  {plan}  {state}  {cloud_name}'"
fi

# =============================================================================
step "Seed PostgreSQL"
note "The service URI carries user, password, host and sslmode - we never type credentials."
run "PG_URI=\$(avn service get $AIVEN_PG_NAME --format '{service_uri}')
psql \"\$PG_URI\" -v rows=$ROWS_PG -f sql/pg_seed.sql
psql \"\$PG_URI\" -c 'SELECT count(*) AS rows, round(sum(liters)::numeric) AS liters FROM beer_sales'"

# =============================================================================
step "One integration: PostgreSQL into ClickHouse"
note "Type clickhouse_postgresql: no connector, no Kafka. ClickHouse gets a database that mirrors the PostgreSQL schema."
if [ "$MODE" = terraform ]; then
  note "(already created by Terraform: aiven_service_integration.pg_to_ch)"
  run "avn service integration-list $AIVEN_CH_NAME"
elif [ -n "$(integration_id clickhouse_postgresql)" ]; then
  note "(the integration exists already - nothing to create)"
  run "avn service integration-list $AIVEN_CH_NAME"
else
  run "avn service integration-create -t clickhouse_postgresql -s $AIVEN_PG_NAME -d $AIVEN_CH_NAME \\
  --user-config-json '{\"databases\":[{\"database\":\"$AIVEN_PG_DATABASE\",\"schema\":\"public\"}]}'
avn service integration-list $AIVEN_CH_NAME"
fi

# =============================================================================
step "Query PostgreSQL from ClickHouse"
ch_connect_aiven
note "Plain clickhouse-client over TLS; host, user and password come from 'avn service get'."
ch "SHOW DATABASES;

SHOW TABLES FROM $DBQ;

SELECT country, round(sum(liters)) AS liters, count() AS sales
FROM $DBQ.beer_sales
GROUP BY country ORDER BY liters DESC LIMIT 5" --time

# =============================================================================
step "A refreshable, replicated local copy"
note "Like demo 2, now on a managed, replicated cluster. If your version lacks refreshable MVs, skip with [s]."
ch_prep "DROP VIEW IF EXISTS default.beer_sales_refresh SYNC" "DROP TABLE IF EXISTS default.beer_sales_local SYNC"
ch "CREATE TABLE default.beer_sales_local ($CH_BEER_COLS)
ENGINE = $CH_LOCAL_ENGINE
ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW default.beer_sales_refresh
REFRESH EVERY 30 SECOND
TO default.beer_sales_local AS
SELECT * FROM $DBQ.beer_sales;

SYSTEM WAIT VIEW default.beer_sales_refresh;
SELECT count() AS rows_in_the_copy FROM default.beer_sales_local"
ch "SELECT country, round(sum(liters)) AS liters FROM $DBQ.beer_sales        GROUP BY country ORDER BY liters DESC LIMIT 3;
SELECT country, round(sum(liters)) AS liters FROM default.beer_sales_local GROUP BY country ORDER BY liters DESC LIMIT 3" --time

# =============================================================================
if [ "$WITH_KAFKA" = 1 ]; then
  step "Bonus: Kafka into ClickHouse"
  if [ "$MODE" = terraform ]; then
    note "(topic and clickhouse_kafka integration were created by Terraform)"
  else
    note "A topic, the second integration type, and a table mapping - all from the CLI."
    KAFKA_CMDS=""
    if ! avn service topic-list "$AIVEN_KAFKA_NAME" 2>/dev/null | grep -q "$KAFKA_TOPIC"; then
      KAFKA_CMDS="avn service topic-create $AIVEN_KAFKA_NAME $KAFKA_TOPIC --partitions 3 --replication 2
"
    fi
    if [ -z "$(integration_id clickhouse_kafka)" ]; then
      KAFKA_CMDS="${KAFKA_CMDS}avn service integration-create -t clickhouse_kafka -s $AIVEN_KAFKA_NAME -d $AIVEN_CH_NAME
"
    fi
    run "${KAFKA_CMDS}ID=\$(avn service integration-list $AIVEN_CH_NAME --json | jq -r '.[] | select(.integration_type==\"clickhouse_kafka\") | .service_integration_id')
avn service integration-update \$ID --user-config-json '{\"tables\":[{\"name\":\"beer_events\",\"group_name\":\"clickhouse-sidekick\",\"data_format\":\"JSONEachRow\",\"auto_offset_reset\":\"earliest\",\"columns\":[{\"name\":\"beer_name\",\"type\":\"String\"},{\"name\":\"country\",\"type\":\"String\"},{\"name\":\"liters\",\"type\":\"Float32\"},{\"name\":\"sold_at\",\"type\":\"DateTime\"}],\"topics\":[{\"name\":\"$KAFKA_TOPIC\"}]}]}'"
  fi
  note "The Kafka table is read AND write: INSERT produces to the topic, a materialized view consumes it into MergeTree."
  ch_prep "DROP VIEW IF EXISTS default.beer_events_mv SYNC" "DROP TABLE IF EXISTS default.beer_events_local SYNC"
  ch "CREATE TABLE default.beer_events_local ($CH_BEER_COLS)
ENGINE = $CH_LOCAL_ENGINE
ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW default.beer_events_mv
TO default.beer_events_local AS
SELECT * FROM $KDBQ.beer_events;

INSERT INTO $KDBQ.beer_events VALUES
    ('Chimay', 'BE', 12.5, now()), ('Pilsner Urquell', 'CZ', 20.0, now()), ('Weizen', 'DE', 15.0, now())"
  printf '%s   waiting a few seconds for the consumer ...%s\n' "$DIM" "$RST"; sleep "${KAFKA_WAIT:-8}"
  ch "SELECT * FROM default.beer_events_local ORDER BY sold_at"
fi

recap "Aiven creates the services with one command each (or one terraform apply)." \
      "ONE integration (clickhouse_postgresql) replaces the whole plumbing: ClickHouse sees the PostgreSQL tables." \
      "The same refreshable materialized view as in demo 2 gives you a fast, replicated copy on a managed cluster." \
      "Remember: the services cost money while they run -> ./demo3_aiven.sh cleanup"
