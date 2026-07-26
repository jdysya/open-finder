# OpenFinder 模块参考

本文是当前源码的查找索引。它描述每个目录的职责、关键类型、依赖和修改影响；流程原因见 [`architecture.md`](architecture.md)。

## 仓库布局

| 路径 | 内容 |
| --- | --- |
| `Package.swift` | macOS 14+、`OpenFinderCore` library、`OpenFinderApp` executable、两个 test target、GRDB 7.10.0 |
| `Sources/OpenFinderCore/` | 无 UI 的领域与运行时核心 |
| `Sources/OpenFinderApp/` | macOS 入口、应用组合与 UI |
| `Tests/OpenFinderCoreTests/` | Core 单元、契约、集成和真实 transport characterization |
| `Tests/OpenFinderAppTests/` | 组合、UI interaction、routing 和 visual harness |
| `ExamplePlugins/` | 可打包的内置/开发示例插件 |
| `Resources/` | App icon |
| `script/` | 构建 app bundle、签名、运行和图标生成 |
| `docs/` | 当前文档、规范和历史计划 |

## OpenFinderCore

### Domain

| 文件 | 关键类型 | 职责 |
| --- | --- | --- |
| `FileItem.swift` | `FileItem`, `FileKind` | UI 与任务共享的文件快照，含 location、类型、大小、MIME/UTI、标签和能力 |
| `Location.swift` | `Location` | 公开位置模型与兼容解码：local/remote |
| `FileSource.swift` | `FileSourceID`, `FileLocation`, `FileSourceCapabilities` | 可扩展文件源身份、解析结果和分层能力 |
| `FileProvider.swift` | `FileProvider`, `FileSort`, `FileListOptions` | 本地 provider 的基础文件操作契约 |
| `FileCapabilityDecision.swift` | `FileCapabilityDecision`, `FileOperationPreflight` | 把源/项目/关系能力转成允许、禁用或拒绝 |
| `FileTag.swift` | `FileTag`, `FileTagScope`, `TagProvider` | 本地、个人、团队 scope 的标签目录、变更和部分失败 |
| `OpenFinderError.swift` | `OpenFinderError` | Core 的稳定用户可读错误类别 |

维护约束：新增文件操作先扩展能力模型，再实现 provider 和 UI；不要在 App 层通过 connector ID 猜能力。

### FileSystem

| 文件/组 | 关键类型 | 职责 |
| --- | --- | --- |
| `LocalFileProvider.swift` | `LocalFileProvider` | 本地 list/stat/create/rename/trash/copy/move |
| `LocalFileProvider+Tags.swift` | `TagProvider` 实现 | Finder 公共 tag-name API、delta 更新和并发串行化 |
| `FileSourceRegistry.swift` | `FileSourceRegistry`, adapters, `MaterializationLease` | Location 兼容、文件源解析、有效能力、远端 materialization |
| `FileSourceAdapterOperations.swift` | adapter 操作 | 将统一操作转发给 local/remote provider |
| `MaterializationService.swift` | `MaterializationService` | 把远端项目下载到拥有生命周期的本地命名空间 |
| `TransferCoordinator.swift` | `TransferCoordinator` | local↔local、local↔remote、remote↔remote 复制/移动策略与补偿 |
| `TransferFileOperationsRegistry.swift` | transfer operations | 为恢复任务重新绑定精确 provider I/O |
| `TransferRegistryIO.swift` | `TransferRegistryIO` | 传输读取、写入、创建目录、删除和路径辅助 |
| `PaneState.swift` | `PaneState` | Core 可测试的 pane 导航/选择状态 |

传输实现必须保留“先预检、执行时重新解析、无静默覆盖、move 失败可恢复”的边界。

### Remote

