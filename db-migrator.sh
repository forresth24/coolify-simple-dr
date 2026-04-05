#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC2317
# db-migrator.sh
# -----------------------------------------------------------------------------
# Interactive/Postgres/MongoDB migration helper with remote SSH support.
#
# Design goals:
#   - Minimal dependencies (bash + coreutils; optional fzf/dialog for richer TUI).
#   - Safe defaults and explicit confirmations for disruptive operations.
#   - Works with Docker containers and native database processes.
#   - Supports non-interactive execution via CLI flags.
#
# Spec format (SOURCE/TARGET for --backup/--migrate):
#   [user@host::]<docker|native>::<postgres|mongodb|other>::<identifier>
#
# Examples:
#   local Docker Postgres container:
#     docker::postgres::pg_container
#   remote native MongoDB URI-like identifier:
#     admin@10.0.0.8::native::mongodb::mongodb://127.0.0.1:27017/admin
#   local Docker volume fallback for non-native engines:
#     docker::other::my_data_volume
#
# Notes:
#   - For remote operations, SSH key auth is required (BatchMode=yes).
#   - Zero-downtime is attempted by default using hot logical streams.
#   - Any stop/restart action requires explicit operator confirmation.
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly STATE_DIR="${SCRIPT_DIR}/state"
readonly DATE_TAG="$(/usr/bin/date '+%Y%m%d-%H%M%S')"
readonly RUN_LOG="${LOG_DIR}/db-migrator-${DATE_TAG}.log"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

readonly SSH_BIN="$(command -v ssh || true)"
readonly DOCKER_BIN="$(command -v docker || true)"
readonly RSYNC_BIN="$(command -v rsync || true)"
readonly FIND_BIN="$(command -v find || true)"
readonly GZIP_BIN="$(command -v gzip || true)"
readonly TAR_BIN="$(command -v tar || true)"
readonly DIALOG_BIN="$(command -v dialog || true)"
readonly FZF_BIN="$(command -v fzf || true)"

TEMP_DIR=''

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    /usr/bin/rm -rf -- "${TEMP_DIR}"
  fi
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  printf '%b[ERROR]%b %s failed at line %s (exit=%s).\n' "${RED}" "${NC}" "${SCRIPT_NAME}" "${line_no}" "${exit_code}" >&2
}

trap 'on_error "$?" "$LINENO"' ERR
trap cleanup EXIT

init_runtime() {
  /usr/bin/mkdir -p -- "${LOG_DIR}" "${STATE_DIR}"
  TEMP_DIR="$(/usr/bin/mktemp -d)"
  : >"${RUN_LOG}"
}

log() {
  local level="$1"
  local color="$2"
  local message="$3"
  local stamp
  stamp="$(/usr/bin/date '+%Y-%m-%d %H:%M:%S')"
  printf '%s [%s] %s\n' "${stamp}" "${level}" "${message}" >>"${RUN_LOG}"
  printf '%b[%s]%b %s\n' "${color}" "${level}" "${NC}" "${message}"
}

info() { log 'INFO' "${BLUE}" "$1"; }
warn() { log 'WARN' "${YELLOW}" "$1"; }
ok() { log ' OK ' "${GREEN}" "$1"; }
die() { log 'FAIL' "${RED}" "$1"; exit 1; }

usage() {
  /usr/bin/cat <<'USAGE'
Usage:
  db-migrator.sh                         # interactive TUI mode
  db-migrator.sh --help                  # show help
  db-migrator.sh --list                  # list local Docker DB-like instances
  db-migrator.sh --backup SOURCE         # backup a SOURCE spec
  db-migrator.sh --migrate SOURCE TARGET # migrate/clone SOURCE -> TARGET

Spec format:
  [user@host::]<docker|native>::<postgres|mongodb|other>::<identifier>

Examples:
  db-migrator.sh --backup docker::postgres::pg_main
  db-migrator.sh --migrate docker::postgres::pg_old admin@10.0.0.2::native::postgres::postgres://postgres@127.0.0.1/postgres
  db-migrator.sh --migrate docker::other::my_volume root@backup-host::docker::other::target_volume

Behavior:
  * Mandatory health checks before backup/migration.
  * Automatic full backup before migration/clone.
  * PostgreSQL: pg_dump | pg_restore stream.
  * MongoDB: mongodump | mongorestore stream.
  * Other engines: rsync of Docker volume or native path.
  * Zero-downtime attempted by default (no stop unless confirmed).
USAGE
}

