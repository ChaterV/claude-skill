#!/usr/bin/env bash
# 把仓库 claude/ 下的配置以软链接方式挂到 Claude Code 配置目录（默认 ~/.claude/，设置了 CLAUDE_CONFIG_DIR 时用它），实现多台机器共用同一份配置。
#
# 用法:
#   ./install.sh            建立或修复软链接。本地已有的不同文件会先备份到 <配置目录>/backups/，再以仓库版本为准
#   ./install.sh --check    只检查状态，不做修改
#   ./install.sh --adopt    以本地版本为准：把本地被改动过的文件收回仓库，再重建软链接
#                           （用于 Claude Code / herdr 改写 settings.json 时把软链接替换成了普通文件的情况）
#
# 受管理的条目：claude/ 下的 CLAUDE.md、settings.json，以及 claude/skills/ 下的每个 skill 目录。
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
  -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "未知参数: $1" >&2; exit 2 ;;
esac

items=()
for f in CLAUDE.md settings.json; do [[ -e "$SRC/$f" ]] && items+=("$f"); done
for d in "$SRC"/skills/*/; do [[ -d "$d" ]] && items+=("skills/$(basename "$d")"); done

backup_dir="$DEST/backups/claude-skill-$(date +%Y%m%d-%H%M%S)"
backup() {
  mkdir -p "$backup_dir/$(dirname "$1")"
  mv "$DEST/$1" "$backup_dir/$1"
  echo "  备份    $1 -> ${backup_dir/#$HOME/~}/$1"
}

same_content() { diff -rq "$1" "$2" >/dev/null 2>&1; }

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
