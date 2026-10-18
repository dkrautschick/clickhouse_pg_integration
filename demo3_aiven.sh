#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Demo 3 - roll it out on the Aiven platform (Aiven for PostgreSQL + Aiven for
# ClickHouse, optionally Aiven for Apache Kafka) with the Aiven CLI `avn`
# or - with --terraform - with the Terraform files in ./terraform.
#
#   ./demo3_aiven.sh              presentation run (default command "run")
#   ./demo3_aiven.sh prepare      create services + data beforehand, no pauses
#   ./demo3_aiven.sh status       show the demo services
#   ./demo3_aiven.sh cleanup      terminate the demo services (costs money!)
#
# Options: --kafka  also demo the clickhouse_kafka integration
#          --terraform  create services + integrations with Terraform
#          --recreate   terminate existing demo services first (slow)
#          -y / --auto  no pauses
#
# Re-runnable: integrations and demo objects are removed at the start of "run";
# the (slow to create) services are reused unless you pass --recreate.
# Needs: avn (pip install aiven-client), jq, psql, an Aiven project, a login
# (avn user login ... or AIVEN_AUTH_TOKEN) and AIVEN_PROJECT. See README.md.
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

: "${AIVEN_CLOUD:=google-europe-west1}"
: "${AIVEN_PG_NAME:=shop-pg}"
: "${AIVEN_CH_NAME:=beer-clickhouse}"
: "${AIVEN_KAFKA_NAME:=events-kafka}"
: "${AIVEN_PG_PLAN:=startup-4}"
: "${AIVEN_CH_PLAN:=startup-16}"
: "${AIVEN_KAFKA_PLAN:=startup-2}"
: "${AIVEN_PG_DATABASE:=defaultdb}"
: "${KAFKA_TOPIC:=beer_sales_events}"
: "${WITH_KAFKA:=0}"
: "${MODE:=cli}"
: "${RECREATE:=0}"
: "${INSTALL_AVN:=0}"
: "${CH_LOCAL_ENGINE:=ReplicatedMergeTree()}"   # Aiven ClickHouse replicates; MergeTree for a plain local test

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

CMD="run"
for a in "$@"; do
  case "$a" in
    run|prepare|cleanup|status) CMD="$a" ;;
    --terraform) MODE=terraform ;;
    --kafka)     WITH_KAFKA=1 ;;
    --recreate)  RECREATE=1 ;;
  esac
done
parse_common_args "$@"
detect_os

# shellcheck disable=SC2034
PG_URI=""   # filled by a presented step, used by later ones
TF_DIR="$HERE/terraform"
# ClickHouse database names created by the integrations (dashes need backticks)
DBQ="\`service_${AIVEN_PG_NAME}_${AIVEN_PG_DATABASE}_public\`"
KDBQ="\`service_${AIVEN_KAFKA_NAME}\`"
CH_BEER_COLS="beer_name String, country String, liters Float32, sold_at DateTime"

