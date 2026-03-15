# ChatGPT Codex Project Kit (Bash Scripting)

Bộ kit này chuyển đổi ý tưởng từ skill `bash-scripting` sang dạng dùng trực tiếp trong project chatgpt.com/codex (không cần cài local skill vào `~/.codex/skills`).

## Vì sao không nhét toàn bộ rules cực dài vào project instructions?

Có thể làm được, nhưng không nên để nguyên khối vì sẽ:

- làm instructions nặng và khó tái sử dụng,
- khiến Codex áp dụng quá mức cho task đơn giản,
- tăng nhiễu khi yêu cầu chỉ cần sửa nhỏ.

Kit này dùng mô hình **2 tầng**:

1. **Tầng mặc định (ngắn gọn)**: `prompts/bash-scripting-system-prompt.md`
2. **Tầng hardening (mở rộng theo nhu cầu)**: `references/bash-hardening-checklist.md`

=> Khi cần tiêu chuẩn production/security cao, chỉ cần yêu cầu "hardening mode".

## Cấu trúc

- `prompts/bash-scripting-system-prompt.md`: project instructions ngắn gọn, có workflow rõ ràng.
- `prompts/task-template.md`: template giao task với profile Standard/Hardening.
- `references/bash-hardening-checklist.md`: checklist mở rộng (safety, portability, observability, CI).
- `scripts/bash-lint-runner.sh`: syntax check bắt buộc (`bash -n`).
- `scripts/bash-quality-gate.sh`: quality gate mở rộng (syntax + shellcheck/shfmt/bats nếu có).

## Cách dùng trên chatgpt.com/codex project

1. Copy `prompts/bash-scripting-system-prompt.md` vào project instructions.
2. Giao task bằng `prompts/task-template.md`.
3. Chạy check bắt buộc:

   ```bash
   ./chatgpt-project/scripts/bash-lint-runner.sh
   ```

4. Nếu task cần hardening, thêm câu này vào prompt:

   ```text
   Use hardening mode from chatgpt-project/references/bash-hardening-checklist.md.
   Apply only relevant items and explain what was applied.
   ```

5. Nếu tool có sẵn, chạy thêm:

   ```bash
   ./chatgpt-project/scripts/bash-quality-gate.sh
   ```

## Gợi ý thực tế

- Task nhỏ: dùng Standard mode để tốc độ cao.
- Task chạm backup/restore, data deletion, quyền root: bật Hardening mode.
- Không bắt buộc cài thêm tool; script quality gate sẽ tự skip phần thiếu.
