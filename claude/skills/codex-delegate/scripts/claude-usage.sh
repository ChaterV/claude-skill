#!/usr/bin/env bash
# 统计 Claude Code 会话的 token 用量（包括子 agent），用于对比"Claude 独做"和"委托 Codex"的消耗。
# 数据来自 ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<项目>/<session>.jsonl。同一次 API 回复会被记录多次，按 message.id 去重。
#
# 用法:
#   claude-usage.sh --list [N]                           列出当前项目最近 N 个会话（默认 10）
#   claude-usage.sh [session_id|jsonl路径] [--since T] [--until T]
#       不指定会话时取当前项目最近修改的会话；T 为 ISO 时间（UTC，如 2026-11-02T02:10:00Z）或本地时间 "HH:MM"（今天）
#   通用选项: --project DIR  指定项目目录（默认当前目录）
#
# 加权 token = 把各类 token 按相对单价折算成"未缓存输入 token"，近似反映费用和订阅额度的消耗。
# 默认权重（相对于输入单价）可通过环境变量覆盖：
#   W_INPUT=1  W_CACHE_5M=1.25  W_CACHE_1H=2  W_CACHE_READ=0.1  W_OUTPUT=5
set -uo pipefail

project="$PWD"; target=""; since=""; until=""; list=0; list_n=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list=1; [[ "${2:-}" =~ ^[0-9]+$ ]] && { list_n="$2"; shift; }; shift ;;
    --since) since="$2"; shift 2 ;;
    --until) until="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) target="$1"; shift ;;
  esac
done

project="$(cd "$project" && pwd)"
pdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$project" | sed 's#[^A-Za-z0-9]#-#g')"
[[ -d "$pdir" ]] || { echo "找不到项目会话目录: $pdir" >&2; exit 2; }

# date 兼容：GNU（Linux）用 -d，BSD（macOS）用 -j -f / -r
if date --version >/dev/null 2>&1; then GNU_DATE=1; else GNU_DATE=0; fi

# "HH:MM" → 今天该本地时间对应的 UTC ISO 时间
to_utc() {
  local t="$1"
  if [[ "$t" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    if [[ $GNU_DATE == 1 ]]; then
      date -u -d "$(date +%Y-%m-%d) $t" +%Y-%m-%dT%H:%M:%SZ
    else
      date -u -r "$(date -j -f '%Y-%m-%d %H:%M' "$(date +%Y-%m-%d) $t" +%s)" +%Y-%m-%dT%H:%M:%SZ
    fi
  else
    printf '%s' "$t"
  fi
}
[[ -n "$since" ]] && since="$(to_utc "$since")"
[[ -n "$until" ]] && until="$(to_utc "$until")"

if [[ $list == 1 ]]; then
  printf '%-36s  %-16s  %6s  %s\n' "session" "开始(本地)" "请求数" "首条用户消息"
  ls -t "$pdir"/*.jsonl 2>/dev/null | head -n "$list_n" | while read -r f; do
    sid="$(basename "$f" .jsonl)"
    jq -rs --arg sid "$sid" '
      ([.[] | select(.type=="assistant" and .message.usage) | .message.id] | unique | length) as $n
      | ([.[] | select(.timestamp) | .timestamp] | min // "") as $t0
      | ([.[] | select(.type=="user" and (.message.content | type) == "string")
              | .message.content | select(startswith("<") | not)][0] // "") as $first
      | [$sid, $t0, ($n|tostring), ($first | gsub("\\s+"; " ") | .[0:50])] | @tsv' "$f" 2>/dev/null \
    | while IFS=$'\t' read -r s t n first; do
        local_t="-"
        if [[ -n "$t" && $GNU_DATE == 1 ]]; then
          local_t="$(date -d "${t%%.*}Z" '+%m-%d %H:%M' 2>/dev/null || echo -)"
        elif [[ -n "$t" ]] && epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${t%%.*}" +%s 2>/dev/null)"; then
          local_t="$(date -r "$epoch" '+%m-%d %H:%M')"
        fi
        printf '%-36s  %-16s  %6s  %s\n' "$s" "$local_t" "$n" "$first"
      done
  done
  exit 0
fi

if [[ -z "$target" ]]; then
  main="$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -n 1)"
elif [[ -f "$target" ]]; then
  main="$target"
else
  main="$pdir/$target.jsonl"
fi
[[ -f "$main" ]] || { echo "找不到会话文件: $main" >&2; exit 2; }
sid="$(basename "$main" .jsonl)"

# 主会话 + 同名目录下的子 agent 记录
files=("$main")
if [[ -d "$pdir/$sid" ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(find "$pdir/$sid" -name '*.jsonl' 2>/dev/null)
fi

jq -rn \
  --arg since "$since" --arg until "$until" --arg sid "$sid" --argjson nfiles "${#files[@]}" \
  --argjson wi "${W_INPUT:-1}" --argjson w5 "${W_CACHE_5M:-1.25}" --argjson w1 "${W_CACHE_1H:-2}" \
  --argjson wr "${W_CACHE_READ:-0.1}" --argjson wo "${W_OUTPUT:-5}" '
  [inputs | select(.type=="assistant" and .message.usage and .message.id)
          | select($since == "" or .timestamp >= $since)
          | select($until == "" or .timestamp <= $until)
          | {id: .message.id, side: (.isSidechain // false), ts: .timestamp, model: .message.model, u: .message.usage}]
  | unique_by(.id)
  | map(.u as $u
        | ($u.cache_creation.ephemeral_5m_input_tokens // null) as $c5
        | ($u.cache_creation.ephemeral_1h_input_tokens // null) as $c1
        | . + {in: ($u.input_tokens // 0),
               c5: (if $c5 == null and $c1 == null then ($u.cache_creation_input_tokens // 0) else ($c5 // 0) end),
               c1: ($c1 // 0),
               cr: ($u.cache_read_input_tokens // 0),
               out: ($u.output_tokens // 0)}
        | . + {ctx: (.in + .c5 + .c1 + .cr)})
  | def sum(f): map(f) | add // 0;
    def w: (.in * $wi) + (.c5 * $w5) + (.c1 * $w1) + (.cr * $wr) + (.out * $wo);
    def fmt: tostring | if length > 3 then (.[0:length-3] | if length > 3 then .[0:length-3] + "," + .[length-3:] else . end) + "," + .[length-3:] else . end;
    def block(name; xs):
      (xs | length) as $n
      | if $n == 0 then "\(name): 无请求" else
          "\(name): 请求 \($n) 次",
          "  未缓存输入   \(xs | sum(.in) | fmt)",
          "  缓存写入     \(xs | sum(.c5 + .c1) | fmt)",
          "  缓存读取     \(xs | sum(.cr) | fmt)",
          "  输出         \(xs | sum(.out) | fmt)",
          "  加权合计     \(xs | sum(w) | floor | fmt)",
          "  平均上下文   \((xs | sum(.ctx)) / $n | floor | fmt)    峰值上下文 \(xs | map(.ctx) | max | fmt)"
        end;
  "会话 \($sid)（\($nfiles) 个记录文件）",
  "时间范围: \(if length > 0 then (map(.ts) | min) + " ~ " + (map(.ts) | max) else "-" end) UTC",
  "模型: \(map(.model) | unique | join(", "))",
  block("主会话"; map(select(.side | not))),
  block("子 agent"; map(select(.side))),
  block("合计"; .)
  ' "${files[@]}"
