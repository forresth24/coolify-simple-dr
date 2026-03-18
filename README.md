# coolify-simple-dr

A minimal disaster recovery (DR) script set for Coolify, using **restic + rclone** with a remote backup backend.

> Note: the env variable name is still `GDRIVE_REMOTE` for backward compatibility, but the remote can be any rclone backend (Google Drive, S3, B2, etc.) as long as it is configured in `rclone`.

## Features

- Incremental backups every minute (`systemd` timer).
- Split-brain protection via DNS guard checks before critical scripts run.
- Integrity verification before backup/upload (`verify-backup.sh`).
- Timestamped logs with host/IP metadata (`/var/log/coolify-dr`).
- Periodic sandbox restore testing (`restore-test.sh`).

## Main scripts

- `backup.sh`
- `retention.sh`
- `verify-backup.sh`
- `restore-test.sh`
- `coolify-dr.sh` (main entrypoint)
- `dr.sh` (compatibility wrapper)
- `install.sh`
- `start-safe.sh`

## Quick install

```bash
git clone <repo>
cd coolify-simple-dr
sudo bash install.sh
```

`install.sh` expects `/etc/coolify-dr.env` to exist (it does not create temporary config files). If this is a fresh setup, prefer the one-command flow below so the script can prompt for all required values.

If you already have the env file, update `/etc/coolify-dr.env`:

```bash
DR_DOMAIN=your-domain.com
GDRIVE_REMOTE=myremote:coolify-dr
BACKUP_TARGETS="/data/coolify /var/lib/docker/volumes"
```

## One-command DR bootstrap

```bash
curl -fsSL https://repo/coolify-dr.sh | DR_SCRIPT_URL="https://repo/coolify-dr.sh" bash
```

The bootstrap script will:

1. Auto-derive `DR_REPO_RAW_BASE` from `DR_SCRIPT_URL`.
2. If `/etc/coolify-dr.env` already exists and has non-empty bootstrap values, show them first and ask whether to overwrite before prompting again.
3. Prompt and validate key values (`DR_REPO_RAW_BASE`, `DR_DOMAIN`, `GDRIVE_REMOTE`, `BACKUP_TARGETS`).
4. Show a full configuration summary for confirmation.

Confirmation behavior:

- Press `Y`, `y`, or `Enter` to continue.
- Press any other key to cancel confirmation: the script removes `/etc/coolify-dr.env`, clears old values, and restarts the prompt flow.

After confirmation, it saves `/etc/coolify-dr.env`, downloads remaining scripts from `DR_REPO_RAW_BASE`, installs to `/opt/coolify-dr`, and runs restore.

> `coolify-dr.sh` and `install.sh` must run as `root` (or `sudo`).

> `DR_DOMAIN` note:
> - The DNS `A` record of `DR_DOMAIN` must point to the current VPS before running (split-brain guard).
> - If you use Cloudflare, disable proxy (`DNS only`) during DR checks so public IP comparison works.

> `GDRIVE_REMOTE` note: must be in `remote:path` format (example: `myremote:coolify-dr`). Install/bootstrap validates format only; runtime scripts validate the remote really exists in `rclone config`.

## rclone configuration (correct-result guide)

On the DR VPS, configure a remote with the same name used in `GDRIVE_REMOTE` (example remote name: `myremote`).

### Interactive setup

```bash
rclone config
```

Create a new remote and follow your backend-specific auth flow.

### Check which config file is used

```bash
rclone config file
```

Example expected output:

```text
Configuration file is stored at:
/root/.config/rclone/rclone.conf
```

### Example of a valid config snippet

If `GDRIVE_REMOTE=myremote:coolify-dr`, your config file should contain a matching section header:

```ini
[myremote]
type = drive
scope = drive
token = {"access_token":"...","token_type":"Bearer","refresh_token":"...","expiry":"2026-01-01T00:00:00Z"}
```

> The exact keys vary by backend (`drive`, `s3`, `b2`, ...), but `[myremote]` must exist.

### Verify remote and list data

```bash
rclone listremotes
rclone lsd myremote:coolify-dr
```

