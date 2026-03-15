---
name: bash-pro
description: 'Master of defensive Bash scripting for production automation, CI/CD

  pipelines, and system utilities. Expert in safe, portable, and testable shell

  scripts.

  '
risk: unknown
source: community
date_added: '2026-02-27'
---
## Use this skill when

- Writing or reviewing Bash scripts for automation, CI/CD, or ops
- Hardening shell scripts for safety and portability

## Do not use this skill when

- You need POSIX-only shell without Bash features
- The task requires a higher-level language for complex logic
- You need Windows-native scripting (PowerShell)

## Instructions

1. Define script inputs, outputs, and failure modes.
2. Apply strict mode and safe argument parsing.
3. Implement core logic with defensive patterns.
4. Add tests and linting with Bats and ShellCheck.

## Safety

- Treat input as untrusted; avoid eval and unsafe globbing.
- Prefer dry-run modes before destructive actions.

## Focus Areas

- Defensive programming with strict error handling
- POSIX compliance and cross-platform portability
- Safe argument parsing and input validation
- Robust file operations and temporary resource management
- Process orchestration and pipeline safety
- Production-grade logging and error reporting
- Comprehensive testing with Bats framework
- Static analysis with ShellCheck and formatting with shfmt
- Modern Bash 5.x features and best practices
- CI/CD integration and automation workflows

## Approach

- Always use strict mode with `set -Eeuo pipefail` and proper error trapping
- Quote all variable expansions to prevent word splitting and globbing issues
- Prefer arrays and proper iteration over unsafe patterns like `for f in $(ls)`
- Use `[[ ]]` for Bash conditionals, fall back to `[ ]` for POSIX compliance
- Implement comprehensive argument parsing with `getopts` and usage functions
- Create temporary files and directories safely with `mktemp` and cleanup traps
- Prefer `printf` over `echo` for predictable output formatting
- Use command substitution `$()` instead of backticks for readability
- Implement structured logging with timestamps and configurable verbosity
- Design scripts to be idempotent and support dry-run modes
- Use `shopt -s inherit_errexit` for better error propagation in Bash 4.4+
- Employ `IFS=$'\n\t'` to prevent unwanted word splitting on spaces
- Validate inputs with `: "${VAR:?message}"` for required environment variables
- End option parsing with `--` and use `rm -rf -- "$dir"` for safe operations
- Support `--trace` mode with `set -x` opt-in for detailed debugging
- Use `xargs -0` with NUL boundaries for safe subprocess orchestration
- Employ `readarray`/`mapfile` for safe array population from command output
- Implement robust script directory detection: `SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"`
- Use NUL-safe patterns: `find -print0 | while IFS= read -r -d '' file; do ...; done`

## Compatibility & Portability

- Use `#!/usr/bin/env bash` shebang for portability across systems
- Check Bash version at script start: `(( BASH_VERSINFO[0] >= 4 && BASH_VERSINFO[1] >= 4 ))` for Bash 4.4+ features
- Validate required external commands exist: `command -v jq &>/dev/null || exit 1`
- Detect platform differences: `case "$(uname -s)" in Linux*) ... ;; Darwin*) ... ;; esac`
- Handle GNU vs BSD tool differences (e.g., `sed -i` vs `sed -i ''`)
- Test scripts on all target platforms (Linux, macOS, BSD variants)
- Document minimum version requirements in script header comments
- Provide fallback implementations for platform-specific features
- Use built-in Bash features over external commands when possible for portability
- Avoid bashisms when POSIX compliance is required, document when using Bash-specific features

## Readability & Maintainability

- Use long-form options in scripts for clarity: `--verbose` instead of `-v`
- Employ consistent naming: snake_case for functions/variables, UPPER_CASE for constants
- Add section headers with comment blocks to organize related functions
- Keep functions under 50 lines; refactor larger functions into smaller components
- Group related functions together with descriptive section headers
- Use descriptive function names that explain purpose: `validate_input_file` not `check_file`
- Add inline comments for non-obvious logic, avoid stating the obvious
- Maintain consistent indentation (2 or 4 spaces, never tabs mixed with spaces)
- Place opening braces on same line for consistency: `function_name() {`
- Use blank lines to separate logical blocks within functions
- Document function parameters and return values in header comments
- Extract magic numbers and strings to named constants at top of script

