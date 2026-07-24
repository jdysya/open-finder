# OpenFinder 架构与设计指南

本文档是根据当前仓库代码同步整理的架构说明。它负责解释“代码为什么这样组织、各模块如何协作、后续扩展应遵守哪些边界”。产品规划仍以 [`docs/plan.md`](plan.md) 为准；插件协议细节见 [`docs/plugin-api.md`](plugin-api.md) 与 [`docs/plugins/http-plugin-v1.md`](plugins/http-plugin-v1.md)；Provider 专项行为见 [`docs/webdav-notes.md`](webdav-notes.md) 与 [`docs/kodbox-tag-support.md`](kodbox-tag-support.md)。

## 1. 产品定位与工程原则

OpenFinder 是一个原生 macOS 文件工作台，不是 Finder 的完整复刻。当前实现围绕四个核心原则展开：

1. **文件浏览是入口。** 本地与远程位置使用共享领域模型表示，Pane、菜单、任务与插件在执行副作用前都可以先判断能力边界。
2. **插件动作是扩展层。** 插件通过 manifest 声明右键动作与匹配规则，执行层可路由到本地进程或 loopback HTTP 服务。
3. **任务队列是可观察执行层。** 传输、插件、视频分析等耗时操作都会变成有状态、有日志、有进度、可取消、可重试的任务记录。
4. **远程存储是 Provider 边界，不是挂载盘。** WebDAV 与 Kodbox 在 App 内通过 Provider 浏览和操作；未实现的 SFTP、S3、rclone 等连接器保持显式不可用，而不是伪装成本地路径。

项目当前由一个 SwiftPM macOS 14 App 和一个可测试 Core Library 组成：`OpenFinderApp` 负责 SwiftUI/AppKit 界面与主应用编排；`OpenFinderCore` 负责 Provider 合约、领域模型、持久化接缝、任务系统、插件协议、远程实现、产物处理与视频分析模型。

## 2. 模块地图

```text
OpenFinder
├─ Sources/OpenFinderApp
│  ├─ App/          SwiftUI App 入口、应用委托与 Commands
│  ├─ Models/       MainActor 应用状态、双 Pane 编排、任务/插件/远程账号接入
│  ├─ Support/      面向 UI 的 reducer、平台适配、展示模型和工作区辅助逻辑
│  └─ Views/        SwiftUI 页面，以及用于文件表格的 AppKit NSTableView bridge
├─ Sources/OpenFinderCore
│  ├─ Domain/       Provider 中立的文件、位置、能力、标签与错误模型
│  ├─ FileSystem/   本地文件 Provider、文件源注册表、传输协调与 Pane 状态
│  ├─ Remote/       远程连接器注册表，以及 WebDAV、Kodbox Provider
│  ├─ Plugins/      插件 manifest、匹配、进程/HTTP runner、协议校验与产物模型
│  ├─ Tasks/        任务队列、任务描述符、handler、进度、日志与恢复语义
│  ├─ Persistence/  JSON 配置存储与 SQLite 数据库基础
│  ├─ Security/     Bookmark、Keychain、插件凭据解析与本地凭据存储
│  ├─ Artifacts/    插件产物的受限读取、暂存、发布、链接与一致性修复
│  ├─ Results/      可持久化结果文档 schema
│  ├─ VideoAnalysis/视频分析请求、事件、结果、持久化与展示逻辑
│  └─ Utilities/    编码、文件大小格式化等共享工具
├─ ExamplePlugins/  内置/开发用插件示例
├─ Tests/           Core 与 App 层契约测试
└─ docs/            产品、架构、Provider 与插件协议文档
```

这个分层的目标是：让领域模型先于 UI 出现，让 Provider 差异限制在 Provider 内部，让耗时工作统一进入任务队列，让插件协议独立于具体界面。

## 3. 运行时组合关系

`AppModel` 是交互式 App 的组合根，运行在 `@MainActor`。启动时它创建或注入远程账号目录、JSON 配置存储、Keychain 凭据存储、远程连接器/Provider 注册表、文件源注册表、任务队列、插件 runner 路由器、插件连接检查器、插件执行协调器、视频分析结果存储，以及左右两个浏览 Pane。

