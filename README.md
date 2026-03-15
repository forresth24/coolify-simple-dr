# coolify-simple-dr

Bộ script DR tối giản cho Coolify với **1 nguồn backup duy nhất: Google Drive** (qua `rclone` + `restic`).

## Tính năng

- Backup incremental mỗi 1 phút (`systemd timer`).
- Chống split-brain: mọi script quan trọng đều check DNS guard trước khi chạy.
- Verify integrity trước khi backup/upload (`verify-backup.sh`).
- Log đầy đủ theo thời gian + metadata host/IP (`/var/log/coolify-dr`).
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

`install.sh` cần sẵn `/etc/coolify-dr.env` (không tự tạo file tạm). Nếu cài mới, nên chạy one-command ở dưới để script hỏi đủ biến.

Nếu đã có env file thì sửa `/etc/coolify-dr.env`:

```bash
DR_DOMAIN=your-domain.com
GDRIVE_REMOTE=gdrive:coolify-dr
BACKUP_TARGETS="/data/coolify /var/lib/docker/volumes"
```

Và cấu hình `rclone config` để có remote `gdrive`.

## DR one-command

```bash
curl -fsSL https://repo/dr.sh | DR_SCRIPT_URL="https://repo/dr.sh" bash
```

Script bootstrap sẽ tự lấy `DR_REPO_RAW_BASE` từ `DR_SCRIPT_URL` (mặc định bằng URL `dr.sh` bỏ phần `/dr.sh`), hỏi kỹ các biến quan trọng (`DR_REPO_RAW_BASE`, `DR_DOMAIN`, `GDRIVE_REMOTE`, `BACKUP_TARGETS`) với validation, sau đó hiển thị lại toàn bộ cấu hình để xác nhận trước khi cài đặt:

- Nhấn `Y`, `y` hoặc `Enter` để tiếp tục.
- Nhấn phím khác để hủy xác nhận: script sẽ xóa `/etc/coolify-dr.env`, bỏ toàn bộ biến cũ và hỏi lại từ đầu (luồng clean/retry an toàn).

Sau khi xác nhận, bootstrap mới lưu vào `/etc/coolify-dr.env`, tải toàn bộ script còn lại từ `DR_REPO_RAW_BASE`, cài đặt vào `/opt/coolify-dr`, rồi tự chạy restore.

> Lưu ý: `dr.sh` và `install.sh` cần chạy bằng `root` (hoặc `sudo`). Nếu chạy non-root, script sẽ cảnh báo sớm và dừng ngay trước khi ghi file hệ thống.

> Lưu ý cho `DR_DOMAIN`:
> - DNS `A` record của `DR_DOMAIN` phải trỏ về VPS hiện tại trước khi chạy (guard chống split-brain).
> - Nếu dùng Cloudflare, **không bật proxy (orange cloud)** cho record này trong lúc DR; để `DNS only` để IP public khớp check guard.

> Lưu ý cho `GDRIVE_REMOTE`: phải đúng format `remote:path` (ví dụ `gdrive:coolify-dr`) và remote đó phải tồn tại trong `rclone config`.

## Luồng DR

1. Spin up VPS mới.
2. Trỏ DNS về VPS mới.
3. Chạy `dr.sh`.
4. Script restore snapshot mới nhất từ Google Drive.
5. `start-safe.sh` chỉ khởi động dịch vụ an toàn; backup ngay lập tức là tùy chọn (chạy tay nếu muốn test).

## ChatGPT Codex project kit

Repo có thêm bộ template tại `chatgpt-project/` để dùng workflow Bash scripting trực tiếp trong project trên chatgpt.com/codex (không phụ thuộc cơ chế cài local skills). Bộ này dùng mô hình instructions 2 tầng (standard + hardening checklist). Xem hướng dẫn trong `chatgpt-project/README.md`.