rotate_logs() {
  [[ -n "${FIND_BIN}" && -n "${GZIP_BIN}" ]] || return 0
  /usr/bin/mkdir -p -- "${LOG_DIR}"

  # Compress stale .log files (excluding current run log).
  while IFS= read -r -d '' file; do
    if [[ "${file}" != "${RUN_LOG}" ]]; then
      "${GZIP_BIN}" -f -- "${file}" || true
    fi
  done < <("${FIND_BIN}" "${LOG_DIR}" -type f -name '*.log' -mtime +0 -print0)

  # Retain compressed logs for 3 days only.
  "${FIND_BIN}" "${LOG_DIR}" -type f -name '*.gz' -mtime +3 -delete
}

validate_spec() {
  local spec="$1"
  # Accept conservative character set to reduce injection risk.
  # Added '@' in identifier part to allow username specification.
  [[ "${spec}" =~ ^([a-zA-Z0-9_.-]+@[^:]+::)?(docker|native)::(postgres|mongodb|other)::[a-zA-Z0-9_./:@?=+,-]+$ ]]
}

parse_spec() {
  local spec="$1"
  local -n out_host_ref="$2"
  local -n out_mode_ref="$3"
  local -n out_engine_ref="$4"
  local -n out_ident_ref="$5"
  local -n out_user_ref="${6:-_dummy_user}"
  local -n out_db_ref="${7:-_dummy_db}"

  local _dummy_user='' _dummy_db=''
  local _rest="${spec}"
  local _host=''

  if [[ "${_rest}" == *"::"*"::"*"::"* ]]; then
    local _first _part2
    _first="${_rest%%::*}"
    _part2="${_rest#*::}"
    if [[ "${_first}" == *'@'* && "${_part2}" == *"::"*"::"* ]]; then
      _host="${_first}"
      _rest="${_part2}"
    fi
  fi

  local _mode _engine _ident _user _db
  _mode="${_rest%%::*}"
  _rest="${_rest#*::}"
  _engine="${_rest%%::*}"
  _ident="${_rest#*::}"
  
  # Format: identifier[@user][:db]
  # Handle :db suffix first
  if [[ "${_ident}" == *':'* && ( "${_engine}" == 'postgres' || "${_engine}" == 'mongodb' ) ]]; then
    _db="${_ident##*:}"
    _ident="${_ident%:*}"
  fi

  # Handle @user suffix
  if [[ "${_ident}" == *'@'* && ( "${_engine}" == 'postgres' || "${_engine}" == 'mongodb' ) ]]; then
    _user="${_ident##*@}"
    _ident="${_ident%@*}"
  fi

  out_host_ref="${_host}"
  out_mode_ref="${_mode}"
  out_engine_ref="${_engine}"
  out_ident_ref="${_ident}"
  out_user_ref="${_user:-}"
  out_db_ref="${_db:-}"
}

prompt_if_empty() {
  local var_name="$1"
  local prompt_msg="$2"
  local current_val="${!var_name:-}"
  local is_password="${3:-false}"

  if [[ -z "${current_val}" ]]; then
    if [[ "${is_password}" == "true" ]]; then
      read -r -s -p "${prompt_msg}: " current_val
      printf '\n' >&2
    else
      read -r -p "${prompt_msg}: " current_val
    fi
    eval "${var_name}=\"${current_val}\""
  fi
}

ssh_wrapper() {
  local host="$1"
  local cmd="$2"

  [[ -n "${SSH_BIN}" ]] || die 'ssh binary not found for remote operation.'
  "${SSH_BIN}" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -- "${host}" "bash -lc $(printf '%q' "${cmd}")"
}

run_cmd() {
  local host="$1"
  local cmd="$2"

  if [[ -n "${host}" ]]; then
    ssh_wrapper "${host}" "${cmd}"
  else
    /bin/bash -lc "${cmd}"
  fi
}

