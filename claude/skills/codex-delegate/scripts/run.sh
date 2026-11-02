#!/usr/bin/env bash
# 后台模式：用 codex exec 无界面运行。不在 herdr 中时使用；在 herdr 中优先用 pane.sh（可见窗格）。
# 由 Claude 通过 Bash(run_in_background) 调用；本轮结束时把结果摘要打印到 stdout。
#
# 用法:
#   run.sh start  <run_dir> [--cd DIR] [--sandbox MODE] [--network] [--model M]
#       读取 <run_dir>/brief.md 作为任务简报（自动在前面拼接委托协议）
#   run.sh resume <run_dir> <reply_file> [--sandbox MODE] [--network|--no-network] [--model M]
#       把 reply_file 的内容发给同一 Codex 会话继续执行；可调整权限（会写回 meta）
#
# MODE: read-only | workspace-write（默认）| danger-full-access
#
# run_dir 中的文件:
#   brief.md / reply-N.md       Claude 写的简报与答复
#   meta.env                    工作目录 / 沙箱 / 模型 / 网络
#   events.jsonl                当前轮的 codex --json 事件流（progress.sh 读取）
#   result.json                 当前轮的结构化结果（result.raw.txt 为提取前的原文）
#   stderr.log                  当前轮 codex 的 stderr
#   events.N.jsonl / result.N.json / stderr.N.log   历史轮次归档
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$SKILL_DIR/scripts/lib.sh"

usage() { sed -n '5,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

command -v codex >/dev/null || die "未找到 codex CLI"
command -v jq >/dev/null || die "未找到 jq"

cmd="${1:-}"; run_dir="${2:-}"
[[ ( "$cmd" == start || "$cmd" == resume ) && -n "$run_dir" ]] || usage
shift 2
mkdir -p "$run_dir" && run_dir="$(cd "$run_dir" && pwd)"
META="$run_dir/meta.env"

reply_file=""
if [[ "$cmd" == resume ]]; then
  [[ -f "$META" ]] || die "$META 不存在，请先 start"
  reply_file="${1:-}"; [[ -f "$reply_file" ]] || die "答复文件不存在: $reply_file"
  shift
  # shellcheck disable=SC1090
  source "$META"
else
  [[ -f "$META" ]] && die "$run_dir 已有会话；续跑用 resume，新任务请换目录"
  [[ -f "$run_dir/brief.md" ]] || die "缺少 $run_dir/brief.md"
  CWD="$PWD"; SANDBOX="workspace-write"; NETWORK=0; MODEL=""
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) [[ "$cmd" == start ]] || die "--cd 只能在 start 时指定"; CWD="$2"; shift 2 ;;
    --sandbox) SANDBOX="$2"; shift 2 ;;
    --network) NETWORK=1; shift ;;
    --no-network) NETWORK=0; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done
case "$SANDBOX" in read-only|workspace-write|danger-full-access) ;; *) die "非法 sandbox: $SANDBOX" ;; esac
CWD="$(cd "$CWD" && pwd)" || die "工作目录不存在: $CWD"
MODE=exec
save_meta MODE CWD SANDBOX NETWORK MODEL

# 从当前及历史事件中找 thread_id（被中断的轮次也能恢复）
find_thread_id() {
  local f
  for f in "$run_dir"/events.jsonl "$run_dir"/events.*.jsonl; do
    [[ -f "$f" ]] || continue
    jq -r 'select(.type=="thread.started") | .thread_id' "$f" 2>/dev/null | head -n 1
  done | grep -m 1 . || true
}

# 归档上一轮的产物，保证 events.jsonl / result.json 只属于当前轮
archive_round() {
  local n=1
  while [[ -e "$run_dir/events.$n.jsonl" ]]; do n=$((n + 1)); done
  [[ -f "$run_dir/events.jsonl" ]] && mv "$run_dir/events.jsonl" "$run_dir/events.$n.jsonl"
  [[ -f "$run_dir/result.json" ]] && mv "$run_dir/result.json" "$run_dir/result.$n.json"
  [[ -f "$run_dir/stderr.log" ]] && mv "$run_dir/stderr.log" "$run_dir/stderr.$n.log"
  [[ -f "$run_dir/result.raw.txt" ]] && mv "$run_dir/result.raw.txt" "$run_dir/result.$n.raw.txt"
  [[ -f "$run_dir/events.fix.jsonl" ]] && mv "$run_dir/events.fix.jsonl" "$run_dir/events.$n.fix.jsonl"
  rm -f "$run_dir/.progress_offset"
}