| 文件/组 | 关键类型 | 职责 |
| --- | --- | --- |
| `RemoteModels.swift` | `RemoteAccount`, `RemotePath`, `RemoteProvider` | connector 无关的账号、路径、listing、能力与 actor 协议 |
| `RemoteConnectorRegistry.swift` | `RemoteConnector`, `RemoteConnectorRegistry` | 连接器元数据、配置字段和 provider factory；内置 WebDAV/Kodbox |
| `RemoteProviderRegistry.swift` | `RemoteProviderRegistry` | 按 account/revision 缓存并失效 provider |
| `WebDAVProvider.swift` | `WebDAVProvider` | PROPFIND/MKCOL/DELETE/MOVE/COPY/PUT/GET、Multi-Status 校验 |
| `KodboxHTTPClient.swift` | `KodboxHTTPClient`, `KodboxEndpoint` | 表单/multipart 请求、信封解码、错误与敏感信息脱敏 |
| `KodboxAPISession.swift` | `KodboxAPISession` | bootstrap、登录、token refresh 一次重试 |
| `KodboxProvider.swift` | `KodboxProvider` | synthetic root、列表、文件/目录变更、上传下载 |
| `KodboxProvider+PersonalTags.swift` | `TagProvider` 实现 | 个人标签 catalog 与项目关联 |
| `KodboxProvider+TeamTags.swift` | team tag 操作 | group scope、权限、最小 diff 和安全 path |
| `KodboxTeamTagCatalog.swift` | team payload/diff models | Kodbox team tag wire shape 与编码 |

Generic WebDAV 不实现 `TagProvider`。Kodbox 规则的字段级边界见 [`kodbox-tag-support.md`](kodbox-tag-support.md)。

### Tasks

| 文件/组 | 关键类型 | 职责 |
| --- | --- | --- |
| `TaskModels.swift` | `TaskRecord`, `TaskDescriptorEnvelope`, `TaskStatus` | durable identity、谱系、状态、进度和序列化 envelope |
| `TaskQueueService.swift` | `TaskQueueService`, `TaskRequest`, `TaskExecutionContext` | actor 队列、并发/资源互斥、取消、重试、执行与持久化 |
| `TaskStore.swift` | `TaskStore` | task/descriptor/log 原子存取协议 |
| `GRDBTaskStore.swift` | `GRDBTaskStore` | SQLite 实现和启动 recovery transaction |
| `TaskEventSink.swift` | `TaskEventSink`, `TaskEvent` | handler 到 queue 的 progress/log/status 通道 |
| `TaskHandlerRegistry.swift` | `TaskHandler`, `TaskHandlerRegistry` | `handlerID + payloadVersion` 精确分派 |
| `PluginTaskEnvelope.swift` | plugin descriptor payload | 不可变插件、文件、配置、secret reference 和 workspace 快照 |
| `PluginExecuteTaskHandler.swift` | `PluginExecuteTaskHandler` | 恢复 plugin snapshot、运行 coordinator、发布 projection |
| `TransferTaskEnvelope.swift` | transfer descriptor payload | 源/目标/项目、overwrite、谱系与恢复信息 |
| `TransferCopyTaskHandler.swift` | copy handler | durable copy 执行 |
| `TransferMoveTaskHandler.swift` | move handler | durable move、部分提交与补偿 |

任务状态包括 `queued/running/succeeded/failed/cancelling/cancelled/interrupted/unavailable`。新增 handler 时必须注册精确 payload version，并更新 App 组合门禁。

### Plugins

