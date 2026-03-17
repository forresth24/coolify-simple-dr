#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

exec > >(tee -a "$LOG_DIR/verify-backup.log") 2>&1

log "Starting verify-backup.sh"
ensure_dependencies
check_dns_guard
restic_env

for p in $BACKUP_TARGETS; do
  if [[ ! -e "$p" ]]; then
    log "ERROR: Backup target missing: $p"
    exit 1
  fi
  if [[ ! -r "$p" ]]; then
    log "ERROR: Backup target not readable: $p"
    exit 1
  fi
  log "Verified backup target: $p"
done

if ! restic cat config >/dev/null 2>&1; then
  log "Restic repository not initialized yet."
  restic init
fi

log "Running metadata consistency check"
restic check --with-cache >/dev/null
log "verify-backup.sh completed successfully"
