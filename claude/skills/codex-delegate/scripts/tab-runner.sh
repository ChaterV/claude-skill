#!/bin/bash
# tab 模式中运行在新开的 tab / 窗口里，由 tab.sh 启动，不要手动调用。
# 按 meta.env 中的 ROUND 启动交互式 Codex：没有会话 ID 时新开会话，有就用 codex resume 接着同一会话。
# Codex 退出后（被 tab.sh 结束、准备下一轮，或用户自己退出）回到等待，直到出现新的一轮。
run_dir="${1:?用法: tab-runner.sh <run_dir>}"
META="$run_dir/meta.env"
# shellcheck disable=SC1090
source "$META" || { echo "读取 $META 失败"; read -r _; exit 1; }
export PATH="$RUN_PATH"
cd "$CWD" || { echo "无法进入 $CWD"; read -r _; exit 1; }
echo $$ > "$run_dir/runner.pid"
printf '\033]0;codex: %s\007' "$(basename "$run_dir")"

done_round=0
while :; do
  # shellcheck disable=SC1090
  source "$META" 2>/dev/null
  if [[ "${ROUND:-}" =~ ^[0-9]+$ ]] && (( ROUND > done_round )); then
    n=$ROUND
    args=(-s "$SANDBOX" -a on-request --add-dir "$run_dir")
    [[ "$NETWORK" == 1 ]] && args+=(-c 'sandbox_workspace_write.network_access=true')
    [[ -n "$MODEL" ]] && args+=(-m "$MODEL")
    prompt="请完整阅读文件 $run_dir/prompt-$n.md ，并严格按其中的内容执行。"
    if [[ -z "$SID" ]]; then
      "$CODEX_BIN" "${args[@]}" "$prompt"
    else
      "$CODEX_BIN" resume "${args[@]}" "$SID" "$prompt"
    fi
    echo $? > "$run_dir/exit-$n"
    # Codex 被信号结束时可能来不及恢复终端状态
    stty sane 2>/dev/null; printf '\033[?25h'
    done_round=$n
    echo
    echo "（Codex 已退出，等待 Claude 发起下一轮。不再需要时直接关闭这个 tab 或窗口。）"
  fi
  sleep 1
done
