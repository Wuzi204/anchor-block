#!/usr/bin/env bash
#
# triage.sh — Tự động hóa khâu lọc false positive bằng Claude Code (headless).
#
# Chạy TRONG thư mục gốc của repo target đã clone (để Claude đọc được source code).
# Lấy semgrep.json (từ CI artifact hoặc quét local) rồi gọi `claude -p` sinh triage-report.md.
#
# Cách dùng:
#   ./triage.sh                      # mặc định: tải artifact mới nhất từ GitHub Actions
#   ./triage.sh --from-ci            # như trên, nói rõ
#   ./triage.sh --from-ci --repo me/plugin-x   # chỉ định repo nếu gh không tự nhận
#   ./triage.sh --local              # quét semgrep local trên thư mục hiện tại
#   ./triage.sh --local ./src        # quét local trên ./src
#   ./triage.sh --file semgrep.json  # dùng file JSON có sẵn
#
set -euo pipefail

# ---- Cấu hình (sửa nếu cần) -------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_PROMPT_FILE="${SCRIPT_DIR}/triage-system-prompt.md"
FINDINGS_FILE="semgrep.json"
REPORT_FILE="triage-report.md"
ARTIFACT_NAME="semgrep-findings"
SEMGREP_CONFIGS=(--config p/default --config p/security-audit --config p/secrets --config "${SCRIPT_DIR}/../rules")
CLAUDE_MAX_TURNS="${CLAUDE_MAX_TURNS:-60}"
CLAUDE_MAX_BUDGET="${CLAUDE_MAX_BUDGET:-3}"   # USD; bỏ nếu bạn không muốn giới hạn chi phí

# ---- Phân tích tham số ------------------------------------------------------
MODE="from-ci"
TARGET="."
REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-ci) MODE="from-ci"; shift ;;
    --local)   MODE="local"; shift
               if [[ $# -gt 0 && "$1" != --* ]]; then TARGET="$1"; shift; fi ;;
    --file)    MODE="file"; FINDINGS_FILE="${2:?--file cần đường dẫn}"; shift 2 ;;
    --repo)    REPO="${2:?--repo cần OWNER/REPO}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Tham số lạ: $1" >&2; exit 2 ;;
  esac
done

# ---- Kiểm tra công cụ -------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Thiếu '$1' trong PATH." >&2; exit 1; }; }
need claude
[[ -f "$SYSTEM_PROMPT_FILE" ]] || { echo "❌ Không thấy system prompt: $SYSTEM_PROMPT_FILE" >&2; exit 1; }

# ---- Bước 1: lấy findings ---------------------------------------------------
case "$MODE" in
  from-ci)
    need gh
    echo "⏬ Tải artifact '$ARTIFACT_NAME' từ run GitHub Actions mới nhất..."
    rm -f "$FINDINGS_FILE" semgrep.sarif
    GH_ARGS=(run download --name "$ARTIFACT_NAME" --dir .)
    [[ -n "$REPO" ]] && GH_ARGS+=(--repo "$REPO")
    if ! gh "${GH_ARGS[@]}"; then
      echo "❌ Không tải được artifact. Kiểm tra: đã 'gh auth login' chưa, repo đúng chưa, run có artifact chưa." >&2
      exit 1
    fi
    ;;
  local)
    need semgrep
    echo "🔎 Quét semgrep local trên '$TARGET'..."
    semgrep scan "${SEMGREP_CONFIGS[@]}" \
      --json-output="$FINDINGS_FILE" --metrics=off --timeout 120 "$TARGET" \
      || echo "   (semgrep kết thúc có finding/lỗi nhẹ — tiếp tục)"
    ;;
  file)
    echo "📄 Dùng file có sẵn: $FINDINGS_FILE"
    ;;
esac

[[ -f "$FINDINGS_FILE" ]] || { echo "❌ Không có $FINDINGS_FILE để triage." >&2; exit 1; }

# Đếm finding; nếu rỗng thì khỏi tốn tiền gọi Claude.
COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("results",[])))' "$FINDINGS_FILE" 2>/dev/null || echo "?")"
echo "📊 Semgrep có $COUNT finding."
if [[ "$COUNT" == "0" ]]; then
  echo "✅ Không có finding nào — không cần triage."
  exit 0
fi

# Cảnh báo giới hạn stdin 10MB của claude -p: ta tham chiếu FILE, không pipe.
SIZE_MB="$(du -m "$FINDINGS_FILE" | cut -f1)"
[[ "$SIZE_MB" -ge 9 ]] && echo "⚠️  $FINDINGS_FILE ~${SIZE_MB}MB — Claude sẽ đọc qua Read (không pipe), nên vẫn ổn."

# ---- Bước 2: gọi Claude headless triage ------------------------------------
echo "🤖 Gọi Claude triage (đọc code + ghi $REPORT_FILE)..."
PROMPT="Đọc file ${FINDINGS_FILE} trong thư mục hiện tại và triage toàn bộ finding theo đúng quy trình trong system prompt. Với mỗi finding, hãy Read file nguồn tương ứng để kiểm chứng. Ghi kết quả ra ${REPORT_FILE}."

CLAUDE_ARGS=(
  -p "$PROMPT"
  --append-system-prompt "$(cat "$SYSTEM_PROMPT_FILE")"
  --allowedTools "Read,Grep,Glob,Write"
  --permission-mode acceptEdits
  --max-turns "$CLAUDE_MAX_TURNS"
  --output-format text
)
[[ -n "${CLAUDE_MAX_BUDGET}" ]] && CLAUDE_ARGS+=(--max-budget-usd "$CLAUDE_MAX_BUDGET")

claude "${CLAUDE_ARGS[@]}"

# ---- Kết quả ----------------------------------------------------------------
echo
if [[ -f "$REPORT_FILE" ]]; then
  echo "✅ Xong. Báo cáo triage: $(pwd)/$REPORT_FILE"
  echo "   Mở ra review các mục TP và NEEDS-REVIEW để kiểm chứng thật (bước thủ công của bạn)."
else
  echo "⚠️  Claude chạy xong nhưng chưa thấy $REPORT_FILE — xem lại output phía trên." >&2
fi
