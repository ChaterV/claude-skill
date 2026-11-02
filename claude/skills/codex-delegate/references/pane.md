# 窗格模式（herdr）

`$SK` 是 skill 所在目录，见 SKILL.md 开头。

## 打开窗格（前台执行，几秒内返回）

```bash
$SK/scripts/pane.sh open "$RUN" --cd <仓库目录> [--sandbox MODE] [--network] [--model M] [--direction right|down]
```

- 当前窗格宽度够时往右分屏，否则往下。焦点留在 Claude 的窗格。
- Codex 的审批模式是 `on-request`，只有需要越出沙箱时才会请求审批。
- **决策和审批都由用户直接在窗格里处理，不交回 Claude。** 脚本会让 Codex 把需要决策的问题直接问用户（末尾带 `[等待用户决策]` 标记），等用户回答、Codex 继续执行直到本轮交付结果，期间不唤醒 Claude。
- 退出码 3：Codex 启动时在窗格里等确认（例如是否信任目录）。请用户在窗格里处理好，再执行下一步。

## 发送一轮任务（Bash，`run_in_background: true`）

```bash
$SK/scripts/pane.sh run "$RUN"                      # 首轮：发送简报
$SK/scripts/pane.sh run "$RUN" "$RUN/reply-<n>.md"  # 后续：发送答复或新指令
```

- 每轮的提示词保存在 `prompt-N.md`，Codex 把结果写到 `result-N.json`。
- 同一个 Codex 会话一直活着，后续轮次直接接着发，不需要 resume。
- 启动后告诉用户：Codex 正在右侧（或下方）窗格执行，可以直接看；如果 Codex 提问或请求审批，直接在窗格里回答即可；随时可以叫停。然后结束本轮回复，等待完成通知。

## 完成通知的退出码

- `0`：已拿到结果，回到 SKILL.md「处理结果」。结果里 `assumptions` 中以「用户决策：」开头的条目是用户在窗格里做的决定，验收时当作用户决策对照。
- `4`：Codex 退出了、窗格被关了，或者自动催促后仍然没有结果。根据摘要里的窗格内容判断下一步。

等待被打断（例如 TaskStop）后想继续等，后台执行 `pane.sh wait "$RUN"`。

用户也可以直接在窗格里和 Codex 对话、进行干预。这种情况下，Claude 照常读取该轮的结果文件即可。

## 换权限

窗格模式不能中途改沙箱：先 `pane.sh close "$RUN"`，再用新参数 open。

## 结束与停止

- 任务完成后**默认保留窗格**，用户可以回看执行记录或继续对话。只有用户明确要求时才执行 `pane.sh close "$RUN"`（只关闭本任务创建的窗格）。
- 用户中途叫停：先用 TaskStop 停掉等待中的 `pane.sh run`，再执行 `herdr agent send-keys <AGENT> esc` 打断 Codex。AGENT 记录在 `$RUN/meta.env`。