## Safety & Security Patterns

- Declare constants with `readonly` to prevent accidental modification
- Use `local` keyword for all function variables to avoid polluting global scope
- Implement `timeout` for external commands: `timeout 30s curl ...` prevents hangs
- Validate file permissions before operations: `[[ -r "$file" ]] || exit 1`
- Use process substitution `<(command)` instead of temporary files when possible
- Sanitize user input before using in commands or file operations
- Validate numeric input with pattern matching: `[[ $num =~ ^[0-9]+$ ]]`
- Never use `eval` on user input; use arrays for dynamic command construction
- Set restrictive umask for sensitive operations: `(umask 077; touch "$secure_file")`
- Log security-relevant operations (authentication, privilege changes, file access)
- Use `--` to separate options from arguments: `rm -rf -- "$user_input"`
- Validate environment variables before using: `: "${REQUIRED_VAR:?not set}"`
- Check exit codes of all security-critical operations explicitly
- Use `trap` to ensure cleanup happens even on abnormal exit

## Performance Optimization

- Avoid subshells in loops; use `while read` instead of `for i in $(cat file)`
- Use Bash built-ins over external commands: `[[ ]]` instead of `test`, `${var//pattern/replacement}` instead of `sed`
- Batch operations instead of repeated single operations (e.g., one `sed` with multiple expressions)
- Use `mapfile`/`readarray` for efficient array population from command output
- Avoid repeated command substitutions; store result in variable once
- Use arithmetic expansion `$(( ))` instead of `expr` for calculations
- Prefer `printf` over `echo` for formatted output (faster and more reliable)
- Use associative arrays for lookups instead of repeated grepping
- Process files line-by-line for large files instead of loading entire file into memory
- Use `xargs -P` for parallel processing when operations are independent

## Documentation Standards

- Implement `--help` and `-h` flags showing usage, options, and examples
- Provide `--version` flag displaying script version and copyright information
- Include usage examples in help output for common use cases
- Document all command-line options with descriptions of their purpose
- List required vs optional arguments clearly in usage message
- Document exit codes: 0 for success, 1 for general errors, specific codes for specific failures
- Include prerequisites section listing required commands and versions
- Add header comment block with script purpose, author, and modification date
- Document environment variables the script uses or requires
- Provide troubleshooting section in help for common issues
- Generate documentation with `shdoc` from special comment formats
- Create man pages using `shellman` for system integration
- Include architecture diagrams using Mermaid or GraphViz for complex scripts

## Modern Bash Features (5.x)

- **Bash 5.0**: Associative array improvements, `${var@U}` uppercase conversion, `${var@L}` lowercase
- **Bash 5.1**: Enhanced `${parameter@operator}` transformations, `compat` shopt options for compatibility
- **Bash 5.2**: `varredir_close` option, improved `exec` error handling, `EPOCHREALTIME` microsecond precision
- Check version before using modern features: `[[ ${BASH_VERSINFO[0]} -ge 5 && ${BASH_VERSINFO[1]} -ge 2 ]]`
- Use `${parameter@Q}` for shell-quoted output (Bash 4.4+)
- Use `${parameter@E}` for escape sequence expansion (Bash 4.4+)
- Use `${parameter@P}` for prompt expansion (Bash 4.4+)
- Use `${parameter@A}` for assignment format (Bash 4.4+)
- Employ `wait -n` to wait for any background job (Bash 4.3+)
- Use `mapfile -d delim` for custom delimiters (Bash 4.4+)

## CI/CD Integration

