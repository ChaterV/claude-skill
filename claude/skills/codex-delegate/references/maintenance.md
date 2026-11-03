# 维护说明（修改脚本时读，运行委托时不需要）

- `codex exec` 必须关闭 stdin，否则会卡在 `Reading additional input from stdin...`。run.sh 已经处理。
- `codex exec resume` 不支持 `-s` 和 `-C`。run.sh 改用 `-c sandbox_mode=...`，并 cd 到 meta 里记录的原目录。
- 非 OpenAI 模型（如通过 cc-switch 接入的自定义 provider）不保证遵守 `--output-schema`，结果常夹带文字，甚至括号不匹配。脚本会先尝试截取末尾的 JSON（原文另存为 `*.raw.txt`）；截取不出来，就按"自动催促继续"处理（最多 5 次，不唤醒 Claude）。
- macOS 自带 bash 3.2：变量后面紧跟中文字符时必须写成 `${VAR}`，否则会被当成变量名的一部分。
- `~/.codex/config.toml` 的配置告警会以 error 事件出现，progress.sh 已经过滤。
- 协议 `references/protocol.md` 和结果格式 `references/result-schema.json` 由脚本自动附加给 Codex，Claude 不需要读。
- 窗格模式读 Codex 界面要用 `--source visible` 整屏读取再去空行：Codex 把对话画在屏幕上方、输入框钉在底部，中间隔着大量空行，`--lines N` 只能读到输入框；`recent` / `recent-unwrapped` 来源里没有对话内容（codex 0.166 实测）。
- `awaiting_user` 依赖 Codex 界面中消息和工具调用以 `•` 开头、续行缩进（codex 0.166 实测成立）。Codex 改界面样式后要重新验证；出错的表现：用户回答后脚本一直等（误判为在等用户），或 Codex 在等用户时被自动催促（误判为没在等）。
- 窗格和 tab 模式不支持 read-only：Codex 需要自己写结果文件；codex 0.166 下 `-s read-only` 加 `--add-dir` 会直接启动失败。
- tab 模式不往 Codex 界面里输入文字（自带终端等没有可靠的办法）：首轮提示词作为 `codex [PROMPT]` 的参数传入；后续轮次先对 tab 里的 Codex 发 TERM 结束它，再由 `tab-runner.sh` 执行 `codex resume <SID> [PROMPT]`。codex 0.166 实测：被 TERM 结束后会话可以正常恢复，`resume` 也接受 `-s` `-a` `--add-dir` `-m`。
- tab 模式的会话 ID 从 `${CODEX_HOME:-~/.codex}/sessions/**/rollout-*.jsonl` 中查找：比 `.started` 新、且内容包含本任务 `prompt-1.md` 绝对路径的文件，第一行 `session_meta` 的 `payload.id`。Codex 改了会话记录的位置或格式后要重新验证。
- tab 模式各终端的打开方式见 `tab.sh` 的 `open_with`。Ghostty 用的是 1.4 的 AppleScript（`new tab ... with configuration {command:...}`）；iTerm2、WezTerm、kitty、tmux 的写法还没有实测过。
- tab 模式启动 Codex 时用的是 open 时记下的 `CODEX_BIN` 和 `PATH`（存在 meta.env 里），因为 Ghostty、iTerm2 直接执行命令时不加载用户的 shell 配置。
- 修正轮数计数在 `lib.sh` 的 `count_fix_rounds`，记在 `<run_dir>/fix-rounds.tsv`，三个脚本都在发送答复之前调用。上限可用 `CODEX_DELEGATE_MAX_FIX_ROUNDS` 调整。解析「修正:」行时，中文标点用交替 `(，|、|,)` 而不是方括号：BSD sed 在 C locale 下会把方括号里的多字节字符拆成单个字节，弄坏中文标识。