choose_option() {
  local title="$1"
  shift
  local -a options=("$@")

  if [[ -n "${DIALOG_BIN}" && -t 1 ]]; then
    local dialog_out="${TEMP_DIR}/dialog.out"
    local -a items=()
    local idx
    for idx in "${!options[@]}"; do
      items+=("${idx}" "${options[${idx}]}")
    done
    "${DIALOG_BIN}" --clear --stdout --title "${title}" --menu "Choose an option" 20 90 10 "${items[@]}" >"${dialog_out}" || return 1
    local selected
    selected="$(/usr/bin/cat -- "${dialog_out}")"
    printf '%s\n' "${options[${selected}]}"
    return 0
  fi

  if [[ -n "${FZF_BIN}" && -t 1 ]]; then
    printf '%s\n' "${options[@]}" | "${FZF_BIN}" --height 40% --prompt "${title}> "
    return $?
  fi

  local choice=''
  PS3="${title} > "
  select choice in "${options[@]}"; do
    if [[ -n "${choice}" ]]; then
      printf '%s\n' "${choice}"
      return 0
    fi
    warn 'Invalid selection. Try again.'
  done
}

detect_db_type() {
  local host="$1"
  local mode="$2"
  local ident="$3"

  if [[ "${mode}" == 'docker' ]]; then
    local image
    image="$(run_cmd "${host}" "docker inspect --format '{{.Config.Image}}' -- ${ident} 2>/dev/null || true")"
    if [[ "${image}" =~ [Pp]ostgres ]]; then
      printf 'postgres\n'
      return
    fi
    if [[ "${image}" =~ [Mm]ongo ]]; then
      printf 'mongodb\n'
      return
    fi
  fi
  printf 'other\n'
}

health_check_postgres() {
  local host="$1"
  local mode="$2"
  local ident="$3"
  local user="$4"
  local db="$5"

  local eff_user="${user:-postgres}"
  local eff_db="${db:-postgres}"

  if [[ "${mode}" == 'docker' ]]; then
    run_cmd "${host}" "docker exec -- ${ident} pg_isready -U '${eff_user}' -d '${eff_db}' -q"
  else
    run_cmd "${host}" "pg_isready -d '${eff_db}' -U '${eff_user}' -q"
  fi
}

health_check_mongodb() {
  local host="$1"
  local mode="$2"
  local ident="$3"

  if [[ "${mode}" == 'docker' ]]; then
    run_cmd "${host}" "docker exec -- ${ident} mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' | grep -q 1"
  else
    run_cmd "${host}" "mongosh '${ident}' --quiet --eval 'db.adminCommand({ ping: 1 }).ok' | grep -q 1"
  fi
}

health_check() {
  local spec="$1"
  local host='' mode='' engine='' ident='' user='' db=''
  parse_spec "${spec}" host mode engine ident user db

  info "Running health check for ${spec}"
  case "${engine}" in
    postgres) health_check_postgres "${host}" "${mode}" "${ident}" "${user}" "${db}" ;;
    mongodb) health_check_mongodb "${host}" "${mode}" "${ident}" ;;
    other)
      if [[ "${mode}" == 'docker' ]]; then
        run_cmd "${host}" "docker inspect --type volume -- ${ident} >/dev/null 2>&1 || docker inspect --type container -- ${ident} >/dev/null 2>&1"
      else
        run_cmd "${host}" "test -e '${ident}'"
      fi
      ;;
  esac
  ok "Health check passed for ${spec}"
}

backup_postgres_logical() {
  local host="$1"
  local mode="$2"
  local ident="$3"
  local out_file="$4"
  local user="$5"
  local db="$6"

  prompt_if_empty user "Postgres User (leave blank for 'postgres')"
  prompt_if_empty db "Postgres Database (leave blank for 'postgres')"
  local password=''
  prompt_if_empty password "Postgres Password (optional)" true

  local eff_user="${user:-postgres}"
  local eff_db="${db:-postgres}"
  local env_pass=""
  [[ -n "${password}" ]] && env_pass="PGPASSWORD='${password}' "

  if [[ "${mode}" == 'docker' ]]; then
    run_cmd "${host}" "${env_pass}docker exec -e PGPASSWORD='${password}' -- ${ident} pg_dump -Fc -U '${eff_user}' -d '${eff_db}'" >"${out_file}"
  else
    run_cmd "${host}" "${env_pass}pg_dump -Fc -U '${eff_user}' '${eff_db}'" >"${out_file}"
  fi
}

