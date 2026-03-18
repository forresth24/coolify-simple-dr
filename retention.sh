#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

exec > >(tee -a "$LOG_DIR/retention.log") 2>&1

log "Starting retention.sh"
ensure_dependencies
acquire_lock || exit 0
check_dns_guard
restic_env
log_runtime_context "retention.sh"

# Keep dense recent points + long-term points.
restic forget --prune \
  --keep-last 180 \
  --keep-hourly 48 \
  --keep-daily 30 \
  --keep-weekly 12 \
  --keep-monthly 12

log "retention.sh completed"