```text
OpenFinderApp
  └─ AppModel (@MainActor)
      ├─ BrowserPaneModel(left) ──┐
      ├─ BrowserPaneModel(right) ─┤→ FileSourceRegistry → LocalFileProvider / RemoteProvider
      ├─ TaskQueueService ─────────→ TaskHandlerRegistry / ad-hoc operation
      ├─ PluginRegistry ───────────→ LoadedPlugin + load diagnostics
      ├─ PluginExecutionCoordinator
      │   └─ PluginRunnerRouter ───→ ProcessPluginRunner / HTTPPluginRunner
      ├─ RemoteAccountDirectory ───→ remote-accounts.json
      ├─ JSONConfigStore ──────────→ config.json
      ├─ KeychainStore ────────────→ 远程账号密码与插件 secret
      └─ VideoAnalysisResultStore ─→ Application Support/video-analysis
```

UI 状态集中在主线程，Core 中的队列、注册表、Provider、结果存储等多数使用 actor 或 Sendable value type。这样既保持 AppKit/SwiftUI 状态更新可预测，也允许文件 I/O、网络、插件与任务执行异步运行。

## 4. 领域模型与能力模型

`Sources/OpenFinderCore/Domain` 是项目最重要的边界之一。它不应该泄漏 AppKit 细节，也不应该泄漏 WebDAV/Kodbox DTO。

核心概念如下：

- `Location`：用户在 Pane 中看到的位置，可解析为 `FileLocation`，也可能携带“不支持”的原因。
- `FileSourceID`：区分 `.local` 与 `.remote(accountID, connectorID)`。
- `FileItem`：文件/目录展示与操作所需的中立元数据，包括名称、类型、大小、日期、标签、来源位置、可读/可写/可编辑标签状态。
- `FileProvider`：本地文件操作合约，包括 list、stat、create、rename、trash/delete、copy、move。
- `RemoteProvider`：远程浏览与操作合约，返回 `RemoteDirectoryListing` 与 `RemoteItem`。
- `FileSourceCapabilities`、`FileListingCapabilities`、`FileItemCapabilities`：把“Provider 静态支持什么”和“当前目录/条目元数据允许什么”合并为最终能力判断。

能力模型不是纯 UI 装饰，而是副作用执行前的安全边界。Generic WebDAV 支持浏览和传输，但不支持标签；Kodbox 通过专门 API 支持标签；未知 connector、legacy rclone、跨源 server-side 操作、远程覆盖等场景都应显式返回不可用原因。

## 5. 浏览 Pane 与文件列表

每个 `BrowserPaneModel` 拥有一个 Pane 的位置、列表、选中项、过滤条件、排序、加载/错误状态、标签编辑会话以及远程 Provider revision。为了避免把所有逻辑堆进一个巨型模型，Pane 的能力被拆分到多个扩展文件：

- `BrowserPaneListing.swift` / `BrowserPaneNavigation.swift`：列表加载、路径导航、刷新；
- `BrowserPaneFileActions.swift`：新建、重命名、删除等文件动作；
- `BrowserPaneRemote.swift`：远程 Provider 解析与远程列表适配；
- `BrowserPaneTagSupport.swift` / `BrowserPaneTags.swift`：标签目录、作用域、关联与编辑会话。

文件列表使用 AppKit `NSTableView` bridge，而不是纯 SwiftUI 表格。原因是文件管理器需要稳定的桌面行为：高密度列表、多选、range selection、右键时先规范化选中行、动态菜单、列宽调整、拖放、焦点与键盘行为。SwiftUI 负责窗口、Pane 容器、设置页、任务队列、sheet、视频分析工作区等更适合声明式组织的部分。

## 6. 文件源与传输设计

`FileSourceRegistry` 将 `Location` 解析为 `ResolvedFileSource`，底层可能是 `LocalFileProvider`，也可能是从 `RemoteProviderRegistry` 取出的远程 Provider。它还负责 materialization：当插件或预览需要本地文件时，将远程资源下载到受控临时命名空间，并通过 `MaterializationLease` 管理生命周期。

传输逻辑独立于简单 Provider 调用：

- `TransferRequest` 描述 copy/move、源位置、目标位置、覆盖策略和条目快照；
- `TransferCoordinator` 通过 `TransferFileOperations` 执行具体文件操作；
- `TransferCopyTaskHandler` 与 `TransferMoveTaskHandler` 把传输请求接入任务队列；
- App 层在执行破坏性覆盖前做冲突检测并展示确认；远程覆盖默认仍保持显式防护。

这种设计避免假设所有来源都能做同一种操作。同源远程操作可以使用 Provider 的原生 COPY/MOVE；跨源传输可以退化为读取/materialize/写入；失败恢复和部分失败由任务与传输 handler 负责表达。

