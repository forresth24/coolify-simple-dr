#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
  tmpdir="$(mktemp -d)"
  echo "[INFO] Bootstrap mode: downloading scripts"
  curl -fsSL "${DR_REPO_RAW_BASE:-https://raw.githubusercontent.com/your-org/coolify-simple-dr/main}/install.sh" -o "$tmpdir/install.sh"
  bash "$tmpdir/install.sh"
  exit 0
fi

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
exec > >(tee -a "$LOG_DIR/dr.log") 2>&1

log "Starting dr.sh"
ensure_dependencies
acquire_lock || exit 0
check_dns_guard
restic_env

mkdir -p /data
log "Stopping old coolify services (if any)"
if command -v docker >/dev/null 2>&1; then
  docker ps -q | xargs -r docker stop || true
fi

snapshot="$(restic snapshots --latest 1 --json | jq -r '.[0].short_id // empty')"
if [[ -z "$snapshot" ]]; then
  log "ERROR: No snapshot found in repository"
  exit 1
fi

log "Restoring snapshot $snapshot to /"
restic restore "$snapshot" --target /

log "Restore done. Starting services safely."
"$SCRIPT_DIR/start-safe.sh"
log "DR flow complete"