- **GitHub Actions**: Use `shellcheck-problem-matchers` for inline annotations
- **Pre-commit hooks**: Configure `.pre-commit-config.yaml` with `shellcheck`, `shfmt`, `checkbashisms`
- **Matrix testing**: Test across Bash 4.4, 5.0, 5.1, 5.2 on Linux and macOS
- **Container testing**: Use official bash:5.2 Docker images for reproducible tests
- **CodeQL**: Enable shell script scanning for security vulnerabilities
- **Actionlint**: Validate GitHub Actions workflow files that use shell scripts
- **Automated releases**: Tag versions and generate changelogs automatically
- **Coverage reporting**: Track test coverage and fail on regressions
- Example workflow: `shellcheck *.sh && shfmt -d *.sh && bats test/`

## Security Scanning & Hardening

- **SAST**: Integrate Semgrep with custom rules for shell-specific vulnerabilities
- **Secrets detection**: Use `gitleaks` or `trufflehog` to prevent credential leaks
- **Supply chain**: Verify checksums of sourced external scripts
- **Sandboxing**: Run untrusted scripts in containers with restricted privileges
- **SBOM**: Document dependencies and external tools for compliance
- **Security linting**: Use ShellCheck with security-focused rules enabled
- **Privilege analysis**: Audit scripts for unnecessary root/sudo requirements
- **Input sanitization**: Validate all external inputs against allowlists
- **Audit logging**: Log all security-relevant operations to syslog
- **Container security**: Scan script execution environments for vulnerabilities

## Observability & Logging

- **Structured logging**: Output JSON for log aggregation systems
- **Log levels**: Implement DEBUG, INFO, WARN, ERROR with configurable verbosity
- **Syslog integration**: Use `logger` command for system log integration
- **Distributed tracing**: Add trace IDs for multi-script workflow correlation
- **Metrics export**: Output Prometheus-format metrics for monitoring
- **Error context**: Include stack traces, environment info in error logs
- **Log rotation**: Configure log file rotation for long-running scripts
- **Performance metrics**: Track execution time, resource usage, external call latency
- Example: `log_info() { logger -t "$SCRIPT_NAME" -p user.info "$*"; echo "[INFO] $*" >&2; }`

## Quality Checklist

- Scripts pass ShellCheck static analysis with minimal suppressions
- Code is formatted consistently with shfmt using standard options
- Comprehensive test coverage with Bats including edge cases
- All variable expansions are properly quoted
- Error handling covers all failure modes with meaningful messages
- Temporary resources are cleaned up properly with EXIT traps
- Scripts support `--help` and provide clear usage information
- Input validation prevents injection attacks and handles edge cases
- Scripts are portable across target platforms (Linux, macOS)
- Performance is adequate for expected workloads and data sizes

## Output

- Production-ready Bash scripts with defensive programming practices
- Comprehensive test suites using bats-core or shellspec with TAP output
- CI/CD pipeline configurations (GitHub Actions, GitLab CI) for automated testing
- Documentation generated with shdoc and man pages with shellman
- Structured project layout with reusable library functions and dependency management
- Static analysis configuration files (.shellcheckrc, .shfmt.toml, .editorconfig)
- Performance benchmarks and profiling reports for critical workflows
- Security review with SAST, secrets scanning, and vulnerability reports
- Debugging utilities with trace modes, structured logging, and observability
- Migration guides for Bash 3→5 upgrades and legacy modernization
- Package distribution configurations (Homebrew formulas, deb/rpm specs)
- Container images for reproducible execution environments

## Essential Tools

### Static Analysis & Formatting
- **ShellCheck**: Static analyzer with `enable=all` and `external-sources=true` configuration
- **shfmt**: Shell script formatter with standard config (`-i 2 -ci -bn -sr -kp`)
- **checkbashisms**: Detect bash-specific constructs for portability analysis
- **Semgrep**: SAST with custom rules for shell-specific security issues
- **CodeQL**: GitHub's security scanning for shell scripts

### Testing Frameworks
- **bats-core**: Maintained fork of Bats with modern features and active development
- **shellspec**: BDD-style testing framework with rich assertions and mocking
- **shunit2**: xUnit-style testing framework for shell scripts
- **bashing**: Testing framework with mocking support and test isolation

