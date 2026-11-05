# Custom rules

Mọi file `.yaml` / `.yml` ở đây được nạp qua `--config ./rules` (cả trong CI lẫn script local).

## Thêm rule mới
1. Copy `example-command-injection.yaml` → đổi `id`, `languages`, `pattern-sources/sinks`.
2. Test cục bộ: `semgrep scan --test` (nếu có fixtures) hoặc chạy trên 1 file mẫu.
3. Commit — CI tự quét bằng rule mới ở lần push sau.

## Mẹo săn CVE
- Dùng `mode: taint` (source → sink) để giảm false positive thay vì match thô.
- Đặt `confidence: MEDIUM/LOW` cho rule rộng — để khâu Claude triage lọc tiếp.
- Mỗi lớp lỗ hổng (SSRFi, path traversal, deserialization, SQLi, SSTI...) nên là 1 file riêng cho dễ quản lý.
