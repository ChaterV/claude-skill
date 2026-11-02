---
name: codex-delegate
description: Claude 当大脑，Codex 当执行者：Claude 调研并制定具体计划，委托 OpenAI Codex CLI 按步骤执行（herdr 中开可见窗格，否则后台运行）；Codex 遇到计划外情况交回 Claude 决策，完成后 Claude 对照计划验收。目的是节省 Claude 的 token。当用户说"交给 codex""委托给 codex""让 codex 执行/实现/修""用 codex 当执行者/子 agent""delegate to codex"或输入 /codex-delegate 时使用。
---

# Codex 委托：Claude 决策，Codex 执行

Claude 负责调研、写计划、回答决策问题、验收；Codex 负责按计划改代码、跑命令和测试、自行修复执行中的失败，不改计划、不做计划外改动。

**token 原则**：Codex 执行期间，Claude 只在一轮结束、需要决策、出现阻塞或异常时被唤醒。机械性工作全部交给 Codex。Codex 停下却没交结果时，脚本会自动催它继续，不唤醒 Claude。

`SK=${CLAUDE_SKILL_DIR}`：本 skill 所在目录，下文和 references 文档中的 `$SK` 都替换成这个绝对路径。如果这里显示的不是绝对路径（旧版 Claude Code 不替换该变量），改用加载时提示的 Base directory。

## 1. 调研与计划（Claude 自己做）

- 调研到能写出**具体执行计划**为止：每一步都落到文件、位置和改法，让 Codex 不需要再做方案判断。
- 涉及用户决策的问题，委托之前先问清楚，不要留给 Codex 猜。
- 从讨论中提炼**验收清单**（目标、用户的决策、预期行为、不做的事），写进简报的「验收标准」。每一条都要能对照代码或实际行为检查。
- 计划里写上 Codex 要跑的验证命令，并确认命令本身能跑（例如 Node 24 中 `node --test <目录>` 会报错，要写成具体文件或 glob）。

## 2. 写简报

- `RUN=<scratchpad>/codex-runs/<短任务名>-<HHMM>`，按 `$SK/references/brief-template.md` 写 `$RUN/brief.md`。
- Codex 看不到这段对话，也读不到 CLAUDE.md 和 memory，只会自动读仓库里的 AGENTS.md。调研结论、用户的决策和相关偏好都写进「关键上下文」。
- **只写文件路径、行号和符号名，让 Codex 自己读，不要粘贴代码。** 不要重复 AGENTS.md 里已有的规则。

## 3. 权限与启动

| 场景 | 参数 |
|---|---|
| 改代码（默认） | `--sandbox workspace-write`（可写工作目录，不能联网） |
| 只读任务 | `--sandbox read-only` |
| 需要装依赖、请求接口 | 再加 `--network` |
| 不受沙箱限制 | `--sandbox danger-full-access`，必须先征得用户同意 |

同一工作目录里不要同时跑两个会写文件的 Codex 任务；Codex 运行期间，Claude 不要改它负责的文件。

选择模式后，**只读对应的那一份文档**并照做：
- `HERDR_ENV=1`（默认）→ 窗格模式：读 `$SK/references/pane.md`
- 不在 herdr 中，或用户要求后台运行 → 后台模式：读 `$SK/references/background.md`

始终通过脚本调用 Codex，不要绕过脚本直接执行 `codex exec`。

## 4. 处理结果

完成通知里已带有结果摘要（状态、步骤、改动文件、验证结果、问题和假设），通常不需要再读结果文件。按 `status` 处理：

- **completed** → 第 5 步验收。
- **needs_input** → Claude 自己判断：计划层面的问题（计划不可行、有更好的做法、需改计划外文件）根据调研结论决定；只有涉及用户意图、业务取舍或高风险操作时，才用 AskUserQuestion 问用户（选项来自 `options`，Codex 推荐的放第一个并标「(推荐)」）。然后写 reply，进入第 6 步。
- **blocked** → 多半是沙箱、网络或凭据问题，跟用户确认后调整权限。
- **failed / 没有结构化结果** → 看摘要附带的原文，判断是发指令修正，还是调整计划后重新委托。

## 5. 验收（分级）

原则：以实际代码为证据，不以 Codex 的自述为证据。`steps=done`、`verification=passed` 只说明 Codex 认为自己做完了。不审查 Codex 写的测试脚本。

**默认：轻量验收**
1. `git diff --stat`：改动文件是否都在计划范围内，有没有计划外文件。
2. 对照验收清单，只读**关键条目**对应的 diff 片段（`git diff -U2 -- <file>`），重点查两件事：是否采用了用户选定的方案（有没有悄悄换成被否掉的方案）；是否改变了不允许改变的现有行为。
3. 摘要里标为 `deviated` / `skipped` 的步骤，判断理由是否成立。

**完整验收**：仅在以下情况进行，逐个文件阅读 diff，逐条核对清单，并在代码里走一遍关键输入或实际运行一个关键场景：
- 用户要求完整验收；
- 改动超过约 10 个文件或 300 行；
- 涉及接口字段、金额/价格计算、权限、数据删除等高风险逻辑；
- 轻量验收发现了偏差。

**处理不一致**：在 reply 里写清楚哪一条、现在是什么样、期望是什么样，让 Codex 再做一轮，修完后只复查这几条。一两行的小偏差 Claude 直接改。如果是计划或理解有误，先和用户确认。

**向用户汇报**：逐条列出核对结论（符合 / 已修正 / 有偏差及原因），注明这次是轻量还是完整验收，再列出 Codex 的假设和遗留问题。不要复述执行过程。

## 6. 后续轮次

写 `$RUN/reply-<n>.md`：按 question id 逐条给出决定，或写修订/追加的步骤（写法同简报的「执行计划」）。然后按所在模式的文档发起下一轮。后续的修复和追加任务优先沿用同一个会话，不用重写完整简报。

## 7. 停止与收尾

- 用户中途叫停：按所在模式文档的「停止」一节处理。已经产生的改动留在工作区，用 `git status --short` 看一下并告诉用户。
- Codex 不负责提交代码。需要 commit 时，由 Claude 按用户的规则处理。

## 衡量 token 消耗

用户问到"委托之后到底省没省"时，运行 `$SK/scripts/claude-usage.sh --list` 找会话，再用 `claude-usage.sh <session_id> [--since HH:MM] [--until HH:MM]` 统计。看「加权合计」（已按单价折算），用「请求次数」和「平均上下文」解释差异。

修改脚本前读 `$SK/references/maintenance.md`。
