#!/usr/bin/env bash
# 安装本仓库的 Codex 协作 skill：把 claude/skills/ 下的每个 skill 软链接到 Claude Code 配置目录
# （默认 ~/.claude/，设置了 CLAUDE_CONFIG_DIR 时用它），并在该目录的 CLAUDE.md 中写入「执行前评估是否委托 Codex」的规则。
#
# 用法:
#   ./install.sh              安装或修复。已有的同名 skill 内容不同时，先备份到 <配置目录>/backups/ 再以仓库版本为准；
#                             CLAUDE.md 只增改带标记的那一段，改之前先备份，其余内容不动
#   ./install.sh --check      只检查状态，不做修改
#   ./install.sh --adopt      同安装，但 skill 以本地版本为准：把本地被改动过的 skill 收回仓库，再重建软链接
#                             （用于编辑器或其它程序保存时把软链接替换成了普通文件的情况）
#   ./install.sh --uninstall  移除本仓库建立的软链接，以及 CLAUDE.md 中的那段规则
#
# 规则原文在 claude/skills/codex-delegate/references/claude-md-rule.md。它是复制进 CLAUDE.md 的，
# git pull 之后要再运行一次 ./install.sh 才会更新（--check 会提示「过期」）。
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO/claude"
# 与 Claude Code 一致：优先 CLAUDE_CONFIG_DIR（CLAUDE_HOME 为旧名，保留兼容）
DEST="${CLAUDE_CONFIG_DIR:-${CLAUDE_HOME:-$HOME/.claude}}"
mode=install
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  --adopt) mode=adopt ;;
  --uninstall) mode=uninstall ;;
  -h|--help) awk 'NR > 1 && /^set /{exit} NR > 1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "未知参数: $1" >&2; exit 2 ;;
esac

