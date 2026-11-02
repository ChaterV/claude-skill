# shellcheck shell=bash
# run.sh / pane.sh / tab.sh 共用的函数。用 source 引入，不要直接执行。

SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCHEMA="$SKILL_DIR/references/result-schema.json"
PROTOCOL="$SKILL_DIR/references/protocol.md"

die() { echo "错误: $*" >&2; exit 2; }

# 把当前 meta 变量写回 meta.env（值经 %q 转义，可安全 source）。先写临时文件再改名，
# 避免 tab 模式里 tab-runner.sh 读到写了一半的 meta
save_meta() {
  local k tmp="$META.tmp"
  : > "$tmp"
  for k in "$@"; do printf '%s=%q\n' "$k" "${!k-}" >> "$tmp"; done
  mv -f "$tmp" "$META"
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

# ---- 窗格 / tab 模式共用：Codex 在用户可见的界面中运行，把结果写进文件 ----

# Codex 在界面里向用户提问时，提问消息的最后一行
WAIT_MARK='[等待用户决策]'

# 本轮的结果交付说明（每轮都附上，避免模型遗忘写入的路径）
delivery() {
  printf '\n\n## 结果交付\n\n本轮结束时（包括停下来等待决策时）：\n'
  printf '1. 把结果 JSON 对象写入文件 `%s`。整文件覆盖，文件中只能包含 JSON。\n' "$1"
  printf '2. 写完后，界面中只回复一行：`[完成] status=<status>`。\n\n'
  printf '结果 JSON 的 schema：\n\n```json\n%s\n```\n' "$(jq -c . "$SCHEMA")"
}

# 窗格 / tab 模式的交互规则：决策问题直接问用户，不交回 Claude
interaction() {
  printf '\n\n## 决策直接问用户\n\n'
  printf '本任务运行在用户可见的终端界面中，用户能看到你的输出并直接回复你。以下规则优先于委托协议中的对应条款：\n'
  printf -- '- 协议要求"停下询问"的情形（包括计划外情况、破坏性操作、简报「自主权」列出的情形），改为直接在界面里向用户提问：说明情况、可选方案和你的推荐。提问消息的最后一行单独输出 `%s`，然后结束本轮回复，等待用户回答。\n' "$WAIT_MARK"
  printf -- '- 拿到用户回答后，按用户的决定继续执行，不要交付 `needs_input` 结果。\n'
  printf -- '- 用户做出的每个决定，在最终结果的 `assumptions` 中记一条：`用户决策：<问题> → <决定>`。\n'
  printf -- '- 只有 `[完成]` 之后才代表本轮结束；`[进度]` `[问题]` 之后仍然不要停。\n'
}
