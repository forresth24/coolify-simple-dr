# coolify-simple-dr

Bộ script DR tối giản cho Coolify với **1 nguồn backup duy nhất: Google Drive** (qua `rclone` + `restic`).

## Tính năng

- Backup incremental mỗi 1 phút (`systemd timer`).
- Chống split-brain: mọi script quan trọng đều check DNS guard trước khi chạy.
- Verify integrity trước khi backup/upload (`verify-backup.sh`).
- Log đầy đủ theo thời gian + metadata host/IP (`/var/log/coolify-dr`).
- Tự backup ngay sau DR restore thành công (`start-safe.sh` gọi `backup.sh`).
- Tự kiểm tra restore sandbox định kỳ (`restore-test.sh`).

## File chính

- `backup.sh`
- `retention.sh`
- `verify-backup.sh`
- `restore-test.sh`
- `dr.sh`
- `install.sh`
- `start-safe.sh`

## Cài đặt nhanh

```bash
git clone <repo>
cd coolify-simple-dr
sudo bash install.sh
```

Sau đó sửa `/etc/coolify-dr.env`:

```bash
DR_DOMAIN=your-domain.com
GDRIVE_REMOTE=gdrive:coolify-dr
BACKUP_TARGETS="/data/coolify /var/lib/docker/volumes"
```

Và cấu hình `rclone config` để có remote `gdrive`.

## DR one-command

```bash
curl -fsSL https://repo/dr.sh | bash
```

Script bootstrap sẽ hỏi các biến quan trọng (`DR_REPO_RAW_BASE`, `DR_DOMAIN`, `GDRIVE_REMOTE`, `BACKUP_TARGETS`), lưu vào `/etc/coolify-dr.env`, tải toàn bộ script còn lại từ `DR_REPO_RAW_BASE`, cài đặt vào `/opt/coolify-dr`, rồi tự chạy restore.

> Lưu ý: DNS `A` record của `DR_DOMAIN` phải trỏ về VPS hiện tại trước khi chạy (guard chống split-brain).

## Luồng DR

1. Spin up VPS mới.
2. Trỏ DNS về VPS mới.
3. Chạy `dr.sh`.
4. Script restore snapshot mới nhất từ Google Drive.
5. `start-safe.sh` khởi động lại dịch vụ và tạo backup mới ngay lập tức.
