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
: "${GDRIVE_REMOTE:?Set GDRIVE_REMOTE in $ENV_FILE (e.g. gdrive:coolify-dr or gdrive:)}"

GDRIVE_REMOTE_NAME="${GDRIVE_REMOTE%%:*}"
GDRIVE_REMOTE_PATH="${GDRIVE_REMOTE#*:}"
if [[ "$GDRIVE_REMOTE_PATH" == "$GDRIVE_REMOTE" ]]; then
  GDRIVE_REMOTE_PATH=""
fi

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

log_kv() {
  local key="$1"
  local value="$2"
  log "ENV ${key}=${value}"
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

rclone_config_section_value() {
  local remote_name="$1"
  local key="$2"
  local config_path="${RCLONE_CONFIG:-}"

  [[ -n "$config_path" && -f "$config_path" ]] || return 1

  awk -v section="$remote_name" -v key="$key" '
    $0 == "[" section "]" { in_section=1; next }
    /^\[/ { in_section=0 }
    in_section {
      split($0, parts, "=")
      current_key=parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_key)
      if (current_key == key) {
        value=substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$config_path"
}

rclone_remote_has_root_folder_id() {
  local root_folder_id=""
  root_folder_id="$(rclone_config_section_value "$GDRIVE_REMOTE_NAME" "root_folder_id" || true)"
  [[ -n "$root_folder_id" ]]
}

effective_gdrive_remote() {
  if [[ -n "$GDRIVE_REMOTE_PATH" && "$GDRIVE_REMOTE_PATH" != */* ]] && rclone_remote_has_root_folder_id; then
    printf '%s:' "$GDRIVE_REMOTE_NAME"
    return 0
  fi

  printf '%s' "$GDRIVE_REMOTE"
}

restic_repository_for_domain_folder() {
  local domain_folder="$1"
  local remote_base=""

  remote_base="$(effective_gdrive_remote)"
  printf 'rclone:%s/%s/restic' "$remote_base" "$domain_folder"
}

probe_restic_repository() {
  local domain_folder="${RESTIC_DOMAIN_FOLDER:-$DR_DOMAIN}"
  local repository="${RESTIC_REPOSITORY:-}"
  local probe_output=""

  if [[ -z "$repository" ]]; then
    repository="$(restic_repository_for_domain_folder "$domain_folder")"
  fi

  if probe_output="$(restic --repo "$repository" cat config 2>&1 >/dev/null)"; then
    return 0
  fi

  if [[ "$probe_output" == *"unsupported repository version"* ]]; then
    log "ERROR: Restic cannot open '$repository' because this host's restic binary is too old for that repository format."
    log "ERROR: Install the same or a newer restic version than the primary backup host, then retry."
    return 20
  fi

  if [[ "$probe_output" == *"wrong password or no key found"* ]]; then
    log "ERROR: Restic password does not match repository '$repository'."
    log "ERROR: Copy the original password file from the primary host or export RESTIC_PASSWORD before retrying."
    return 21
  fi

  if [[ "$probe_output" == *"Is there a repository at the following location?"* ]] || [[ "$probe_output" == *"config file does not exist"* ]]; then
    return 10
  fi

  printf '%s\n' "$probe_output" >&2
  return 1
}

ensure_restic_password_ready() {
  if [[ -n "${RESTIC_PASSWORD:-}" ]]; then
    return 0
  fi

  if [[ ! -f "$RESTIC_PASSWORD_FILE" ]]; then
    log "ERROR: Restic password file not found at '$RESTIC_PASSWORD_FILE'."
    log "ERROR: Copy the original password from the primary server or export RESTIC_PASSWORD before running restore/backup."
    return 1
  fi

  if [[ ! -r "$RESTIC_PASSWORD_FILE" ]]; then
    log "ERROR: Restic password file is not readable at '$RESTIC_PASSWORD_FILE'."
    return 1
  fi
}

restic_password_source() {
  if [[ -n "${RESTIC_PASSWORD:-}" ]]; then
    printf '%s' 'env:RESTIC_PASSWORD'
    return 0
  fi

  printf '%s' "$RESTIC_PASSWORD_FILE"
}

restic_env() {
  local domain_folder="${1:-${RESTIC_DOMAIN_FOLDER:-$DR_DOMAIN}}"

  ensure_gdrive_remote_configured || return 1
  ensure_restic_password_ready || return 1
  RESTIC_REPOSITORY="$(restic_repository_for_domain_folder "$domain_folder")"
  export RESTIC_DOMAIN_FOLDER="$domain_folder"
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
}

log_runtime_context() {
  local action="${1:-runtime}"
  local password_source=""

  password_source="$(restic_password_source)"
  log "Runtime context for ${action}:"
  log_kv "ENV_FILE" "$ENV_FILE"
  log_kv "DR_DOMAIN" "$DR_DOMAIN"
  log_kv "GDRIVE_REMOTE" "$GDRIVE_REMOTE"
  log_kv "RCLONE_CONFIG" "${RCLONE_CONFIG:-<unresolved>}"
  log_kv "RESTIC_DOMAIN_FOLDER" "${RESTIC_DOMAIN_FOLDER:-$DR_DOMAIN}"
  log_kv "RESTIC_REPOSITORY" "${RESTIC_REPOSITORY:-<unresolved>}"
  log_kv "RESTIC_PASSWORD_SOURCE" "$password_source"
  log_kv "BACKUP_TARGETS" "$BACKUP_TARGETS"
  log_kv "LOG_DIR" "$LOG_DIR"
  log_kv "STATE_DIR" "$STATE_DIR"
  log_kv "RESTORE_SANDBOX" "$RESTORE_SANDBOX"
  log_kv "LOCK_FILE" "$LOCK_FILE"
}

log_post_backup_status() {
  log "Status commands to inspect this backup:"
  log "STATUS tail -n 100 '$LOG_DIR/backup.log'"
  log "STATUS tail -n 100 '$LOG_DIR/verify-backup.log'"
  log "STATUS cat '$STATE_DIR/last-backup-meta.json'"
  log "STATUS restic --repo '$RESTIC_REPOSITORY' snapshots --latest 5"
  log "STATUS restic --repo '$RESTIC_REPOSITORY' stats latest"
  log "STATUS rclone lsd '$(effective_gdrive_remote)'"
}

log_restore_status() {
  log "Status commands to inspect restore state:"
  log "STATUS tail -n 100 '$LOG_DIR/dr.log'"
  log "STATUS tail -n 100 '$LOG_DIR/start-safe.log'"
  log "STATUS restic --repo '$RESTIC_REPOSITORY' snapshots --latest 5"
  log "STATUS docker ps -a"
  log "STATUS systemctl status docker --no-pager"
}

list_backup_domain_folders() {
  local remote_base=""

  remote_base="$(effective_gdrive_remote)"
  rclone lsf "$remote_base" --dirs-only | sed 's:/$::' | awk 'NF > 0'
}

rclone_config_file_path() {
  local raw_line
  local -a candidates=()
  local home_dir="${HOME:-}"
  local sudo_home=""
  local candidate=""

  raw_line="$({
    rclone config file 2>/dev/null || true
  } | awk '
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
  if [[ -n "$raw_line" && -f "$raw_line" ]]; then
    printf '%s' "$raw_line"
    return 0
  fi

  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    candidates+=("$RCLONE_CONFIG")
  fi

  if [[ -n "$home_dir" ]]; then
    candidates+=(
      "$home_dir/.config/rclone/rclone.conf"
      "$home_dir/.rclone.conf"
    )
  fi

  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [[ -n "$sudo_home" ]]; then
      candidates+=(
        "$sudo_home/.config/rclone/rclone.conf"
        "$sudo_home/.rclone.conf"
      )
    fi
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_gdrive_remote_configured() {
  local remote_name config_path

  remote_name="$GDRIVE_REMOTE_NAME"
  config_path="$(rclone_config_file_path || true)"

  if [[ -z "$config_path" ]]; then
    log "ERROR: Unable to determine an rclone config file path."
    log "ERROR: Configure Google Drive with 'rclone config', then verify using 'rclone listremotes'."
    return 1
  fi

  if [[ ! -f "$config_path" ]]; then
    log "ERROR: rclone config file not found at '$config_path'."
    log "ERROR: Create or copy config first (for example from desktop via 'rclone config file')."
    return 1
  fi

  export RCLONE_CONFIG="$config_path"

  if ! grep -Fqx "[$remote_name]" "$config_path"; then
    log "ERROR: rclone remote '$remote_name' is not configured in '$config_path'."
    log "ERROR: Run 'rclone config' (interactive), or use headless OAuth: 'rclone authorize "drive"' on a machine with browser, then paste token on VPS during 'rclone config'."
    return 1
  fi
}

ensure_dependencies() {
  local deps=(curl dig flock jq restic rclone tar)
  local missing=()
  local d
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
