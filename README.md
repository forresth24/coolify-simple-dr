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
- `dr.sh`
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
curl -fsSL https://repo/dr.sh | DR_SCRIPT_URL="https://repo/dr.sh" bash
```

The bootstrap script will:

1. Auto-derive `DR_REPO_RAW_BASE` from `DR_SCRIPT_URL`.
2. Prompt and validate key values (`DR_REPO_RAW_BASE`, `DR_DOMAIN`, `GDRIVE_REMOTE`, `BACKUP_TARGETS`).
3. Show a full configuration summary for confirmation.

Confirmation behavior:

- Press `Y`, `y`, or `Enter` to continue.
- Press any other key to cancel confirmation: the script removes `/etc/coolify-dr.env`, clears old values, and restarts the prompt flow.

After confirmation, it saves `/etc/coolify-dr.env`, downloads remaining scripts from `DR_REPO_RAW_BASE`, installs to `/opt/coolify-dr`, and runs restore.

> `dr.sh` and `install.sh` must run as `root` (or `sudo`).

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

## Domain-separated backups

Restic repository path is automatically namespaced by domain:

- `rclone:${GDRIVE_REMOTE}/${DR_DOMAIN}/restic`

Example with:

- `GDRIVE_REMOTE=myremote:coolify-dr`
- `DR_DOMAIN=dr-new.example.com`

Resulting backup location:

- `myremote:coolify-dr/dr-new.example.com/restic`

When running `dr.sh`, it:

1. Lists first-level folders under `GDRIVE_REMOTE` (treated as domain candidates).
2. Prompts you to choose a restore folder (number or folder name).
3. Restores the latest snapshot from that folder.

Non-interactive restore example:

```bash
DR_RESTORE_DOMAIN_FOLDER=dr-new.example.com sudo /opt/coolify-dr/dr.sh
```

If `DR_RESTORE_DOMAIN_FOLDER` is not set and no TTY is available, it defaults to `DR_DOMAIN`.

## DR workflow

1. Provision a new VPS.
2. Point DNS to the new VPS.
3. Run `dr.sh`.
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