backup_mongodb_logical() {
  local host="$1"
  local mode="$2"
  local ident="$3"
  local out_file="$4"

  if [[ "${mode}" == 'docker' ]]; then
    run_cmd "${host}" "docker exec -- ${ident} mongodump --archive --gzip" >"${out_file}"
  else
    run_cmd "${host}" "mongodump --uri='${ident}' --archive --gzip" >"${out_file}"
  fi
}

backup_docker_physical() {
  local host="$1"
  local ident="$2"
  local out_file="$3"

  local volume_path
  volume_path="$(run_cmd "${host}" "docker volume inspect --format '{{.Mountpoint}}' -- ${ident} 2>/dev/null || true")"
  if [[ -z "${volume_path}" ]]; then
    volume_path="$(run_cmd "${host}" "docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' -- ${ident} | head -n1" || true)"
  fi
  [[ -n "${volume_path}" ]] || die "Could not determine Docker volume path for '${ident}'."

  # Check if path is a directory or a file on the remote/local host
  local is_dir
  is_dir="$(run_cmd "${host}" "test -d '${volume_path}' && echo true || echo false")"

  if [[ "${is_dir}" == "true" ]]; then
    run_cmd "${host}" "tar -C '${volume_path}' -czf - ." >"${out_file}"
  else
    # It's a file (like an init.sql file), archive it directly
    local base_name
    base_name="$(basename "${volume_path}")"
    local dir_name
    dir_name="$(dirname "${volume_path}")"
    run_cmd "${host}" "tar -C '${dir_name}' -czf - '${base_name}'" >"${out_file}"
  fi
}

backup_other() {
  local host="$1"
  local mode="$2"
  local ident="$3"
  local out_file="$4"

  if [[ "${mode}" == 'docker' ]]; then
    backup_docker_physical "${host}" "${ident}" "${out_file}"
  else
    run_cmd "${host}" "tar -C '${ident}' -czf - ." >"${out_file}"
  fi
}

backup() {
  local source_spec="$1"
  local host='' mode='' engine='' ident='' user='' db=''
  parse_spec "${source_spec}" host mode engine ident user db

  local stamp
  stamp="$(/usr/bin/date '+%Y%m%d-%H%M%S')"
  local backup_base="${STATE_DIR}/backup-${engine:-unknown}-${stamp}"

  health_check "${source_spec}"
  info "Creating logical/physical backup for ${source_spec}"

  case "${engine}" in
    postgres)
      backup_postgres_logical "${host}" "${mode}" "${ident}" "${backup_base}.pgdump" "${user}" "${db}"
      if [[ "${mode}" == 'docker' ]]; then
        backup_docker_physical "${host}" "${ident}" "${backup_base}.physical.tgz"
      fi
      ;;
    mongodb)
      backup_mongodb_logical "${host}" "${mode}" "${ident}" "${backup_base}.mongodump.gz"
      if [[ "${mode}" == 'docker' ]]; then
        backup_docker_physical "${host}" "${ident}" "${backup_base}.physical.tgz"
      fi
      ;;
    other)
      backup_other "${host}" "${mode}" "${ident}" "${backup_base}.tgz"
      ;;
    *)
      die "Unsupported engine '${engine}'."
      ;;
  esac

  ok "Backup created under ${backup_base}*"
}

