# 后台模式（codex exec）

`$SK` 是 skill 所在目录，见 SKILL.md 开头。

## 启动（Bash，`run_in_background: true`）

```bash
$SK/scripts/run.sh start "$RUN" --cd <仓库目录> [--sandbox MODE] [--network] [--model M]
```

启动后告诉用户：
- 已经交给 Codex 执行；
- 想看实时进度，可以在另一个终端运行 `$SK/scripts/progress.sh <RUN 的绝对路径> --watch`（不消耗 Claude 的 token）；
- 随时可以叫停。

然后结束本轮回复，等待完成通知。**不要轮询，也不要读事件文件。**

## 告警监听（可选，默认不挂）

只有任务时间长或风险高时，才在启动后的下一条消息里挂 Monitor：
- command：`$SK/scripts/progress.sh "$RUN"`（告警模式，只推送 `[问题]` `[错误]` `[本轮失败]`）
- timeout_ms：`1800000`；到期后用同样的命令重新挂上，会从断点继续
- 不要用 `--all` 或 `--verbose` 挂 Monitor：每条通知都会唤醒 Claude 一次。

## 续跑（后台执行）

```bash
$SK/scripts/run.sh resume "$RUN" "$RUN/reply-<n>.md" [--sandbox MODE] [--network|--no-network]
```

换权限直接在 resume 时带参数。

## 停止

用 TaskStop 停掉 run.sh（挂了 Monitor 的话一并停掉）。
