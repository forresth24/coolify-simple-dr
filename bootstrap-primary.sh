#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
INSTALL_DIR="${INSTALL_DIR:-/opt/coolify-dr}"
DR_BOOTSTRAP_MODE="install-only"
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"
CRON_COMMAND="${CRON_COMMAND:-$INSTALL_DIR/backup.sh}"
LIB_FILE="${LIB_FILE:-$INSTALL_DIR/lib.sh}"

require_root_user() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[WARN] bootstrap-primary.sh needs root privileges (sudo or root account)."
    exit 1
  fi
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

main() {
  require_root_user

  echo "[INFO] Running DR bootstrap in install-only mode to reuse dr.sh flow..."
  DR_BOOTSTRAP_MODE="$DR_BOOTSTRAP_MODE" bash "$SCRIPT_DIR/dr.sh"

  validate_runtime_prereqs
  install_crontab_if_missing
  ensure_backup_cron_job
  run_first_backup_upload

  echo "[INFO] Primary bootstrap complete."
}

main "$@"