| 文件/组 | 关键类型 | 职责 |
| --- | --- | --- |
| `PluginModels.swift` | manifest/action/permissions/input | 插件公开数据模型 |
| `PluginManifestExecution.swift` | manifest Codable/validation | schema 1 process 与 schema 2 HTTP 的互斥校验 |
| `PluginRegistry.swift` | `PluginRegistry`, `LoadedPlugin` | 包扫描、诊断、来源优先级和重复 ID 解析 |
| `PluginMatcher.swift` | `PluginMatcher` | selection、extension、UTType、MIME 匹配 |
| `PluginConfigurationResolver.swift` | `ResolvedPluginConfiguration` | 声明字段的 saved/default/secret reference 合并 |
| `PluginRunnerRouter.swift` | `PluginRunnerRouter` | 按 execution transport 运行并路由取消 |
| `ProcessPluginRunner.swift` | `ProcessPluginRunner`, `PluginRunner` | stdin JSON、环境变量、并发 stdout/stderr、进程取消 |
| `ConfigurableProcessPluginRunner`（App） | runtime wrapper | 运行中更新 Python/Node 路径 |
| `PluginOutput.swift` | events/parser/validator | 严格 NDJSON、progress 和 terminal result |
| `PluginArtifact.swift` | inline/file artifact | 工件公开 wire shape |
| `PluginExecutionWorkspace.swift` | workspace model | temp/output 目录与清理策略 |
| `PluginExecutionCoordinator.swift`、`PluginExecutionCoordinatorRun.swift` | `PluginExecutionCoordinator` | transport 无关的身份、连接、凭据、终端、提交与投影 |
| `PluginResultHandling.swift` | handler/registry/projection | schema 驱动的 typed/generic result |
| `ConfinedArtifactReader.swift`, `ConfinedArtifactCopy.swift` | confined I/O | 路径、symlink、size、SHA-256 和安全复制 |
| `HTTPPluginEndpoint.swift` | endpoint preparation | 数字 loopback URL、配置和 token 引用边界 |
| `HTTPPluginClient.swift` | client operations | health/capabilities/jobs/snapshot/SSE/result/cancel |
| `HTTPPluginRunner.swift` | HTTP runner | submit、SSE reconnect、poll fallback、terminal fetch |
| `HTTPPluginTransport.swift` | URLSession transport | 请求、stream、取消和 protocol header |
| `HTTPPluginWire.swift` | strict wire decoder | content type、error envelope、未知字段和脱敏 |
| `HTTPPluginModels.swift` | health/capabilities/job models | v1 wire data |
| `HTTPPluginEvent.swift` | event validation | event ID、taskID、schema 和 result 一致性 |
| `ServerSentEventParser.swift` | SSE parser | chunk、CRLF/LF、multi-data、heartbeat 和 cursor |
| `HTTPPluginCancellation.swift` | cancellation registry | task 到 transport request 的取消映射 |
| `HTTPPluginConnectionProbe.swift` | connection checking | 设置界面的 health/capability/token 状态 |
| `PluginConnectionStatus.swift` | status models | ready/degraded/unavailable 与问题代码 |
| `HTTPPluginResponseValidator.swift` | response boundary | status/header/content-type 基础验证 |

公开机制见 [`plugin-api.md`](plugin-api.md)，设计和调用链见 [`plugin-system.md`](plugin-system.md)。

### Artifacts 与 Results

| 文件/组 | 关键类型 | 职责 |
| --- | --- | --- |
| `Results/ArtifactRecord.swift` | `ArtifactRecord`, states | 持久工件元数据与 reconciliation 状态 |
| `Artifacts/ArtifactMetadataBackend.swift` | backend protocol/in-memory | task-artifact 关系、commit/cleanup 记录 |
| `Artifacts/GRDBArtifactMetadataBackend.swift` | GRDB backend | 工件、媒体文档和 tag ledger 的事务写入 |
| `Artifacts/ArtifactStore.swift` | `ArtifactStore` | 持久根身份验证、stage/publish/link/commit/read/rollback |
| `Artifacts/ArtifactCommitCoordinator.swift` | commit coordinator | 文件和 DB 副作用顺序、回滚与清理记录 |
| `Artifacts/ArtifactResultService.swift` | result service | query/open/export、media document 改写和恢复 |
| `Results/MediaAnalysisDocument.swift` | schema document | `mediaAnalysis.v1` 解码、验证和 asset path 替换 |
| `Results/MediaAnalysisPresentationService.swift` | presentation projection | 文档到 UI workspace/asset 投影 |
| `Results/MediaAnalysisTagLedgerService.swift` | managed tag ledger | analyzer 建议与 Finder tag 对账 |

`ArtifactStore.root` 必须是稳定、非符号链接的目录；已 committed 的工件不依赖执行 workspace。

### Persistence

| 文件/组 | 关键类型 | 职责 |
| --- | --- | --- |
| `AppDatabase.swift` | `AppDatabase` | 打开 SQLite、版本检查、按顺序应用 migration |
| `AppDatabaseSchema.swift` | schema v1-v3 SQL | tasks、artifacts、media documents、tag ledger、lineage FK |
| `ConfigStore.swift` | `AppConfiguration`, `JSONConfigStore` | 默认设置、兼容解码、0600 原子保存 |
| `PersistenceRootHandle.swift` | root handle | 绑定持久根 inode/device，抵抗路径替换 |
| `PersistenceMaintenance.swift`、`PersistenceMaintenanceModels.swift`、`PersistenceMaintenanceRecords.swift`、`PersistenceMaintenanceReconciliation.swift` | maintenance/report/snapshots | 启动 reconciliation、retention 和 orphan 清理 |

