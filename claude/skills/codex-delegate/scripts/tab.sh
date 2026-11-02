#!/usr/bin/env bash
# tab 模式：不在 herdr 中时使用。在当前终端新开一个 tab（开不了就用 macOS 自带终端开新窗口），
# 里面运行交互式 Codex，用户能直接看到 Codex 的界面，也能直接回答它的提问。
# 脚本不往 Codex 界面里输入文字：首轮提示词在启动 Codex 时作为参数传入；后续轮次先结束 tab 里的 Codex，
# 再由 tab-runner.sh 用 codex resume <会话ID> <提示词> 在同一个 tab 里接着运行。本轮是否结束靠轮询结果文件判断。
#
# 用法:
#   tab.sh open  <run_dir> [--cd DIR] [--sandbox MODE] [--network] [--model M] [--via 方式]
#       新开 tab 或窗口，启动 Codex 并发送首轮简报（前台执行，几秒内返回）
#       方式: auto（默认）| tmux | wezterm | kitty | ghostty | iterm | terminal（macOS 自带终端，开新窗口）
#   tab.sh wait  <run_dir>
#       等待本轮结束并输出结果摘要（后台执行）
#   tab.sh run   <run_dir> <reply_file>
#       发送答复或追加指令：先结束 tab 里的 Codex，再恢复同一会话；等到本轮结束后输出结果摘要（后台执行）
#   tab.sh stop  <run_dir>
#       结束 tab 里的 Codex（tab 保留，之后仍可 run）
#   tab.sh close <run_dir>
#       结束 Codex 和 tab 里的 tab-runner.sh（tab 本身由用户关闭）
#
# 退出码: 0 本轮有结果 | 4 Codex 退出或 tab 被关闭，本轮没有结果 | 5 无法打开可见的 tab 或窗口（改用后台模式） | 2 用法或环境错误
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$SKILL_DIR/scripts/lib.sh"

usage() { awk '/^# 用法:/,/^# 退出码/' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

command -v jq >/dev/null || die "未找到 jq"

cmd="${1:-}"; run_dir="${2:-}"
[[ -n "$cmd" && -n "$run_dir" ]] || usage
shift 2
mkdir -p "$run_dir" && run_dir="$(cd "$run_dir" && pwd)"
META="$run_dir/meta.env"
# ROUND 放最后：tab-runner.sh 读到新的 ROUND 时，其余字段一定已经写好
META_KEYS=(MODE VIA CWD SANDBOX NETWORK MODEL CODEX_BIN RUN_PATH SID ROUND)
RUNNER="$SKILL_DIR/scripts/tab-runner.sh"

load_meta() {
  [[ -f "$META" ]] || die "$META 不存在，请先 open"
  # shellcheck disable=SC1090
  source "$META"
  [[ "${MODE:-}" == tab ]] || die "$run_dir 不是 tab 模式的任务"
}

# 单引号转义，用于拼接交给 shell 执行的命令行
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

is_ssh() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; }
is_mac_gui() { [[ "$(uname)" == Darwin ]] && ! is_ssh; }

# 根据当前终端选择打开方式
detect_via() {
  if [[ -n "${TMUX:-}" ]]; then echo tmux
  elif [[ -n "${WEZTERM_PANE:-}" ]] && command -v wezterm >/dev/null; then echo wezterm
  elif [[ -n "${KITTY_WINDOW_ID:-}" ]] && command -v kitten >/dev/null; then echo kitty
  elif is_mac_gui; then
    case "${TERM_PROGRAM:-}" in
      ghostty) echo ghostty ;;
      iTerm.app) echo iterm ;;
      *) echo terminal ;;   # 自带终端、IDE 内置终端、不认识的终端：用自带终端开新窗口
    esac
  else echo none
  fi
}

via_name() {
  case "$1" in
    tmux) echo "tmux 新窗口" ;; wezterm) echo "WezTerm 新 tab" ;; kitty) echo "kitty 新 tab" ;;
    ghostty) echo "Ghostty 新 tab" ;; iterm) echo "iTerm2 新 tab" ;; terminal) echo "macOS 终端新窗口" ;;
    *) echo "$1" ;;
  esac
}

# 用方式 $1 在新 tab / 窗口中执行 shell 命令行 $2
open_with() {
  local via="$1" line="$2"
  case "$via" in
    tmux) tmux new-window -d -n codex "$line" ;;
    wezterm) wezterm cli spawn -- /bin/bash -c "$line" >/dev/null ;;
    kitty) kitten @ launch --type=tab --keep-focus --tab-title codex /bin/bash -c "$line" >/dev/null ;;
    ghostty)
      osascript - "$line" >/dev/null <<'OSA'