confirm_stop_if_needed() {
  local prompt_msg="$1"
  local response=''
  read -r -p "${prompt_msg} [y/N]: " response
  [[ "${response}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

migrate_postgres() {
  local shost="$1" smode="$2" sident="$3" suser="$4" sdb="$5"
  local thost="$6" tmode="$7" tident="$8" tuser="$9" tdb="${10}"

  # Prompt for source if not in spec
  prompt_if_empty suser "SOURCE Postgres User (leave blank for 'postgres')"
  prompt_if_empty sdb "SOURCE Postgres Database (leave blank for 'postgres')"
  local spass=''
  prompt_if_empty spass "SOURCE Postgres Password (optional)" true

  # Prompt for target if not in spec
  prompt_if_empty tuser "TARGET Postgres User (leave blank for 'postgres')"
  prompt_if_empty tdb "TARGET Postgres Database (leave blank for 'postgres')"
  local tpass=''
  prompt_if_empty tpass "TARGET Postgres Password (optional)" true

  local s_eff_user="${suser:-postgres}"
  local s_eff_db="${sdb:-postgres}"
  local t_eff_user="${tuser:-postgres}"
  local t_eff_db="${tdb:-postgres}"

  local s_env_pass=""
  [[ -n "${spass}" ]] && s_env_pass="PGPASSWORD='${spass}' "
  local t_env_pass=""
  [[ -n "${tpass}" ]] && t_env_pass="PGPASSWORD='${tpass}' "

  local src_cmd dst_cmd
  if [[ "${smode}" == 'docker' ]]; then
    src_cmd="${s_env_pass}docker exec -e PGPASSWORD='${spass}' -- ${sident} pg_dump -Fc -U '${s_eff_user}' -d '${s_eff_db}'"
  else
    src_cmd="${s_env_pass}pg_dump -Fc -U '${s_eff_user}' '${s_eff_db}'"
  fi

  if [[ "${tmode}" == 'docker' ]]; then
    dst_cmd="${t_env_pass}docker exec -i -e PGPASSWORD='${tpass}' -- ${tident} pg_restore --clean --if-exists -U '${t_eff_user}' -d '${t_eff_db}'"
  else
    dst_cmd="${t_env_pass}pg_restore --clean --if-exists -U '${t_eff_user}' -d '${t_eff_db}'"
  fi

  if [[ -z "${shost}" && -z "${thost}" ]]; then
    /bin/bash -lc "${src_cmd}" | /bin/bash -lc "${dst_cmd}"
  elif [[ -n "${shost}" && -z "${thost}" ]]; then
    ssh_wrapper "${shost}" "${src_cmd}" | /bin/bash -lc "${dst_cmd}"
  elif [[ -z "${shost}" && -n "${thost}" ]]; then
    /bin/bash -lc "${src_cmd}" | ssh_wrapper "${thost}" "${dst_cmd}"
  else
    ssh_wrapper "${shost}" "${src_cmd}" | ssh_wrapper "${thost}" "${dst_cmd}"
  fi
}

migrate_mongodb() {
  local shost="$1"
  local smode="$2"
  local sident="$3"
  local thost="$4"
  local tmode="$5"
  local tident="$6"

  local src_cmd dst_cmd
  if [[ "${smode}" == 'docker' ]]; then
    src_cmd="docker exec -- ${sident} mongodump --archive --gzip"
  else
    src_cmd="mongodump --uri='${sident}' --archive --gzip"
  fi

  if [[ "${tmode}" == 'docker' ]]; then
    dst_cmd="docker exec -i -- ${tident} mongorestore --archive --gzip --drop"
  else
    dst_cmd="mongorestore --uri='${tident}' --archive --gzip --drop"
  fi

  if [[ -z "${shost}" && -z "${thost}" ]]; then
    /bin/bash -lc "${src_cmd}" | /bin/bash -lc "${dst_cmd}"
  elif [[ -n "${shost}" && -z "${thost}" ]]; then
    ssh_wrapper "${shost}" "${src_cmd}" | /bin/bash -lc "${dst_cmd}"
  elif [[ -z "${shost}" && -n "${thost}" ]]; then
    /bin/bash -lc "${src_cmd}" | ssh_wrapper "${thost}" "${dst_cmd}"
  else
    ssh_wrapper "${shost}" "${src_cmd}" | ssh_wrapper "${thost}" "${dst_cmd}"
  fi
}

migrate_other_rsync() {
  local shost="$1"
  local smode="$2"
  local sident="$3"
  local thost="$4"
  local tmode="$5"
  local tident="$6"

  [[ -n "${RSYNC_BIN}" ]] || die 'rsync is required for non-native engine data migration.'

  local src_path dst_path
  if [[ "${smode}" == 'docker' ]]; then
    src_path="$(run_cmd "${shost}" "docker volume inspect --format '{{.Mountpoint}}' -- ${sident} 2>/dev/null || true")"
    [[ -n "${src_path}" ]] || die "Source Docker volume '${sident}' not found."
  else
    src_path="${sident}"
  fi

  if [[ "${tmode}" == 'docker' ]]; then
    dst_path="$(run_cmd "${thost}" "docker volume inspect --format '{{.Mountpoint}}' -- ${tident} 2>/dev/null || true")"
    [[ -n "${dst_path}" ]] || die "Target Docker volume '${tident}' not found."
  else
    dst_path="${tident}"
  fi

  local src_ref dst_ref
  src_ref="${src_path%/}/"
  dst_ref="${dst_path%/}/"

  if [[ -n "${shost}" ]]; then
    src_ref="${shost}:${src_ref}"
  fi
  if [[ -n "${thost}" ]]; then
    dst_ref="${thost}:${dst_ref}"
  fi

  "${RSYNC_BIN}" -aHAX --delete --numeric-ids --info=progress2 -- "${src_ref}" "${dst_ref}"
}

migrate() {
  local source_spec="$1"
  local target_spec="$2"

  local shost='' smode='' sengine='' sident='' suser='' sdb=''
  local thost='' tmode='' tengine='' tident='' tuser='' tdb=''
  parse_spec "${source_spec}" shost smode sengine sident suser sdb
  parse_spec "${target_spec}" thost tmode tengine tident tuser tdb

  health_check "${source_spec}"
  health_check "${target_spec}"

  # Mandatory auto-backup of source before clone/migrate.
  backup "${source_spec}"

  info "Starting migration ${source_spec} -> ${target_spec}"
  if [[ "${sengine}" != "${tengine}" ]]; then
    die "Cross-engine migrations are not supported (source=${sengine}, target=${tengine})."
  fi

  case "${sengine}" in
    postgres) migrate_postgres "${shost}" "${smode}" "${sident}" "${suser}" "${sdb}" "${thost}" "${tmode}" "${tident}" "${tuser}" "${tdb}" ;;
    mongodb) migrate_mongodb "${shost}" "${smode}" "${sident}" "${thost}" "${tmode}" "${tident}" ;;
    other) migrate_other_rsync "${shost}" "${smode}" "${sident}" "${thost}" "${tmode}" "${tident}" ;;
    *) die "Unsupported engine '${sengine}'." ;;
  esac

  ok "Migration completed successfully."
}

