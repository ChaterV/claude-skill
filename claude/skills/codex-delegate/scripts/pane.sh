#!/usr/bin/env bash
# 可见窗格模式：在 herdr 中分出一个窗格运行交互式 Codex，用户能直接看到 Codex 的界面和进度。
# Claude 通过 herdr 下发指令、等待本轮结束，Codex 把结构化结果写入 run 目录中的文件。
#
# 用法:
#   pane.sh open  <run_dir> [--cd DIR] [--sandbox MODE] [--network] [--model M] [--direction right|down]
#       分屏并启动 Codex（前台执行，几秒内返回）
#   pane.sh run   <run_dir> [reply_file]
#       不带 reply_file：发送首轮简报；带 reply_file：发送答复或追加指令。等到本轮结束后输出结果摘要（后台执行）
#   pane.sh wait  <run_dir>
#       重新等待本轮结果（例如等待被 TaskStop 中断后，后台执行）
#   pane.sh close <run_dir>
#       关闭本任务创建的窗格
#
# 退出码: 0 本轮有结果 | 3 open 时 Codex 等待启动确认 | 4 本轮结束但没有拿到结果 | 6 修正轮数超限，未发送 | 2 用法或环境错误
# 审批和决策提问都由用户直接在窗格中处理，run/wait 不会因此返回，只等本轮真正结束。
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$SKILL_DIR/scripts/lib.sh"

