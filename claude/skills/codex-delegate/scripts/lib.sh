# shellcheck shell=bash
# run.sh / pane.sh 共用的函数。用 source 引入，不要直接执行。

SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCHEMA="$SKILL_DIR/references/result-schema.json"
PROTOCOL="$SKILL_DIR/references/protocol.md"

die() { echo "错误: $*" >&2; exit 2; }

# 把当前 meta 变量写回 meta.env（值经 %q 转义，可安全 source）
save_meta() {
  local k
  : > "$META"
  for k in "$@"; do printf '%s=%q\n' "$k" "${!k-}" >> "$META"; done
}

# 本轮停下却没交付结果时，最多自动催促继续的次数
MAX_CONTINUES="${CODEX_DELEGATE_MAX_CONTINUES:-5}"

# 催促继续的消息。$1 为交付说明（文件路径或"最后一条消息只输出 JSON"）
continue_msg() {
  printf '%s' "你停下了，但还没有交付本轮结果。不要等待回复：如果执行计划还有未完成的步骤，并且没有遇到协议规定必须停下询问的情况，请直接继续执行剩余步骤。全部完成，或者遇到必须停下的情况时，再交付结果：$1"
}

# 结果文件是否为合法的结果对象
result_valid() { jq -e 'type=="object" and has("status") and has("summary")' "$1" >/dev/null 2>&1; }

# 非 OpenAI 模型常在 JSON 前夹带文字。截取末尾的结果 JSON 覆盖回原文件，原文另存为 <name>.raw.txt
result_extract() {
  local f="$1" extracted
  [[ -s "$f" ]] || return 1
  result_valid "$f" && return 0
  extracted="$(jq -Rse '[splits("\n")] as $l
      | first(range(0; $l|length) as $k | ($l[$k:] | join("\n")) | try fromjson catch empty
              | select(type=="object" and has("status")))' "$f" 2>/dev/null)" || return 1
  cp "$f" "${f%.json}.raw.txt"
  printf '%s\n' "$extracted" > "$f"
}

# 打印结果摘要：尽量让 Claude 不必再读结果文件就能决定下一步；字段缺失时容错
result_summary() {
  jq -r --arg file "$1" '
    def arr(f): (f // []) | if type == "array" then . else [.] end;
    "status: \(.status)",
    "summary: \(.summary)",
    (arr(.steps) as $s | if ($s|length) > 0 then
       "steps: " + ([$s[] | "\(.id)=\(.status)"] | join(" ")),
       ($s[] | select(.status != "done") | "  - 步骤 \(.id) [\(.status)] \(.note)")
     else "steps: （未回报）" end),
    (arr(.changed_files) | if length > 0 then "changed_files: \(join(", "))" else empty end),
    (arr(.test_files) | if length > 0 then "test_files: \(join(", "))" else empty end),
    (arr(.verification) as $v | if ($v|length) > 0 then "verification:",
       ($v[] | if type == "object" then "  - [\(.result)] \(.command)" + (if .result != "passed" then " — \(.detail)" else "" end) else "  - \(.)" end)
     else "verification: （未回报）" end),
    (arr(.questions) | if length > 0 then "questions:", (.[] | "  - [\(.id)] \(.question)\n    选项: \((.options // []) | join(" / "))\n    推荐: \(.recommendation)\n    影响: \(.impact)") else empty end),
    (arr(.assumptions) | if length > 0 then "assumptions:", (.[] | "  - \(.)") else empty end),
    (arr(.issues) | if length > 0 then "issues:", (.[] | "  - \(.)") else empty end),
    "完整结果: \($file)"' "$1"
}
