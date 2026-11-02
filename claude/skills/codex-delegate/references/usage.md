# 衡量 token 消耗（用户问"委托之后到底省没省"时读）

1. 运行 `$SK/scripts/claude-usage.sh --list` 找到会话。
2. 运行 `$SK/scripts/claude-usage.sh <session_id> [--since HH:MM] [--until HH:MM]` 统计。
3. 以「加权合计」为准（已按单价折算），用「请求次数」和「平均上下文」解释差异。
