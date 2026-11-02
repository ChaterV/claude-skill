# tab 模式（不在 herdr 中）

`$SK` 是 skill 所在目录，见 SKILL.md 开头。

在当前终端新开一个 tab 运行交互式 Codex，用户能直接看到它、直接回答它。当前终端开不了 tab 时（macOS 自带终端、IDE 内置终端、不认识的终端），改用 macOS 自带终端开新窗口。支持 tmux、WezTerm、kitty、Ghostty、iTerm2。

## 打开并发送首轮简报（前台执行，几秒内返回）

```bash
$SK/scripts/tab.sh open "$RUN" --cd <仓库目录> [--sandbox MODE] [--network] [--model M]
```

- 首轮简报在启动 Codex 时一起传入，打开后 Codex 立刻开始执行。
- Codex 的审批模式是 `on-request`，只有需要越出沙箱时才会请求审批。
- **决策和审批都由用户直接在 tab 里处理，不交回 Claude。**
- 退出码 5：开不了可见的 tab 或窗口（例如通过 SSH 连接、没有图形界面）。改用后台模式（`$SK/references/background.md`），并告诉用户这次看不到 Codex 的界面。
- 第一次控制某个终端时，macOS 可能弹窗请求「允许控制」。输出里提示超时的话，请用户允许后重新 open（换一个 RUN 目录）。

## 等待本轮结果（Bash，`run_in_background: true`）

```bash
$SK/scripts/tab.sh wait "$RUN"
```

open 之后马上后台执行。然后告诉用户：Codex 正在新 tab（或新窗口）里执行，可以直接看；如果 Codex 提问或请求审批，直接在里面回答即可；Codex 如果停下来却没说 `[完成]`，在里面让它继续；随时可以叫停。说完结束本轮回复，等待完成通知。

## 后续轮次（Bash，`run_in_background: true`）

```bash
$SK/scripts/tab.sh run "$RUN" "$RUN/reply-<n>.md"
```

脚本会先结束 tab 里的 Codex，再在同一个 tab 里用 `codex resume` 恢复同一会话，并发送这一轮的指令。会话上下文不会丢，不需要重写简报。原来的 tab 被关掉了的话，会自动重新打开一个。

## 完成通知的退出码

- `0`：已拿到结果，回到 SKILL.md「处理结果」。结果里 `assumptions` 中以「用户决策：」开头的条目是用户在 tab 里做的决定，验收时当作用户决策对照。
- `4`：Codex 退出了，或者 tab 被关掉了，本轮没有结果。问用户是否继续；继续的话写 reply，用 `run` 发起下一轮。

tab 模式**没有自动催促**：Codex 停下来却没交结果时，脚本会一直等，不会唤醒 Claude，由用户在 tab 里让它继续。等待被打断（例如 TaskStop）后想继续等，后台执行 `tab.sh wait "$RUN"`。

## 换权限

`tab.sh close "$RUN"`，然后换一个新的 RUN 目录，用新参数 open。

## 结束与停止

- 任务完成后**默认保留 tab**，用户可以回看执行记录或继续对话。只有用户明确要求时才执行 `tab.sh close "$RUN"`。
- 用户中途叫停：先用 TaskStop 停掉等待中的 `tab.sh wait/run`，再执行 `tab.sh stop "$RUN"` 结束 Codex（tab 保留）。