usage() { sed -n '6,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[[ "${HERDR_ENV:-}" == 1 ]] || die "当前不在 herdr 管理的终端中，请改用后台模式 run.sh"
command -v herdr >/dev/null || die "未找到 herdr"
command -v jq >/dev/null || die "未找到 jq"

cmd="${1:-}"; run_dir="${2:-}"
[[ -n "$cmd" && -n "$run_dir" ]] || usage
shift 2
mkdir -p "$run_dir" && run_dir="$(cd "$run_dir" && pwd)"
META="$run_dir/meta.env"
META_KEYS=(MODE PANE AGENT CWD SANDBOX NETWORK MODEL ROUND)

load_meta() {
  [[ -f "$META" ]] || die "$META 不存在，请先 open"
  # shellcheck disable=SC1090
  source "$META"
  [[ "${MODE:-}" == pane ]] || die "$run_dir 不是窗格模式的任务"
}

# 窗格中最后 N 行非空内容。Codex 界面把对话画在屏幕上方、输入框钉在底部，中间可能隔着上百行空白，
# 且 recent / recent-unwrapped 来源里没有对话内容（codex 0.166 实测），所以读整屏 visible、去掉空行后再取末尾。
pane_tail() {
  local out
  out="$(herdr agent read "$AGENT" --source visible 2>/dev/null || herdr pane read "$PANE" --source visible 2>/dev/null)" \
    || { echo "（无法读取窗格内容）"; return; }
  grep -v '^[[:space:]]*$' <<<"$out" | tail -n "${1:-30}"
}

# Codex 是否在窗格里等待用户回答决策问题。不能只看标记在不在窗格末尾：用户回答后 Codex 可能只输出一条短消息就停下，
# 旧标记仍在可见范围内。改为按位置判断：最后一个标记之后，Codex 没有再输出内容（Codex 界面中消息和工具调用都以 "•" 开头），
# 且之后只剩输入框、状态栏等界面元素（非空行不超过 8 行）。
awaiting_user() {
  pane_tail 40 | awk -v mark="$WAIT_MARK" '
    index($0, mark) { found = 1; after = 0; bullet = 0; next }
    found && NF     { after++; if ($0 ~ /^[[:space:]]*•/) bullet = 1 }
    END             { exit !(found && !bullet && after <= 8) }'
}

# 等到本轮真正结束（idle/done）。审批造成的 blocked 由用户在窗格中处理，不算结束
wait_done() { herdr agent wait "$AGENT" --until idle --until done 2>&1; }

# 解析 herdr 返回的 JSON：输出 agent_status，或 error:<code>
parse_state() {
  jq -r 'if .result.agent.agent_status then .result.agent.agent_status
         elif .error.code then "error:" + .error.code else "unknown" end' 2>/dev/null <<<"$1" | head -n 1
}

# 根据本轮的结束状态输出摘要并决定退出码
report() {
  local state="$1" result="$run_dir/result-$ROUND.json"
  if result_extract "$result"; then
    echo "== Codex 第 $ROUND 轮 状态=$state agent=$AGENT pane=$PANE${CONTINUES:+（期间自动催促继续 $CONTINUES 次）}"
    echo "run_dir: $run_dir"
    result_summary "$result"; exit 0
  fi

  case "$state" in
    blocked)
      # 兜底：审批由用户在窗格中处理，Claude 不介入，继续等
      report "$(parse_state "$(wait_done)")" ;;
    error:agent_not_found)
      echo "[异常] Codex 已退出或窗格已被关闭，本轮没有结果。"
      exit 4 ;;
    error:*)
      echo "[异常] herdr 返回 ${state}。窗格末尾内容："; pane_tail 30
      exit 4 ;;
  esac

  # Codex 在窗格里向用户提问：等用户回复（变为 working），再等本轮结束，期间不唤醒 Claude、不催促
  if awaiting_user; then
    local st
    st="$(parse_state "$(herdr agent wait "$AGENT" --until working 2>&1)")"
    [[ "$st" == error:* ]] && report "$st"
    report "$(parse_state "$(wait_done)")"
  fi

  # 停下了但没有交付结果：多半是模型发完一条普通消息（如 [进度]）就结束了本轮。
  # 自动催促继续执行（不唤醒 Claude）；不能说"只写结果"，否则会把未完成的计划提前截断。
  CONTINUES=$(( ${CONTINUES:-0} + 1 ))
  if (( CONTINUES <= MAX_CONTINUES )); then
    local out
    # 兜底 Codex 提问时忘了加标记：让它补上标记，而不是在用户回答之前自己做决定
    local msg_text
    msg_text="$(continue_msg "把结果 JSON 写入文件 ${result}（整文件覆盖、只含 JSON），然后只回复一行 [完成] status=<status>。")"
    msg_text+=" 例外：如果你上一条消息是在向用户提问、正在等用户回答，不要自行决定，也不要继续执行，只回复一行 ${WAIT_MARK}。"
    out="$(herdr agent prompt "$AGENT" "$msg_text" --wait --until idle --until done 2>&1)"
    report "$(parse_state "$out")"
  fi
  echo "== Codex 第 $ROUND 轮 状态=$state agent=$AGENT pane=$PANE"
  echo "run_dir: $run_dir"
  echo "[异常] 已自动催促 $MAX_CONTINUES 次，Codex 仍未交付合法的结果文件。窗格末尾内容："
  pane_tail 40
  exit 4
}