on run argv
  tell application "Ghostty"
    if (count of windows) > 0 then
      new tab in front window with configuration {command:(item 1 of argv)}
    else
      new window with configuration {command:(item 1 of argv)}
    end if
  end tell
end run
OSA
      ;;
    iterm)
      osascript - "$line" >/dev/null <<'OSA'
on run argv
  set cmd to "/bin/bash -c " & quoted form of (item 1 of argv)
  tell application "iTerm2"
    if (count of windows) > 0 then
      tell current window to create tab with default profile command cmd
    else
      create window with default profile command cmd
    end if
  end tell
end run
OSA
      ;;
    terminal)
      osascript - "exec $line" >/dev/null <<'OSA'
on run argv
  tell application "Terminal"
    do script (item 1 of argv)
    activate
  end tell
end run
OSA
      ;;
    *) return 1 ;;
  esac
}

runner_pid() { cat "$run_dir/runner.pid" 2>/dev/null; }
runner_alive() { local p; p="$(runner_pid)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

# 打开 tab 并确认 tab-runner.sh 已经跑起来；当前方式失败时退到 macOS 终端新窗口
launch() {
  local line tried="" v i
  line="/bin/bash $(q "$RUNNER") $(q "$run_dir")"
  for v in "$VIA" terminal; do
    [[ " $tried " == *" $v "* ]] && continue
    tried+=" $v"
    [[ "$v" == terminal ]] && ! is_mac_gui && continue
    rm -f "$run_dir/runner.pid"
    local err
    if ! err="$(open_with "$v" "$line" 2>&1)"; then
      echo "（用 $(via_name "$v") 打开失败：${err:-未知原因}）" >&2
      continue
    fi
    for ((i = 0; i < 40; i++)); do runner_alive && break; sleep 0.5; done
    if runner_alive; then VIA="$v"; return 0; fi
    echo "（已请求 $(via_name "$v")，但 20 秒内没检测到 tab 启动。如果系统弹出了「允许控制」的授权窗口，请允许后重试）" >&2
  done
  return 1
}

# 列出某进程的所有子孙进程
descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }

# 结束 tab 里正在运行的 Codex（不结束 tab-runner.sh）
stop_codex() {
  local r pids p i
  r="$(runner_pid)"; [[ -n "$r" ]] || return 0
  pids=""
  for p in $(pgrep -P "$r"); do
    [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == sleep ]] && continue
    pids+=" $p $(descendants "$p" | tr '\n' ' ')"
  done
  [[ -n "${pids// /}" ]] || return 0
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  for ((i = 0; i < 20; i++)); do
    local alive=0
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
    (( alive )) || return 0
    sleep 0.25
  done
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  return 0
}

# 从 Codex 的会话记录里找到本任务的会话 ID：首轮提示词里含 prompt-1.md 的绝对路径，可以唯一定位
find_sid() {
  local home="${CODEX_HOME:-$HOME/.codex}" f
  f="$(find "$home/sessions" -name 'rollout-*.jsonl' -newer "$run_dir/.started" -print0 2>/dev/null \
        | xargs -0 grep -l -F "$run_dir/prompt-1.md" 2>/dev/null | head -n 1)"
  [[ -n "$f" ]] && head -n 1 "$f" | jq -r '.payload.id // empty' 2>/dev/null
}

# 写第 N 轮的提示词。$1 为 reply_file，为空表示首轮
write_prompt() {
  local reply="${1:-}" msg="$run_dir/prompt-$ROUND.md" result="$run_dir/result-$ROUND.json"
  rm -f "$result" "${result%.json}.raw.txt" "$run_dir/exit-$ROUND"
  if [[ -z "$reply" ]]; then
    { cat "$PROTOCOL"; interaction; delivery "$result"; printf '\n---\n\n# 任务简报\n\n'; cat "$run_dir/brief.md"; } > "$msg"
  else
    { printf '# Claude 的答复 / 追加指示\n\n'; cat "$reply"
      printf '\n\n请继续任务，仍然遵守最初的委托协议：按执行计划执行（若本答复修改或追加了步骤，以本答复为准），用 [进度]/[问题] 汇报，需要决策时直接在界面里问用户。'
      interaction; delivery "$result"; } > "$msg"
  fi
}