## 7. 远程连接器与 Provider

`RemoteConnectorRegistry` 是用户可见连接器目录，目前内置：

- **WebDAV**：通用 WebDAV endpoint，HTTPS 优先，凭据通过 `KeychainStore` 读取；
- **Kodbox**：要求服务器根 URL，使用 Kodbox API session 登录/访问，同时复用 WebDAV 类浏览能力并暴露 Kodbox 个人/团队标签能力。

`RemoteProviderRegistry` 按 account + revision 缓存 Provider actor。远程账号变更时需要 invalidate，防止 Pane 继续使用旧 endpoint 或旧凭据。

Provider 细节不应该散落在 UI 中：

- WebDAV 的 V0 行为、Multi-Status 校验和边界记录在 [`docs/webdav-notes.md`](webdav-notes.md)。
- Kodbox 的个人/团队标签路由、权限、path delimiter 安全、scope 校验记录在 [`docs/kodbox-tag-support.md`](kodbox-tag-support.md)。

未来接入 SFTP、S3、rclone 时，应先扩展 connector registry、provider registry、provider 合约和 capability，而不是在 View 或 AppModel 里增加 provider-specific 分支。

## 8. 标签架构

标签使用 `Domain/FileTag.swift` 中的 Provider 中立模型：

- `FileTagScope`：定义 local、personal、team 等作用域，并声明是否可关联、创建、重命名、改样式、删除、分组；
- `FileTag`：身份由 `scopeID + id` 决定，不由展示名决定；
- `FileTagCatalog`：承载 scopes、groups、tags 和 providerState；
- `FileTagChangeSet`：在 apply 前去重并消除同时 add/remove 的冲突；
- `TagProvider`：Provider 可选实现的目录加载、目录变更、条目关联合约。

本地标签通过 Foundation 公开的 Finder tag name resource API 读写，只处理名称，不读写私有 xattr 或 Finder 内部颜色元数据。Kodbox 个人标签和团队标签属于不同作用域；Generic WebDAV 明确不支持标签。Scoped tag editor 必须防止跨账号、跨 Provider、跨 team group 混用标签。

## 9. 插件架构

插件是带 manifest 的包目录，来自内置、用户和开发位置。`PluginRegistry` 负责扫描、解码 manifest、拒绝不安全包结构、报告 diagnostics，并根据当前选区匹配 action。

当前有两类执行方式：

1. **进程插件**：schema version 1，manifest 使用 `runtime` + `entry`。OpenFinder 向 stdin 发送一个 JSON 输入对象，从 stdout 读取严格的 newline-delimited JSON 事件。
2. **本地 HTTP 插件**：schema version 2，manifest 使用 `execution`。OpenFinder 只允许 loopback HTTP v1 endpoint，通过 bearer token、幂等 job 创建、snapshot、SSE 事件、取消与结果拉取完成交互。

`PluginExecutionCoordinator` 负责准备 workspace、解析配置与 secret 引用、按需检查 HTTP 连接、通过 `PluginRunnerRouter` 执行、接收事件回调、提交插件产物并按策略清理 workspace。进程插件的 secret 通过环境变量注入，`PluginInput` 只携带生成的环境变量名，不序列化明文 secret。

## 10. 任务队列与执行模型

`TaskQueueService` 是统一执行层。它维护队列、运行中任务、任务记录、日志、取消请求、已提交副作用标记、resource key 互斥与最大并发数。

任务可以来自三种形态：

- ad-hoc async operation closure；
- 带 durable descriptor 的任务，由 `TaskHandlerRegistry` 分发给对应 handler；
- 恢复出来的 persisted task：如果 descriptor payload 损坏或 handler 不可用，会变成 unavailable 记录。

任务记录支持 queued、running、succeeded、failed、cancelled、cancelling、unavailable 等状态；支持进度快照、日志追加、取消、重试与 lineage。队列在任务标记 effects committed 后不再允许普通取消，以避免在不可回滚阶段制造更大的不一致。

## 11. 插件产物与结果投影

插件生成的文件必须位于声明的工作区内，并通过 `ConfinedArtifactReader` 复制。`ArtifactStore` 在 App 管理的 root 下完成 staging、validation、publish、link 和 reconciliation，并通过 `ArtifactMetadataBackend` 保存元数据。

