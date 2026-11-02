# 维护说明（修改脚本时读，运行委托时不需要）

- `codex exec` 必须关闭 stdin，否则会卡在 `Reading additional input from stdin...`。run.sh 已经处理。
- `codex exec resume` 不支持 `-s` 和 `-C`。run.sh 改用 `-c sandbox_mode=...`，并 cd 到 meta 里记录的原目录。
- 非 OpenAI 模型（如通过 cc-switch 接入的自定义 provider）不保证遵守 `--output-schema`，结果常夹带文字，甚至括号不匹配。脚本会先尝试截取末尾的 JSON（原文另存为 `*.raw.txt`）；截取不出来，就按"自动催促继续"处理（最多 5 次，不唤醒 Claude）。
- macOS 自带 bash 3.2：变量后面紧跟中文字符时必须写成 `${VAR}`，否则会被当成变量名的一部分。
- `~/.codex/config.toml` 的配置告警会以 error 事件出现，progress.sh 已经过滤。
- 协议 `references/protocol.md` 和结果格式 `references/result-schema.json` 由脚本自动附加给 Codex，Claude 不需要读。
