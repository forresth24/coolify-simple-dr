#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
parse_common_args "$@"

exec > >(tee -a "$LOG_DIR/restore-test.log") 2>&1

log "Starting restore-test.sh"
ensure_dependencies
acquire_lock || exit 0
check_dns_guard
restic_env
log_runtime_context "restore-test.sh"
probe_restic_repository

rm -rf "$RESTORE_SANDBOX"
mkdir -p "$RESTORE_SANDBOX"

snapshot="$(restic snapshots --latest 1 --json | jq -r '.[0].short_id // empty')"
if [[ -z "$snapshot" ]]; then
  log "ERROR: No snapshot available for restore test"
  exit 1
fi

log "Restoring snapshot $snapshot into sandbox $RESTORE_SANDBOX"
restic restore "$snapshot" --target "$RESTORE_SANDBOX"

# Basic sanity check: restored tree has at least one item.
if [[ -z "$(find "$RESTORE_SANDBOX" -mindepth 1 -maxdepth 2 | head -n1)" ]]; then
  log "ERROR: Restore sandbox is empty"
  exit 1
fi

log "restore-test.sh passed"
log "STATUS tail -n 100 '$LOG_DIR/restore-test.log'"
log "STATUS find '$RESTORE_SANDBOX' -mindepth 1 -maxdepth 2 | head"