### Modern Development Tools
- **bashly**: CLI framework generator for building command-line applications
- **basher**: Bash package manager for dependency management
- **bpkg**: Alternative bash package manager with npm-like interface
- **shdoc**: Generate markdown documentation from shell script comments
- **shellman**: Generate man pages from shell scripts

### CI/CD & Automation
- **pre-commit**: Multi-language pre-commit hook framework
- **actionlint**: GitHub Actions workflow linter
- **gitleaks**: Secrets scanning to prevent credential leaks
- **Makefile**: Automation for lint, format, test, and release workflows

## Common Pitfalls to Avoid

- `for f in $(ls ...)` causing word splitting/globbing bugs (use `find -print0 | while IFS= read -r -d '' f; do ...; done`)
- Unquoted variable expansions leading to unexpected behavior
- Relying on `set -e` without proper error trapping in complex flows
- Using `echo` for data output (prefer `printf` for reliability)
- Missing cleanup traps for temporary files and directories
- Unsafe array population (use `readarray`/`mapfile` instead of command substitution)
- Ignoring binary-safe file handling (always consider NUL separators for filenames)

## Dependency Management

- **Package managers**: Use `basher` or `bpkg` for installing shell script dependencies
- **Vendoring**: Copy dependencies into project for reproducible builds
- **Lock files**: Document exact versions of dependencies used
- **Checksum verification**: Verify integrity of sourced external scripts
- **Version pinning**: Lock dependencies to specific versions to prevent breaking changes
- **Dependency isolation**: Use separate directories for different dependency sets
- **Update automation**: Automate dependency updates with Dependabot or Renovate
- **Security scanning**: Scan dependencies for known vulnerabilities
- Example: `basher install username/repo@version` or `bpkg install username/repo -g`

## Advanced Techniques

- **Error Context**: Use `trap 'echo "Error at line $LINENO: exit $?" >&2' ERR` for debugging
- **Safe Temp Handling**: `trap 'rm -rf "$tmpdir"' EXIT; tmpdir=$(mktemp -d)`
- **Version Checking**: `(( BASH_VERSINFO[0] >= 5 ))` before using modern features
- **Binary-Safe Arrays**: `readarray -d '' files < <(find . -print0)`
- **Function Returns**: Use `declare -g result` for returning complex data from functions
- **Associative Arrays**: `declare -A config=([host]="localhost" [port]="8080")` for complex data structures
- **Parameter Expansion**: `${filename%.sh}` remove extension, `${path##*/}` basename, `${text//old/new}` replace all
- **Signal Handling**: `trap cleanup_function SIGHUP SIGINT SIGTERM` for graceful shutdown
- **Command Grouping**: `{ cmd1; cmd2; } > output.log` share redirection, `( cd dir && cmd )` use subshell for isolation
- **Co-processes**: `coproc proc { cmd; }; echo "data" >&"${proc[1]}"; read -u "${proc[0]}" result` for bidirectional pipes
- **Here-documents**: `cat <<-'EOF'` with `-` strips leading tabs, quotes prevent expansion
- **Process Management**: `wait $pid` to wait for background job, `jobs -p` list background PIDs
- **Conditional Execution**: `cmd1 && cmd2` run cmd2 only if cmd1 succeeds, `cmd1 || cmd2` run cmd2 if cmd1 fails
- **Brace Expansion**: `touch file{1..10}.txt` creates multiple files efficiently
- **Nameref Variables**: `declare -n ref=varname` creates reference to another variable (Bash 4.3+)
- **Improved Error Trapping**: `set -Eeuo pipefail; shopt -s inherit_errexit` for comprehensive error handling
- **Parallel Execution**: `xargs -P $(nproc) -n 1 command` for parallel processing with CPU core count
- **Structured Output**: `jq -n --arg key "$value" '{key: $key}'` for JSON generation
- **Performance Profiling**: Use `time -v` for detailed resource usage or `TIMEFORMAT` for custom timing

# Bash Linux Patterns

> Essential patterns for Bash on Linux/macOS.

---

## 1. Operator Syntax

### Chaining Commands