# ---- helpers --------------------------------------------------------------------
svc_exists() { avn service get "$1" >/dev/null 2>&1; }
svc_state()  { avn service get "$1" --format '{state}' 2>/dev/null; }
integration_id() {   # integration_id <type> -> id of that integration on the ClickHouse service
  avn service integration-list "$AIVEN_CH_NAME" --json 2>/dev/null |
    jq -r --arg t "$1" '[.[] | select(.integration_type == $t)][0].service_integration_id // empty'
}
tf_env() {
  export TF_VAR_project_name="$AIVEN_PROJECT" TF_VAR_cloud_name="$AIVEN_CLOUD"
  export TF_VAR_pg_service_name="$AIVEN_PG_NAME" TF_VAR_ch_service_name="$AIVEN_CH_NAME"
  export TF_VAR_kafka_service_name="$AIVEN_KAFKA_NAME"
  export TF_VAR_pg_plan="$AIVEN_PG_PLAN" TF_VAR_ch_plan="$AIVEN_CH_PLAN" TF_VAR_kafka_plan="$AIVEN_KAFKA_PLAN"
  export TF_VAR_pg_database="$AIVEN_PG_DATABASE" TF_VAR_kafka_topic="$KAFKA_TOPIC"
  if [ "$WITH_KAFKA" = 1 ]; then export TF_VAR_with_kafka=true; else export TF_VAR_with_kafka=false; fi
  # the provider reads AIVEN_TOKEN; reuse the token from the environment or from `avn user login`
  if [ -z "${AIVEN_TOKEN:-}" ]; then
    if [ -n "${AIVEN_AUTH_TOKEN:-}" ]; then
      export AIVEN_TOKEN="$AIVEN_AUTH_TOKEN"
    elif [ -r "${AIVEN_CONFIG_DIR:-$HOME/.config/aiven}/aiven-credentials.json" ]; then
      AIVEN_TOKEN="$(jq -r '.auth_token' "${AIVEN_CONFIG_DIR:-$HOME/.config/aiven}/aiven-credentials.json")"
      export AIVEN_TOKEN
    fi
  fi
}
ch_connect_aiven() {   # point chc() at the Aiven ClickHouse service (native TLS port)
  local json host port user pass
  json="$(avn service get "$AIVEN_CH_NAME" --json)" || die "cannot read service $AIVEN_CH_NAME"
  host="$(jq -r '.service_uri_params.host' <<<"$json")"
  user="$(jq -r '.service_uri_params.user' <<<"$json")"
  pass="$(jq -r '.service_uri_params.password' <<<"$json")"
  port="$(jq -r '[.components[]? | select(.component == "clickhouse") | .port][0] // 9440' <<<"$json")"
  CH_CLIENT_ARGS=(--host "$host" --port "${CH_AIVEN_NATIVE_PORT:-$port}" --user "$user" --password "$pass")
  if [ "${CH_AIVEN_SECURE:-1}" = 1 ]; then CH_CLIENT_ARGS+=(--secure); fi   # =0 only for local tests
}
wait_services() {
  local s
  for s in "$@"; do
    printf '%s   waiting for %s (%s) ...%s\n' "$DIM" "$s" "$(svc_state "$s")" "$RST"
  done
  avn service wait "$@"
}

preflight() {
  [ -n "${AIVEN_PROJECT:-}" ] || die "AIVEN_PROJECT is not set (put it in config.env or export it). See README.md"
  export AIVEN_PROJECT
  need_cmd curl "install it with your package manager"
  if ! command -v jq >/dev/null 2>&1; then run "$(pkg_cmd jq jq)"; need_cmd jq "install it manually"; fi
  if ! command -v avn >/dev/null 2>&1; then
    if [ "$INSTALL_AVN" = 1 ] && command -v python3 >/dev/null 2>&1; then
      run "python3 -m pip install --user aiven-client"
      export PATH="$HOME/.local/bin:$PATH"
    fi
    command -v avn >/dev/null 2>&1 || die "the Aiven CLI 'avn' is missing. Install: python3 -m pip install --user aiven-client  (or pipx install aiven-client; or INSTALL_AVN=1)"
  fi
  if [ "$MODE" = terraform ]; then need_cmd terraform "https://developer.hashicorp.com/terraform/install"; fi
  PSQL="$(command -v psql || true)"
  if [ -z "$PSQL" ] && pg_find_bin; then PSQL="$PG_BIN/psql"; fi
  if [ -z "$PSQL" ]; then
    run "$(pkg_cmd postgresql postgresql-client)"
    PSQL="$(command -v psql || true)"; [ -n "$PSQL" ] || die "psql not found after installation"
  fi
  avn user info >/dev/null 2>&1 || die "not logged in to Aiven: run 'avn user login <email>' (add --token for token auth) or set AIVEN_AUTH_TOKEN"
  avn project details >/dev/null 2>&1 || die "cannot access Aiven project '$AIVEN_PROJECT' (check AIVEN_PROJECT / permissions)"
  ch_download
}

