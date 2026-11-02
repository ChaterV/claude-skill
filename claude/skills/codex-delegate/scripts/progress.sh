#!/usr/bin/env bash
# 把 Codex --json 事件流转成一行一条的中文进度。
#
# 用法: progress.sh <run_dir> [--all] [--watch] [--verbose]
#   （默认）  告警模式，给 Claude 的 Monitor 用：只输出 [问题] [错误] [本轮失败]，本轮结束自动退出。
#             已处理行数记在 <run_dir>/.progress_offset，Monitor 到期后重新挂上会从断点继续。
#   --all     输出全部进度（[进度] [计划] [改动] [结果] 等）
#   --watch   给用户在独立终端里看：等同 --all，从头读、带时间戳、跨轮次持续跟踪、不写断点（Ctrl-C 退出）
#   --verbose 额外输出每条命令执行、MCP 工具调用、网页搜索
set -uo pipefail

run_dir="${1:?用法: progress.sh <run_dir> [--all] [--watch] [--verbose]}"
shift
mode=alerts; watch=0; verbose=0
for a in "$@"; do
  case "$a" in
    --all) mode=all ;;
    --watch) mode=all; watch=1 ;;
    --verbose) verbose=1 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

events="$run_dir/events.jsonl"
off_file="$run_dir/.progress_offset"
offset=0
[[ $watch == 0 ]] && offset="$(cat "$off_file" 2>/dev/null || echo 0)"

fifo="$(mktemp -u "${TMPDIR:-/tmp}/codex-progress.XXXXXX")"
mkfifo "$fifo"
tail -n +"$((offset + 1))" -F "$events" > "$fifo" 2>/dev/null &
tail_pid=$!
cleanup() { kill "$tail_pid" 2>/dev/null; rm -f "$fifo"; }
trap cleanup EXIT
trap 'exit 143' TERM INT

read -r -d '' FILTER <<'JQ'
def cut(n): if length > n then .[0:n] + "…" else . end;
def oneline: gsub("\\s*\\n\\s*"; " ");
if .type == "thread.started" then "[会话] thread_id=\(.thread_id)"
elif .type == "turn.completed" then "[本轮结束] tokens in=\(.usage.input_tokens // "?") out=\(.usage.output_tokens // "?")"
elif .type == "turn.failed" then "[本轮失败] \((.error.message // tostring) | oneline | cut(300))"
elif .type == "error" then "[错误] \((.message // tostring) | oneline | cut(300))"
elif (.type | startswith("item.")) then
  (.item // {}) as $i
  | (.type == "item.completed") as $done
  | if $i.type == "agent_message" and $done then
      ($i.text // "") as $t
      | [$t | splits("\n")] as $l
      # 找到能解析为结果 JSON 的最早起始行；之前的部分视为普通消息
      | (first(range(0; $l | length) as $k
          | (($l[$k:] | join("\n")) | try fromjson catch empty) as $j
          | select(($j | type) == "object" and ($j | has("status")))
          | {k: $k, j: $j}) // null) as $r
      | ((if $r then $l[0:$r.k] else $l end) | join("\n") | oneline | sub("^\\s+"; "") | sub("\\s+$"; "")) as $msg
      | (if $msg != "" then ($msg | cut(300)) | (if startswith("[") then . else "[Codex] " + . end) else empty end),
        (if $r then "[结果] status=\($r.j.status) \(($r.j.summary // "") | oneline | cut(200))" else empty end)
    elif $i.type == "file_change" and $done then
      "[改动] " + ([$i.changes[]? | "\(.kind // "?") \(.path // "?")"] | join(", ") | cut(300))
    elif $i.type == "todo_list" then
      ($i.items // []) as $it
      | "[计划] \([$it[] | select(.completed)] | length)/\($it | length) "
        + (([$it[] | select(.completed | not) | .text][0] // "全部完成") | oneline | cut(120))
    elif $i.type == "error" then
      if (($i.message // "") | test("configuration setting")) then empty
      else "[错误] \(($i.message // "") | oneline | cut(300))" end
    elif $verbose == 1 and $done and $i.type == "command_execution" then
      "[命令] exit=\($i.exit_code // "?") \(($i.command // "") | cut(150))"
    elif $verbose == 1 and $done and $i.type == "mcp_tool_call" then
      "[工具] \($i.server // "?")/\($i.tool // "?")"
    elif $verbose == 1 and $done and $i.type == "web_search" then
      "[搜索] \($i.query // "")"
    else empty end
else empty end
JQ

while IFS= read -r line; do
  if [[ $watch == 0 ]]; then offset=$((offset + 1)); echo "$offset" > "$off_file"; fi
  [[ -n "$line" ]] || continue
  out="$(jq -r --argjson verbose "$verbose" "$FILTER" <<<"$line" 2>/dev/null)" || continue
  [[ -n "$out" ]] || continue
  ended=0
  while IFS= read -r l; do
    case "$l" in "[本轮结束]"*|"[本轮失败]"*) ended=1 ;; esac
    if [[ $mode == alerts ]]; then
      case "$l" in "[问题]"*|"[错误]"*|"[本轮失败]"*) printf '%s\n' "$l" ;; esac
    elif [[ $watch == 1 ]]; then
      printf '%s %s\n' "$(date +%H:%M:%S)" "$l"
    else
      printf '%s\n' "$l"
    fi
  done <<<"$out"
  [[ $ended == 1 && $watch == 0 ]] && exit 0
done < "$fifo"