表关系：

| 表 | 主用途 |
| --- | --- |
| `app_schema_metadata` | 当前 schema version |
| `task_descriptors` | durable handler、redacted payload、谱系、资源/idempotency key |
| `task_records` | 运行状态、进度、结果、effects commit |
| `task_logs` | 有序任务日志 |
| `artifact_records` | 工件状态、路径、哈希、retention/reconciliation |
| `task_artifacts` | task 与 artifact 顺序关系 |
| `media_analysis_documents` | validated `mediaAnalysis.v1` payload |
| `media_managed_tags` | analyzer 管理的 Finder tag ledger |

### Security 与 Utilities

| 文件 | 关键类型 | 职责 |
| --- | --- | --- |
| `Security/KeychainStore.swift` | `KeychainStore`, `MacKeychainStore` | 通用 secret 存取与系统 Keychain 实现 |
| `Security/PluginCredentialResolver.swift` | reference/storage/resolver | Keychain/local-config 引用生成和运行时解析 |
| `Security/BookmarkStore.swift` | bookmark records | security-scoped bookmark 持久 seam |
| `Utilities/Coding.swift` | encoder/decoder extensions | 统一日期与 JSON 设置 |
| `Utilities/FileSizeFormatter.swift` | formatter | 文件大小文本 |

## OpenFinderApp

### App

| 文件 | 职责 |
| --- | --- |
| `App/OpenFinderApp.swift` | `@main`、AppDelegate、主窗口/设置窗口、组合根实例 |
| `App/Commands.swift` | macOS menu commands 到 `AppModel` intent |

### Models

Models 目录分成三层：

| 组 | 文件 | 职责 |
| --- | --- | --- |
| UI façade | `AppModel.swift`、`AppModelSupport.swift`、`AppModelTasks.swift`、`AppModelTransfers.swift`、`AppModelPluginSupport.swift`、`AppModelPluginExecution.swift`、`AppModelRemoteAccounts.swift` | `@Published` UI 状态与用户 intent；不拥有持久引擎 |
| 组合/应用服务 | `ApplicationServices.swift`、`ApplicationServicesOperations.swift`、`ApplicationServicesCompatibility.swift`、`ApplicationServicesPluginOperations.swift`、`ApplicationServicesPluginSubmission.swift`、`ApplicationServicesAccountBrowserOperations.swift`、`ApplicationServicesBrowser.swift`、`ApplicationServicesPresentation.swift`、`ApplicationServicesTaskComposition.swift` | 创建服务图并为 AppModel 提供浏览、任务、插件、账号、呈现操作 |
| 领域应用服务 | `TaskApplicationService.swift`、`FileBrowserService.swift`、`FileTransferService.swift`、`FileTransferServiceDownload.swift`、`PluginManagementService.swift`、`RemoteAccountService.swift`、`RuntimeConfigurationService.swift` | 把 UI intent 转成 Core 调用和稳定 projection |
| Pane | `BrowserPaneModel.swift`、`BrowserPaneListing.swift`、`BrowserPaneNavigation.swift`、`BrowserPaneFileActions.swift`、`BrowserPaneRemote.swift`、`BrowserPaneTags.swift`、`BrowserPaneTagSupport.swift` | 单侧位置、历史、listing、选择、文件动作和标签编辑 |
| 存储/桥接 | `RemoteAccountDirectory.swift`、`PluginResultProjectionBox.swift` | 账号 JSON 目录与异步 task-result projection 暂存 |

`AppModel` 可以做状态协调和 presentation intent，但不能解码插件 schema、直接访问 SQLite 或持有 provider-specific HTTP 逻辑。

### Support

| 文件/组 | 职责 |
| --- | --- |
| `AppDurableHandlerComposition.swift` | 验证 task handlers、result handlers、renderers 与依赖集合完全匹配 |
| `PluginWorkspace.swift` | process/HTTP workspace 创建、preserve/cleanup 策略 |
| `ConfigurableProcessPluginRunner.swift` | 在 actor 中热更新 Python/Node 可执行路径 |
| `PluginRendererCatalog.swift` | schema + typed predicate 到 renderer descriptor |
| `PluginConnectionDiagnosticsState.swift` | 设置 UI 的连接状态派生 |
| `GenericArtifactPresentation.swift` | unknown schema 的通用投影 |
| `AppInteractionSupport.swift` | Quick Look、drop、冲突等 UI 支持模型 |
| `PlatformServices.swift` | Terminal/Quick Look 等系统进程桥 |
| `FileIconDescriptor.swift`、`FileTagPresentation.swift` | AppKit/SwiftUI 可共享的呈现 descriptor |
| `TagEditorContext.swift` | 多选三态、scope catalog、pending mutation 状态机 |

