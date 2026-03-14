#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/coolify-dr}"
ENV_FILE="${ENV_FILE:-/etc/coolify-dr.env}"
DEFAULT_RAW_BASE="https://raw.githubusercontent.com/your-org/coolify-simple-dr/main"

prompt_with_default() {
  local var_name="$1"
  local question="$2"
  local default_value="$3"
  local current_value="${!var_name:-}"
  local resolved_default="$default_value"
  local answer

  if [[ -n "$current_value" ]]; then
    resolved_default="$current_value"
  fi

  if [[ -t 0 ]]; then
    read -r -p "$question [$resolved_default]: " answer
    answer="${answer:-$resolved_default}"
    printf -v "$var_name" '%s' "$answer"
  else
    printf -v "$var_name" '%s' "$resolved_default"
  fi
}

bootstrap_download_and_install() {
  local tmpdir required_files file
  tmpdir="$(mktemp -d)"

  echo "[INFO] Bootstrap mode: preparing one-command DR"

  prompt_with_default "DR_REPO_RAW_BASE" "Raw base URL of this repo" "${DR_REPO_RAW_BASE:-$DEFAULT_RAW_BASE}"
  prompt_with_default "DR_DOMAIN" "DR domain (must point to this VPS before restore)" "${DR_DOMAIN:-example.com}"
  prompt_with_default "GDRIVE_REMOTE" "Google Drive remote:path for backups" "${GDRIVE_REMOTE:-gdrive:coolify-dr}"
  prompt_with_default "BACKUP_TARGETS" "Backup targets" "${BACKUP_TARGETS:-/data/coolify /var/lib/docker/volumes}"

  required_files=(
    lib.sh
    backup.sh
    retention.sh
    verify-backup.sh
    restore-test.sh
    start-safe.sh
    install.sh
    dr.sh
  )

  echo "[INFO] Downloading scripts from: $DR_REPO_RAW_BASE"
  for file in "${required_files[@]}"; do
    curl -fsSL "$DR_REPO_RAW_BASE/$file" -o "$tmpdir/$file"
  done
  chmod +x "$tmpdir"/*.sh

  mkdir -p "$(dirname "$ENV_FILE")"
  cat >"$ENV_FILE" <<CONF
DR_REPO_RAW_BASE=$DR_REPO_RAW_BASE
DR_DOMAIN=$DR_DOMAIN
GDRIVE_REMOTE=$GDRIVE_REMOTE
BACKUP_TARGETS="$BACKUP_TARGETS"
RESTORE_SANDBOX=/var/lib/coolify-dr/restore-sandbox
LOG_DIR=/var/log/coolify-dr
STATE_DIR=/var/lib/coolify-dr
CONF

  echo "[INFO] Saved config to $ENV_FILE"
  bash "$tmpdir/install.sh"

  echo "[INFO] Running DR restore workflow"
  exec "$INSTALL_DIR/dr.sh"
}

if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
  bootstrap_download_and_install
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
