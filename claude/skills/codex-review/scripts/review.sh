#!/usr/bin/env bash
# 只读运行 Codex 审查（代码改动或计划文件）。由 Claude 通过 Bash(run_in_background) 调用，结束时把审查意见打印到 stdout。
#
# 用法:
#   review.sh <run_dir> [--cd DIR] [--uncommitted | --base BRANCH | --commit SHA | --plan FILE] [--focus TEXT] [--model M]
#
#   审查对象（四选一，都不给时自动判断代码范围）：
#     --uncommitted   已暂存、未暂存和未跟踪的改动
#     --base BRANCH   当前分支相对 BRANCH 的改动
#     --commit SHA    某个提交引入的改动
#     --plan FILE     计划文件：对照仓库代码审查计划本身，不看工作区里的其他改动
#     自动判断：工作区有改动 → --uncommitted；否则 → --base <默认分支>
#   --focus TEXT     审查重点。代码审查给了重点就改用自定义指令模式（原生预设不能附带指令），输出为中文
#
# run_dir 中的文件: review.md（审查意见）、events.jsonl、stderr.log、meta.txt
set -uo pipefail

die() { echo "错误: $*" >&2; exit 2; }
usage() { sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

command -v codex >/dev/null || die "未找到 codex CLI"
command -v jq >/dev/null || die "未找到 jq"
codex exec review --help >/dev/null 2>&1 || die "当前 codex 版本不支持 codex exec review，请先升级（codex update 或 npm i -g @openai/codex）"

run_dir="${1:-}"; [[ -n "$run_dir" && "$run_dir" != -* ]] || usage
shift
CWD="$PWD"; SCOPE=""; TARGET=""; FOCUS=""; MODEL=""
set_scope() { [[ -z "$SCOPE" ]] || die "--uncommitted / --base / --commit / --plan 只能选一个"; SCOPE="$1"; TARGET="${2-}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) CWD="$2"; shift 2 ;;
    --uncommitted) set_scope uncommitted; shift ;;
    --base) set_scope base "$2"; shift 2 ;;
    --commit) set_scope commit "$2"; shift 2 ;;
    --plan) set_scope plan "$2"; shift 2 ;;
    --focus) FOCUS="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "未知参数: $1" ;;
  esac
done

# 计划路径相对于调用时的目录解析，再切到仓库目录
if [[ "$SCOPE" == plan ]]; then
  [[ -f "$TARGET" ]] || { [[ -f "$CWD/$TARGET" ]] && TARGET="$CWD/$TARGET"; }
  [[ -f "$TARGET" ]] || die "计划文件不存在: $TARGET"
  [[ -s "$TARGET" ]] || die "计划文件是空的: $TARGET"
  TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
fi

cd "$CWD" 2>/dev/null || die "工作目录不存在: $CWD"
if [[ "$SCOPE" != plan ]]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$CWD 不是 git 仓库"
fi
mkdir -p "$run_dir" && run_dir="$(cd "$run_dir" && pwd)"
[[ -e "$run_dir/review.md" ]] && die "$run_dir 已有审查结果，请换一个目录"

default_branch() {
  local b
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && { echo "${b#origin/}"; return; }
  for b in main master; do git show-ref --verify --quiet "refs/heads/$b" && { echo "$b"; return; }; done
  return 1
}

if [[ -z "$SCOPE" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    SCOPE=uncommitted
  else
    SCOPE=base; TARGET="$(default_branch)" || die "工作区无改动，且找不到默认分支；请指定 --base 或 --commit"
  fi
fi

case "$SCOPE" in
  uncommitted)
    [[ -n "$(git status --porcelain)" ]] || die "工作区没有未提交的改动"
    scope_desc="未提交的改动（已暂存、未暂存、未跟踪）"
    scope_cmd="git status --short、git diff HEAD，未跟踪文件直接读取"
    preset=(--uncommitted) ;;
  base)
    git rev-parse --verify --quiet "$TARGET" >/dev/null || die "分支不存在: $TARGET"
    [[ -n "$(git diff --name-only "$TARGET...HEAD")" ]] || die "当前分支相对 $TARGET 没有改动"
    scope_desc="当前分支相对 ${TARGET} 的改动"
    scope_cmd="git diff ${TARGET}...HEAD"
    preset=(--base "$TARGET") ;;
  commit)
    git rev-parse --verify --quiet "${TARGET}^{commit}" >/dev/null || die "提交不存在: $TARGET"
    scope_desc="提交 ${TARGET} 引入的改动"
    scope_cmd="git show ${TARGET}"
    preset=(--commit "$TARGET") ;;
  plan)
    scope_desc="计划 ${TARGET}" ;;