# 等到本轮交付结果、Codex 退出或 tab 被关闭
wait_round() {
  local result="$run_dir/result-$ROUND.json"
  while :; do
    if result_extract "$result"; then
      echo "== Codex 第 $ROUND 轮已交付结果（$(via_name "$VIA")）"
      echo "run_dir: $run_dir"
      result_summary "$result"
      exit 0
    fi
    if [[ -f "$run_dir/exit-$ROUND" ]]; then
      sleep 1; result_extract "$result" && continue
      echo "[异常] Codex 已退出（exit=$(cat "$run_dir/exit-$ROUND")），第 $ROUND 轮没有交付结果。"
      echo "run_dir: $run_dir"
      exit 4
    fi
    if ! runner_alive; then
      echo "[异常] Codex 所在的 tab 或窗口已关闭，第 $ROUND 轮没有交付结果。"
      echo "run_dir: $run_dir"
      exit 4
    fi
    sleep 3
  done
}

case "$cmd" in
  open)
    [[ -f "$META" ]] && die "$run_dir 已打开过；后续轮次用 run，新任务请换目录"
    [[ -f "$run_dir/brief.md" ]] || die "缺少 $run_dir/brief.md"
    MODE=tab; VIA=auto; CWD="$PWD"; SANDBOX=workspace-write; NETWORK=0; MODEL=""; SID=""; ROUND=1
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --cd) CWD="$2"; shift 2 ;;
        --sandbox) SANDBOX="$2"; shift 2 ;;
        --network) NETWORK=1; shift ;;
        --model) MODEL="$2"; shift 2 ;;
        --via) VIA="$2"; shift 2 ;;
        *) die "未知参数: $1" ;;
      esac
    done
    case "$SANDBOX" in
      workspace-write|danger-full-access) ;;
      read-only) die "tab 模式不支持 read-only（Codex 无法写结果文件）。只读任务请用后台模式 run.sh" ;;
      *) die "非法 sandbox: $SANDBOX" ;;
    esac
    CWD="$(cd "$CWD" && pwd)" || die "工作目录不存在: $CWD"
    CODEX_BIN="$(command -v codex)" || die "未找到 codex CLI"
    RUN_PATH="$PATH"
    [[ "$VIA" == auto ]] && VIA="$(detect_via)"
    if [[ "$VIA" == none ]]; then
      echo "[无法显示] 当前环境没有图形界面（例如 SSH），也不在 tmux / WezTerm / kitty 中，开不了可见的 tab。请改用后台模式 run.sh。"
      exit 5
    fi
    write_prompt
    touch "$run_dir/.started"
    save_meta "${META_KEYS[@]}"
    if ! launch; then
      rm -f "$META"
      echo "[无法显示] 打不开可见的 tab 或窗口。请改用后台模式 run.sh（或排查上面的错误后重试）。"
      exit 5
    fi
    save_meta "${META_KEYS[@]}"
    echo "已在 $(via_name "$VIA") 中启动 Codex 并发送首轮简报（cwd=${CWD}，sandbox=${SANDBOX}）"
    ;;

  wait)
    load_meta
    wait_round
    ;;

  run)
    load_meta
    reply_file="${1:-}"
    [[ -f "$reply_file" ]] || die "答复文件不存在: ${reply_file:-（未提供）}"
    if [[ -z "$SID" ]]; then
      SID="$(find_sid)"
      [[ -n "$SID" ]] || die "在 ${CODEX_HOME:-$HOME/.codex}/sessions 中找不到本任务的 Codex 会话，无法续跑"
    fi
    ROUND=$((ROUND + 1))
    write_prompt "$reply_file"
    stop_codex
    save_meta "${META_KEYS[@]}"
    if ! runner_alive; then
      echo "（原来的 tab 已关闭，重新打开一个）"
      launch || { echo "[无法显示] 打不开可见的 tab 或窗口。"; exit 5; }
      save_meta "${META_KEYS[@]}"
    fi
    wait_round
    ;;

  stop)
    load_meta
    stop_codex
    echo "已结束 tab 里的 Codex（tab 保留）"
    ;;

  close)
    load_meta
    stop_codex
    p="$(runner_pid)"
    [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null
    rm -f "$run_dir/runner.pid"
    echo "已结束 Codex 和 tab 中的等待脚本，tab 或窗口可以手动关闭"
    ;;

  *) usage ;;
esac
