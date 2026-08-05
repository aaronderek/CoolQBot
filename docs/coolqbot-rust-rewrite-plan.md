# CoolQBot → Rust 重构设计文档

> 目标：fork [he0119/CoolQBot](https://github.com/he0119/CoolQBot)，用 Rust 重写核心，部署在 Apple container（macOS 26 / Apple Silicon）上；用 Claude Code 编排整个迁移，按任务难度分级调度 Fable 5 / Opus 5 / Sonnet 5。
> 范围决策：**首发只做 QQ（经 OneBot v11 协议，配合 NapCat / Lagrange 等实现端）**，其他平台留接口后续再加。
> 日期：2026-08-05

---

## 1. 调研结论摘要

### 1.1 提示词 → 上下文工程（Context Engineering）

2026 年的共识是：单条"神奇提示词"的时代已经过去，对编码智能体起决定作用的是**上下文的供给结构**——把哪些事实、规则、文件、验证反馈放进模型的工作记忆，以及何时放。落到 Claude Code 上就是三件事：

1. **CLAUDE.md / AGENTS.md 是常驻上下文**：写"这个仓库怎么工作"的稳定事实（构建命令、架构约定、禁止事项），而不是一次性任务描述。
2. **规则外置成文件**（rulebook 模式，见 1.2）：让规则可以被多个 agent 引用、被增量修订，而不是散落在对话历史里。
3. **提示词随阶段递减**：Anthropic 的迁移实践里，早期提示词长（确立架构决策），后期提示词短（机械化队列作业）。指令设计的重点是**阶段划分**，不是措辞雕琢。

### 1.2 大规模重构/迁移的最新方法论（Anthropic 官方实践）

Anthropic 在官方博客公开了他们跑大规模代码迁移的六阶段流程（Bun 的百万行 Zig→Rust 移植即用此法，两周内产出可工作的二进制，合并前测试 100% 通过）：

| 阶段 | 内容 |
|---|---|
| ① Rulebook & 依赖清单 | 建立翻译规则手册、文件依赖图、列出"需要重构而非直译"的缺口 |
| ② 压力测试 | 先用多个 agent、多种方案迁移一个小子集，暴露系统性问题 |
| ③ 翻译 | 并行 implementer agent 铺开到所有文件；reviewer 抓错误后**改 rulebook 并重新生成**，而不是逐个手补 |
| ④ 编译 | 编译器跑批 + fixer agent 并行修错；系统性错误归类回流 rulebook |
| ⑤ 冒烟测试 | 跑崩溃检测，按根因归类 |
| ⑥ 行为对齐 | 两边跑同一测试集，diff 输出保证功能等价 |

三条最重要的工程原则：

- **"修复不落在单个文件上"**：发现模式化错误 → rulebook 加一句话 → 重新生成受影响批次。
- **"完成 = 输出文件存在于磁盘"**：任务队列基于磁盘状态，天然可断点续跑（resumable by construction）。
- **机械裁判优先**：编译器、测试集、diff 脚本提供客观事实；对抗性 review（独立上下文的 reviewer，分歧升级给第三个 agent）处理主观判断。

### 1.3 Graph Engineering（2026 新概念）

"Graph engineering" 是今年从"loop（单 agent 循环）"演进出来的多智能体组织设计方法：**用显式的图（节点 = agent/任务，边 = 依赖/交接协议）来编排多 agent 协作**，而不是让一个 agent 在循环里自己决定一切。要点：

- **两张图并存**：Org Graph（稳定层——长期存在、有固定领域和积累上下文的角色 agent，如 architect / reviewer）和 Work Graph（动态层——每次任务生成的节点，可按运行时证据增删重排）。
- **Advisor-Orchestrator 模式**：高能力模型（Fable 5）做路由和策略，便宜模型执行——报告的参考数字是约 92% 质量、63% 成本（第三方评测，仅供量级参考）。
- **关键教训**："图会逼你承认你的工作流里有多少环节其实没建模。" 显式定义交接协议（一个 agent 的输出如何变成下一个的输入）是价值所在。
- 工程上需要：角色说明书、交接协议、执行轨迹可观测、失败恢复规则（重试/降级路由/升级）。

本方案第 5 节的编排设计就是按 Org Graph + Work Graph 的思路组织的。

### 1.4 Apple container 现状（1.0）

- 已发布稳定 1.0：**每容器一个轻量 VM**（基于 Virtualization framework），OCI 兼容（可直接 pull Docker Hub / GHCR 镜像），Swift 实现。
- 硬性要求：**Apple Silicon + macOS 26**。
- 与 Docker 的差距：**没有成熟的 compose**、卷挂载和网络功能较新、无 K8s 桌面集成。1.0 新增 `container machine`（类似 WSL 的持久 Linux 环境）。
- 对本项目的含义：
  - 单体 bot + SQLite 的形态正好回避了 compose 缺失的短板（原项目 docker-compose 主要是 bot + 数据库/面板的编排）。
  - 构建产物用 `aarch64-unknown-linux-musl` 静态编译 → `FROM scratch` / distroless 镜像，几 MB 大小，VM-per-container 的开销可忽略。
  - 需要的持久化用 `container run -v` 挂载宿主目录（数据库文件、配置）；多进程编排（bot + NapCat）用两个 `container run` + 脚本，不依赖 compose。

### 1.5 Rust 侧生态现状

- **没有对等的 NoneBot2 生态**。原项目 pyproject 里 30+ 个 `nonebot-plugin-*` / adapter 依赖在 Rust 里都不存在，这是重写最大的真实成本（见第 2 节的功能取舍）。
- OneBot v11 在 Rust 有可用基础：[Kovi](https://github.com/Threkork/Kovi)（OneBot v11 插件式 bot 框架）、[onebot_v11 crate](https://crates.io/crates/onebot_v11)（协议类型定义）。可以二选一：直接基于 Kovi 做插件，或者只借协议类型自建框架层。**建议自建框架层 + 引用协议类型 crate**：本项目的核心诉求（自定义权限、ORM、多平台抽象、便于 Claude Code 批量生成插件）需要自己掌控 trait 设计，Kovi 的抽象未必匹配，而 OneBot v11 协议本身不复杂（WS + JSON）。
- 通用基建成熟：tokio（异步运行时）、axum（健康检查/metrics HTTP）、sqlx（SQLite，编译期校验 SQL）、serde、tokio-tungstenite（WebSocket）、cron 调度（tokio-cron-scheduler）。

### 1.6 Claude Code 长程编排与模型分级（2026 实践）

- **Subagent 按角色定义在 `.claude/agents/*.md`，frontmatter 的 `model:` 字段逐 agent 指定模型**——这是模型分级调度的原生机制，不需要外部框架。
- 常用编排模式（与本项目相关的四种）：Orchestrator-Worker（主会话调度专职 agent）、Fan-Out/Fan-In（N 个插件并行迁移）、Pipeline Chain（研究→架构→实现→验证）、Self-Healing Pipeline（验证器把关 + 带失败反馈的重试，设重试上限）。
- 长程任务的可靠性来自三件套：**磁盘化任务队列**（状态写文件，不依赖对话记忆）、**hooks 审计**（TaskCompleted 等钩子把每步结果追加到 jsonl）、**git worktree 隔离**（并行 agent 各占一个 worktree，避免互踩）。
- 模型分级的通行原则："**cheap fan-out, expensive judgment**"——探索和机械劳动用便宜模型，规则制定和裁决用最强模型。混合调度相比全用顶级模型可省 40–60% 成本（第三方数字，量级参考）。

---

## 2. 现状盘点与功能取舍

### 2.1 仓库现状（2026-08 main 分支）

- Python ≥3.14，NoneBot2 2.5，`uv` 管理；一方代码约 **12,000 行**（src/ 下 12 个插件 + utils）；pytest + nonebug 测试；已有一份质量不错的 `AGENTS.md`（架构说明可直接喂给迁移 agent 当背景资料）。
- 一方插件：`repeat`（复读+排行，核心特色）、`check_in`（签到）、`weather`（和风天气 + FF14 艾欧泽亚天气）、`ff14`（游戏查询）、`roll`、`morning`（每日问候+节假日）、`ban`（自主禁言）、`bihua`（表情/笔画）、`cyber_hospital`、`llm`（接大模型对话/TTS）、`health_check`、`qq_bot`。
- 关键基建依赖（都要在 Rust 里找替身或自建）：`nonebot-plugin-orm`（SQLAlchemy）、`alconna`（命令解析）、`apscheduler`（定时）、`send-anything-anywhere` + `uninfo`（跨平台消息/会话抽象）、自定义 permission/user 体系。
- **纯三方功能插件**（wordcloud 词云、memes 表情包制作、bison 订阅推送、parser 链接解析、htmlrender/playwright 渲染图片）：这些在 Python 侧是"免费"的，Rust 侧每个都是独立工程。

### 2.2 取舍建议（三档）

| 档位 | 内容 | 处理 |
|---|---|---|
| **P0 移植** | 框架核心、OneBot v11 适配、权限/用户体系、repeat、check_in、roll、morning、ban、health_check | Rust 重写，行为对齐原版 |
| **P1 移植** | weather、ff14、llm（HTTP API 调用类，逻辑清晰） | Rust 重写，外部 API 客户端用 reqwest |
| **P2 暂弃/外置** | wordcloud、memes、bison、parser、htmlrender 及图片渲染类 | 首期不做。渲染类功能后续可用 sidecar 容器（保留一个小 Python 服务）或 headless-chrome crate 补 |

> 判断依据：P2 那批在 Python 里是引三方库，在 Rust 里是从零造轮子（例如 htmlrender 意味着要带一个浏览器）。重写的价值集中在核心框架 + 自有业务逻辑上；渲染/爬虫类功能保持进程外反而架构更干净。

---

## 3. 目标架构（Rust Workspace）

### 3.1 目录结构

```
coolqbot-rs/
├── CLAUDE.md                    # Claude Code 常驻上下文（模板见附录 A）
├── docs/
│   ├── RULEBOOK.md              # 翻译规则手册（迁移期间的"宪法"，见附录 B）
│   ├── MIGRATION_STATUS.md      # 迁移看板（人读）
│   └── adr/                     # 架构决策记录（ADR-001 起）
├── .claude/
│   ├── agents/                  # subagent 定义（见附录 C）
│   ├── commands/                # /port-plugin 等自定义命令（见附录 D）
│   └── settings.json            # hooks 配置
├── queue/                       # 磁盘任务队列（done = 对应 .done 文件存在）
├── Cargo.toml                   # workspace
├── crates/
│   ├── bot-core/                # 事件模型、Plugin trait、消息段、路由、权限
│   ├── bot-adapter-onebot/      # OneBot v11：WS 正/反连、API 调用、事件解析
│   ├── bot-storage/             # sqlx + SQLite：迁移、会话、通用 KV
│   ├── bot-scheduler/           # cron 定时任务注册
│   ├── bot-command/             # 命令解析（对标 alconna 的子集）
│   └── plugins/
│       ├── plugin-repeat/
│       ├── plugin-check-in/
│       ├── plugin-weather/
│       └── ...                  # 一插件一 crate，feature flag 控制启停
├── bot-app/                     # 二进制入口：装配 core + adapter + plugins + axum 健康检查
├── tests/
│   ├── mock-onebot/             # 模拟 OneBot 实现端（WS server），行为对齐用
│   └── behavior/                # 从 pytest 用例翻译来的行为对齐测试
└── deploy/
    ├── Containerfile            # musl 静态编译 → distroless
    └── run-apple-container.sh   # container build/run 脚本（替代 compose）
```

### 3.2 核心设计决策（先由 Fable 5 定稿，写成 ADR）

1. **Plugin trait**：`async fn on_event(&self, ctx: &BotContext, ev: &Event) -> Result<Handled>`，注册命令/规则/定时任务用声明式 builder——这是全项目最重要的接口，所有插件迁移质量取决于它，必须在 fan-out 之前冻结。
2. **协议抽象分层**：`bot-core` 只认平台无关的 `Event` / `MessageSegment`（对标原项目 uninfo + saa 的角色），OneBot 细节全部隔离在 adapter crate。这样"以后加 Telegram"= 新增一个 adapter crate，不动插件。
3. **存储**：SQLite + sqlx，每插件独立迁移目录；用户/权限表对标原 `nonebot-plugin-user` + 自定义 permission 的语义（跨平台用户绑定这套逻辑是原项目的特色，必须保留）。
4. **配置**：单一 `config.toml` + 环境变量覆盖（figment），对标原 `.env` + 各插件 Config。
5. **可观测**：tracing + axum `/health`、`/metrics`（对标原 health_check 与 prometheus 插件）。

---

## 4. 迁移流程：六阶段改编版

把 Anthropic 的六阶段流程改编到"12k 行、单人 + Claude Code"的规模。每个阶段有明确的**进入条件、产出物、机械裁判**。

### Phase 0 — 清点与规则手册（Fable 5，一次性）

- 输入：CoolQBot 源码、AGENTS.md、本文档。
- 工作：生成插件依赖清单（每个插件用了哪些 nonebot 插件/API）、Python→Rust 惯用法映射初版 RULEBOOK、P0/P1/P2 取舍确认、Plugin trait 草案。
- 产出：`docs/RULEBOOK.md` v1、`queue/` 下每插件一个任务文件、ADR-001~005。
- 裁判：人工 review（这是全流程唯一必须人类深度参与的阶段）。

### Phase 1 — 核心骨架（Fable 5 设计 + Opus 5 实现）

- 工作：bot-core / bot-adapter-onebot / bot-storage / bot-command 四个基建 crate + mock-onebot 测试服务器。
- 裁判：`cargo test` 全绿；mock-onebot 能回放一段真实事件流；一个 hello-world 插件端到端跑通。
- **不并行**。基建是后续所有 fan-out 的地基，串行做完并冻结接口。

### Phase 2 — 压力测试：先迁一个最难的插件（Opus 5 × 2 方案竞争）

- 选 `repeat`（状态最多：数据库 + 定时任务 + 排行 + 概率复读）。让两个独立 agent 各迁一版，对比暴露 RULEBOOK 缺口。
- 产出：repeat 定稿 + **RULEBOOK v2（这是本阶段真正的产出）** + 插件迁移 checklist 模板。
- 裁判：从 `tests/plugins/repeat/` 的 pytest 用例翻译出的行为对齐测试全绿。

### Phase 3 — 插件 fan-out（Sonnet 5 并行 × 每插件，Opus 5 review）

- 每个 P0/P1 插件一个 porter agent（Sonnet 5），在独立 git worktree 里工作，输入 = 该插件 Python 源码 + 测试 + RULEBOOK + checklist。
- 每完成一个，reviewer agent（Opus 5，独立上下文）对照 Python 原版做对抗性 review；**发现模式化问题不许直接改代码，必须提议 RULEBOOK 补条目**，由 Fable 5 裁决后受影响插件重新生成。
- 裁判：该插件行为对齐测试 + clippy 零警告；`queue/<plugin>.done` 落盘才算完成。

### Phase 4 — 编译与修复循环（Sonnet 5 fixer，批量）

- workspace 全量 `cargo build && cargo clippy` → 错误按根因聚类 → fixer agent 逐类修。系统性错误回流 RULEBOOK。
- 裁判：全 workspace 零错误零警告。

### Phase 5 — 行为对齐与部署验收（Sonnet 5 跑批 + Fable 5 终审）

- mock-onebot 回放同一事件流，diff Python 版与 Rust 版的 API 调用序列；差异归类：bug / 有意改进（记入 ADR）/ 测试缺口。
- Apple container 部署验收：`container build` 出镜像 → `run-apple-container.sh` 拉起 bot + NapCat 两个容器 → 真实 QQ 冒烟。
- Fable 5 做最终架构审计：接口一致性、错误处理策略统一性、后续扩展点检查。

---

## 5. Claude Code 编排设计（Org Graph + Work Graph）

### 5.1 Org Graph：五个常驻角色（`.claude/agents/`）

| Agent | 模型 | 职责 | 关键约束 |
|---|---|---|---|
| `architect` | **Fable 5** | ADR、RULEBOOK 修订裁决、接口冻结、终审 | 只写规则和决策，不写业务代码 |
| `porter` | **Sonnet 5** | 按 RULEBOOK + checklist 迁移单个插件 | 禁止改动 crates/bot-core；疑问记入 questions.md 而不是自行发挥 |
| `reviewer` | **Opus 5** | 独立上下文对照 Python 原版审查 | 只产出 findings + RULEBOOK 修订提议，不直接改代码 |
| `fixer` | **Sonnet 5** | 编译/clippy/测试失败的机械修复 | 每次只处理一个根因聚类；重试上限 3 次，超限升级给 reviewer |
| `test-porter` | **Sonnet 5** | 把 pytest 用例翻译成 Rust 行为测试 | 测试必须先失败再随实现变绿（TDD 顺序） |

分歧升级链：porter ↔ reviewer 意见冲突 → architect 裁决（对抗性 review 的三方仲裁模式）。

### 5.2 Work Graph：任务如何流转

```
queue/plugin-repeat.task ──> porter(worktree) ──> reviewer ──┬─ pass ──> merge + touch queue/plugin-repeat.done
                                                             └─ fail ──> RULEBOOK 提议 ──> architect 裁决
                                                                              └─ 受影响插件任务重新入队
```

- **磁盘即状态**：`queue/*.task`（待办，内含插件名、源文件列表、验收命令）与 `queue/*.done`（完成凭证）。任何会话中断后，新会话读 queue 目录即可恢复，不依赖对话历史。
- **每晚跑批**：长程任务不追求单会话跑完。每个 porter 任务控制在一个会话能完成的粒度（一个插件 ≈ 300–1500 行），主会话只做调度。
- **hooks 审计**：`TaskCompleted` / `SubagentStop` 钩子追加 `{时间, 阶段, 插件, 结果, 模型}` 到 `.claude/audit.jsonl`，随时可以复盘哪个模型在哪类任务上返工率高，反过来调整路由表。
- **并行纪律**：fan-out 阶段每批 3–5 个 porter（不是 12 个全开）——批间可以吸收 RULEBOOK 修订，避免同一个系统性错误复制 12 份。

### 5.3 模型路由表（核心交付之一）

原则："cheap fan-out, expensive judgment"。判断标准不是任务大小，而是**错误的代价是否会向下游扩散**。

| 任务类型 | 模型 | 理由 |
|---|---|---|
| 接口/trait 设计、RULEBOOK 修订、取舍裁决、终审 | **Fable 5** | 错一处，全体 agent 跟着错；判断密集、产出短 |
| 基建 crate 实现、最难插件的首次迁移、疑难 bug（异步/生命周期/Send+Sync） | **Opus 5** | 需要深推理但产出是代码不是规则 |
| 对抗性 review | **Opus 5** | 要能看出 Sonnet 看不出的问题，但不必 Fable |
| 批量插件迁移、测试翻译、编译修复、文档 | **Sonnet 5** | 规则已定，执行为主；量大 |
| 代码库扫描、依赖清点、grep 类探索 | **Haiku**（如可用，否则 Sonnet 5） | 纯机械 |

落地方式（三层，按需组合）：
1. **静态路由**：subagent frontmatter 写死 `model:`（附录 C）——覆盖 90% 场景，零额外机制。
2. **升级路由**：fixer 重试 3 次失败 → 任务文件加 `escalate: opus` 标记重新入队；reviewer 与 porter 分歧 → architect（Fable）介入。难度不是预判出来的，是失败暴露出来的，所以**用失败信号驱动升级比预先分类更准**。
3. **降级检查**：audit.jsonl 里某类任务 Opus 一次通过率长期 100% → 降到 Sonnet 试点。

---

## 6. Apple container 部署方案

```dockerfile
# deploy/Containerfile —— 两阶段构建
FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY . .
RUN cargo build --release --target aarch64-unknown-linux-musl

FROM gcr.io/distroless/static
COPY --from=build /src/target/aarch64-unknown-linux-musl/release/bot-app /bot
VOLUME /data
ENTRYPOINT ["/bot", "--config", "/data/config.toml"]
```

```bash
# deploy/run-apple-container.sh —— 无 compose 的两容器编排
container system start
container build -t coolqbot-rs -f deploy/Containerfile .
container run -d --name napcat -v ~/botdata/napcat:/app/napcat/config mlikiowa/napcat-docker
container run -d --name coolqbot -v ~/botdata/bot:/data coolqbot-rs
```

注意点：Apple container 是 VM-per-container，网络上两个容器互访要用 `container inspect` 拿到的 IP 或宿主端口转发（其网络模型与 Docker bridge 不同，Phase 5 部署验收时实测为准）；数据全部落在挂载卷，容器无状态可随时重建；macOS 26 + Apple Silicon 是硬要求，你的 Mac mini 满足。

---

## 附录：可直接复制的指令模板

### 附录 A — `CLAUDE.md`（放仓库根目录）

```markdown
# coolqbot-rs

CoolQBot（Python/NoneBot2）的 Rust 重写。首发平台：QQ（OneBot v11）。
原 Python 代码在 `legacy/` 子目录（git subtree，只读参考）。

## 构建与验证
- 构建：`cargo build --workspace`
- 测试：`cargo test --workspace`（行为对齐测试在 tests/behavior/）
- Lint：`cargo clippy --workspace -- -D warnings`（零警告是合并条件）
- 单插件测试：`cargo test -p plugin-<name>`

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
```

### 附录 B — `docs/RULEBOOK.md` 种子版（Phase 0 由 architect 扩写）

```markdown
# 迁移规则手册 v1

> 本文件是迁移的唯一事实来源。发现模式化问题 → 在这里加规则 →
> 重新生成受影响代码。禁止绕过本文件在单个文件里打补丁。
> 每条规则有编号，review 意见必须引用规则编号或提议新规则。

## R1 框架映射
- R1.1 `on_alconna(...)` 命令 → `PluginDef::command(name, aliases, handler)`
- R1.2 NoneBot `Matcher.finish(msg)` → 返回 `Handled::Reply(msg)`
- R1.3 `nonebot_plugin_apscheduler` 定时任务 → `PluginDef::cron(expr, handler)`
- R1.4 NoneBot 事件类型 (GroupMessageEvent 等) → `Event` 枚举变体，
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
- R4.2 运行时插件发现 → 编译期注册表（bot-app 的 inventory/显式列表）

## 变更日志
- v1 (Phase 0): 初始版本
```

### 附录 C — Subagent 定义（`.claude/agents/`）

`architect.md`：
```markdown
---
name: architect
description: 架构决策、RULEBOOK 修订裁决、接口冻结、阶段终审。
  在接口设计、规则冲突、review 分歧升级时必须使用本 agent。
model: fable-5
tools: Read, Grep, Glob, Write, Edit
---
你是本项目唯一的架构权威。职责：
1. 裁决 RULEBOOK 修订提议：接受则改写 docs/RULEBOOK.md 并列出受影响的
   已完成任务（它们需要重新入队）；拒绝则在提议下写明理由。
2. 维护 docs/adr/：任何公共接口变更必须先有 ADR。
3. 阶段终审：检查接口一致性、错误处理统一性、扩展点是否保留。
约束：你不写业务代码。你的每个决定都要考虑"这条规则会被下游 agent
机械执行"——宁可具体到啰嗦，不要留判断空间。
```

`porter.md`：
```markdown
---
name: porter
description: 按 RULEBOOK 迁移单个插件。输入是 queue/ 里的一个任务文件。
model: sonnet-5
tools: Read, Grep, Glob, Write, Edit, Bash
---
迁移流程（严格按序）：
1. 读任务文件 → 读 legacy/ 对应插件全部源码和测试 → 读 docs/RULEBOOK.md。
2. 先写 crate 骨架和数据结构，对照 R2 规则建 migrations。
3. 逐命令迁移，每个命令完成后跑 `cargo test -p plugin-<name>`。
4. RULEBOOK 未覆盖的模式：追加到 queue/questions.md（格式：插件/文件:行号/
   Python 模式/你建议的 Rust 对应），然后跳过该处继续，留 `todo!()` 标记。
5. 完成条件：clippy 零警告 + 本插件测试全绿 + 无 todo!() 遗留
   （有遗留则任务状态写 blocked，不写 done）。
禁止：改 bot-core；发明 RULEBOOK 外的新约定；跨插件"顺手重构"。
```

`reviewer.md`：
```markdown
---
name: reviewer
description: 对抗性审查已迁移插件。独立上下文，对照 Python 原版逐行核对行为。
model: opus-5
tools: Read, Grep, Glob, Bash
---
你没有参与迁移，你的任务是找出问题。流程：
1. 只读 legacy/ 原版 + Rust 实现 + 该插件测试，不读 porter 的对话。
2. 逐个命令核对：触发条件、权限、回复文案、边界行为（空输入/超长/并发）。
3. 输出 findings 到 queue/review-<plugin>.md，每条分级：
   - BLOCKER：行为不等价
   - RULE：模式化问题 → 必须写成 RULEBOOK 修订提议（引用规则编号）
   - NIT：可留待后续
4. 你无权改代码。BLOCKER 退回 porter；RULE 升级给 architect。
判断标准：与 Python 版行为不一致就是错的，除非 ADR 里写了这是有意修正。
```

`fixer.md`：
```markdown
---
name: fixer
description: 批量修复编译错误/clippy 警告/测试失败。按根因聚类工作。
model: sonnet-5
tools: Read, Grep, Glob, Edit, Bash
---
1. 跑构建/测试，把错误按根因聚类，一次只修一类。
2. 同类错误出现 ≥3 处 → 先在 queue/questions.md 提议 RULEBOOK 规则，
   等裁决后再批量修，避免同一错误修出三种风格。
3. 每类重试上限 3 次；超限在任务文件标 `escalate: opus` 并停止。
```

### 附录 D — 自定义命令（`.claude/commands/`）

`port-plugin.md`：
```markdown
---
description: 迁移一个插件（porter → reviewer → 收尾的完整闭环）
---
迁移插件 $ARGUMENTS：
1. 确认 queue/$ARGUMENTS.task 存在且无 .done；读取任务文件。
2. 用 porter subagent 执行迁移。
3. porter 完成后，用 reviewer subagent 审查。
4. review 结果处理：BLOCKER → 带 findings 退回 porter（最多 2 轮）；
   RULE → 停下来汇报给我（人类）和 architect；全清 → 合并 worktree，
   touch queue/$ARGUMENTS.done，更新 docs/MIGRATION_STATUS.md。
5. 全程把每步结果追加到 .claude/audit.jsonl。
```

`triage-questions.md`：
```markdown
---
description: 用 architect 批量裁决 queue/questions.md 里积累的问题
---
读 queue/questions.md 全部未裁决条目，用 architect subagent 逐条处理：
更新 RULEBOOK / 写 ADR / 标记受影响任务重新入队。
处理完把条目移到 queue/questions-resolved.md 并附裁决结果。
```

### 附录 E — 阶段提示词模板（主会话使用）

**Phase 0 启动（对 architect，Fable 5）：**
```text
读 legacy/ 全部源码和 AGENTS.md，以及 docs/coolqbot-rust-rewrite-plan.md。
产出四份文件：
1. docs/plugin-inventory.md：每个插件的依赖清单（用到的 nonebot 插件、
   外部 API、数据库表、定时任务、消息类型），并标注 P0/P1/P2。
2. docs/RULEBOOK.md：在种子版基础上，针对本代码库实际出现的每种
   Python 模式补全映射规则（目标：porter 遇到 90% 的代码都有规则可查）。
3. queue/*.task：每个 P0/P1 插件一个任务文件，含源文件列表、涉及的表、
   验收命令、预估难度(S/M/L)。
4. docs/adr/ADR-001~005：Plugin trait 签名、事件模型、存储方案、
   配置方案、错误处理策略。
不要写任何实现代码。每个 ADR 给出被否决的备选方案及理由。
```

**Phase 3 fan-out（主会话调度，每批 3–5 个）：**
```text
读 queue/ 目录，选出 3 个无 .done、无 blocked、难度为 S/M 的任务。
对每个任务：在独立 git worktree 中执行 /port-plugin <name>。
三个全部收尾后：汇总 audit.jsonl 本批次数据（一次通过率、返工原因、
RULEBOOK 新增条目），如果出现 RULE 级问题，先跑 /triage-questions
再开下一批。
```

**Phase 5 行为对齐（Sonnet 5 跑批 + Fable 5 终审）：**
```text
用 mock-onebot 回放 tests/fixtures/events-*.jsonl，分别驱动
legacy（Python，docker 里跑）和 bot-app（Rust），录制两边的出站 API 调用序列。
diff 之，把差异归为三类写入 docs/behavior-diff.md：
(a) Rust bug → 生成 fixer 任务入队
(b) 有意改进 → 检查是否有对应 ADR，没有则标记
(c) 测试缺口 → 生成 test-porter 任务
全部归零后，用 architect 做终审 checklist。
```

---

## 7. 给你的操作顺序（TL;DR）

1. fork 仓库 → `git subtree add --prefix legacy <原仓库>`（保留原码只读参考）→ 放入附录 A–D 的文件。
2. 开一个 Fable 5 会话跑 Phase 0 提示词，**人工认真 review RULEBOOK 和 ADR**（全流程你唯一必须深度参与的点）。
3. Phase 1 基建：Fable 5 定接口 + Opus 5 实现，串行，直到 hello-world 插件端到端跑通。
4. Phase 2 用 repeat 插件双方案压力测试，喂肥 RULEBOOK。
5. Phase 3 起进入日常节奏：每批 3–5 个 `/port-plugin`，批间 `/triage-questions`。中断随时恢复（状态全在 queue/ 里）。
6. Phase 4–5 收敛，Apple container 实机部署验收。
7. 迁移完成后：删 queue/、把 RULEBOOK 里的通用约定合并进 CLAUDE.md，agents 里留 architect/reviewer 转为日常开发用——这套 Org Graph 不是一次性的，就是你后续开发的常驻结构。

## 主要参考来源

- Anthropic 官方：How Anthropic runs large-scale code migrations with Claude Code — https://claude.com/blog/ai-code-migration
- Graph Engineering (explainx) — https://www.explainx.ai/blog/graph-engineering-ai-agents-multi-agent-organizations-2026
- Graph Engineering 其他综述 — https://www.eigent.ai/blog/graph-engineering-ai-agents 、https://www.analyticsvidhya.com/blog/2026/07/graph-engineering/
- Apple Container 1.0 — https://cloudnativenow.com/features/apple-ships-stable-1-0-of-its-native-container-tool-for-macos/ 、https://www.explainx.ai/blog/apple-container-1-linux-containers-macos-26-swift-2026
- Claude Code 多智能体编排模式 — https://thepromptshelf.dev/blog/claude-code-multi-agent-orchestration-patterns-2026/
- 2026 模型选择指南 — https://claude-world.com/articles/claude-model-selection-guide-2026/
- Context Engineering 指南 — https://sourcegraph.com/blog/context-engineering 、https://www.firecrawl.dev/blog/context-engineering
- Rust 生态：Kovi — https://github.com/Threkork/Kovi 、onebot_v11 crate — https://crates.io/crates/onebot_v11