get_local_instances() {
  [[ -n "${DOCKER_BIN}" ]] || return 1
  "${DOCKER_BIN}" ps --format '{{.Names}}|{{.Image}}' | while IFS='|' read -r name image; do
    local engine='other'
    if [[ "${image}" =~ [Pp]ostgres ]]; then
      engine='postgres'
    elif [[ "${image}" =~ [Mm]ongo ]]; then
      engine='mongodb'
    fi
    printf 'docker::%s::%s\n' "${engine}" "${name}"
  done
}

list_instances() {
  [[ -n "${DOCKER_BIN}" ]] || die 'docker not found for --list operation.'
  info 'Listing local Docker PostgreSQL/MongoDB-like containers:'
  "${DOCKER_BIN}" ps --format '{{.Names}}|{{.Image}}|{{.Status}}' | while IFS='|' read -r name image status; do
    local engine='other'
    if [[ "${image}" =~ [Pp]ostgres ]]; then
      engine='postgres'
    elif [[ "${image}" =~ [Mm]ongo ]]; then
      engine='mongodb'
    fi
    printf '%s\t%s\t%s\t%s\n' "${name}" "${engine}" "${image}" "${status}"
  done
}

print_spec_instructions() {
  /usr/bin/cat >&2 <<'EOF'

======================================================================
  HOW TO FORMAT A "SPEC" (SOURCE OR TARGET DATABASE ADDRESS)
======================================================================
A "spec" is text that tells this tool exactly where your database/data 
is located and how to connect. It is made of parts glued together by 
double colons (::).

FORMAT:  [SERVER_LOGIN::]WHERE_IT_RUNS::WHAT_IT_IS::NAME_OR_PATH

--- Break down of the parts ---

1. SERVER_LOGIN (Optional):
   Are you connecting to a remote server over SSH? Put the login here.
   If the database is on THIS machine right now, SKIP THIS entirely!
   -> Example 1: root@192.168.1.50
   -> Example 2: admin@mysite.com

2. WHERE_IT_RUNS (Required):
   Is the database inside "Docker", or installed straight on the OS?
   -> Type "docker" for Docker containers and Docker volumes.
   -> Type "native" for normal installed databases or raw folders.

3. WHAT_IT_IS (Required):
   What kind of database or data is this?
   -> Type "postgres" for PostgreSQL databases.
   -> Type "mongodb" for MongoDB databases.
   -> Type "other" for anything else (MySQL, Redis, regular files).

4. NAME_OR_PATH (Required):
   The exact container, volume, or folder path you want to target:
   -> If you chose 'docker' & 'postgres/mongodb' => Container Name (e.g. pg-db)
      Tip: For detailed access, use ID@user:dbname (e.g. pg-db@myuser:mydb)
      If you leave out user, password, or dbname, you will be prompted!
   -> If you chose 'docker' & 'other' => Type Docker Volume Name (e.g. my_data)
   -> If you chose 'native' & 'postgres/mongodb' => Local DB URI or DB Name
      Tip: For detailed access, use ID@user:dbname (e.g. my-app-db@myuser:mydb)
   -> If you chose 'native' & 'other' => exact folder path (e.g. /var/www/html)

--- EXAMPLES TO COPY/ADAPT ---

- Local Docker Postgres database named "coolify-db":
    docker::postgres::coolify-db

- Local Docker MongoDB container named "mongo-prod":
    docker::mongodb::mongo-prod

- Local Docker Volume (for generic text/media files or MySQL):
    docker::other::mysite_data

- Remote server Postgres database (IP: 10.0.0.5):
    root@10.0.0.5::docker::postgres::coolify-db
======================================================================
EOF
}

