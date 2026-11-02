# 维护说明（修改脚本时读，运行委托时不需要）

- `codex exec` 必须关闭 stdin，否则会卡在 `Reading additional input from stdin...`。run.sh 已经处理。
- `codex exec resume` 不支持 `-s` 和 `-C`。run.sh 改用 `-c sandbox_mode=...`，并 cd 到 meta 里记录的原目录。
- 非 OpenAI 模型（如通过 cc-switch 接入的自定义 provider）不保证遵守 `--output-schema`，结果常夹带文字，甚至括号不匹配。脚本会先尝试截取末尾的 JSON（原文另存为 `*.raw.txt`）；截取不出来，就按"自动催促继续"处理（最多 5 次，不唤醒 Claude）。
- macOS 自带 bash 3.2：变量后面紧跟中文字符时必须写成 `${VAR}`，否则会被当成变量名的一部分。
- `~/.codex/config.toml` 的配置告警会以 error 事件出现，progress.sh 已经过滤。
- 协议 `references/protocol.md` 和结果格式 `references/result-schema.json` 由脚本自动附加给 Codex，Claude 不需要读。
- 窗格模式读 Codex 界面要用 `--source visible` 整屏读取再去空行：Codex 把对话画在屏幕上方、输入框钉在底部，中间隔着大量空行，`--lines N` 只能读到输入框；`recent` / `recent-unwrapped` 来源里没有对话内容（codex 0.166 实测）。
- `awaiting_user` 依赖 Codex 界面中消息和工具调用以 `•` 开头、续行缩进（codex 0.166 实测成立）。Codex 改界面样式后要重新验证；出错的表现：用户回答后脚本一直等（误判为在等用户），或 Codex 在等用户时被自动催促（误判为没在等）。
- 窗格模式不支持 read-only：Codex 需要自己写结果文件；codex 0.166 下 `-s read-only` 加 `--add-dir` 会直接启动失败。
