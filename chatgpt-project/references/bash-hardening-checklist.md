# Bash Hardening Checklist (Use Selectively)

Use this file as an extended profile when tasks explicitly require stronger production/security/portability guarantees.

## 1) Safety baseline

- Prefer `set -Eeuo pipefail` + `trap '...' ERR` for actionable failures.
- Use `IFS=$'\n\t'` when word-splitting risk exists.
- Quote all variable expansions unless intentionally unquoted.
- Never use `eval` on untrusted input.
- Use `--` to terminate options for dangerous commands (`rm -rf -- "$target"`).

## 2) Input handling and argument parsing

- Define required env vars with `: "${VAR:?message}"`.
- Validate numeric/path inputs before use.
- Provide `--help` and usage examples for non-trivial scripts.
- Prefer `getopts` (or a consistent long-option parser wrapper).

## 3) File/process safety

- Create temp files via `mktemp` and always cleanup via `trap`.
- Use NUL-safe file iteration for arbitrary filenames:
  `find ... -print0 | while IFS= read -r -d '' f; do ...; done`
- Prefer arrays over string-built commands.
- Add timeouts to external network/system calls where hangs are possible.

## 4) Portability and compatibility

- Use `#!/usr/bin/env bash`.
- If Bash >=4.4 features are required, check version explicitly.
- Detect Linux/macOS differences where tools diverge (GNU vs BSD).
- Document minimum runtime/tool versions in script header.

## 5) Observability

- Standardize log helpers (`debug/info/warn/error`) with timestamps.
- Include enough context in errors to support quick rollback.
- For multi-step automation, print step boundaries and outcome.

## 6) Quality gates

- Required: syntax check (`bash -n`) for changed scripts.
- Recommended: ShellCheck, shfmt, Bats tests when available.
- Keep suppressions minimal and documented.

## 7) CI/CD starter policy

- Run lint + tests on PR.
- Fail builds on syntax/lint/test errors.
- Optionally matrix-test Bash versions when project is widely distributed.

## Suggested prompt usage

```text
Use hardening mode from chatgpt-project/references/bash-hardening-checklist.md.
Apply only items relevant to this task. Explain which items were applied and why.
```
