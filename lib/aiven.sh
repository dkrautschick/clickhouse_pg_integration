#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
# -----------------------------------------------------------------------------
# lib/aiven.sh - helpers shared by demo3_aiven.sh and demo3_aiven_short.sh
# (defaults, Aiven CLI helpers, preflight, maintenance). Source it after common.sh.
# -----------------------------------------------------------------------------
if [ -n "${_DEMO_AIVEN_LOADED:-}" ]; then return 0; fi
_DEMO_AIVEN_LOADED=1

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

PG_URI=""   # filled by a presented step, used by later ones
TF_DIR="$DEMO_ROOT/terraform"
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
    ch_prep "DROP VIEW IF EXISTS default.beer_sales_refresh SYNC" "DROP VIEW IF EXISTS default.beer_events_mv SYNC" \
            "DROP TABLE IF EXISTS default.beer_sales_local SYNC" "DROP TABLE IF EXISTS default.beer_events_local SYNC"
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

