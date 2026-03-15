# Task Template for ChatGPT Codex Project

## Goal

<!-- What should be changed? -->

## Instruction profile

- [ ] Standard mode (default)
- [ ] Hardening mode (use `references/bash-hardening-checklist.md` selectively)

## Constraints

- Keep changes minimal and production-safe.
- Do not modify unrelated files.
- Preserve existing behavior unless explicitly requested.

## Environment details

- OS/runtime:
- Relevant paths:
- Service/timer names:

## Acceptance criteria

- [ ] Feature/fix implemented
- [ ] Syntax checks pass for touched shell scripts
- [ ] Summary + risks + rollback provided

## Required command(s)

```bash
./chatgpt-project/scripts/bash-lint-runner.sh
```

## Optional quality gate (if tools are installed)

```bash
./chatgpt-project/scripts/bash-quality-gate.sh
```

## Delivery

- Commit changes with a descriptive message.
- Include rollback steps.