结果展示是 schema-driven 的：插件结果 handler registry 将已知 schema 映射到 UI projection；未知结果保留 fallback projection，避免新插件结果导致 UI 崩溃。视频分析是当前最完整的结果类型，用结构化文档、受限 asset 引用和专门视图展示结果。

## 12. 视频分析工作流

视频分析并不是独立于插件系统的特殊后门，而是建立在同一套插件/任务/结果机制之上：

1. 视频分析 action 通过插件匹配进入任务队列；
2. worker 事件更新任务进度和日志；
3. 插件返回结构化 media-analysis document 与可选受限资产；
4. App 解码、持久化并投影到视频分析工作区；
5. UI 上的分析标签筛选只影响展示，不修改文件元数据；
6. Finder 标签建议默认不选中，只有用户显式勾选后才进入 Finder tag reconciliation。

因此，分析维度和文件系统标签保持分离：过滤是展示状态，同步 Finder 标签是用户确认后的元数据写入。

## 13. 持久化与安全边界

持久化保持 seam-oriented，方便测试和未来替换：

- `JSONConfigStore` 保存显示偏好、删除确认、最大并发、Python/Node 路径、插件配置、本地插件 secret 和迁移标记；在 Darwin 平台上使用 owner-only 权限写入；
- `RemoteAccountDirectory` 保存非 secret 的远程账号元数据；
- `KeychainStore` 抽象 macOS Keychain，测试中可使用 in-memory store；
- `BookmarkStore` 为未来 sandbox/security-scoped bookmark 流程保留模型；
- `AppDatabase` 与迁移测试提供 SQLite 持久化基础；
- `PluginCredentialResolver` 将 Keychain 与本地插件 secret 统一解析给执行层。

当前安全姿态适合 Developer ID 原型：脚本插件以用户权限执行，manifest permissions 用于 UX/audit 而不是强隔离；HTTP 插件只允许 loopback endpoint；远程凭据优先存 Keychain；HTTPS 默认必需，只有显式开发开关允许不安全 HTTP；artifact/materialization 路径必须通过边界校验。

## 14. UI 与设计理念

`DESIGN.md` 是视觉与交互设计的长期来源。架构层面对 UI 的约束是：

- 使用 macOS 原生控件、语义颜色、焦点环、菜单、sheet 和可访问性语义；
- 桌面表格细节交给 AppKit，页面组合、设置、任务和结果视图交给 SwiftUI；
- 操作不可用时优先在能力模型和 UI 层禁用，而不是等副作用失败；
- 标签、进度、分析 label 都是辅助文件工作流的元数据，不应压过文件名和路径；
- 视觉截断不能丢数据：tooltip、accessibility label/value 必须保留完整信息。

## 15. 测试策略

当前测试更偏契约测试，而不是只覆盖 happy path：

- Domain/capability contract；
- Local provider 与 Finder tag 行为；
- WebDAV/Kodbox 请求、响应、权限与异常形状；
- 插件 manifest、匹配、进程输出校验、HTTP transport、SSE、取消与 malformed wire；
- 任务队列调度、取消、重试、恢复、descriptor availability；
- transfer copy/move 恢复和部分失败；
- App 层 reducer、插件路由、workspace 生命周期、设置持久化、展示 helper；
- 视频分析 schema、结果解码、持久化与展示。

新增功能时，优先为不可变约束添加 Core/provider 测试，再为 App 编排添加轻量模型测试。依赖真实 AppKit 复用、右键选区、桌面焦点或窗口行为的内容，需要专门 App 测试或明确的手动 QA 记录。

## 16. 后续扩展规范

扩展仓库时请遵守以下顺序和边界：

1. 新概念先进入 `OpenFinderCore/Domain`，避免直接从 View 或 Provider DTO 开始；
2. 新操作先定义 capability，再暴露按钮、菜单或快捷键；
3. Provider-specific DTO 留在 `Remote/` 实现内部；
4. 新远程存储通过 `RemoteConnectorRegistry`、`RemoteProviderRegistry`、`FileSourceRegistry` 接入；
5. 耗时任务进入 `TaskQueueService`，需要恢复/重试时使用 durable descriptor；
6. 插件协议变更必须版本化，或保持向后兼容，并同步 `docs/plugins/`；
7. 不要把明文 secret 写入 manifest、config、task descriptor、plugin input、日志或 fixture；
8. Finder 标签只使用公开 macOS API，不读写私有 metadata/xattr；
9. 横切架构变更同步更新本文档，Provider 或协议细节写入对应专题文档。