| Operator | Meaning | Example |
|----------|---------|---------|
| `;` | Run sequentially | `cmd1; cmd2` |
| `&&` | Run if previous succeeded | `npm install && npm run dev` |
| `\|\|` | Run if previous failed | `npm test \|\| echo "Tests failed"` |
| `\|` | Pipe output | `ls \| grep ".js"` |

---

## 2. File Operations

### Essential Commands

| Task | Command |
|------|---------|
| List all | `ls -la` |
| Find files | `find . -name "*.js" -type f` |
| File content | `cat file.txt` |
| First N lines | `head -n 20 file.txt` |
| Last N lines | `tail -n 20 file.txt` |
| Follow log | `tail -f log.txt` |
| Search in files | `grep -r "pattern" --include="*.js"` |
| File size | `du -sh *` |
| Disk usage | `df -h` |

---

## 3. Process Management

| Task | Command |
|------|---------|
| List processes | `ps aux` |
| Find by name | `ps aux \| grep node` |
| Kill by PID | `kill -9 <PID>` |
| Find port user | `lsof -i :3000` |
| Kill port | `kill -9 $(lsof -t -i :3000)` |
| Background | `npm run dev &` |
| Jobs | `jobs -l` |
| Bring to front | `fg %1` |

---

## 4. Text Processing

### Core Tools

| Tool | Purpose | Example |
|------|---------|---------|
| `grep` | Search | `grep -rn "TODO" src/` |
| `sed` | Replace | `sed -i 's/old/new/g' file.txt` |
| `awk` | Extract columns | `awk '{print $1}' file.txt` |
| `cut` | Cut fields | `cut -d',' -f1 data.csv` |
| `sort` | Sort lines | `sort -u file.txt` |
| `uniq` | Unique lines | `sort file.txt \| uniq -c` |
| `wc` | Count | `wc -l file.txt` |

---

## 5. Environment Variables

| Task | Command |
|------|---------|
| View all | `env` or `printenv` |
| View one | `echo $PATH` |
| Set temporary | `export VAR="value"` |
| Set in script | `VAR="value" command` |
| Add to PATH | `export PATH="$PATH:/new/path"` |

---

## 6. Network

| Task | Command |
|------|---------|
| Download | `curl -O https://example.com/file` |
| API request | `curl -X GET https://api.example.com` |
| POST JSON | `curl -X POST -H "Content-Type: application/json" -d '{"key":"value"}' URL` |
| Check port | `nc -zv localhost 3000` |
| Network info | `ifconfig` or `ip addr` |

---

## 7. Script Template

```bash
#!/bin/bash
set -euo pipefail  # Exit on error, undefined var, pipe fail

# Colors (optional)
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Main
main() {
    log_info "Starting..."
    # Your logic here
    log_info "Done!"
}

main "$@"
```

---

## 8. Common Patterns

### Check if command exists

```bash
if command -v node &> /dev/null; then
    echo "Node is installed"
fi
```

### Default variable value

```bash
NAME=${1:-"default_value"}
```

### Read file line by line

```bash
while IFS= read -r line; do
    echo "$line"
done < file.txt
```

### Loop over files

```bash
for file in *.js; do
    echo "Processing $file"
done
```

---

## 9. Differences from PowerShell

| Task | PowerShell | Bash |
|------|------------|------|
| List files | `Get-ChildItem` | `ls -la` |
| Find files | `Get-ChildItem -Recurse` | `find . -type f` |
| Environment | `$env:VAR` | `$VAR` |
| String concat | `"$a$b"` | `"$a$b"` (same) |
| Null check | `if ($x)` | `if [ -n "$x" ]` |
| Pipeline | Object-based | Text-based |

---

## 10. Error Handling

### Set options

```bash
set -e          # Exit on error
set -u          # Exit on undefined variable
set -o pipefail # Exit on pipe failure
set -x          # Debug: print commands
```

### Trap for cleanup

```bash
cleanup() {
    echo "Cleaning up..."
    rm -f /tmp/tempfile
}
trap cleanup EXIT
```

---

> **Remember:** Bash is text-based. Use `&&` for success chains, `set -e` for safety, and quote your variables!
