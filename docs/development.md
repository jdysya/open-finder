# 开发与维护指南

本文提供可执行的维护步骤。架构原因见 [`architecture.md`](architecture.md)，字段级查找见 [`module-reference.md`](module-reference.md)。

## 前置条件

- macOS 14 或更高版本；
- Swift 6 工具链；
- Xcode Command Line Tools；
- 首次构建可访问 GitHub，以解析锁定为 `7.10.0` 的 GRDB；
- 运行示例 Python/Node 插件时安装对应 runtime。

## 构建与运行

只编译：

```bash
swift build
```

运行全部测试：

```bash
swift test
```

构建、组装、签名并启动 macOS app：

```bash
./script/build_and_run.sh
```

常用模式：

```bash
./script/build_and_run.sh build
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

`build` 只生成并签名 `dist/OpenFinder.app`；`--verify` 启动后检查进程存在；`--logs` 和 `--telemetry` 分别按进程与 subsystem 跟踪 unified log。

若本机有稳定开发证书，可设置：

```bash
OPENFINDER_SIGNING_IDENTITY="证书名称" ./script/build_and_run.sh
```

找不到证书时脚本使用 ad-hoc 签名，Keychain/TCC 授权可能无法跨重建稳定保留。

## 第一次运行后的检查

1. 主窗口显示左右两个本地 pane，默认分别为 home 和 `Downloads`。
2. 在任一 pane 中刷新、进入目录并选择多个文件。
3. 打开 Settings，确认插件列表包含 `ExamplePlugins` 中的合法插件。
4. 执行一个不需要外部服务的插件，例如 Batch Rename Demo。
5. 确认 task queue 依次出现 queued/running/terminal 状态，并可查看日志。
6. 退出并重新打开，确认任务历史仍存在。

持久数据位于 `~/Library/Application Support/OpenFinder/`。不要通过删除 `tasks.sqlite` 处理迁移错误；先保存副本并检查 readiness/日志。

## 运行有针对性的测试

按模块筛选：

```bash
swift test --filter PluginSystemTests
swift test --filter TaskQueueTests
swift test --filter WebDAVProviderTests
swift test --filter KodboxProviderTests
swift test --filter ArtifactResultServiceTests
```

HTTP transport 变更至少覆盖 endpoint、wire、SSE/stream、取消与一个真实 URLSession characterization。数据库变更至少覆盖 migration、未来版本拒绝、reconciliation 和 task/artifact 集成。

## 添加 process 插件

1. 在 `ExamplePlugins/` 或用户 Plugins 目录创建 `.openfinderplugin` 包。
2. 使用 manifest schema 1，声明 `runtime`、`entry`、actions、permissions 和 configuration。
3. 从 stdin 解码一个 `PluginInput` JSON。
4. 只向 stdout 写 NDJSON 事件；诊断文本写 stderr。
5. 最后一条 stdout 事件必须是唯一 terminal result。
6. 文件结果写入 `outputDirectory`，计算 byte count 与 SHA-256，并返回相对路径 artifact。
7. 在应用中确认 action 匹配、任务状态、取消和结果呈现。

完整字段与示例见 [`plugin-api.md`](plugin-api.md)。

## 添加 HTTP 插件

1. 使用 manifest schema 2 和 `execution.type = "http"`。
2. endpoint 配置字段必须指向数字 loopback URL。
3. token key 必须出现在 `keychainSecrets` 或 `localSecrets` 中且只能出现一次。
4. 服务严格实现 [HTTP v1](plugins/http-plugin-v1.md)。
5. 先在 Settings 执行连接检查，再提交 action。
6. 验证 SSE、poll fallback、取消、同 taskID 幂等、断线重连和服务重启失败。
7. 若更改 wire contract，同时更新 Markdown、OpenAPI 和两端契约测试。

不要把服务源码、venv 或二进制 worker 复制进 `video-analyzer.plugin`；该包只描述独立服务连接。

## 添加远端连接器

1. 为 connector 定义稳定 `RemoteConnectorID`。
2. 在 `RemoteConnectorRegistry` 提供显示名、配置字段、凭据键和 provider factory。
3. 实现 `RemoteProvider` actor；所有路径保持 provider 自己的 opaque identity。
4. 明确 `RemoteDirectoryCapabilities` 与每个 item 的能力。
5. 若支持标签，额外实现 `TagProvider`；不要让所有远端 provider 被迫支持标签。
6. 在 `RemoteProviderRegistry` 的 revision 中包含会改变 provider 行为的账号字段。
7. 添加 registry、provider contract、缓存失效、传输和错误映射测试。
8. 更新 [`module-reference.md`](module-reference.md) 和 provider 专题文档。

UI 应读取能力，不应新增 `if connectorID == ...` 来决定通用操作可用性。

## 添加 durable task handler

1. 选择稳定且命名空间化的 handler ID。
2. 定义 Codable、可 redaction 的 payload envelope，并从 version 1 开始。
3. 实现 `TaskHandler`，通过 `TaskEventSink` 发布 progress/log/status。
4. 为所有外部依赖保存稳定 identity/reference，不保存 live object 或明文 secret。
5. 在 `ApplicationServices.taskRegistrations` 注册 handler 与精确依赖集合。
6. 更新 `AppDurableHandlerComposition` 的期望组合；缺少或多余注册都应使 readiness 失败。
7. 定义取消窗口、effects commit 点、retry 行为和 recovery unavailable 原因。
8. 添加 descriptor contract、handler、恢复和真实副作用测试。
9. 更新 [`task-recovery.md`](task-recovery.md) 与模块参考。

Payload 发生不兼容变化时新增 version/decoder；不要把旧 payload 当作新版本猜测解码。

## 添加结果 schema 与 renderer

1. 为公开 schema 选择稳定 ID 和独立 schema version。
2. 在 Core 定义 Codable document 及显式 `validate`。
3. 添加 `PluginResultHandler`，按 schema ID 生成 typed projection。
4. 若需要专用 UI，在 App 添加 `PluginRendererCatalog.Entry`，包含 schema ID、descriptor 和 typed predicate。
5. 在 `ApplicationServiceDependencies` 默认 handler/renderer 列表注册。
6. 更新 `AppDurableHandlerComposition` 组合期望。
7. 用至少两个不同 plugin ID 验证同一 schema 共享 handler 与 renderer。
8. 保证类型不匹配时回退 generic renderer。
9. 更新 [`renderer-catalog.md`](renderer-catalog.md)、插件文档和 fixtures。

若新插件能表达为已有 schema，不要新增 plugin-ID renderer 分支。

## 修改持久化 schema

1. 在 `AppDatabase` 增加严格递增、append-only migration。
2. 更新 `app_schema_metadata.schema_version`。
3. 保留未知未来版本数据库，不删除、不重建。
4. 为新表/列定义 CHECK、外键、索引和 reconciliation 状态。
5. 设计崩溃发生在每个文件/数据库副作用之间时的 roll-forward 行为。
6. 添加从所有已发布版本迁移、未来版本拒绝、malformed schema 和 root race 测试。
7. 更新架构中的数据模型与 [`task-recovery.md`](task-recovery.md)。

## 修改 UI

1. 先确认行为属于 `AppModel` intent、应用服务还是纯 presentation。
2. 文件选择、context menu、拖放和表格复用优先在 `FileTableRepresentable` 的 AppKit 边界维护。
3. 使用 `DESIGN.md` 的动态系统颜色、字体、间距和 accessibility 规则。
4. 更新现有 visual harness，或为新的可观察状态增加等价验收。
5. 实际启动 app 检查 Light/Dark、resize、keyboard、空/加载/错误状态。

## 文档变更检查

提交前从 [`docs/README.md`](README.md#维护规则) 查找触发矩阵，并运行：

```bash
swift build
swift test
./script/build_and_run.sh --verify
```

纯文档变更仍需检查相对链接、Mermaid/PlantUML 语法，以及文档命令是否与当前脚本一致。
