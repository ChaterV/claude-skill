#!/bin/bash
# Claude Code status line: ctx 5h 7d │ 目录 分支 · 模型 思考强度
input=$(cat)

dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

YELLOW='\033[33m'; RESET='\033[0m'
GRAY='\033[38;5;245m'   # 标签、重置时间
DIMGRAY='\033[38;5;242m' # 次要区与分隔符
GREEN='\033[38;5;71m'; AMBER='\033[38;5;179m'; RED='\033[38;5;167m'

# 按百分比取颜色：<50 绿，50~<80 黄，>=80 红
pct_color() {
  awk -v p="$1" 'BEGIN {
    if (p + 0 >= 80) print "R"; else if (p + 0 >= 50) print "Y"; else print "G"
  }'
}

# 生成「标签 百分比」片段：标签灰色，数字按数值变色
pct_item() {
  local label="$1" val="$2" c
  case "$(pct_color "$val")" in
    R) c="$RED" ;;
    Y) c="$AMBER" ;;
    *) c="$GREEN" ;;
  esac
  printf "${GRAY}%s${RESET} ${c}%.0f%%${RESET}" "$label" "$val"
}

# ===== 重点区：ctx / 5h(+重置时间) / 7d，项之间两个空格 =====
focus=""
add_focus() { focus="${focus:+$focus  }$1"; }

# 上下文已用百分比（优先 used_percentage，否则 100 - remaining_percentage）
if [ -z "$used" ] && [ -n "$remaining" ]; then
  used=$(awk -v r="$remaining" 'BEGIN { printf "%.4f", 100 - r }')
fi
[ -n "$used" ] && add_focus "$(pct_item ctx "$used")"

# 5h 额度，重置时间紧跟其后（一个空格）
if [ -n "$five" ]; then
  item=$(pct_item 5h "$five")
  if [ -n "$five_reset" ]; then
    # macOS 用 date -r <秒>，Linux 用 date -d @<秒>
    reset_time=$(date -r "$five_reset" +%H:%M 2>/dev/null || date -d "@$five_reset" +%H:%M 2>/dev/null)
    [ -n "$reset_time" ] && item="$item $(printf "${GRAY}↻%s${RESET}" "$reset_time")"
  fi
  add_focus "$item"
fi

# 7d 额度
[ -n "$week" ] && add_focus "$(pct_item 7d "$week")"

# ===== 次要区：目录+分支 · 模型 思考强度 =====
# 目录名
loc=""
if [ -n "$dir" ]; then
  loc=$(printf "${DIMGRAY}%s${RESET}" "$(basename "$dir")")
fi

# git 分支（跳过可选锁），有改动时追加黄色 ●
if [ -n "$dir" ] && git -C "$dir" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$dir" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null \
    || git -C "$dir" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    git_part=$(printf "${DIMGRAY}%s${RESET}" "$branch")
    if [ -n "$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
      git_part="$git_part $(printf "${YELLOW}●${RESET}")"
    fi
    loc="${loc:+$loc }$git_part"
  fi
fi

# 模型 + 思考强度（空格连接，缺失则跳过）
mdl=""
[ -n "$model" ] && mdl=$(printf "${DIMGRAY}%s${RESET}" "$model")
if [ -n "$effort" ]; then
  mdl="${mdl:+$mdl }$(printf "${DIMGRAY}%s${RESET}" "$effort")"
fi

# 两组之间用 " · " 连接
DOT=$(printf "${DIMGRAY} · ${RESET}")
secondary=""
[ -n "$loc" ] && secondary="$loc"
[ -n "$mdl" ] && secondary="${secondary:+$secondary$DOT}$mdl"

# ===== 拼装：重点区 + 分隔符 + 次要区；重点区为空则不输出分隔符 =====
SEP=$(printf "${DIMGRAY}  │  ${RESET}")
if [ -n "$focus" ] && [ -n "$secondary" ]; then
  out="$focus$SEP$secondary"
else
  out="$focus$secondary"
fi

printf '%b\n' "$out"