DELIVERY='

## 结果交付

本轮的最后一条消息**只能**是符合 output schema 的 JSON 对象，前后不能有任何其它文字。`[进度]` 等消息必须在此之前单独发送，不要和最终 JSON 合并成一条。
'

thread_id=""
[[ "$cmd" == resume ]] && { thread_id="$(find_thread_id)"; [[ -n "$thread_id" ]] || die "找不到上一轮的 thread_id，无法续跑"; }

archive_round
: > "$run_dir/events.jsonl"

args=(--json --skip-git-repo-check
      --output-schema "$SCHEMA"
      -o "$run_dir/result.json"
      -c "sandbox_mode=\"$SANDBOX\"")
[[ "$NETWORK" == 1 ]] && args+=(-c 'sandbox_workspace_write.network_access=true')
[[ -n "$MODEL" ]] && args+=(-m "$MODEL")

cd "$CWD" || die "无法进入 $CWD"
# 提示词一律从 stdin 传入（读到 EOF 即结束），避免 codex 卡在 "Reading additional input from stdin..."
if [[ "$cmd" == start ]]; then
  { cat "$PROTOCOL"; printf '%s' "$DELIVERY"; printf '\n---\n\n# 任务简报\n\n'; cat "$run_dir/brief.md"; } \
    | codex exec "${args[@]}" - > "$run_dir/events.jsonl" 2> "$run_dir/stderr.log"
else
  { printf '# Claude 的答复 / 追加指示\n\n'; cat "$reply_file"
    printf '\n\n请在当前会话中继续任务，仍然遵守最初的委托协议：按执行计划执行（若本答复修改或追加了步骤，以本答复为准），用 [进度]/[问题] 汇报，需要决策时停下。'
    printf '%s' "$DELIVERY"; } \
    | codex exec resume "$thread_id" "${args[@]}" - > "$run_dir/events.jsonl" 2> "$run_dir/stderr.log"
fi
code=$?

[[ -n "$thread_id" ]] || thread_id="$(find_thread_id)"
echo "== Codex 本轮结束 exit=$code thread=${thread_id:-未知}"
echo "run_dir: $run_dir"
# 结果不合法时：先截取末尾 JSON；仍无效多半是模型发完一条普通消息（如 [进度]）就结束了本轮，
# 自动续跑催促继续执行（不唤醒 Claude），续跑事件追加到 events.jsonl，--watch 能持续看到
continues=0
while [[ $code -eq 0 && -n "$thread_id" ]] && ! result_extract "$run_dir/result.json" && (( continues < MAX_CONTINUES )); do
  continues=$((continues + 1))
  [[ -f "$run_dir/result.json" ]] && cp "$run_dir/result.json" "$run_dir/result.raw.txt"
  echo "（本轮已停但没有交付合法结果，第 $continues 次自动催促继续…）"
  continue_msg "最后一条消息只输出符合 output schema 的 JSON 对象，前后不要有任何其它文字。" \
    | codex exec resume "$thread_id" "${args[@]}" - >> "$run_dir/events.jsonl" 2>> "$run_dir/stderr.log"
  code=$?
done
if result_valid "$run_dir/result.json"; then
  result_summary "$run_dir/result.json"
else
  echo "status: 无结构化结果（可能被中断、出错或输出不符合 schema）"
  raw="$run_dir/result.json"; [[ -s "$raw" ]] || raw="$run_dir/result.raw.txt"
  if [[ -s "$raw" ]]; then
    echo "  最后一条消息原文（请自行解读 status / questions）:"
    # 限长，避免超长原文整段进入 Claude 的上下文
    head -c 3000 "$raw"; echo
    (( $(wc -c < "$raw") > 3000 )) && echo "  …（已截断，完整内容见 $raw）"
  fi
  jq -r 'select(.type=="turn.failed" or .type=="error") | "  事件: \(.error.message // .message // tostring)"' "$run_dir/events.jsonl" 2>/dev/null | tail -n 5
  echo "  stderr 末尾:"; grep -v 'rmcp::transport' "$run_dir/stderr.log" 2>/dev/null | tail -n 5 | sed 's/^/    /'
fi
exit "$code"