case "$cmd" in
  open)
    [[ -f "$META" ]] && die "$run_dir 已打开过；续跑用 run，新任务请换目录"
    [[ -f "$run_dir/brief.md" ]] || die "缺少 $run_dir/brief.md"
    MODE=pane; CWD="$PWD"; SANDBOX=workspace-write; NETWORK=0; MODEL=""; ROUND=0; direction=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --cd) CWD="$2"; shift 2 ;;
        --sandbox) SANDBOX="$2"; shift 2 ;;
        --network) NETWORK=1; shift ;;
        --model) MODEL="$2"; shift 2 ;;
        --direction) direction="$2"; shift 2 ;;
        *) die "未知参数: $1" ;;
      esac
    done
    case "$SANDBOX" in
      workspace-write|danger-full-access) ;;
      # Codex 要把结果写进 run_dir，只读沙箱写不了；codex 0.166 下 read-only 加 --add-dir 还会直接启动失败
      read-only) die "窗格模式不支持 read-only（Codex 无法写结果文件）。只读任务请用后台模式 run.sh" ;;
      *) die "非法 sandbox: $SANDBOX" ;;
    esac
    CWD="$(cd "$CWD" && pwd)" || die "工作目录不存在: $CWD"
    if [[ -z "$direction" ]]; then
      width="$(herdr pane layout --current 2>/dev/null \
        | jq -r --arg p "${HERDR_PANE_ID:-}" '.result.layout.panes[] | select(.pane_id == $p) | .rect.width' 2>/dev/null)"
      if [[ "${width:-0}" -ge 140 ]]; then direction=right; else direction=down; fi
    fi
    split_out="$(herdr pane split --current --direction "$direction" --cwd "$CWD" --no-focus 2>&1)" || die "分屏失败: $split_out"
    PANE="$(jq -r '.result.pane.pane_id' <<<"$split_out")"
    [[ -n "$PANE" && "$PANE" != null ]] || die "分屏失败: $split_out"
    AGENT="codex-$(date +%H%M%S)"
    herdr pane rename "$PANE" "codex: $(basename "$run_dir")" >/dev/null 2>&1 || true
    save_meta "${META_KEYS[@]}"

    cargs=(-s "$SANDBOX" -a on-request --add-dir "$run_dir")
    [[ "$NETWORK" == 1 ]] && cargs+=(-c 'sandbox_workspace_write.network_access=true')
    [[ -n "$MODEL" ]] && cargs+=(-m "$MODEL")
    if start_out="$(herdr agent start "$AGENT" --kind codex --pane "$PANE" --timeout 60000 -- "${cargs[@]}" 2>&1)"; then
      echo "已在窗格 $PANE 启动 Codex（agent=${AGENT}，cwd=${CWD}，sandbox=${SANDBOX}）"
    elif grep -q agent_not_ready <<<"$start_out"; then
      echo "[阻塞] Codex 启动时在窗格 $PANE 中等待确认（例如是否信任该目录）。请在窗格中处理，之后再执行 run。"
      pane_tail 20
      exit 3
    else
      echo "$start_out" >&2
      die "启动 Codex 失败（窗格 $PANE 已保留，可手动关闭或执行 close）"
    fi
    ;;

  run)
    load_meta
    reply_file="${1:-}"
    if [[ -n "$reply_file" ]]; then
      [[ -f "$reply_file" ]] || die "答复文件不存在: $reply_file"
      count_fix_rounds "$run_dir" "$reply_file"
    fi
    ROUND=$((ROUND + 1))
    result="$run_dir/result-$ROUND.json"
    msg="$run_dir/prompt-$ROUND.md"
    rm -f "$result" "${result%.json}.raw.txt"
    if [[ -z "$reply_file" ]]; then
      [[ "$ROUND" == 1 ]] || die "非首轮必须提供 reply_file"
      { cat "$PROTOCOL"; interaction; delivery "$result"; printf '\n---\n\n# 任务简报\n\n'; cat "$run_dir/brief.md"; } > "$msg"
    else
      [[ -f "$reply_file" ]] || die "答复文件不存在: $reply_file"
      { printf '# Claude 的答复 / 追加指示\n\n'; cat "$reply_file"
        printf '\n\n请继续任务，仍然遵守最初的委托协议：按执行计划执行（若本答复修改或追加了步骤，以本答复为准），用 [进度]/[问题] 汇报，需要决策时直接在界面里问用户。'
        interaction; delivery "$result"; } > "$msg"
    fi
    save_meta "${META_KEYS[@]}"
    out="$(herdr agent prompt "$AGENT" "请完整阅读文件 $msg ，并严格按其中的内容执行。" --wait --until idle --until done 2>&1)"
    report "$(parse_state "$out")"
    ;;

  wait)
    load_meta
    report "$(parse_state "$(wait_done)")"
    ;;

  close)
    load_meta
    herdr pane close "$PANE" >/dev/null 2>&1 && echo "已关闭窗格 $PANE" || echo "窗格 $PANE 已不存在"
    ;;

  *) usage ;;
esac