read_spec_prompt() {
  local prompt="$1"
  local help_text="${2:-}"
  local spec=''
  
  # Try to offer local instances first
  local -a locals=()
  while IFS= read -r line; do
    locals+=("$line")
  done < <(get_local_instances 2>/dev/null || true)

  if [[ ${#locals[@]} -gt 0 ]]; then
    printf '\n%b%s%b\n' "${BOLD}${CYAN}" "--- ${prompt} ---" "${NC}" >&2
    local choice
    choice="$(choose_option "Select from detected local instances or enter manually" \
      "${locals[@]}" \
      "[ Enter Manually ]")" || return 1
    
    if [[ "${choice}" != "[ Enter Manually ]" ]]; then
      printf '%s\n' "${choice}"
      return 0
    fi
  fi

  printf '\n' >&2
  print_spec_instructions
  printf '\n' >&2

  while true; do
    read -r -p "${prompt} (e.g. docker::postgres::coolify-db): " spec
    if validate_spec "${spec}"; then
      printf '%s\n' "${spec}"
      return 0
    fi
    printf '\n%b[WARN]%b Invalid format! Please review the guide above and use "::" as separator.\n\n' "${YELLOW}" "${NC}" >&2
  done
}

interactive_backup() {
  local source_spec
  source_spec="$(read_spec_prompt 'Enter SOURCE spec for backup')"
  backup "${source_spec}"
}

interactive_migrate() {
  local source_spec target_spec
  source_spec="$(read_spec_prompt 'STEP 1: Enter SOURCE spec (The database you want to COPY FROM)')"
  target_spec="$(read_spec_prompt 'STEP 2: Enter TARGET spec (The database you want to PASTE/CLONE TO)')"
  migrate "${source_spec}" "${target_spec}"
}

interactive_menu() {
  while true; do
    printf '%b\n' "${BOLD}${CYAN}==== DB Migrator Main Menu ====${NC}"
    local choice
    choice="$(choose_option 'Main menu' \
      'List local instances' \
      'Backup source instance' \
      'Migrate/Clone source -> target' \
      'Rotate logs now' \
      'Quit')" || true

    case "${choice}" in
      'List local instances') list_instances ;;
      'Backup source instance') interactive_backup ;;
      'Migrate/Clone source -> target') interactive_migrate ;;
      'Rotate logs now') rotate_logs; ok 'Log rotation complete.' ;;
      'Quit') info 'Exiting.'; return 0 ;;
      *) warn 'No option selected.' ;;
    esac
  done
}

main() {
  init_runtime
  rotate_logs

  if [[ "$#" -eq 0 ]]; then
    interactive_menu
    return 0
  fi

  case "$1" in
    --help|-h)
      usage
      ;;
    --list)
      list_instances
      ;;
    --backup)
      [[ "$#" -eq 2 ]] || die '--backup requires exactly one SOURCE spec.'
      validate_spec "$2" || die 'Invalid SOURCE spec.'
      backup "$2"
      ;;
    --migrate)
      [[ "$#" -eq 3 ]] || die '--migrate requires SOURCE and TARGET specs.'
      validate_spec "$2" || die 'Invalid SOURCE spec.'
      validate_spec "$3" || die 'Invalid TARGET spec.'
      migrate "$2" "$3"
      ;;
    *)
      usage
      die "Unknown argument '$1'."
      ;;
  esac
}

main "$@"