esac

args=(--json -o "$run_dir/review.md" -c 'sandbox_mode="read-only"')
[[ -n "$MODEL" ]] && args+=(-m "$MODEL")

{
  echo "cwd: $CWD"
  echo "scope: $scope_desc"
  [[ -n "$FOCUS" ]] && echo "focus: $FOCUS"
} > "$run_dir/meta.txt"

plan_prompt() {
  printf '%s\n' \
    "你是计划审查者。这是一次只读审查：不要修改任何文件，也不要开始执行计划。" \
    "" \
    "计划文件：${TARGET}" \
    "仓库目录：${CWD}" \
    "先完整阅读计划，再对照仓库中的实际代码逐条核实。工作区里与计划无关的其他改动不在审查范围内。" \
    "" \
    "审查要点：" \
    "1. 计划引用的文件、函数、组件、字段、行号是否真实存在，描述是否与代码一致；" \
    "2. 步骤是否完整：调用方、类型定义、导出、多语言词条、配置、样式、测试等是否有遗漏；" \
    "3. 按计划执行能否达成计划声明的目标，有无逻辑错误，是否会破坏现有行为；" \
    "4. 是否违反仓库 AGENTS.md 等规范；" \
    "5. 性能、兼容性、数据方面的风险，以及明显更简单的做法。"
  [[ -n "$FOCUS" ]] && printf '%s\n' "" "审查重点：${FOCUS}" "重点之外，明显的严重问题（P0/P1）也要报告。"
  printf '%s\n' \
    "" \
    "不要报告措辞、排版等纯文档问题。" \
    "" \
    "输出要求：用中文。先用一两句话给出总体结论（计划能否直接执行），再逐条列出审查意见，每条格式为：" \
    "- [P0-P3] 一句话标题 — 计划中的位置（章节或步骤号）；相关代码：文件绝对路径:起始行-结束行" \
    "  说明问题和依据，并给出计划应该怎么改。" \
    "优先级：P0 按计划执行会失败或造成严重错误；P1 结果会不符合目标或遗漏关键改动；P2 有风险或明显可改进；P3 小问题。" \
    "没有发现问题就明确说明。"
}

code_prompt() {
  printf '%s\n' \
    "审查范围：${scope_desc}。用 ${scope_cmd} 获取改动，只审查这些改动及其直接影响，不要修改任何文件。" \
    "" \
    "审查重点：${FOCUS}" \
    "重点之外，范围内明显的严重问题（P0/P1）也要报告。" \
    "" \
    "输出要求：用中文。先用一两句话给出总体结论，再逐条列出审查意见，每条格式为：" \
    "- [P0-P3] 一句话标题 — 文件绝对路径:起始行-结束行" \
    "  说明问题、触发条件和影响，给出依据（引用的代码位置）。" \
    "没有发现问题就明确说明。不要报告纯风格问题。"
}

echo "== Codex 审查开始：${scope_desc}${FOCUS:+；重点：$FOCUS}"
SECONDS=0
# 提示词一律从 stdin 传入（读到 EOF 即结束），避免 codex 等待额外输入
if [[ "$SCOPE" == plan ]]; then
  plan_prompt | codex exec --skip-git-repo-check "${args[@]}" - > "$run_dir/events.jsonl" 2> "$run_dir/stderr.log"
elif [[ -z "$FOCUS" ]]; then
  codex exec review "${preset[@]}" "${args[@]}" < /dev/null > "$run_dir/events.jsonl" 2> "$run_dir/stderr.log"
else
  code_prompt | codex exec review "${args[@]}" - > "$run_dir/events.jsonl" 2> "$run_dir/stderr.log"
fi
code=$?

echo "== Codex 审查结束 exit=$code 用时=${SECONDS}s"
echo "run_dir: $run_dir"
if [[ -s "$run_dir/review.md" ]]; then
  echo "---"
  cat "$run_dir/review.md"; echo
else
  echo "没有拿到审查结果（可能被中断或出错）"
  jq -r 'select(.type=="turn.failed" or .type=="error") | "  事件: \(.error.message // .message // tostring)"' "$run_dir/events.jsonl" 2>/dev/null | tail -n 5
  echo "  stderr 末尾:"; grep -v 'rmcp::transport' "$run_dir/stderr.log" 2>/dev/null | tail -n 5 | sed 's/^/    /'
fi
exit "$code"