# ---- maintenance: make the demo re-runnable ----------------------------------------
reset_demo_objects() {
  local id
  info "Maintenance: removing integrations and demo objects of earlier runs (services are kept)..."
  if svc_exists "$AIVEN_CH_NAME" && [ "$(svc_state "$AIVEN_CH_NAME")" = RUNNING ]; then
    ch_connect_aiven
    chq "DROP VIEW  IF EXISTS default.beer_sales_refresh;
         DROP VIEW  IF EXISTS default.beer_events_mv;
         DROP TABLE IF EXISTS default.beer_sales_local SYNC;
         DROP TABLE IF EXISTS default.beer_events_local SYNC" >/dev/null 2>&1 || true
  fi
  if [ "$MODE" = cli ] && svc_exists "$AIVEN_CH_NAME"; then
    for t in clickhouse_postgresql clickhouse_kafka; do
      id="$(integration_id "$t")"
      if [ -n "$id" ]; then avn service integration-delete "$id" >/dev/null 2>&1 || true; fi
    done
  fi
}
terminate_services() {
  local s
  for s in "$AIVEN_PG_NAME" "$AIVEN_CH_NAME" "$AIVEN_KAFKA_NAME"; do
    if svc_exists "$s"; then info "Terminating service $s ..."; avn service terminate --force "$s" >/dev/null; fi
  done
  for _ in $(seq 1 120); do
    if ! svc_exists "$AIVEN_PG_NAME" && ! svc_exists "$AIVEN_CH_NAME" && ! svc_exists "$AIVEN_KAFKA_NAME"; then return 0; fi
    sleep 5
  done
  warn "services still shutting down - check 'avn service list'"
}

# ---- demo steps ------------------------------------------------------------------
s_context() {
  step "Where are we? Account, project, regions"
  note "The Aiven CLI talks to the same API as the console and Terraform."
  run "avn user info"
  run "avn project details"
  run "avn cloud list | sed -n '1,8p'"
}

s_create_cli() {
  step "Create the services with the CLI"
  note "Aiven for PostgreSQL, Aiven for ClickHouse$([ "$WITH_KAFKA" = 1 ] && echo ', Aiven for Apache Kafka'): one command each."
  run "avn service create $AIVEN_PG_NAME -t pg --plan $AIVEN_PG_PLAN --cloud $AIVEN_CLOUD --no-fail-if-exists"
  run "avn service create $AIVEN_CH_NAME -t clickhouse --plan $AIVEN_CH_PLAN --cloud $AIVEN_CLOUD --no-fail-if-exists"
  if [ "$WITH_KAFKA" = 1 ]; then
    run "avn service create $AIVEN_KAFKA_NAME -t kafka --plan $AIVEN_KAFKA_PLAN --cloud $AIVEN_CLOUD --no-fail-if-exists"
  fi
  note "First creation takes a few minutes (ClickHouse the longest). Services that already run return immediately."
  run "avn service wait $AIVEN_PG_NAME $AIVEN_CH_NAME$([ "$WITH_KAFKA" = 1 ] && echo " $AIVEN_KAFKA_NAME")"
  run "avn service list --format '{service_name}  {service_type}  {plan}  {state}  {cloud_name}'"
}

s_create_tf() {
  step "Create services and integrations with Terraform"
  note "Same result as code: $TF_DIR/main.tf"
  run "cat '$TF_DIR/main.tf' | head -n 70"
  run "terraform -chdir='$TF_DIR' init -input=false"
  run "terraform -chdir='$TF_DIR' plan -input=false"
  run "terraform -chdir='$TF_DIR' apply -input=false -auto-approve"
  run "avn service list --format '{service_name}  {service_type}  {plan}  {state}  {cloud_name}'"
}

