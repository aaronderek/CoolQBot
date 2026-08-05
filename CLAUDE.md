# coolqbot-rs

CoolQBot（Python/NoneBot2）的 Rust 重写。首发平台：QQ（OneBot v11，配合 NapCat/Lagrange 实现端）。
原 Python 代码在 `legacy/` 目录（只读参考，不要修改）。
完整设计文档：`docs/coolqbot-rust-rewrite-plan.md`。

## 构建与验证
- 构建：`cargo build --workspace`
- 测试：`cargo test --workspace`（行为对齐测试在 tests/behavior/）
- Lint：`cargo clippy --workspace -- -D warnings`（零警告是合并条件）
- 单插件测试：`cargo test -p plugin-<name>`
（注：Cargo workspace 在 Phase 1 才创建，当前仓库尚无 Rust 代码属正常状态）

## 铁律（违反即返工）
1. 迁移插件时先读 `docs/RULEBOOK.md`，冲突以 RULEBOOK 为准，而不是你的直觉。
2. 发现 RULEBOOK 没覆盖的模式：停下，把问题写进 `queue/questions.md`，
   不要自行发明约定。
3. 永远不要修改 `crates/bot-core/` 的公共接口——接口变更只能由
   architect agent 走 ADR 流程。
4. 错误处理：库 crate 用 `thiserror`，bot-app 用 `anyhow`；禁止 `unwrap()`
   出现在非测试代码。
5. 完成一个任务的定义：验收命令通过 + `queue/<task>.done` 落盘。
6. 不要直接翻译 Python 的动态技巧（monkey-patch、运行时反射）；
   查 RULEBOOK 的对应模式，没有就走第 2 条。

## 架构速览
- 事件流：adapter(WS) → Event(平台无关) → 路由 → Plugin::on_event
- 插件注册：每个插件 crate 导出 `pub fn plugin() -> PluginDef`
- 数据库：sqlx + SQLite，迁移文件在各插件 `migrations/`
- 定时任务：插件在 PluginDef 里声明 cron 表达式，由 bot-scheduler 统一驱动

## 参考资料
- 原项目架构说明：`legacy/AGENTS.md`
- 迁移规则：`docs/RULEBOOK.md`
- 架构决策：`docs/adr/`
- 迁移看板：`docs/MIGRATION_STATUS.md`
