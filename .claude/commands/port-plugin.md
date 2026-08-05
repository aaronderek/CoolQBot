---
description: 迁移一个插件（porter → reviewer → 收尾的完整闭环）
---
迁移插件 $ARGUMENTS：
1. 确认 queue/$ARGUMENTS.task 存在且无对应 .done；读取任务文件。
2. 用 porter subagent 执行迁移。
3. porter 完成后，用 test-porter subagent 翻译该插件测试（如尚未翻译）。
4. 用 reviewer subagent 审查。
5. review 结果处理：BLOCKER → 带 findings 退回 porter（最多 2 轮）；
   RULE → 停下来汇报给我（人类）和 architect；全清 → 合并 worktree，
   touch queue/$ARGUMENTS.done，更新 docs/MIGRATION_STATUS.md。
6. 全程把每步结果追加到 .claude/audit.jsonl
   （格式：{"ts","phase","plugin","agent","model","result"}）。
