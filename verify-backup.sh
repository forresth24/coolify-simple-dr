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

if probe_restic_repository; then
  probe_status=0
else
  probe_status=$?
fi

if [[ $probe_status -eq 10 ]]; then
  log "Restic repository not initialized yet."
  restic init
elif [[ $probe_status -ne 0 ]]; then
  exit $probe_status
fi

restic_check_mode="${RESTIC_CHECK_MODE:-quick}"
case "$restic_check_mode" in
  quick)
    log "Running quick repository access check"
    restic snapshots --last 1 >/dev/null
    ;;
  full)
    log "Running full metadata consistency check"
    restic check --with-cache >/dev/null
    ;;
  *)
    log "ERROR: Unsupported RESTIC_CHECK_MODE='$restic_check_mode'. Use 'quick' or 'full'."
    exit 1
    ;;
esac

log "verify-backup.sh completed successfully"