s_seed() {
  step "Put some beer into Aiven for PostgreSQL"
  note "The service URI contains user, password, host and sslmode=require - we never type credentials."
  run "PG_URI=\$(avn service get $AIVEN_PG_NAME --format '{service_uri}')"
  run "'$PSQL' \"\$PG_URI\" -X -q -v rows=$ROWS_PG -f '$HERE/sql/pg_seed.sql'"
  run "'$PSQL' \"\$PG_URI\" -X -c 'SELECT count(*) AS rows, round(sum(liters)::numeric) AS liters FROM beer_sales'"
}

s_integrate_pg() {
  step "Wire PostgreSQL into ClickHouse: one integration"
  note "Type clickhouse_postgresql: no Debezium, no Kafka - ClickHouse gets a database that mirrors the PostgreSQL schema."
  if [ "$MODE" = cli ]; then
    run "avn service integration-create -t clickhouse_postgresql -s $AIVEN_PG_NAME -d $AIVEN_CH_NAME --user-config-json '{\"databases\":[{\"database\":\"$AIVEN_PG_DATABASE\",\"schema\":\"public\"}]}'"
  else
    note "(created by Terraform above: resource aiven_service_integration.pg_to_ch)"
  fi
  run "avn service integration-list $AIVEN_CH_NAME"
}

s_query_pg() {
  step "Query PostgreSQL from ClickHouse"
  ch_connect_aiven
  note "Connecting with the plain clickhouse-client over TLS (native port), credentials from 'avn service get'."
  ch "SHOW DATABASES"
  ch "SHOW TABLES FROM $DBQ"
  ch "SELECT count() AS rows, round(sum(liters)) AS liters FROM $DBQ.beer_sales"
  ch "SELECT country, round(sum(liters)) AS liters FROM $DBQ.beer_sales GROUP BY country ORDER BY liters DESC LIMIT 5" --time
  note "Live read from PostgreSQL (like demo 2, path 2). Now a local copy, so dashboards stop hitting the primary:"
}

s_local_copy() {
  step "A local, columnar copy that refreshes itself"
  note "If your Aiven ClickHouse version has no refreshable materialized views, skip this step with [s]."
  ch "CREATE TABLE default.beer_sales_local ($CH_BEER_COLS)
ENGINE = $CH_LOCAL_ENGINE
ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW default.beer_sales_refresh
REFRESH EVERY 30 SECOND
TO default.beer_sales_local AS
SELECT * FROM $DBQ.beer_sales;"
  ch "SYSTEM WAIT VIEW default.beer_sales_refresh;

SELECT count() AS rows_in_local_copy FROM default.beer_sales_local;"
  ch "SELECT country, round(sum(liters)) AS liters FROM default.beer_sales_local GROUP BY country ORDER BY liters DESC LIMIT 5" --time
}

