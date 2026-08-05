# 迁移规则手册 v1（种子版，Phase 0 由 architect 扩写）

> 本文件是迁移的唯一事实来源。发现模式化问题 → 在这里加规则 →
> 重新生成受影响代码。禁止绕过本文件在单个文件里打补丁。
> 每条规则有编号，review 意见必须引用规则编号或提议新规则。

## R1 框架映射
- R1.1 `on_alconna(...)` 命令 → `PluginDef::command(name, aliases, handler)`
- R1.2 NoneBot `Matcher.finish(msg)` → 返回 `Handled::Reply(msg)`
- R1.3 `nonebot_plugin_apscheduler` 定时任务 → `PluginDef::cron(expr, handler)`
- R1.4 NoneBot 事件类型（GroupMessageEvent 等）→ `Event` 枚举变体，
       群/私聊判断用 `ev.scene()`

## R2 数据层
- R2.1 SQLAlchemy Model → sqlx 手写 SQL + Rust struct（FromRow）
- R2.2 `get_session()` 事务 → `storage.tx(|conn| async {...})`
- R2.3 Alembic 迁移 → 每插件 `migrations/NNN_*.sql`，语义等价即可，
       不逐条翻译历史迁移，以最终 schema 为准

## R3 惯用法
- R3.1 Python `Optional[X]` 默认值链 → Rust `Option<X>` + `unwrap_or_else`
- R3.2 异常控制流（try/except 当分支用）→ `Result` + `match`，
       不允许用 panic 模拟异常
- R3.3 datetime + 时区：全部用 `chrono_tz::Asia::Shanghai`，
       与原项目行为一致（原项目隐式依赖系统时区，这是有意的行为修正，记 ADR）

## R4 禁止直译清单（发现即上报）
- R4.1 monkey-patch（原 utils/patch_*）→ 在 Rust 里是编译期装配，见 ADR-003
- R4.2 运行时插件发现 → 编译期注册表（bot-app 的显式列表）

## 变更日志
- v1: 初始种子版本（待 Phase 0 扩写）
