#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

exec > >(tee -a "$LOG_DIR/start-safe.log") 2>&1

log "Starting start-safe.sh"
ensure_dependencies
check_dns_guard

if command -v systemctl >/dev/null 2>&1; then
  systemctl start docker || true
fi

if command -v docker >/dev/null 2>&1; then
  if [[ -f /data/coolify/docker-compose.yml ]]; then
    log "Starting Coolify compose stack"
    docker compose -f /data/coolify/docker-compose.yml up -d
  else
    log "WARN: /data/coolify/docker-compose.yml missing; skip stack start"
  fi
fi

log "Safe start finished. Run backup.sh manually if you want an immediate test backup."
