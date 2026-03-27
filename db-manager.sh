#!/usr/bin/env bash
# db-manager.sh - Manage PostgreSQL and MongoDB containers on Coolify.
#
# Features:
#   * Discover PostgreSQL/MongoDB containers.
#   * Create and restore native backups.
#   * Migrate between same-type databases using pg_dump/pg_restore and
#     mongodump/mongorestore.
#   * Best-effort cross-type migrations (PostgreSQL <-> MongoDB) with explicit
#     schema-loss warnings.
#
# Safety:
#   * Fails fast on command errors, unset variables, and pipeline failures.
#   * Uses defensive input validation.
#   * Requires explicit opt-in for cross-type migrations.

set -Eeuo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly SCRIPT_NAME="$(basename "$0")"
readonly TMP_ROOT='/tmp/db-manager'

DOCKER_BIN=''
DATE_BIN=''
MKDIR_BIN=''
RM_BIN=''
CAT_BIN=''

TEMP_DIR=''

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    "${RM_BIN}" -rf -- "${TEMP_DIR}"
  fi
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  printf '%b[ERROR]%b %s failed at line %s (exit=%s).\n' "${RED}" "${NC}" "${SCRIPT_NAME}" "${line_no}" "${exit_code}" >&2
}

trap 'on_error "$?" "$LINENO"' ERR
trap cleanup EXIT

usage() {
  "${CAT_BIN}" <<'USAGE'
Usage:
  db-manager.sh list
  db-manager.sh backup  --type <postgres|mongodb> --container <name> --output <file>
  db-manager.sh restore --type <postgres|mongodb> --container <name> --input <file>
  db-manager.sh migrate --source-type <postgres|mongodb> --source-container <name> \
                        --target-type <postgres|mongodb> --target-container <name> \
                        [--allow-cross-type] [--workdir <dir>]

Notes:
  * Same-type migrations are native and lossless (within tool constraints).
  * Cross-type migrations are best-effort and may lose schema fidelity.
USAGE
}

print_info() {
  local message="$1"
  printf '%b[INFO]%b %s\n' "${BLUE}" "${NC}" "${message}"
}

print_success() {
  local message="$1"
  printf '%b[OK]%b %s\n' "${GREEN}" "${NC}" "${message}"
}

print_warn() {
  local message="$1"
  printf '%b[WARN]%b %s\n' "${YELLOW}" "${NC}" "${message}"
}

print_error() {
  local message="$1"
  printf '%b[ERROR]%b %s\n' "${RED}" "${NC}" "${message}" >&2
}