s_kafka() {
  step "Optional: Kafka -> ClickHouse with the second integration"
  local id
  if [ "$MODE" = cli ]; then
    if ! avn service topic-list "$AIVEN_KAFKA_NAME" 2>/dev/null | grep -q "$KAFKA_TOPIC"; then
      run "avn service topic-create $AIVEN_KAFKA_NAME $KAFKA_TOPIC --partitions 3 --replication 2"
    fi
    run "avn service integration-create -t clickhouse_kafka -s $AIVEN_KAFKA_NAME -d $AIVEN_CH_NAME"
    id="$(integration_id clickhouse_kafka)"
    note "The integration config says which topic becomes which ClickHouse table:"
    run "avn service integration-update $id --user-config-json '{\"tables\":[{\"name\":\"beer_events\",\"group_name\":\"clickhouse-sidekick\",\"data_format\":\"JSONEachRow\",\"auto_offset_reset\":\"earliest\",\"columns\":[{\"name\":\"beer_name\",\"type\":\"String\"},{\"name\":\"country\",\"type\":\"String\"},{\"name\":\"liters\",\"type\":\"Float32\"},{\"name\":\"sold_at\",\"type\":\"DateTime\"}],\"topics\":[{\"name\":\"$KAFKA_TOPIC\"}]}]}'"
  else
    note "(topic and integration were created by Terraform: aiven_kafka_topic + aiven_service_integration.kafka_to_ch)"
  fi
  ch "SHOW TABLES FROM $KDBQ"
  note "A materialized view stores whatever arrives in the topic into a MergeTree table (this one IS an insert trigger):"
  ch "CREATE TABLE default.beer_events_local ($CH_BEER_COLS)
ENGINE = $CH_LOCAL_ENGINE
ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW default.beer_events_mv
TO default.beer_events_local AS
SELECT * FROM $KDBQ.beer_events;"
  note "The Kafka table is read AND write: INSERT produces messages to the topic ..."
  ch "INSERT INTO $KDBQ.beer_events VALUES
    ('Chimay',      'BE', 12.5, now()),
    ('Pilsner Urquell', 'CZ', 20.0, now()),
    ('Weizen',      'DE', 15.0, now())"
  printf '%s   waiting a few seconds for the consumer ...%s\n' "$DIM" "$RST"; sleep "${KAFKA_WAIT:-8}"
  note "... and the materialized view consumes them into MergeTree:"
  ch "SELECT * FROM default.beer_events_local ORDER BY sold_at"
}

s_summary() {
  echo
  info "Demo 3 finished. The services keep running and cost money:  ./demo3_aiven.sh cleanup"
}

# ---- commands --------------------------------------------------------------------
case "$CMD" in
  status)
    [ -n "${AIVEN_PROJECT:-}" ] || die "AIVEN_PROJECT is not set"
    export AIVEN_PROJECT
    avn service list --format '{service_name}  {service_type}  {plan}  {state}  {cloud_name}'
    exit 0 ;;

  cleanup)
    [ -n "${AIVEN_PROJECT:-}" ] || die "AIVEN_PROJECT is not set"
    export AIVEN_PROJECT
    need_cmd avn "python3 -m pip install --user aiven-client"
    if [ "${DEMO_YES:-0}" != 1 ] && [ "$DEMO_AUTO" != 1 ]; then
      printf '%sTerminate %s, %s and %s in project %s? [y/N] %s' "$YEL" "$AIVEN_PG_NAME" "$AIVEN_CH_NAME" "$AIVEN_KAFKA_NAME" "$AIVEN_PROJECT" "$RST"
      read -r ans </dev/tty || ans=n
      case "$ans" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac
    fi
    if [ -f "$TF_DIR/terraform.tfstate" ] && command -v terraform >/dev/null 2>&1; then
      tf_env; info "Terraform state found: terraform destroy"
      terraform -chdir="$TF_DIR" destroy -input=false -auto-approve
    fi
    terminate_services
    info "Done."
    exit 0 ;;

  prepare)
    DEMO_AUTO=1
    banner "Demo 3 - prepare" "creating services and data in the background of your talk"
    preflight
    [ "$RECREATE" = 1 ] && terminate_services
    if [ "$MODE" = terraform ]; then tf_env; s_create_tf; else s_create_cli; fi
    s_seed
    info "Prepared. Run ./demo3_aiven.sh for the live part."
    exit 0 ;;

  run)
    banner "Demo 3 - Aiven platform" "avn CLI ($MODE mode)   project: ${AIVEN_PROJECT:-?}   $OS_PRETTY"
    preflight
    [ "$RECREATE" = 1 ] && terminate_services
    reset_demo_objects
    s_context
    if [ "$MODE" = terraform ]; then tf_env; s_create_tf; else s_create_cli; fi
    s_seed
    s_integrate_pg
    s_query_pg
    s_local_copy
    if [ "$WITH_KAFKA" = 1 ]; then s_kafka; fi
    s_summary ;;
esac
