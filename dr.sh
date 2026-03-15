#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/coolify-dr}"
ENV_FILE="${ENV_FILE:-/etc/coolify-dr.env}"
DEFAULT_RAW_BASE="https://raw.githubusercontent.com/your-org/coolify-simple-dr/main"

require_root_user() {
  local context="$1"

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[WARN] $context"
    echo "[WARN] Please run this script with root privileges (sudo or root account)."
    exit 1
  fi
}

trim_trailing_slash() {
  local value="$1"
  value="${value%/}"
  printf '%s' "$value"
}

guess_raw_base() {
  local candidate=""

  if [[ -n "${DR_SCRIPT_URL:-}" ]]; then
    candidate="${DR_SCRIPT_URL%/dr.sh}"
  elif [[ -n "${BOOTSTRAP_SCRIPT_URL:-}" ]]; then
    candidate="${BOOTSTRAP_SCRIPT_URL%/dr.sh}"
  fi

  if [[ -n "$candidate" ]]; then
    trim_trailing_slash "$candidate"
    return
  fi

  trim_trailing_slash "${DR_REPO_RAW_BASE:-$DEFAULT_RAW_BASE}"
}

validate_non_empty() {
  local value="$1"
  [[ -n "${value// }" ]]
}

validate_url_base() {
  local value
  value="$(trim_trailing_slash "$1")"
  [[ "$value" =~ ^https?://[^[:space:]]+$ ]]
}

validate_domain() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$value" == *.* ]]
}

validate_gdrive_remote() {
  local value="$1"

  [[ "$value" =~ ^[A-Za-z0-9_-]+:.+ ]] || return 1

  return 0
}

prompt_until_valid() {
  local var_name="$1"
  local question="$2"
  local default_value="$3"
  local validator="$4"
  local hint="$5"
  local answer=""

  while true; do
    prompt_with_default "$var_name" "$question" "$default_value"
    answer="${!var_name}"

    if "$validator" "$answer"; then
      if [[ "$var_name" == "DR_REPO_RAW_BASE" ]]; then
        printf -v "$var_name" '%s' "$(trim_trailing_slash "$answer")"
      fi
      return
    fi

    echo "[ERROR] Invalid value for $var_name. $hint"
    if [[ ! -t 0 ]]; then
      exit 1
    fi
  done
}

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

  require_root_user "Bootstrap and install steps need write access to /etc, /opt and systemd."
  tmpdir="$(mktemp -d)"

  echo "[INFO] Bootstrap mode: preparing one-command DR"

  while true; do
    if [[ -f "$ENV_FILE" ]]; then
      echo "[INFO] Found existing env file: $ENV_FILE"
      # shellcheck source=/dev/null
      source "$ENV_FILE"
    fi

    prompt_until_valid \
      "DR_REPO_RAW_BASE" \
      "Raw base URL of this repo" \
      "$(guess_raw_base)" \
      validate_url_base \
      "Use full URL, e.g. https://raw.githubusercontent.com/<org>/<repo>/<branch>"

    prompt_until_valid \
      "DR_DOMAIN" \
      "DR domain (must point to this VPS before restore)" \
      "${DR_DOMAIN:-example.com}" \
      validate_domain \
      "Use a valid FQDN, e.g. dr.example.com"

    prompt_until_valid \
      "GDRIVE_REMOTE" \
      "Google Drive remote:path for backups" \
      "${GDRIVE_REMOTE:-gdrive:coolify-dr}" \
      validate_gdrive_remote \
      "Format must be <rclone-remote>:<path>, e.g. gdrive:coolify-dr"

    prompt_until_valid \
      "BACKUP_TARGETS" \
      "Backup targets" \
      "${BACKUP_TARGETS:-/data/coolify /var/lib/docker/volumes}" \
      validate_non_empty \
      "Provide at least one path, e.g. /data/coolify /var/lib/docker/volumes"

    cat <<SUMMARY
[INFO] Bootstrap configuration review:
  - ENV_FILE: $ENV_FILE
  - DR_REPO_RAW_BASE: $DR_REPO_RAW_BASE
  - DR_DOMAIN: $DR_DOMAIN
  - GDRIVE_REMOTE: $GDRIVE_REMOTE
  - BACKUP_TARGETS: $BACKUP_TARGETS
SUMMARY

    if [[ -t 0 ]]; then
      local confirm
      read -r -p "Continue bootstrap/install? [Y/n]: " confirm
      confirm="${confirm:-Y}"
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        break
      fi

      echo "[WARN] Confirmation rejected. Resetting bootstrap state and starting clean..."
      rm -f "$ENV_FILE"
      unset DR_REPO_RAW_BASE DR_DOMAIN GDRIVE_REMOTE BACKUP_TARGETS
      continue
    fi

    echo "[INFO] Non-interactive mode: proceeding with reviewed config."
    break
  done

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

require_root_user "DR restore mode needs root privileges for filesystem restore and service control."

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
