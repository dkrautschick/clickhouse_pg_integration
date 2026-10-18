#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# cleanup.sh - remove everything the demos created on this machine
#   (stops the demo ClickHouse and the temporary PostgreSQL, deletes $WORKDIR)
#
#   --keep-binary   keep the downloaded ClickHouse binary (saves the re-download)
#   --purge-pg      also remove the PostgreSQL PACKAGES that demo 2 installed
#   --aiven         also tear down the Aiven services of demo 3
#   -y, --yes       no confirmation prompts
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

PURGE_PG=0; AIVEN=0; YES=0
for a in "$@"; do
  case "$a" in
    --keep-binary) KEEP_BINARY=1 ;;
    --purge-pg)    PURGE_PG=1 ;;
    --aiven)       AIVEN=1 ;;
    -y|--yes)      YES=1 ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
  esac
done
detect_os

info "Stopping and removing the demo ClickHouse ($CH_DIR) ..."
ch_cleanup
info "Stopping and removing the temporary PostgreSQL ($PG_DIR) ..."
pg_cleanup

if [ "$PURGE_PG" = 1 ]; then
  case "$PKG_MGR" in
    dnf|yum) cmd="$SUDO $PKG_MGR remove -y postgresql-server postgresql" ;;
    apt)     cmd="$SUDO apt-get remove -y postgresql postgresql-client" ;;
    *)       cmd="" ;;
  esac
  if [ -n "$cmd" ]; then info "Removing PostgreSQL packages: $cmd"; eval "$cmd"; fi
fi

if [ "$AIVEN" = 1 ]; then
  [ "$YES" = 1 ] && export DEMO_YES=1
  "$HERE/demo3_aiven.sh" cleanup
fi

# remove the work dir if nothing is left in it
rmdir "$WORKDIR" 2>/dev/null || true
info "Done."