resolve_bin() {
  local name="$1"
  local resolved=''

  resolved="$(command -v -- "${name}" || true)"
  if [[ -z "${resolved}" || "${resolved}" != /* ]]; then
    print_error "Required binary '${name}' not found with absolute path."
    exit 1
  fi
  printf '%s\n' "${resolved}"
}

init_bins() {
  DOCKER_BIN="$(resolve_bin docker)"
  DATE_BIN="$(resolve_bin date)"
  MKDIR_BIN="$(resolve_bin mkdir)"
  RM_BIN="$(resolve_bin rm)"
  CAT_BIN="$(resolve_bin cat)"
}

ensure_temp_dir() {
  TEMP_DIR="${TMP_ROOT}/$(${DATE_BIN} +%s)-$$"
  "${MKDIR_BIN}" -p -- "${TEMP_DIR}"
}

validate_db_type() {
  local db_type="$1"
  if [[ ! "${db_type}" =~ ^(postgres|mongodb)$ ]]; then
    print_error "Invalid DB type: '${db_type}'. Use postgres or mongodb."
    exit 1
  fi
}

validate_container_name() {
  local name="$1"
  if [[ ! "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    print_error "Invalid container name: '${name}'."
    exit 1
  fi
}

validate_file_path() {
  local path="$1"
  if [[ ! "${path}" =~ ^[a-zA-Z0-9/_.,:=+@-]+$ ]]; then
    print_error "Path contains unsupported characters: '${path}'."
    exit 1
  fi
}

docker_container_exists() {
  local container="$1"
  "${DOCKER_BIN}" inspect --type container -- "${container}" >/dev/null 2>&1
}

get_container_image() {
  local container="$1"
  "${DOCKER_BIN}" inspect --format '{{.Config.Image}}' -- "${container}"
}

infer_type_from_image() {
  local image="$1"
  if [[ "${image}" =~ [Pp]ostgres ]]; then
    printf 'postgres\n'
  elif [[ "${image}" =~ mongo ]]; then
    printf 'mongodb\n'
  else
    printf 'unknown\n'
  fi
}

get_env_from_container() {
  local container="$1"
  local key="$2"
  "${DOCKER_BIN}" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' -- "${container}" \
    | awk -F= -v k="${key}" '$1==k {sub($1"=", ""); print; exit}'
}

list_instances() {
  print_info 'Scanning running Docker containers for PostgreSQL/MongoDB...'
  "${DOCKER_BIN}" ps --format '{{.Names}}|{{.Image}}|{{.Status}}' | while IFS='|' read -r name image status; do
    local db_type=''
    db_type="$(infer_type_from_image "${image}")"
    if [[ "${db_type}" == 'unknown' ]]; then
      continue
    fi

    printf '%s\t%s\t%s\t%s\n' "${name}" "${db_type}" "${image}" "${status}"
  done
}

backup_postgres() {
  local container="$1"
  local output_file="$2"
  local db_name=''
  local db_user=''

  db_name="$(get_env_from_container "${container}" POSTGRES_DB || true)"
  db_user="$(get_env_from_container "${container}" POSTGRES_USER || true)"
  db_name="${db_name:-postgres}"
  db_user="${db_user:-postgres}"

  print_info "Running pg_dump from container '${container}' (db=${db_name}, user=${db_user})..."
  "${DOCKER_BIN}" exec -- "${container}" pg_dump -Fc -U "${db_user}" -d "${db_name}" >"${output_file}"
  print_success "PostgreSQL backup created: ${output_file}"
}

restore_postgres() {
  local container="$1"
  local input_file="$2"
  local db_name=''
  local db_user=''

  db_name="$(get_env_from_container "${container}" POSTGRES_DB || true)"
  db_user="$(get_env_from_container "${container}" POSTGRES_USER || true)"
  db_name="${db_name:-postgres}"
  db_user="${db_user:-postgres}"

  print_info "Restoring PostgreSQL backup into '${container}' (db=${db_name}, user=${db_user})..."
  "${DOCKER_BIN}" exec -i -- "${container}" pg_restore --clean --if-exists -U "${db_user}" -d "${db_name}" <"${input_file}"
  print_success 'PostgreSQL restore completed.'
}

backup_mongodb() {
  local container="$1"
  local output_file="$2"

  print_info "Running mongodump from container '${container}'..."
  "${DOCKER_BIN}" exec -- "${container}" mongodump --archive --gzip >"${output_file}"
  print_success "MongoDB backup created: ${output_file}"
}

restore_mongodb() {
  local container="$1"
  local input_file="$2"

  print_info "Restoring MongoDB dump into '${container}'..."
  "${DOCKER_BIN}" exec -i -- "${container}" mongorestore --archive --gzip --drop <"${input_file}"
  print_success 'MongoDB restore completed.'
}

backup_command() {
  local db_type="$1"
  local container="$2"
  local output_file="$3"

  validate_db_type "${db_type}"
  validate_container_name "${container}"
  validate_file_path "${output_file}"

  if ! docker_container_exists "${container}"; then
    print_error "Container '${container}' not found."
    exit 1
  fi

  case "${db_type}" in
    postgres) backup_postgres "${container}" "${output_file}" ;;
    mongodb) backup_mongodb "${container}" "${output_file}" ;;
  esac
}

restore_command() {
  local db_type="$1"
  local container="$2"
  local input_file="$3"

  validate_db_type "${db_type}"
  validate_container_name "${container}"
  validate_file_path "${input_file}"

  if [[ ! -f "${input_file}" ]]; then
    print_error "Input file does not exist: ${input_file}"
    exit 1
  fi
  if ! docker_container_exists "${container}"; then
    print_error "Container '${container}' not found."
    exit 1
  fi

  case "${db_type}" in
    postgres) restore_postgres "${container}" "${input_file}" ;;
    mongodb) restore_mongodb "${container}" "${input_file}" ;;
  esac
}

confirm_cross_type() {
  local source_type="$1"
  local target_type="$2"
  local allow_cross_type="$3"
  local answer=''

  if [[ "${source_type}" == "${target_type}" ]]; then
    return 0
  fi

  print_warn "Cross-type migration requested: ${source_type} -> ${target_type}."
  print_warn 'Schema/index/constraint semantics are different and data loss is possible.'
  print_warn 'A native source backup will be created before conversion.'

  if [[ "${allow_cross_type}" != 'true' ]]; then
    print_error 'Refusing cross-type migration without --allow-cross-type.'
    exit 1
  fi

  read -rp 'Type YES to continue with a best-effort migration: ' answer
  if [[ "${answer}" != 'YES' ]]; then
    print_error 'Migration cancelled by user.'
    exit 1
  fi
}

migrate_same_type() {
  local db_type="$1"
  local source_container="$2"
  local target_container="$3"
  local dump_file="$4"

  if [[ "${db_type}" == 'postgres' ]]; then
    backup_postgres "${source_container}" "${dump_file}"
    restore_postgres "${target_container}" "${dump_file}"
  else
    backup_mongodb "${source_container}" "${dump_file}"
    restore_mongodb "${target_container}" "${dump_file}"
  fi
}

migrate_postgres_to_mongodb() {
  local source_container="$1"
  local target_container="$2"
  local workdir="$3"
  local source_backup="$4"
  local db_name=''
  local db_user=''
  local tables_file=''

  db_name="$(get_env_from_container "${source_container}" POSTGRES_DB || true)"
  db_user="$(get_env_from_container "${source_container}" POSTGRES_USER || true)"
  db_name="${db_name:-postgres}"
  db_user="${db_user:-postgres}"

  backup_postgres "${source_container}" "${source_backup}"

  tables_file="${workdir}/postgres_tables.txt"
  "${DOCKER_BIN}" exec -- "${source_container}" psql -U "${db_user}" -d "${db_name}" -Atc \
    "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;" >"${tables_file}"

  while IFS= read -r table_name; do
    local export_file=''
    if [[ -z "${table_name}" ]]; then
      continue
    fi

    if [[ ! "${table_name}" =~ ^[a-zA-Z0-9_]+$ ]]; then
      print_warn "Skipping unsupported table name: ${table_name}"
      continue
    fi

    export_file="${workdir}/${table_name}.ndjson"
    print_info "Exporting PostgreSQL table '${table_name}' to NDJSON..."
    "${DOCKER_BIN}" exec -- "${source_container}" psql -U "${db_user}" -d "${db_name}" -Atc \
      "SELECT row_to_json(t)::text FROM ${table_name} t;" >"${export_file}"

    print_info "Importing NDJSON into MongoDB collection '${table_name}'..."
    "${DOCKER_BIN}" exec -i -- "${target_container}" mongoimport --drop --collection "${table_name}" <"${export_file}"
  done <"${tables_file}"
}

migrate_mongodb_to_postgres() {
  local source_container="$1"
  local target_container="$2"
  local workdir="$3"
  local source_backup="$4"
  local db_name=''
  local db_user=''
  local collections_file=''

  db_name="$(get_env_from_container "${target_container}" POSTGRES_DB || true)"
  db_user="$(get_env_from_container "${target_container}" POSTGRES_USER || true)"
  db_name="${db_name:-postgres}"
  db_user="${db_user:-postgres}"

  backup_mongodb "${source_container}" "${source_backup}"

  collections_file="${workdir}/mongo_collections.txt"
  "${DOCKER_BIN}" exec -- "${source_container}" mongosh --quiet --eval \
    'db.getMongo().getDBNames().forEach(function(d){if(d!=="admin"&&d!=="local"&&d!=="config"){db.getSiblingDB(d).getCollectionNames().forEach(function(c){print(d+"."+c);});}});' \
    >"${collections_file}"

  while IFS= read -r ns; do
    local database=''
    local collection=''
    local safe_table=''
    local export_file=''

    if [[ -z "${ns}" ]]; then
      continue
    fi

    database="${ns%%.*}"
    collection="${ns#*.}"
    if [[ ! "${collection}" =~ ^[a-zA-Z0-9_]+$ ]]; then
      print_warn "Skipping unsupported collection name: ${ns}"
      continue
    fi

    safe_table="mongo_${database}_${collection}"
    export_file="${workdir}/${safe_table}.ndjson"

    print_info "Exporting MongoDB collection '${ns}' to NDJSON..."
    "${DOCKER_BIN}" exec -- "${source_container}" mongoexport --db "${database}" --collection "${collection}" >"${export_file}"

    print_info "Importing collection '${ns}' into PostgreSQL table '${safe_table}' (jsonb)..."
    "${DOCKER_BIN}" exec -- "${target_container}" psql -U "${db_user}" -d "${db_name}" -v ON_ERROR_STOP=1 -c \
      "CREATE TABLE IF NOT EXISTS ${safe_table} (id bigserial PRIMARY KEY, doc jsonb NOT NULL); TRUNCATE TABLE ${safe_table};"
    "${DOCKER_BIN}" exec -i -- "${target_container}" psql -U "${db_user}" -d "${db_name}" -v ON_ERROR_STOP=1 -c \
      "COPY ${safe_table}(doc) FROM STDIN;" <"${export_file}"
  done <"${collections_file}"
}

migrate_command() {
  local source_type="$1"
  local source_container="$2"
  local target_type="$3"
  local target_container="$4"
  local allow_cross_type="$5"
  local workdir="$6"
  local ts=''
  local dump_file=''

  validate_db_type "${source_type}"
  validate_db_type "${target_type}"
  validate_container_name "${source_container}"
  validate_container_name "${target_container}"
  validate_file_path "${workdir}"

  if ! docker_container_exists "${source_container}"; then
    print_error "Source container '${source_container}' not found."
    exit 1
  fi
  if ! docker_container_exists "${target_container}"; then
    print_error "Target container '${target_container}' not found."
    exit 1
  fi

  confirm_cross_type "${source_type}" "${target_type}" "${allow_cross_type}"

  "${MKDIR_BIN}" -p -- "${workdir}"
  ts="$(${DATE_BIN} +%Y%m%d-%H%M%S)"
  dump_file="${workdir}/source-native-${source_type}-${ts}.dump"

  if [[ "${source_type}" == "${target_type}" ]]; then
    migrate_same_type "${source_type}" "${source_container}" "${target_container}" "${dump_file}"
    print_success "Migration completed (${source_type} -> ${target_type})."
    return
  fi

  if [[ "${source_type}" == 'postgres' && "${target_type}" == 'mongodb' ]]; then
    migrate_postgres_to_mongodb "${source_container}" "${target_container}" "${workdir}" "${dump_file}"
  elif [[ "${source_type}" == 'mongodb' && "${target_type}" == 'postgres' ]]; then
    migrate_mongodb_to_postgres "${source_container}" "${target_container}" "${workdir}" "${dump_file}"
  else
    print_error "Unsupported migration path: ${source_type} -> ${target_type}"
    exit 1
  fi

  print_success "Best-effort cross-type migration completed (${source_type} -> ${target_type})."
}

parse_and_run() {
  local command=''
  command="${1:-}"

  if [[ -z "${command}" ]]; then
    usage
    exit 1
  fi
  shift || true

  case "${command}" in
    list)
      list_instances
      ;;
    backup)
      local db_type=''
      local container=''
      local output_file=''
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --type) db_type="${2:-}"; shift 2 ;;
          --container) container="${2:-}"; shift 2 ;;
          --output) output_file="${2:-}"; shift 2 ;;
          *) print_error "Unknown option for backup: $1"; usage; exit 1 ;;
        esac
      done
      if [[ -z "${db_type}" || -z "${container}" || -z "${output_file}" ]]; then
        print_error 'Missing required backup options.'
        usage
        exit 1
      fi
      backup_command "${db_type}" "${container}" "${output_file}"
      ;;
    restore)
      local db_type=''
      local container=''
      local input_file=''
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --type) db_type="${2:-}"; shift 2 ;;
          --container) container="${2:-}"; shift 2 ;;
          --input) input_file="${2:-}"; shift 2 ;;
          *) print_error "Unknown option for restore: $1"; usage; exit 1 ;;
        esac
      done
      if [[ -z "${db_type}" || -z "${container}" || -z "${input_file}" ]]; then
        print_error 'Missing required restore options.'
        usage
        exit 1
      fi
      restore_command "${db_type}" "${container}" "${input_file}"
      ;;
    migrate)
      local source_type=''
      local source_container=''
      local target_type=''
      local target_container=''
      local allow_cross_type='false'
      local workdir='/var/backups/coolify-db-migrations'
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --source-type) source_type="${2:-}"; shift 2 ;;
          --source-container) source_container="${2:-}"; shift 2 ;;
          --target-type) target_type="${2:-}"; shift 2 ;;
          --target-container) target_container="${2:-}"; shift 2 ;;
          --allow-cross-type) allow_cross_type='true'; shift ;;
          --workdir) workdir="${2:-}"; shift 2 ;;
          *) print_error "Unknown option for migrate: $1"; usage; exit 1 ;;
        esac
      done
      if [[ -z "${source_type}" || -z "${source_container}" || -z "${target_type}" || -z "${target_container}" ]]; then
        print_error 'Missing required migrate options.'
        usage
        exit 1
      fi
      migrate_command "${source_type}" "${source_container}" "${target_type}" "${target_container}" "${allow_cross_type}" "${workdir}"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      print_error "Unknown command: ${command}"
      usage
      exit 1
      ;;
  esac
}

main() {
  init_bins
  ensure_temp_dir
  parse_and_run "$@"
}

main "$@"
