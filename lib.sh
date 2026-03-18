#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
ENV_FILE="${ENV_FILE:-/etc/coolify-dr.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

: "${DR_DOMAIN:?Set DR_DOMAIN in $ENV_FILE}"
: "${GDRIVE_REMOTE:?Set GDRIVE_REMOTE in $ENV_FILE (e.g. gdrive:coolify-dr)}"

GDRIVE_REMOTE_NAME="${GDRIVE_REMOTE%%:*}"

LOG_DIR="${LOG_DIR:-/var/log/coolify-dr}"
STATE_DIR="${STATE_DIR:-/var/lib/coolify-dr}"
BACKUP_TARGETS="${BACKUP_TARGETS:-/data/coolify /var/lib/docker/volumes}"
DEFAULT_RESTIC_DOMAIN_FOLDER="${RESTIC_DOMAIN_FOLDER:-$DR_DOMAIN}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:${GDRIVE_REMOTE}/${DEFAULT_RESTIC_DOMAIN_FOLDER}/restic}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/coolify-dr/restic-password}"
RESTORE_SANDBOX="${RESTORE_SANDBOX:-/var/lib/coolify-dr/restore-sandbox}"
LOCK_FILE="${LOCK_FILE:-/var/run/coolify-dr.lock}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() {
  local msg="$*"
  printf '[%s] %s\n' "$(date -Iseconds)" "$msg"
}

public_ipv4() {
  local ip
  ip="$(curl -4fsS --max-time 5 https://ifconfig.co 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$ip"
}

dns_ipv4() {
  dig +short A "$DR_DOMAIN" | head -n1
}

check_dns_guard() {
  local local_ip dns_ip
  local_ip="$(public_ipv4)"
  dns_ip="$(dns_ipv4)"

  if [[ -z "$dns_ip" ]]; then
    log "ERROR: DNS lookup failed for ${DR_DOMAIN}. Refusing to continue."
    return 1
  fi

  if [[ "${FORCE_DNS_BYPASS:-0}" == "1" ]]; then
    log "WARN: FORCE_DNS_BYPASS=1 enabled, skipping split-brain DNS guard."
    return 0
  fi

  if [[ "$local_ip" != "$dns_ip" ]]; then
    log "ERROR: Split-brain guard blocked action. DNS(${DR_DOMAIN})=$dns_ip but local=$local_ip"
    return 1
  fi

  log "DNS guard passed: ${DR_DOMAIN} -> ${dns_ip} == local host"
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "INFO: Another coolify-dr process is already running."
    return 1
  fi
}

restic_repository_for_domain_folder() {
  local domain_folder="$1"
  printf 'rclone:%s/%s/restic' "$GDRIVE_REMOTE" "$domain_folder"
}

restic_env() {
  local domain_folder="${1:-${RESTIC_DOMAIN_FOLDER:-$DR_DOMAIN}}"

  ensure_gdrive_remote_configured || return 1
  RESTIC_REPOSITORY="$(restic_repository_for_domain_folder "$domain_folder")"
  export RESTIC_DOMAIN_FOLDER="$domain_folder"
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
}

list_backup_domain_folders() {
  rclone lsf "$GDRIVE_REMOTE" --dirs-only | sed 's:/$::' | awk 'NF > 0'
}


rclone_config_file_path() {
  local raw_line

  raw_line="$(
    rclone config file 2>/dev/null | awk '
      /stored at:[[:space:]]*$/ {
        if (getline > 0) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
          print
          exit
        }
      }
      /stored at:[[:space:]]+/ {
        sub(/^.*stored at:[[:space:]]+/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        print
        exit
      }
    '
  )"
  if [[ -n "$raw_line" ]]; then
    printf '%s' "$raw_line"
    return 0
  fi

  return 1
}

ensure_gdrive_remote_configured() {
  local remote_name config_path

  remote_name="$GDRIVE_REMOTE_NAME"
  config_path="$(rclone_config_file_path || true)"

  if [[ -z "$config_path" ]]; then
    log "ERROR: Unable to determine rclone config file path via 'rclone config file'."
    log "ERROR: Configure Google Drive with 'rclone config', then verify using 'rclone listremotes'."
    return 1
  fi

  if [[ ! -f "$config_path" ]]; then
    log "ERROR: rclone config file not found at '$config_path'."
    log "ERROR: Create or copy config first (for example from desktop via 'rclone config file')."
    return 1
  fi

  if ! grep -Fqx "[$remote_name]" "$config_path"; then
    log "ERROR: rclone remote '$remote_name' is not configured in '$config_path'."
    log "ERROR: Run 'rclone config' (interactive), or use headless OAuth: 'rclone authorize \"drive\"' on a machine with browser, then paste token on VPS during 'rclone config'."
    return 1
  fi
}


ensure_dependencies() {
  local deps=(curl dig flock jq restic rclone tar)
  local missing=()
  for d in "${deps[@]}"; do
    if ! command -v "$d" >/dev/null 2>&1; then
      missing+=("$d")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    log "ERROR: Missing dependencies: ${missing[*]}"
    return 1
  fi
}

snapshot_metadata() {
  local host ip stamp
  host="$(hostname -f 2>/dev/null || hostname)"
  ip="$(public_ipv4)"
  stamp="$(date -Iseconds)"
  cat >"$STATE_DIR/last-backup-meta.json" <<META
{
  "timestamp": "$stamp",
  "hostname": "$host",
  "public_ip": "$ip",
  "domain": "$DR_DOMAIN",
  "repository": "$RESTIC_REPOSITORY"
}
META
}
