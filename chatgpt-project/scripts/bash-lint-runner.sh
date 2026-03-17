#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
ROOT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")/../.." && pwd -P)"

mapfile -t shell_files < <(find "$ROOT_DIR" -maxdepth 2 -type f -name "*.sh" | sort)

if [[ ${#shell_files[@]} -eq 0 ]]; then
  echo "No shell scripts found."
  exit 0
fi

failed=0
for file in "${shell_files[@]}"; do
  if bash -n "$file"; then
    echo "[OK] $file"
  else
    echo "[FAIL] $file"
    failed=1
  fi
done

exit "$failed"
