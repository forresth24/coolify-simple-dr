#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/coolify-dr"
ENV_FILE="/etc/coolify-dr.env"

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl dnsutils jq restic rclone util-linux
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl bind-utils jq restic rclone util-linux
  else
    echo "Unsupported distro. Please install dependencies manually: curl dig jq restic rclone flock"
  fi
}

setup_files() {
  mkdir -p "$INSTALL_DIR" /etc/coolify-dr /var/log/coolify-dr /var/lib/coolify-dr
  cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib.sh "$INSTALL_DIR"/
  chmod +x "$INSTALL_DIR"/*.sh

  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'CONF'
DR_DOMAIN=example.com
GDRIVE_REMOTE=gdrive:coolify-dr
BACKUP_TARGETS="/data/coolify /var/lib/docker/volumes"
RESTORE_SANDBOX=/var/lib/coolify-dr/restore-sandbox
LOG_DIR=/var/log/coolify-dr
STATE_DIR=/var/lib/coolify-dr
CONF
    echo "Created $ENV_FILE. Please update values before running backup/dr."
  fi

  if [[ ! -f /etc/coolify-dr/restic-password ]]; then
    openssl rand -hex 32 >/etc/coolify-dr/restic-password
    chmod 600 /etc/coolify-dr/restic-password
  fi
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

install_deps
setup_files
install_systemd

echo "Install complete. Configure rclone remote and edit $ENV_FILE"
echo "For one-shot DR from clean host: curl -fsSL <raw-repo>/dr.sh | bash"