### Views

| 组 | 文件 | 职责 |
| --- | --- | --- |
| Shell | `ContentView.swift`、`SettingsView.swift`、`SettingsComponents.swift` | 双栏 + task queue 主壳与设置导航 |
| 文件列表 | `FilePaneView.swift`、`FileTableRepresentable.swift`、`FileTagCellView.swift` | SwiftUI pane、`NSTableView` bridge、选择/菜单/拖放/tag cell |
| 标签 | `TagEditorView.swift` | scoped tag assignment 与 catalog 管理 |
| 任务 | `TaskQueueView.swift` | 状态、阶段、进度、日志、取消/重试 |
| 插件设置 | `PluginSettingsView.swift`、`PluginSettingsSupport.swift`、`PluginConfigurationView.swift`、`PluginConnectionDiagnosticsView.swift` | 扫描诊断、typed config、secret 和 HTTP 连通性 |
| 账号 | `ConnectionsSettingsView.swift`、`GeneralSettingsView.swift` | WebDAV/Kodbox 账号与运行设置 |
| 插件结果 | `PluginResultView.swift`、`MediaAnalysisResultView.swift`、`MediaAnalysisWorkspaceView.swift`、`MediaAnalysisMomentViews.swift` | renderer 分派、媒体工作区、关键帧和 Finder tag 动作 |

`FileTableRepresentable` 是 AppKit 交互事实源；不要在外围 SwiftUI 再实现一套独立选择或上下文菜单状态。

## 运行时 Registry

| Registry | Key | Value/行为 | 默认注册 |
| --- | --- | --- | --- |
| `RemoteConnectorRegistry` | `RemoteConnectorID` | 连接器 metadata + provider factory | WebDAV、Kodbox |
| `RemoteProviderRegistry` | account ID + revision | actor provider cache | 按账号延迟创建 |
| `FileSourceRegistry` | `FileSourceID` | local/remote adapter + materialization | local + remote registry |
| `TaskHandlerRegistry` | handler ID + payload version | durable executor | `plugin.execute.v1`@1、`transfer.copy.v1`@1、`transfer.move.v1`@1 |
| `PluginRunnerRouter` | execution transport | process/HTTP runner + cancellation route | process、HTTP |
| `PluginResultHandlerRegistry` | result schema ID | typed/generic projection | mediaAnalysis.v1 + generic fallback |
| `PluginRendererCatalog` | result schema ID | renderer + typed predicate | mediaAnalysis.v1 + generic fallback |

## 测试分区

| 测试组 | 关注点 |
| --- | --- |
| `*ContractTests` | 公开模型、能力、descriptor、wire 不变量 |
| `*IntegrationTests` | registry/provider/queue/DB/result 的跨模块路径 |
| `*RecoveryTests`、`Persistence*Tests` | 崩溃窗口、roll-forward、retention、root race |
| `HTTPPlugin*Tests` | endpoint、wire、SSE、取消、真实 URLSession、成功/失败 E2E |
| `App*Tests` | 组合根、facade、持久化、workspace 生命周期 |
| `*VisualTests`、`*VisualHarnessTests` | renderer 和状态视图的可观察行为 |
| `Fixtures/` | location 兼容 JSON、测试专用媒体插件；不得打包为内置插件 |

## 构建与打包

`script/build_and_run.sh`：

1. `swift build`；
2. 重建 `dist/OpenFinder.app`；
3. 复制可执行文件、icon 和 `ExamplePlugins` 到 `BuiltinPlugins`；
4. 对 Video Analyzer manifest 做打包时契约断言；
5. 拒绝测试 fixture plugin ID、虚拟环境和已移除的 process bridge；
6. 使用指定开发证书或 ad-hoc 签名；
7. 根据 mode 运行、验证、调试或跟踪日志。

脚本会重建 `dist/OpenFinder.app`，因此不要在 app bundle 内手工维护文件。
