#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/coolify-dr}"
ENV_FILE="${ENV_FILE:-/etc/coolify-dr.env}"
DEFAULT_RAW_BASE="https://raw.githubusercontent.com/your-org/coolify-simple-dr/main"
DR_BOOTSTRAP_MODE="${DR_BOOTSTRAP_MODE:-restore}"
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"
CRON_COMMAND="${CRON_COMMAND:-$INSTALL_DIR/backup.sh}"
LIB_FILE="${LIB_FILE:-$INSTALL_DIR/lib.sh}"

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
    candidate="${DR_SCRIPT_URL%/coolify-dr.sh}"
    candidate="${candidate%/dr.sh}"
  elif [[ -n "${BOOTSTRAP_SCRIPT_URL:-}" ]]; then
    candidate="${BOOTSTRAP_SCRIPT_URL%/coolify-dr.sh}"
    candidate="${candidate%/dr.sh}"
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

read_parent_env_var() {
  local var_name="$1"
  local parent_pid="${PPID:-}"
  local entry=""

  [[ -n "$parent_pid" ]] || return 1
  [[ -r "/proc/$parent_pid/environ" ]] || return 1

  while IFS= read -r -d '' entry; do
    if [[ "$entry" == "$var_name="* ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done </proc/"$parent_pid"/environ

  return 1
}

resolve_restore_domain_folder_override() {
  local folder="${DR_RESTORE_DOMAIN_FOLDER:-}"

  if [[ -n "$folder" ]]; then
    printf '%s' "$folder"
    return 0
  fi

  if [[ -n "${SUDO_USER:-}" ]]; then
    folder="$(read_parent_env_var DR_RESTORE_DOMAIN_FOLDER || true)"
    if [[ -n "$folder" ]]; then
      printf '%s' "$folder"
      return 0
    fi
  fi

  return 1
}

choose_restore_domain_folder() {
  local default_folder="$DR_DOMAIN"
  local selected_folder=""
  local folder_override=""

  folder_override="$(resolve_restore_domain_folder_override || true)"
  if [[ -n "$folder_override" ]]; then
    printf '%s' "$folder_override"
    return 0
  fi

  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    printf '%s' "$default_folder"
    return 0
  fi

  local folders=()
  local folder
  while IFS= read -r folder; do
    folders+=("$folder")
  done < <(list_backup_domain_folders || true)

  echo "[INFO] Backup domain folders on Google Drive (${GDRIVE_REMOTE}):" >&2
  if (( ${#folders[@]} == 0 )); then
    echo "  (empty - no folders found, defaulting to DR_DOMAIN)" >&2
    printf '%s' "$default_folder"
    return 0
  fi

  local i=1
  for folder in "${folders[@]}"; do
    echo "  [$i] $folder" >&2
    ((i++))
  done

  local prompt_stream="/dev/tty"
  [[ -t 0 ]] && prompt_stream="/dev/stdin"

  local answer
  read -r -p "Choose restore folder by number or name [$default_folder]: " answer <"$prompt_stream" >&2
  answer="${answer:-$default_folder}"

  if [[ "$answer" =~ ^[0-9]+$ ]]; then
    local idx=$((answer - 1))
    if (( idx >= 0 && idx < ${#folders[@]} )); then
      selected_folder="${folders[$idx]}"
    fi
  fi

  if [[ -z "$selected_folder" ]]; then
    selected_folder="$answer"
  fi

  printf '%s' "$selected_folder"
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
    if [[ ! -t 0 && ! -r /dev/tty ]]; then
      exit 1
    fi
  done
}



have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_crontab_if_missing() {
  if have_cmd crontab; then
    return 0
  fi

  echo "[INFO] 'crontab' command not found. Installing cron package..."
  if have_cmd apt-get; then
    apt-get update
    apt-get install -y cron
  elif have_cmd dnf; then
    dnf install -y cronie
  else
    echo "[ERROR] Unsupported distro. Install cron/cronie manually and retry."
    exit 1
  fi

  if ! have_cmd crontab; then
    echo "[ERROR] Failed to install crontab command."
    exit 1
  fi
}

ensure_backup_cron_job() {
  local current_crontab=""
  local temp_file

  if current_crontab="$(crontab -l 2>/dev/null)"; then
    :
  else
    current_crontab=""
  fi

  if printf '%s\n' "$current_crontab" | grep -Fq "$CRON_COMMAND"; then
    echo "[INFO] Backup cron job already exists. Skipping crontab update."
    return 0
  fi

  temp_file="$(mktemp)"
  {
    if [[ -n "${current_crontab//[[:space:]]/}" ]]; then
      printf '%s\n' "$current_crontab"
    fi
    echo "# coolify-dr primary backup upload"
    echo "$CRON_SCHEDULE $CRON_COMMAND >> /var/log/coolify-dr/cron-backup.log 2>&1"
  } >"$temp_file"

  crontab "$temp_file"
  rm -f "$temp_file"

  echo "[INFO] Installed backup cron job: $CRON_SCHEDULE $CRON_COMMAND"
}

validate_runtime_prereqs() {
  if [[ ! -f "$LIB_FILE" ]]; then
    echo "[ERROR] Missing library file: $LIB_FILE"
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$LIB_FILE"

  ensure_dependencies
  ensure_gdrive_remote_configured
  check_dns_guard
  restic_env
}

run_first_backup_upload() {
  if [[ ! -x "$CRON_COMMAND" ]]; then
    echo "[ERROR] Backup script not found or not executable: $CRON_COMMAND"
    exit 1
  fi

  echo "[INFO] Running first backup upload to remote now..."
  "$CRON_COMMAND"
}

run_primary_bootstrap_workflow() {
  echo "[INFO] Running primary mode: install + cron + first upload"
  validate_runtime_prereqs
  install_crontab_if_missing
  ensure_backup_cron_job
  run_first_backup_upload
  echo "[INFO] Primary bootstrap complete."
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
  elif [[ -r /dev/tty ]]; then
    read -r -p "$question [$resolved_default]: " answer </dev/tty
    answer="${answer:-$resolved_default}"
    printf -v "$var_name" '%s' "$answer"
  else
    printf -v "$var_name" '%s' "$resolved_default"
  fi
}

bootstrap_has_existing_values() {
  local key

  for key in DR_REPO_RAW_BASE DR_DOMAIN GDRIVE_REMOTE BACKUP_TARGETS; do
    if [[ -n "${!key:-}" ]]; then
      return 0
    fi
  done

  return 1
}

confirm_bootstrap_overwrite_existing_env() {
  local overwrite=""

  cat <<SUMMARY
[INFO] Existing bootstrap values detected in $ENV_FILE:
  - DR_REPO_RAW_BASE: ${DR_REPO_RAW_BASE:-<empty>}
  - DR_DOMAIN: ${DR_DOMAIN:-<empty>}
  - GDRIVE_REMOTE: ${GDRIVE_REMOTE:-<empty>}
  - BACKUP_TARGETS: ${BACKUP_TARGETS:-<empty>}
SUMMARY

  if [[ -t 0 ]]; then
    read -r -p "Overwrite these values and prompt again? [y/N]: " overwrite
  elif [[ -r /dev/tty ]]; then
    read -r -p "Overwrite these values and prompt again? [y/N]: " overwrite </dev/tty
  else
    echo "[INFO] Non-interactive mode: keeping existing env values."
    return 1
  fi

  if [[ "$overwrite" =~ ^[Yy]$ ]]; then
    unset DR_REPO_RAW_BASE DR_DOMAIN GDRIVE_REMOTE BACKUP_TARGETS
    return 0
  fi

  echo "[INFO] Keeping existing env values as prompt defaults."
  return 1
}

bootstrap_download_and_install() {
  local tmpdir required_files file

  require_root_user "Bootstrap and install steps need write access to /etc, /opt and systemd."
  tmpdir="$(mktemp -d)"

  echo "[INFO] Bootstrap mode: preparing one-command DR"

  while true; do
    local should_prompt_env="yes"

    if [[ -f "$ENV_FILE" ]]; then
      echo "[INFO] Found existing env file: $ENV_FILE"
      # shellcheck source=/dev/null
      source "$ENV_FILE"
      if bootstrap_has_existing_values; then
        if ! confirm_bootstrap_overwrite_existing_env; then
          should_prompt_env="no"
        fi
      fi
    fi

    if [[ "$should_prompt_env" == "yes" ]]; then
      prompt_until_valid \
        "DR_REPO_RAW_BASE" \
        "Raw base URL of this repo" \
        "$(guess_raw_base)" \
        validate_url_base \
        "Use full URL, e.g. https://raw.githubusercontent.com/<org>/<repo>/<branch>"

      prompt_until_valid \
        "DR_DOMAIN" \
        "DR domain (must point to this VPS before restore)" \
        "${DR_DOMAIN:-}" \
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
    fi

    cat <<SUMMARY
[INFO] Bootstrap configuration review:
  - ENV_FILE: $ENV_FILE
  - DR_REPO_RAW_BASE: $DR_REPO_RAW_BASE
  - DR_DOMAIN: $DR_DOMAIN
  - GDRIVE_REMOTE: $GDRIVE_REMOTE
  - BACKUP_TARGETS: $BACKUP_TARGETS
SUMMARY

    if [[ -t 0 || -r /dev/tty ]]; then
      local confirm
      if [[ -t 0 ]]; then
        read -r -p "Continue bootstrap/install? [Y/n]: " confirm
      else
        read -r -p "Continue bootstrap/install? [Y/n]: " confirm </dev/tty
      fi
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
    coolify-dr.sh
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

  if [[ "$DR_BOOTSTRAP_MODE" == "install-only" ]]; then
    echo "[INFO] DR_BOOTSTRAP_MODE=install-only set. Skipping restore workflow."
    exit 0
  fi

  if [[ "$DR_BOOTSTRAP_MODE" == "primary" ]]; then
    run_primary_bootstrap_workflow
    exit 0
  fi

  echo "[INFO] Running DR restore workflow"
  exec "$INSTALL_DIR/coolify-dr.sh"
}

if [[ -z "${BASH_SOURCE:-}" ]]; then
  bootstrap_download_and_install
  exit 0
fi

SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"

if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
  bootstrap_download_and_install
  exit 0
fi

require_root_user "DR restore mode needs root privileges for filesystem restore and service control."

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
exec > >(tee -a "$LOG_DIR/dr.log") 2>&1

log "Starting coolify-dr.sh"
ensure_dependencies
acquire_lock || exit 0
check_dns_guard

restore_domain_folder="$(choose_restore_domain_folder)"
log "Selected restore domain folder: $restore_domain_folder"
restic_env "$restore_domain_folder"

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