- `rclone listremotes` should include `myremote:`.
- `rclone lsd myremote:coolify-dr` should list directories (or return empty if the path is new).

If you configured rclone on another machine, copy the config file to the VPS path returned by `rclone config file`, then re-run the checks above.
If your rclone remote already has `root_folder_id` set to the backup folder itself (for example the folder `ncoolify-dr`), set `GDRIVE_REMOTE` to just `remote:` (or keep `remote:ncoolify-dr` and let the scripts normalize it). Otherwise `remote:ncoolify-dr` can create a nested `ncoolify-dr/ncoolify-dr` structure.


## Domain-separated backups

Restic repository path is automatically namespaced by domain:

- `rclone:${GDRIVE_REMOTE}/${DR_DOMAIN}/restic`

Example with:

- `GDRIVE_REMOTE=myremote:coolify-dr`
- `DR_DOMAIN=dr-new.example.com`

Resulting backup location:

- `myremote:coolify-dr/dr-new.example.com/restic`

When running `coolify-dr.sh`, it:

1. Lists first-level folders under `GDRIVE_REMOTE` (treated as domain candidates).
2. Prompts you to choose a restore folder (number or folder name).
3. Restores the latest snapshot from that folder.

Non-interactive restore example:

```bash
DR_RESTORE_DOMAIN_FOLDER=dr-new.example.com sudo /opt/coolify-dr/coolify-dr.sh
```

If `DR_RESTORE_DOMAIN_FOLDER` is not set and no TTY is available, it defaults to `DR_DOMAIN`.

## Restic password requirements

The DR/restore host must use the same restic password as the primary backup host.

- Primary mode (`DR_BOOTSTRAP_MODE=primary`) auto-generates `/etc/coolify-dr/restic-password` only when the file does not exist yet.
- Restore mode does **not** generate a replacement password anymore, because that causes restic to fail with `Fatal: wrong password or no key found` against an existing repository.
- Before restore, copy the original `/etc/coolify-dr/restic-password` from the primary server to the DR server and run `chmod 600 /etc/coolify-dr/restic-password`.
- As an alternative, export `RESTIC_PASSWORD` in the environment before running the scripts.
- If you now get `Fatal: config cannot be loaded: unsupported repository version`, the password is likely correct but the DR host's `restic` binary is older than the repository format created on the primary host. Upgrade `restic` on the DR host to the same or newer version than the primary host, then retry.


## One-command for the primary instance (install + cron + first upload)

Use the shared `coolify-dr.sh` entrypoint on the **primary Coolify instance** before running restore mode on the second DR instance:

```bash
curl -fsSL https://repo/coolify-dr.sh | DR_SCRIPT_URL="https://repo/coolify-dr.sh" DR_BOOTSTRAP_MODE=primary bash
```

Primary mode will:

1. Run bootstrap/install flow first.
2. Install `crontab` (`cron`/`cronie`) if the command is missing.
3. Validate runtime prerequisites (including rclone remote configuration) before scheduling backups.
4. Add an idempotent backup cron job (`*/5 * * * * /opt/coolify-dr/backup.sh`) if not already present.
5. Run `backup.sh` immediately for the first upload.

You can override the cron schedule with `CRON_SCHEDULE`, for example:

```bash
CRON_SCHEDULE="*/10 * * * *" DR_BOOTSTRAP_MODE=primary bash coolify-dr.sh
```

## DR workflow

1. Provision a new VPS.
2. Point DNS to the new VPS.
3. Run `coolify-dr.sh`.
4. Restore the latest snapshot from the configured remote.
5. Start services safely with `start-safe.sh`; immediate backup afterward is optional.

## Documentation links

- rclone docs: <https://rclone.org/docs/>
- rclone config docs: <https://rclone.org/commands/rclone_config/>
- restic docs: <https://restic.readthedocs.io/en/stable/>
- systemd timer docs: <https://www.freedesktop.org/software/systemd/man/systemd.timer.html>
- jq docs: <https://jqlang.github.io/jq/>

## ChatGPT Codex project kit

This repo also includes `chatgpt-project/` templates for Bash scripting workflows in chatgpt.com/codex (standard mode + optional hardening checklist mode). See `chatgpt-project/README.md`.
