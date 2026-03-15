#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

status=0

run_step() {
  local name="$1"
  shift

  echo "==> $name"
  if "$@"; then
    echo "[PASS] $name"
  else
    echo "[FAIL] $name"
    status=1
  fi
  echo
}

# Always run syntax checks.
run_step "bash -n syntax checks" "$ROOT_DIR/chatgpt-project/scripts/bash-lint-runner.sh"

# Optional tools.
if command -v shellcheck >/dev/null 2>&1; then
  mapfile -t shell_files < <(find "$ROOT_DIR" -maxdepth 2 -type f -name "*.sh" | sort)
  if [[ ${#shell_files[@]} -gt 0 ]]; then
    run_step "shellcheck" shellcheck "${shell_files[@]}"
  fi
else
  echo "[SKIP] shellcheck not installed"
  echo
fi

if command -v shfmt >/dev/null 2>&1; then
  mapfile -t shell_files < <(find "$ROOT_DIR" -maxdepth 2 -type f -name "*.sh" | sort)
  if [[ ${#shell_files[@]} -gt 0 ]]; then
    run_step "shfmt -d" shfmt -d "${shell_files[@]}"
  fi
else
  echo "[SKIP] shfmt not installed"
  echo
fi

if command -v bats >/dev/null 2>&1; then
  if [[ -d "$ROOT_DIR/test" || -d "$ROOT_DIR/tests" ]]; then
    test_dir="$ROOT_DIR/test"
    [[ -d "$ROOT_DIR/tests" ]] && test_dir="$ROOT_DIR/tests"
    run_step "bats" bats "$test_dir"
  else
    echo "[SKIP] bats installed but no test/ or tests/ directory found"
    echo
  fi
else
  echo "[SKIP] bats not installed"
  echo
fi

exit "$status"
