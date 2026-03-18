#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

exec > >(tee -a "$LOG_DIR/backup.log") 2>&1

log "Starting backup.sh"
ensure_dependencies
acquire_lock || exit 0
check_dns_guard
"$SCRIPT_DIR/verify-backup.sh"
restic_env
log_runtime_context "backup.sh"

host="$(hostname -f 2>/dev/null || hostname)"
ip="$(public_ipv4)"
run_id="$(date +%Y%m%d%H%M%S)-$host"

log "Creating incremental backup to $RESTIC_REPOSITORY"
restic backup $BACKUP_TARGETS \
  --host "$host" \
  --tag "run:$run_id" \
  --tag "ip:$ip" \
  --tag "domain:$DR_DOMAIN" \
  --verbose

snapshot_metadata
log "Backup success. Last metadata written to $STATE_DIR/last-backup-meta.json"
log_post_backup_status
