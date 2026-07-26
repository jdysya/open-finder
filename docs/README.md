# OpenFinder 文档中心

本文档集面向项目维护者、插件开发者和新贡献者。代码标识、协议字段和路径保持英文，解释与操作说明使用中文。

## 从哪里开始

| 目标 | 文档类型 | 入口 |
| --- | --- | --- |
| 第一次构建并运行应用 | How-to | [开发与维护指南](development.md#构建与运行) |
| 理解系统边界和主调用链 | Explanation | [系统架构](architecture.md) |
| 理解插件发现、执行和结果呈现 | Explanation | [插件机制](plugin-system.md) |
| 查找模块、关键类型和依赖方向 | Reference | [模块参考](module-reference.md) |
| 编写或排查插件 | Reference | [插件 API](plugin-api.md) |
| 实现本地 HTTP 插件服务 | Reference | [HTTP 插件协议 v1](plugins/http-plugin-v1.md) 与 [OpenAPI](plugins/http-plugin-v1.openapi.json) |
| 理解任务和启动恢复 | Explanation | [持久化任务与恢复](task-recovery.md) |
| 新增结果类型或渲染器 | Reference | [Renderer Catalog](renderer-catalog.md) |
| 维护 Finder/Kodbox 标签 | Reference | [标签支持](kodbox-tag-support.md) |
| 维护 WebDAV | Reference | [WebDAV Provider Notes](webdav-notes.md) |
| 调整视觉规则 | Reference | [设计系统](../DESIGN.md) |

## 文档与代码的事实边界

| 事实 | 唯一事实源 | 文档的职责 |
| --- | --- | --- |
| Swift target、平台、依赖 | `Package.swift` | 解释为何分成 App/Core，并提供入口链接 |
| 插件 manifest 可解码字段与校验 | `PluginModels.swift`、`PluginManifestExecution.swift` | 提供可查表的公开契约与示例 |
| HTTP 插件线协议 | `plugins/http-plugin-v1.md`、`http-plugin-v1.openapi.json` | 两者必须同步；实现和测试不得放宽契约 |
| 持久化 schema | `AppDatabaseSchema.swift` | 解释表之间的关系和迁移原则，不复制完整 SQL |
| 内置结果处理与渲染 | `ApplicationServices.swift`、`PluginResultHandling.swift`、`PluginRendererCatalog.swift` | 解释扩展点和默认回退 |
| 运行时目录 | `ApplicationServices.swift`、`ApplicationServicesPluginOperations.swift`、`build_and_run.sh` | 汇总用户可见路径和生命周期 |
| 产品视觉行为 | `DESIGN.md` | 架构文档只描述技术边界，不重复视觉规范 |

## 现有内容处理决策

这张表是旧内容的保留/重构记录，也用于避免未来出现多个相互冲突的架构说明。

| 内容 | 决策 | 原因 |
| --- | --- | --- |
| `README.md` | 重构为项目入口 | 保留快速启动和功能概览，详细设计下沉到 `docs/` |
| `docs/architecture.md` | 重写 | 原文只覆盖插件结果流，无法代表文件源、远端、任务和持久化架构 |
| `docs/plugin-api.md` | 重写为参考文档 | 保留公开契约，移出架构解释，补齐 manifest、事件、工件和路径 |
| `docs/plugins/http-plugin-v1.md` | 保留 | 这是规范性协议文本；仅由协议变更驱动更新 |
| `docs/plugins/http-plugin-v1.openapi.json` | 保留 | 机器可读协议事实源，必须与规范文本同步 |
| `docs/task-recovery.md` | 保留并交叉链接 | 内容简洁且仍与启动门禁、roll-forward 恢复一致 |
| `docs/renderer-catalog.md` | 保留并交叉链接 | 是新增结果 schema 时的专项参考 |
| `docs/kodbox-tag-support.md` | 保留 | 是 Kodbox/Finder 标签的详细安全边界 |
| `docs/webdav-notes.md` | 保留 | 是 WebDAV V0 能力与限制清单 |
| `docs/2026-07-12-scoped-file-tags-retrospective.md` | 保留为历史记录 | 记录决策过程，不作为当前实现事实源 |
| `docs/plan.md` | 保留为历史产品计划 | 路线图可能超前于实现，不能替代架构文档 |
| `docs/superpowers/plans/`、`docs/superpowers/specs/` | 保留为历史实施材料 | 用于追溯，不纳入当前文档导航的事实层 |
| `DESIGN.md` | 保留 | 继续作为 UI/交互设计系统，不与代码架构混合 |

## 图表

Mermaid 图直接嵌在对应 Markdown 中，便于 GitHub/Codex 预览。可独立渲染的 PlantUML 源文件位于 [`docs/diagrams/`](diagrams/)：

- [`system-architecture.puml`](diagrams/system-architecture.puml)
- [`plugin-execution.puml`](diagrams/plugin-execution.puml)
- [`startup-recovery.puml`](diagrams/startup-recovery.puml)

## 维护规则

修改下列代码时，提交中应同步检查对应文档：

| 代码变更 | 必查文档 |
| --- | --- |
| 新增/删除 target、顶层目录或组合服务 | `architecture.md`、`module-reference.md` |
| 新增 `RemoteConnector`、`FileSourceAdapter` 或传输路径 | `architecture.md`、`module-reference.md`、`development.md` |
| 修改 manifest、匹配、凭据、runner、输出或工件 | `plugin-api.md`、`plugin-system.md` |
| 修改 HTTP 路由、字段、状态机或 SSE | `http-plugin-v1.md`、`http-plugin-v1.openapi.json`、协议测试 |
| 新增 durable task handler 或 payload version | `architecture.md`、`module-reference.md`、`task-recovery.md` |
| 修改数据库表、迁移、保留或 reconciliation | `architecture.md`、`task-recovery.md` |
| 新增结果 schema/handler/renderer | `plugin-system.md`、`renderer-catalog.md` |
| 修改 Finder/Kodbox/WebDAV 能力 | 对应 provider 专题文档 |

文档应描述稳定边界和不变量，而不是复制大段实现。公开字段使用表格，流程使用序列图，设计取舍放在 explanation 文档，具体操作放在 how-to 文档。
