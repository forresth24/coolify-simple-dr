#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
INSTALL_DIR="/opt/coolify-dr"
ENV_FILE="/etc/coolify-dr.env"
DEFAULT_RAW_BASE="https://raw.githubusercontent.com/your-org/coolify-simple-dr/main"

require_root_user() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[WARN] install.sh needs root privileges (sudo or root account)."
    exit 1
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

trim_trailing_slash() {
  local value="$1"
  value="${value%/}"
  printf '%s' "$value"
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
  [[ "$value" =~ ^[A-Za-z0-9_-]+:([^[:space:]]*)$ ]]
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

create_env_if_missing() {
  if [[ -f "$ENV_FILE" ]]; then
    return
  fi

  echo "[INFO] Missing $ENV_FILE. Please answer initial configuration questions."

  prompt_until_valid \
    "DR_REPO_RAW_BASE" \
    "Raw base URL of this repo" \
    "${DR_REPO_RAW_BASE:-$DEFAULT_RAW_BASE}" \
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
    "Format must be <rclone-remote>:<path> (path may be empty), e.g. gdrive:coolify-dr or gdrive:"

  prompt_until_valid \
    "BACKUP_TARGETS" \
    "Backup targets" \
    "${BACKUP_TARGETS:-/data/coolify /var/lib/docker/volumes}" \
    validate_non_empty \
    "Provide at least one path, e.g. /data/coolify /var/lib/docker/volumes"

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
}

install_deps() {
  local missing_pkgs=()

  have_cmd curl || missing_pkgs+=(curl)
  have_cmd dig || missing_pkgs+=(dnsutils)
  have_cmd jq || missing_pkgs+=(jq)
  have_cmd restic || missing_pkgs+=(restic)
  have_cmd rclone || missing_pkgs+=(rclone)
  have_cmd flock || missing_pkgs+=(util-linux)
  have_cmd openssl || missing_pkgs+=(openssl)

  if (( ${#missing_pkgs[@]} == 0 )); then
    echo "[INFO] Dependencies already satisfied. Skipping package installation."
    return 0
  fi

  echo "[INFO] Missing dependencies detected: ${missing_pkgs[*]}"

  if have_cmd apt-get; then
    apt-get update
    apt-get install -y "${missing_pkgs[@]}"
  elif have_cmd dnf; then
    local dnf_pkgs=()
    local pkg
    for pkg in "${missing_pkgs[@]}"; do
      if [[ "$pkg" == "dnsutils" ]]; then
        dnf_pkgs+=(bind-utils)
      else
        dnf_pkgs+=("$pkg")
      fi
    done
    dnf install -y "${dnf_pkgs[@]}"
  else
    echo "Unsupported distro. Please install dependencies manually: curl dig jq restic rclone flock openssl"
    exit 1
  fi
}

setup_restic_password() {
  local password_file="/etc/coolify-dr/restic-password"

  if [[ -f "$password_file" ]]; then
    chmod 600 "$password_file"
    return 0
  fi

  if [[ "${DR_BOOTSTRAP_MODE:-restore}" == "primary" ]]; then
    openssl rand -hex 32 >"$password_file"
    chmod 600 "$password_file"
    echo "[INFO] Generated new restic password at $password_file for primary backups."
    return 0
  fi

  cat <<EOF
[WARN] Missing $password_file.
[WARN] Restore mode will fail with 'Fatal: wrong password or no key found' unless you copy the existing restic password from the primary server.
[WARN] Copy the original password into $password_file, chmod 600 it, then re-run restore.
EOF
}

setup_files() {
  mkdir -p "$INSTALL_DIR" /etc/coolify-dr /var/log/coolify-dr /var/lib/coolify-dr
  cp "$SCRIPT_DIR"/*.sh "$INSTALL_DIR"/
  chmod +x "$INSTALL_DIR"/*.sh

  create_env_if_missing
  setup_restic_password
}

install_systemd() {
  cat >/etc/systemd/system/coolify-dr-backup.service <<'UNIT'
[Unit]
Description=Coolify DR incremental backup

[Service]
Type=oneshot
ExecStart=/opt/coolify-dr/backup.sh
UNIT

  cat >/etc/systemd/system/coolify-dr-backup.timer <<'UNIT'
[Unit]
Description=Run Coolify DR backup every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  cat >/etc/systemd/system/coolify-dr-retention.service <<'UNIT'
[Unit]
Description=Coolify DR retention

[Service]
Type=oneshot
ExecStart=/opt/coolify-dr/retention.sh
UNIT

  cat >/etc/systemd/system/coolify-dr-retention.timer <<'UNIT'
[Unit]
Description=Run Coolify DR retention hourly

[Timer]
OnBootSec=5m
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  cat >/etc/systemd/system/coolify-dr-restore-test.service <<'UNIT'
[Unit]
Description=Coolify DR restore sandbox self-test

[Service]
Type=oneshot
ExecStart=/opt/coolify-dr/restore-test.sh
UNIT

  cat >/etc/systemd/system/coolify-dr-restore-test.timer <<'UNIT'
[Unit]
Description=Run Coolify DR restore self-test every 6 hours

[Timer]
OnBootSec=10m
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now coolify-dr-backup.timer coolify-dr-retention.timer coolify-dr-restore-test.timer
}

require_root_user
install_deps
setup_files
install_systemd

echo "Install complete. Ensure rclone remote is configured and verify $ENV_FILE"
echo "Google Drive OAuth: run 'rclone config' (interactive)."
echo "Headless option: run 'rclone authorize \"drive\"' on a machine with browser, then paste token during 'rclone config' on this host."
echo "Tip: run 'rclone config file' to confirm config path, then ensure that file contains your remote section."
echo 'For one-shot DR from clean host: curl -fsSL <raw-repo>/coolify-dr.sh | DR_SCRIPT_URL="<raw-repo>/coolify-dr.sh" DR_BOOTSTRAP_MODE=restore bash'