items=()
for d in "$SRC"/skills/*/; do [[ -d "$d" ]] && items+=("skills/$(basename "$d")"); done

backup_dir="$DEST/backups/claude-skill-$(date +%Y%m%d-%H%M%S)"
# 同一秒内多次运行时不要覆盖上一次的备份
n=2; base="$backup_dir"; while [[ -e "$backup_dir" ]]; do backup_dir="$base-$n"; n=$((n + 1)); done
backup() {
  mkdir -p "$backup_dir/$(dirname "$1")"
  mv "$DEST/$1" "$backup_dir/$1"
  echo "  备份    $1 -> ${backup_dir/#$HOME/~}/$1"
}

same_content() { diff -rq "$1" "$2" >/dev/null 2>&1; }

# ---- CLAUDE.md 中的委托规则：只管理两行标记之间的内容 ----
RULE_SRC="$SRC/skills/codex-delegate/references/claude-md-rule.md"
CLAUDE_MD="$DEST/CLAUDE.md"
BEGIN='<!-- BEGIN claude-skill codex-delegate (managed by install.sh; manual edits will be overwritten) -->'
END='<!-- END claude-skill codex-delegate -->'

want_block() { printf '%s\n' "$BEGIN"; cat "$RULE_SRC"; printf '%s\n' "$END"; }
cur_block() { awk -v b="$BEGIN" -v e="$END" '$0 == b { on = 1 } on { print } on && $0 == e { exit }' "$CLAUDE_MD"; }

# 输出规则状态：缺失 | 正常 | 过期 | 标记损坏（开始、结束标记不是各一行）
rule_state() {
  local nb ne
  [[ -f "$CLAUDE_MD" ]] || { echo 缺失; return; }
  nb="$(grep -cxF -- "$BEGIN" "$CLAUDE_MD" || true)"; ne="$(grep -cxF -- "$END" "$CLAUDE_MD" || true)"
  if [[ $nb == 0 && $ne == 0 ]]; then echo 缺失
  elif [[ $nb != 1 || $ne != 1 ]]; then echo 标记损坏
  elif [[ "$(cur_block)" == "$(want_block)" ]]; then echo 正常
  else echo 过期; fi
}

backup_claude_md() {
  mkdir -p "$backup_dir"
  cp -p "$CLAUDE_MD" "$backup_dir/CLAUDE.md"
  echo "  备份    CLAUDE.md -> ${backup_dir/#$HOME/~}/CLAUDE.md"
}

# 写回时用 cat > 而不是 mv：CLAUDE.md 是软链接时写到链接目标，不破坏链接
write_claude_md() { cat "$1" > "$CLAUDE_MD"; rm -f "$1"; }

install_rule() {
  local state tmp
  state="$(rule_state)"
  case "$state" in
    正常) echo "  正常    CLAUDE.md 委托规则"; return ;;
    标记损坏) echo "  跳过    CLAUDE.md 委托规则（标记不完整或重复，请手动删掉 claude-skill 的 BEGIN/END 标记及其间内容后重试）"; return ;;
  esac
  mkdir -p "$DEST"
  tmp="$(mktemp)"
  if [[ $state == 过期 ]]; then
    backup_claude_md
    want_block > "$tmp.block"
    awk -v b="$BEGIN" -v e="$END" -v f="$tmp.block" '
      $0 == b { while ((getline l < f) > 0) print l; skip = 1; next }
      skip { if ($0 == e) skip = 0; next }
      { print }' "$CLAUDE_MD" > "$tmp"
    rm -f "$tmp.block"
    write_claude_md "$tmp"
    echo "  已更新  CLAUDE.md 委托规则"
  else
    if [[ -s "$CLAUDE_MD" ]]; then
      backup_claude_md
      { cat "$CLAUDE_MD"; [[ -z "$(tail -c 1 "$CLAUDE_MD")" ]] || echo; echo; want_block; } > "$tmp"
    else
      want_block > "$tmp"
    fi
    write_claude_md "$tmp"
    echo "  已写入  CLAUDE.md 委托规则"
  fi
}

uninstall_rule() {
  local tmp
  case "$(rule_state)" in
    缺失) return ;;
    标记损坏) echo "  跳过    CLAUDE.md 委托规则（标记不完整或重复，请手动删除）"; return ;;
  esac
  backup_claude_md
  tmp="$(mktemp)"
  # 删掉标记之间的内容，连同安装时在它前面补的那一个空行
  awk -v b="$BEGIN" -v e="$END" '
    skip { if ($0 == e) skip = 0; next }
    $0 == b { skip = 1; pend = 0; next }
    { if (pend) print ""; pend = 0 }
    $0 == "" { pend = 1; next }
    { print }
    END { if (pend) print "" }' "$CLAUDE_MD" > "$tmp"
  if grep -q '[^[:space:]]' "$tmp"; then
    write_claude_md "$tmp"
    echo "  已移除  CLAUDE.md 委托规则"
  else
    rm -f "$tmp" "$CLAUDE_MD"
    echo "  已移除  CLAUDE.md（只剩委托规则，整个文件删除）"
  fi
}

if [[ $mode == uninstall ]]; then
  for rel in "${items[@]}"; do
    src="$SRC/$rel"; dst="$DEST/$rel"
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then rm "$dst"; echo "  已移除  $rel"
    elif [[ -e "$dst" || -L "$dst" ]]; then echo "  跳过    ${rel}（不是指向本仓库的软链接，未改动）"; fi
  done
  uninstall_rule
  exit 0
fi

problems=0
for rel in "${items[@]}"; do
  src="$SRC/$rel"; dst="$DEST/$rel"

  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    echo "  正常    $rel"
    continue
  fi

  if [[ $mode == check ]]; then
    problems=$((problems + 1))
    if [[ -L "$dst" ]]; then echo "  错链    $rel -> $(readlink "$dst")"
    elif [[ -e "$dst" ]]; then
      if same_content "$src" "$dst"; then echo "  未链接  ${rel}（内容与仓库相同）"
      else echo "  已分叉  ${rel}（本地是普通文件且内容不同：可能被程序改写替换了软链接，用 --adopt 收回，或直接运行以仓库为准）"; fi
    else echo "  缺失    $rel"; fi
    continue
  fi

  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" || -L "$dst" ]]; then
    if [[ $mode == adopt && ! -L "$dst" ]] && ! same_content "$src" "$dst"; then
      rm -rf "$src"
      cp -Rp "$dst" "$src"
      echo "  收回    ${rel}（本地版本已写回仓库，用 git diff 查看改动）"
    fi
    if [[ -L "$dst" ]] || same_content "$src" "$dst"; then
      rm -rf "$dst"
    else
      backup "$rel"
    fi
  fi
  ln -s "$src" "$dst"
  echo "  已链接  $rel"
done

if [[ -f "$RULE_SRC" ]]; then
  if [[ $mode == check ]]; then
    state="$(rule_state)"
    echo "  ${state}    CLAUDE.md 委托规则"
    [[ $state == 正常 ]] || problems=$((problems + 1))
  else
    install_rule
  fi
fi

if [[ $mode == check ]]; then
  [[ $problems == 0 ]] && echo "全部正常" || echo "$problems 项需要处理"
fi

# 依赖检查：只提示，不影响安装
dep() { command -v "$1" >/dev/null 2>&1 || echo "  $2"; }
missing="$(
  dep jq    "缺少 jq（必需）：codex-delegate、codex-review 都依赖它。macOS: brew install jq；Debian/Ubuntu: apt install jq"
  dep git   "缺少 git（必需）：codex-review 依赖它"
  dep codex "未安装 codex CLI：codex-delegate、codex-review 不可用。安装：npm i -g @openai/codex，然后运行 codex login"
  dep herdr "未安装 herdr（可选）：codex-delegate 会改为新开 tab 或窗口显示 Codex"
)"
[[ -z "$missing" ]] || { echo "依赖："; echo "$missing"; }

[[ $mode == check && $problems != 0 ]] && exit 1
exit 0
