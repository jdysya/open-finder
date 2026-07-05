下面这份方案按“一个人可以逐步做出来，每一阶段都有可用成果”的标准设计。结论先说清楚：**推荐 Swift 原生主路线：SwiftUI 负责窗口、布局、设置、任务面板；AppKit 负责高性能文件列表、右键菜单、键盘焦点、拖拽、Quick Look 等桌面细节；插件、任务队列、远程存储都先做成 App 内部能力，不碰 Finder Sync、File Provider、macFUSE 挂载。**

---

## 0. 核心架构判断

你的产品不是 Finder 复制品，而是一个 **developer-oriented extensible file manager**。它的核心差异应该是：

**文件浏览是入口，插件动作是核心生产力，任务队列是可见执行层，远程存储是统一文件源，自动化是长期壁垒。**

所以第一版不要追求“像 Finder 一样完整”，而要追求：

1. 本地双栏浏览稳定；
2. 右键插件动作跑得通；
3. 插件任务队列可观察、可取消、可重试；
4. WebDAV 作为第一个远程文件源跑通；
5. 所有能力都抽象成 LocalProvider / RemoteProvider / PluginAction / Task。

Apple 的 App Sandbox 文档说明 sandbox 会通过 entitlements 限制 app 对系统资源和用户数据的访问，并且 Mac App Store 分发必须启用 App Sandbox；App Review Guidelines 又对 Mac App Store app 的 sandbox、自包含、不得下载/安装额外代码、不得执行会改变功能的代码有明确限制。因此，**这个项目的完整形态更适合先走 Developer ID + notarization 分发；Mac App Store 版本可以后期做成“无任意脚本插件的 Lite 版”**。([Apple Developer][1])

---

# 1. 产品定位

产品可以定位为：

> 一个面向开发者、内容创作者和重度文件管理用户的 extensible file manager，用统一 UI 管理本地文件、远程存储和自定义动作，并把所有耗时动作放入可追踪任务队列。

它不应该主打“替代 Finder”，而应该主打：

* 双栏 / 多栏高效率文件操作；
* 对开发者友好的自定义右键动作；
* 用 manifest + script 快速扩展能力；
* 文件处理任务有队列、有日志、有进度；
* WebDAV / SFTP / S3 / rclone 统一进同一套文件浏览体验；
* 后期支持批处理、自动化 pipeline、AI 文件处理。

一个更清晰的产品描述可以是：

> Finder for workflows, not Finder replacement.

---

# 2. 目标用户

第一目标用户：

* 开发者：经常处理项目目录、截图、日志、构建产物、脚本、远程服务器文件；
* Markdown / blog / 文档用户：需要图床上传、复制图片链接、批量整理附件；
* 设计 / 视频 / 图片用户：需要图片压缩、OCR、视频转码、批量重命名；
* NAS / WebDAV / S3 用户：想在一个 UI 中管理本地与远程文件；
* CLI heavy users：愿意写 shell / Python / Node 插件。

暂时不要服务：

* 完全不懂脚本、不懂权限、不需要插件的普通 Finder 用户；
* 想要系统级挂载、云盘同步盘、Finder 深度集成的用户；
* 需要团队权限管理、企业级审计、协作共享的用户。

---

# 3. 核心使用场景

第一批高价值场景：

1. **双栏复制 / 移动文件**
   左边项目目录，右边目标目录或远程 WebDAV 目录，快速复制、移动、重命名。

2. **截图上传图床**
   选中图片 → 右键 → Upload to Image Host → 任务队列执行 → 成功后复制 Markdown 链接。

3. **批量文件处理**
   选中多张图片 → 右键 → Compress Images / OCR / Batch Rename → 显示任务进度和日志。

4. **远程目录浏览**
   添加 WebDAV 账号 → 像浏览目录一样进入远程路径 → 上传 / 下载 / 新建文件夹。

5. **开发者目录动作**
   在当前目录打开 Terminal、VS Code、外部 editor；对日志文件执行解析脚本；对构建产物执行上传。

6. **任务可追踪**
   所有插件、上传、复制、转码任务都进入同一个任务队列，有 stdout / stderr / exit code / 错误信息 / 最近历史。

---

# 4. 技术选型比较

## 4.1 推荐结论

**推荐：Swift 原生 App，采用 SwiftUI + AppKit 混合架构。**

原因很现实：

* 文件管理器是典型 macOS desktop app，强依赖菜单、右键、键盘焦点、拖拽、路径、Quick Look、Keychain、sandbox、Security-Scoped Bookmarks；
* 插件执行需要和 macOS 进程、权限、文件访问打交道；
* 远程存储、任务队列、日志、通知都可以用 Swift 原生实现；
* 作品集角度，SwiftUI + AppKit + 文件系统 + 插件系统 + 远程存储，含金量比套 Electron UI 更高。

## 4.2 对比表

| 方案                   | 优点                                                                                                       | 缺点                                                                                                       | 适合程度               |
| -------------------- | -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------ |
| **SwiftUI + AppKit** | 原生体验最好；容易接 AppKit 菜单、右键、拖拽、Quick Look、Keychain、Security-Scoped Bookmarks；性能和系统集成最好                       | 学习曲线高；SwiftUI 对复杂 desktop 控件不够完整；需要写 AppKit bridge                                                       | **最推荐**            |
| 纯 SwiftUI            | 开发快；布局、Settings、任务面板好写；状态管理简单                                                                            | 高性能文件列表、右键菜单验证、键盘焦点、拖拽、多选表格细节会痛苦                                                                         | 适合 UI 外壳，不适合完整文件列表 |
| 纯 AppKit             | 控制力最强；NSTableView / NSOutlineView 成熟                                                                     | 写 UI 较繁琐；现代状态管理和声明式布局成本高                                                                                 | 可行，但一个人做会慢         |
| Tauri                | 前端技术栈自由；官方定位是小型、快速、安全、跨平台；架构是 Rust backend + WebView frontend，不自带 Chromium runtime，体积优势明显 ([Tauri][2])   | macOS 文件管理细节仍要写 native bridge；Swift/AppKit/Keychain/security-scoped bookmark 都要桥接；Rust + Swift + JS 三栈复杂 | 如果要跨平台可考虑，不适合作为第一版 |
| Electron             | JS/Node 生态强；插件、child_process、Web UI 很方便；官方说明 Electron 通过嵌入 Chromium 和 Node.js 来构建跨平台桌面应用 ([Electron][3]) | 体积和内存压力大；原生体验弱；macOS sandbox/App Store/权限更麻烦；文件管理器会显得“不够 Mac”                                            | 不推荐做这个产品的第一技术栈     |

Electron 的 main process / renderer process 模型适合 web app 包壳，但对你的产品来说，许多关键功能最终都要回到 native 层；Electron 官方文档也说明 main process 管窗口和 native API，renderer process 负责 web 内容，二者通过 preload / IPC 协作。([Electron][4])

---

# 5. 哪些部分用 SwiftUI，哪些部分用 AppKit

## SwiftUI 适合

* 主窗口布局外壳；
* 双栏容器；
* 工具栏；
* 路径栏；
* 设置页；
* 插件配置表单；
* 任务队列面板；
* 日志详情面板；
* 远程账号管理；
* 空状态、错误状态、权限提示；
* SwiftUI Commands / keyboard shortcuts 的高层声明。

## AppKit 适合

* 文件列表核心控件：`NSTableView` 或 `NSOutlineView`；
* 多选、range selection、焦点控制；
* 右键菜单动态生成与 validation；
* 拖拽文件进出 app；
* 与 Finder / Terminal / 外部编辑器交互；
* Quick Look preview panel；
* path control 如果你想做成 native `NSPathControl`；
* responder chain、菜单启用状态、复杂快捷键；
* 高性能大目录滚动。

推荐实现方式：

```text
SwiftUI root
 ├─ ToolbarView
 ├─ DualPaneView
 │   ├─ FilePaneView
 │   │   └─ AppKitFileTableViewRepresentable -> NSTableView
 │   └─ FilePaneView
 │       └─ AppKitFileTableViewRepresentable -> NSTableView
 ├─ TaskQueueSidebar / BottomPanel
 └─ Inspector / PreviewPanel bridge
```

不要把整个 App 写成一个巨大的 `ContentView`。从一开始就分模块。

---

# 6. 是否需要 sandbox，是否适合上架 App Store

## 6.1 我的建议

做两个发行口径：

### A. Developer ID 版：主版本

适合你的完整产品：

* 任意脚本插件；
* 用户自定义 Python / Node / shell runtime；
* rclone 集成；
* 外部编辑器；
* Terminal；
* 高级自动化；
* 未来可能的本地 helper。

这个版本可以使用 Hardened Runtime + notarization。Apple 有 notarizing macOS software 的官方分发流程文档；对于不走 Mac App Store 的专业工具，这是更现实的路径。([Apple Developer][5])

### B. Mac App Store Lite 版：后期考虑

限制：

* sandbox 必须开；
* 插件系统不能做“下载脚本后改变 App 功能”的开放模型；
* 不能要求 root；
* 不能安装共享位置资源；
* 更新必须通过 Mac App Store；
* arbitrary executable plugin 会触碰审核风险。([Apple Developer][6])

可以做成：

* 只有内置动作；
* 或用户自己编写、源码可见、仅用于教育 / 自动化的受限脚本；
* 或改成 Shortcuts / Automator / App Intents 集成；
* 或只允许 manifest 描述“调用外部 app / URL scheme / shortcut”，不下载执行新代码。

## 6.2 开发阶段怎么选

第一阶段建议：

```text
Debug / Personal Build:
  sandbox = off
  hardened runtime = later
  plugin = enabled

Release / Developer ID:
  sandbox = optional initially
  hardened runtime = on
  notarization = on
  plugin = enabled

Mac App Store Lite:
  sandbox = on
  arbitrary plugin = disabled or severely restricted
```

---

# 7. 文件访问权限设计

## 7.1 非 sandbox 版本

非 sandbox 版可以直接访问用户权限范围内的文件系统。但仍建议做“授权根目录”概念：

* 用户添加 `~/Projects`、`~/Downloads`、某个外接盘；
* App 记录这些 roots；
* 插件默认只能接收选中文件，不默认扫描全盘；
* 危险动作需要确认。

这样后续迁移到 sandbox 更容易。

## 7.2 sandbox 版本

sandbox 版必须走用户选择文件夹授权：

1. 用户通过 `NSOpenPanel` 选择目录；
2. App 对目录 URL 创建 security-scoped bookmark；
3. bookmark data 存到数据库；
4. 每次访问前 resolve bookmark；
5. 调用 `startAccessingSecurityScopedResource()`；
6. 操作结束后 `stopAccessingSecurityScopedResource()`；
7. bookmark stale 时提示用户重新授权。

Apple 的 App Sandbox 文档把 user-selected read/write entitlement、文件访问和 security protection 放在 file access 主题下；URL 也有 `bookmarkData` 和 `startAccessingSecurityScopedResource()` 等 API 页面。([Apple Developer][1])

建议数据结构：

```swift
struct BookmarkRecord: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var originalPath: String
    var bookmarkData: Data
    var permission: Permission // readOnly / readWrite
    var createdAt: Date
    var lastResolvedAt: Date?
}
```

---

# 8. MVP 功能清单

## MVP 1：本地双栏文件管理

必须做：

* 主窗口；
* 双栏布局；
* 每栏路径栏；
* 目录浏览；
* 返回 / 前进；
* 上级目录；
* 刷新；
* 文件排序；
* 文件过滤；
* 显示隐藏文件；
* 多选；
* 右键菜单；
* 新建文件夹；
* 新建空文件；
* 重命名；
* 移到废纸篓；
* 复制 / 移动到另一栏；
* Open With；
* Reveal in Finder；
* Open in Terminal；
* Space 预览；
* 基础快捷键。

## MVP 2：插件动作 + 任务队列

必须做：

* 插件目录扫描；
* manifest 解析；
* 根据文件扩展名 / UTType / 多选规则过滤动作；
* 右键菜单展示插件动作；
* 执行 shell 插件；
* stdin 输入 JSON；
* stdout 输出 JSON；
* stderr 作为日志；
* 任务状态：queued / running / succeeded / failed / cancelled；
* 取消、重试；
* 成功后复制结果到剪贴板；
* 最近任务历史。

## MVP 3：WebDAV

必须做：

* 添加 WebDAV 账号；
* Keychain 保存密码 / token；
* 浏览远程目录；
* 新建目录；
* 上传本地文件；
* 下载远程文件；
* 删除；
* 重命名 / move；
* 任务队列展示上传下载进度。

---

# 9. 第一版不建议做的功能

这些很诱人，但会显著拖慢你：

* Finder Sync Extension；
* File Provider Extension；
* macFUSE 挂载；
* rclone mount；
* 插件市场；
* 插件签名系统；
* 多用户账号系统；
* 云端同步配置；
* 完整 S3 multipart 上传；
* 完整 SFTP 权限和 symlink 语义；
* Git 状态栏；
* Spotlight 级搜索；
* 文件内容索引；
* AI agent 自动整理文件；
* 工作流 DAG；
* 自研终端模拟器；
* 自定义虚拟文件系统；
* App Store 上架。

File Provider 和 macFUSE 更适合后期：File Provider 是系统级文件提供者方向，适合把远程文件暴露给系统；rclone mount 则会进入 FUSE / macFUSE 复杂区。rclone 官方文档说明 `rclone mount` 在 macOS 上通过 FUSE 把云存储挂成文件系统，并且 macOS 有 macFUSE 相关注意事项。([Apple Developer][7])

---

# 10. 推荐技术架构

整体分层：

```text
UI Layer
  SwiftUI shell + AppKit file table bridge
  Toolbar / PathBar / ContextMenu / TaskPanel / Settings

Application Layer
  PaneController
  FileCommandRouter
  PluginActionService
  TaskQueueService
  RemoteAccountService

Domain Layer
  FileItem
  Location
  FileProvider protocol
  PluginManifest
  TaskRecord
  RemoteProvider protocol

Infrastructure Layer
  LocalFileProvider
  WebDAVProvider
  RcloneProvider later
  PluginRunner
  ProcessExecutor
  KeychainStore
  BookmarkStore
  SQLiteStore / JSONStore
  NotificationService
  ClipboardService
```

核心抽象：

```swift
protocol FileProvider {
    func list(_ location: Location) async throws -> [FileItem]
    func stat(_ location: Location) async throws -> FileItem
    func createFolder(at location: Location, name: String) async throws
    func createFile(at location: Location, name: String) async throws
    func rename(_ item: FileItem, to newName: String) async throws
    func trashOrDelete(_ items: [FileItem]) async throws
    func copy(_ items: [FileItem], to destination: Location) async throws -> TaskID
    func move(_ items: [FileItem], to destination: Location) async throws -> TaskID
}

protocol RemoteProvider {
    func list(path: String) async throws -> [RemoteItem]
    func mkdir(path: String) async throws
    func delete(path: String) async throws
    func move(from: String, to: String) async throws
    func upload(localURL: URL, remotePath: String) async throws -> TaskID
    func download(remotePath: String, localURL: URL) async throws -> TaskID
}
```

建议把本地和远程都统一成 `Location`：

```swift
enum Location: Codable, Hashable {
    case local(rootBookmarkID: UUID?, path: String)
    case webDAV(accountID: UUID, path: String)
    case rclone(remoteID: UUID, path: String)
}
```

这样 UI 不关心当前栏是本地还是远程。

---

# 11. UI 架构

## 11.1 主窗口

主窗口建议：

```text
┌─────────────────────────────────────────────────────────┐
│ Toolbar: back / forward / refresh / new / tasks / search │
├─────────────────────────────────────────────────────────┤
│ PathBar Left                         PathBar Right       │
├──────────────────────────────┬──────────────────────────┤
│ FilePane A                   │ FilePane B               │
│ NSTableView                  │ NSTableView              │
│ name / ext / size / date     │ name / ext / size / date │
├──────────────────────────────┴──────────────────────────┤
│ Task Queue Panel: running / logs / errors / history      │
└─────────────────────────────────────────────────────────┘
```

## 11.2 每个 FilePane 的状态

```swift
@Observable
final class PaneState {
    var id: UUID
    var location: Location
    var items: [FileItem]
    var selection: Set<FileItem.ID>
    var sort: FileSort
    var filterText: String
    var showHiddenFiles: Bool
    var history: [Location]
    var historyIndex: Int
    var isLoading: Bool
    var error: FileBrowserError?
}
```

## 11.3 快捷键建议

| 快捷键                         | 行为           |
| --------------------------- | ------------ |
| Enter                       | 打开文件 / 进入目录  |
| Cmd + ↑                     | 上级目录         |
| Cmd + [ / ]                 | 后退 / 前进      |
| Cmd + R                     | 刷新           |
| Space                       | Quick Look   |
| F2 或 Enter on selected name | 重命名          |
| Delete                      | 移到废纸篓        |
| Cmd + C                     | 复制文件引用       |
| Cmd + V                     | 粘贴 / 复制到当前目录 |
| Cmd + Option + V            | 移动到当前目录      |
| Cmd + F                     | 过滤           |
| Cmd + Shift + .             | 显示 / 隐藏隐藏文件  |
| Cmd + N                     | 新建文件         |
| Cmd + Shift + N             | 新建文件夹        |

## 11.4 文件预览

本地文件：

* Space 调用 Quick Look；
* 文件列表中缩略图可以后期用 QuickLookThumbnailing；
* 文本文件右侧 inspector 可以做轻量预览。

远程文件：

* 小文件下载到 cache 后预览；
* 大文件显示 metadata，不自动下载；
* 预览 cache 放在 `Application Support/Caches/RemotePreview`。

---

# 12. 数据模型

## 12.1 FileItem

```swift
struct FileItem: Identifiable, Codable, Hashable {
    let id: String              // providerID + normalized path
    let name: String
    let location: Location
    let kind: FileKind          // file / directory / symlink / package / unknown
    let size: Int64?
    let modificationDate: Date?
    let creationDate: Date?
    let uti: String?
    let mimeType: String?
    let fileExtension: String?
    let isHidden: Bool
    let isReadable: Bool
    let isWritable: Bool
}
```

## 12.2 PluginManifest

```swift
struct PluginManifest: Codable, Identifiable {
    let id: String
    let name: String
    let version: String
    let description: String?
    let runtime: PluginRuntime
    let entry: String
    let actions: [PluginActionManifest]
    let permissions: PluginPermissions
    let configSchema: [PluginConfigField]
}
```

## 12.3 TaskRecord

```swift
struct TaskRecord: Codable, Identifiable {
    let id: UUID
    let kind: TaskKind          // plugin / copy / move / upload / download / webdav / rclone
    var title: String
    var status: TaskStatus
    var progress: Double?      // 0...1, nil means indeterminate
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var inputSummary: String
    var resultSummary: String?
    var errorMessage: String?
    var logFilePath: String?
    var retryCount: Int
}
```

## 12.4 RemoteAccount

```swift
struct RemoteAccount: Codable, Identifiable {
    let id: UUID
    var name: String
    var provider: RemoteProviderKind // webDAV / sftp / s3 / rclone
    var baseURL: URL?
    var username: String?
    var secretKeychainRef: String?
    var options: [String: String]
}
```

---

# 13. 本地文件操作模块设计

## 13.1 LocalFileProvider

职责：

* list directory；
* read metadata；
* create folder/file；
* rename；
* move to Trash；
* copy / move；
* resolve aliases / symlinks；
* monitor directory changes；
* generate preview metadata。

实现建议：

```swift
actor LocalFileProvider: FileProvider {
    private let bookmarkStore: BookmarkStore
    private let taskQueue: TaskQueueService

    func list(_ location: Location) async throws -> [FileItem] {
        // 1. resolve security-scoped bookmark if needed
        // 2. FileManager.contentsOfDirectory
        // 3. fetch resourceValues
        // 4. map to FileItem
        // 5. sort/filter at PaneController or here depending on design
    }
}
```

## 13.2 删除策略

默认行为应该是 **Move to Trash**，不是永久删除。永久删除可以做成高级菜单：

```text
Right click:
  Move to Trash
  Delete Permanently...  // with confirmation
```

## 13.3 Copy / Move 策略

同 volume：

* move 可以用 `FileManager.moveItem`；
* rename 是 move 的特殊形式。

跨 volume / 大文件：

* 放入 TaskQueue；
* 先计算总大小和文件数；
* 递归复制；
* 逐文件更新进度；
* 出错时记录失败路径；
* 支持取消。

## 13.4 目录刷新

第一版可以手动刷新。后面加：

* active pane 目录监听；
* 文件变化后 debounce reload；
* 大目录不要每个事件都全量刷新。

Apple 有 File System Events 相关文档；第一版可以先不做实时监听，避免过早复杂化。([Apple Developer][8])

---

# 14. 插件系统设计

## 14.1 插件包结构

建议插件就是一个目录：

```text
image-upload.plugin/
  manifest.json
  upload.py
  README.md
  icon.png
```

用户插件目录：

```text
~/Library/Application Support/ExtFM/Plugins/
```

内置示例插件目录：

```text
ExtFM.app/Contents/Resources/BuiltinPlugins/
```

## 14.2 插件运行协议

输入：App 通过 stdin 传 JSON。

输出：插件通过 stdout 输出 JSON event。建议用 **NDJSON**，也就是每一行一个 JSON：

```json
{"type":"log","level":"info","message":"Uploading file..."}
{"type":"progress","fraction":0.4,"message":"Uploaded 40%"}
{"type":"result","status":"success","clipboard":"![image](https://example.com/a.png)","message":"Uploaded"}
```

stderr：原样作为 debug log，不作为结构化结果。

exit code：

* `0`：成功；
* 非 0：失败；
* App 仍尝试解析 stdout 中的错误 JSON。

## 14.3 为什么用 NDJSON

因为任务队列需要实时进度。单个最终 JSON 不够表达：

* progress；
* log；
* warning；
* partial result；
* final result。

但对简单插件，允许只输出一个最终 JSON。

## 14.4 插件 runtime

第一版建议只支持：

* `shell`;
* `python3`;
* `node`.

但要注意：不要假设用户机器一定有你想要的 Python / Node。更稳的设计是：

```text
Settings > Runtimes
  shell: /bin/zsh
  python3: user configured path
  node: user configured path
```

第一版最简单：

* 内置 shell 插件；
* Python / Node 需要用户在设置里指定 runtime path；
* 如果找不到 runtime，插件菜单置灰并显示原因。

## 14.5 插件权限模型

manifest 里声明：

* `readFiles`;
* `writeFiles`;
* `network`;
* `clipboardRead`;
* `clipboardWrite`;
* `keychainSecrets`;
* `remoteAccounts`;
* `runExternalCommands`.

但要非常清楚：**manifest 权限在第一版主要是 UX 层和审计层，不等于真正 sandbox。** 如果你运行任意 shell / Python / Node 脚本，脚本本身理论上可以做很多事，尤其在非 sandbox 版里。真正权限隔离需要后期用 sandboxed XPC helper、不同 entitlements 的 runner、临时目录、受限环境变量和 security-scoped URL 传递。Apple 的 App Sandbox 机制本质是基于 entitlements 限制资源访问，不是动态按插件 manifest 改权限。([Apple Developer][1])

第一版可执行策略：

* 插件只通过 stdin 得到选中文件；
* 默认不传全量环境变量；
* 不把 token 写进 input JSON；
* secret 通过临时 env var 注入；
* App 负责剪贴板写入，插件只返回 `clipboard` 字段；
* App 负责保存文件变更记录；
* 每次首次运行高权限插件时弹确认；
* 插件目录清晰展示“用户安装的脚本会以你的用户权限运行”。

后期增强策略：

```text
PluginRunnerNoNetwork.xpc
  sandbox = on
  network entitlement = off

PluginRunnerNetwork.xpc
  sandbox = on
  network entitlement = on

Main App
  负责授权、选择文件、解析 bookmark、传递最小输入
```

---

# 15. 插件 manifest 示例

```json
{
  "schemaVersion": 1,
  "id": "dev.extfm.plugins.image-upload.generic",
  "name": "Upload Image to Generic Host",
  "version": "0.1.0",
  "description": "Upload selected images and copy Markdown links.",
  "author": "Example",
  "runtime": {
    "type": "python3",
    "minimumVersion": "3.9"
  },
  "entry": "upload.py",
  "actions": [
    {
      "id": "upload-image",
      "title": "Upload Image",
      "category": "Upload",
      "selection": {
        "minItems": 1,
        "maxItems": 20,
        "allowDirectories": false
      },
      "match": {
        "extensions": ["png", "jpg", "jpeg", "gif", "webp"],
        "uttypes": ["public.image"],
        "mimePrefixes": ["image/"],
        "matchMode": "all"
      },
      "output": {
        "resultType": "markdownLinks",
        "canCopyToClipboard": true
      }
    }
  ],
  "permissions": {
    "readFiles": "selected",
    "writeFiles": "none",
    "network": {
      "required": true,
      "hosts": ["api.example-image-host.com"]
    },
    "clipboardWrite": true,
    "clipboardRead": false,
    "keychainSecrets": ["apiToken"]
  },
  "configuration": [
    {
      "key": "endpoint",
      "type": "string",
      "title": "Upload Endpoint",
      "default": "https://api.example-image-host.com/upload",
      "required": true
    },
    {
      "key": "apiToken",
      "type": "password",
      "title": "API Token",
      "required": true,
      "storage": "keychain"
    },
    {
      "key": "markdownFormat",
      "type": "select",
      "title": "Markdown Format",
      "default": "image",
      "options": [
        { "label": "![alt](url)", "value": "image" },
        { "label": "[filename](url)", "value": "link" }
      ]
    }
  ]
}
```

---

# 16. 插件输入 JSON 示例

```json
{
  "schemaVersion": 1,
  "taskID": "9B785A9D-2DF9-49AB-A7B4-4C0D8C8DF7EF",
  "actionID": "upload-image",
  "app": {
    "name": "ExtFM",
    "version": "0.1.0"
  },
  "context": {
    "activePane": "left",
    "currentLocation": {
      "type": "local",
      "path": "/Users/me/Pictures"
    }
  },
  "files": [
    {
      "path": "/Users/me/Pictures/demo.png",
      "name": "demo.png",
      "extension": "png",
      "uti": "public.png",
      "mimeType": "image/png",
      "size": 183920,
      "isDirectory": false
    }
  ],
  "config": {
    "endpoint": "https://api.example-image-host.com/upload",
    "markdownFormat": "image"
  },
  "secrets": {
    "apiToken": {
      "env": "EXTFM_SECRET_API_TOKEN"
    }
  },
  "tempDirectory": "/var/folders/.../ExtFMTasks/9B785A9D",
  "outputDirectory": "/var/folders/.../ExtFMTasks/9B785A9D/output"
}
```

---

# 17. 图床上传插件示例

`upload.py`：

```python
#!/usr/bin/env python3
import json
import os
import sys
import uuid
import mimetypes
import urllib.request
import urllib.error

def emit(event):
    print(json.dumps(event, ensure_ascii=False), flush=True)

def multipart_body(fields, files):
    boundary = "----ExtFMBoundary" + uuid.uuid4().hex
    chunks = []

    for name, value in fields.items():
        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
        )
        chunks.append(str(value).encode())
        chunks.append(b"\r\n")

    for field_name, file_path in files:
        filename = os.path.basename(file_path)
        mime = mimetypes.guess_type(file_path)[0] or "application/octet-stream"

        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(
            f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'.encode()
        )
        chunks.append(f"Content-Type: {mime}\r\n\r\n".encode())

        with open(file_path, "rb") as f:
            chunks.append(f.read())

        chunks.append(b"\r\n")

    chunks.append(f"--{boundary}--\r\n".encode())
    return boundary, b"".join(chunks)

def upload_one(endpoint, token, file_path):
    boundary, body = multipart_body(
        fields={},
        files=[("file", file_path)]
    )

    req = urllib.request.Request(endpoint, data=body, method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read().decode("utf-8")
        data = json.loads(raw)
        # 假设服务返回 {"url": "..."}
        return data["url"]

def main():
    input_data = json.load(sys.stdin)

    endpoint = input_data["config"]["endpoint"]
    token = os.environ.get("EXTFM_SECRET_API_TOKEN")
    markdown_format = input_data["config"].get("markdownFormat", "image")
    files = input_data["files"]

    if not token:
        emit({
            "type": "result",
            "status": "failure",
            "message": "Missing API token"
        })
        return 2

    links = []

    for index, item in enumerate(files):
        path = item["path"]
        emit({
            "type": "progress",
            "fraction": index / max(len(files), 1),
            "message": f"Uploading {item['name']}"
        })

        url = upload_one(endpoint, token, path)

        if markdown_format == "link":
            links.append(f"[{item['name']}]({url})")
        else:
            alt = os.path.splitext(item["name"])[0]
            links.append(f"![{alt}]({url})")

    result = "\n".join(links)

    emit({
        "type": "progress",
        "fraction": 1.0,
        "message": "Upload complete"
    })

    emit({
        "type": "result",
        "status": "success",
        "message": f"Uploaded {len(files)} file(s)",
        "clipboard": result,
        "artifacts": [
            {
                "type": "markdown",
                "content": result
            }
        ]
    })

    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.HTTPError as e:
        emit({
            "type": "result",
            "status": "failure",
            "message": f"HTTP error: {e.code} {e.reason}"
        })
        raise SystemExit(1)
    except Exception as e:
        emit({
            "type": "result",
            "status": "failure",
            "message": str(e)
        })
        raise SystemExit(1)
```

这个插件遵循几个原则：

* token 不出现在 input JSON；
* token 从环境变量读；
* stdout 输出 JSON event；
* App 负责把 `clipboard` 写入剪贴板；
* App 记录 stdout / stderr / exit code。

---

# 18. 任务队列设计

## 18.1 任务类型

任务队列不只服务插件，也服务所有耗时操作：

```swift
enum TaskKind: Codable {
    case plugin(pluginID: String, actionID: String)
    case localCopy
    case localMove
    case localDelete
    case webDAVUpload
    case webDAVDownload
    case rcloneOperation
}
```

## 18.2 状态机

```text
queued
  ↓
running
  ├─ succeeded
  ├─ failed
  └─ cancelling → cancelled
```

支持：

* cancel；
* retry；
* reveal output；
* copy result；
* open log；
* notification on completion；
* 保存最近历史。

## 18.3 TaskQueueService

```swift
actor TaskQueueService {
    private var queue: [TaskID] = []
    private var running: [TaskID: RunningTask] = [:]
    private let maxConcurrentTasks: Int = 2

    func enqueue(_ request: TaskRequest) async throws -> TaskID
    func cancel(_ id: TaskID) async
    func retry(_ id: TaskID) async throws -> TaskID
    func appendLog(_ id: TaskID, _ line: TaskLogLine) async
    func updateProgress(_ id: TaskID, _ progress: Double?) async
}
```

## 18.4 PluginRunner

```swift
struct PluginRunRequest {
    let manifest: PluginManifest
    let action: PluginActionManifest
    let input: PluginInput
    let environment: [String: String]
    let workingDirectory: URL
}

protocol PluginRunner {
    func run(_ request: PluginRunRequest) async throws -> PluginRunResult
    func cancel(taskID: UUID) async
}
```

`Process` 执行策略：

* `standardInput` 写入 JSON；
* `standardOutput` 逐行读取 JSON event；
* `standardError` 逐行写日志；
* `terminationStatus` 映射成功失败；
* cancel 时先 `terminate()`，超时后 kill；
* 每个 task 创建独立 temp dir；
* 环境变量白名单，不继承全部 shell env。

---

# 19. WebDAV 集成方案

## 19.1 为什么 WebDAV 适合第一阶段

WebDAV 是 HTTP 扩展，适合用 `URLSession` 实现；它有标准目录/文件操作语义：`PROPFIND` 列目录和属性，`MKCOL` 新建 collection，`COPY` 复制，`MOVE` 移动/重命名，`DELETE` 删除，复杂操作可能返回 `207 Multi-Status`。这些行为在 RFC 4918 中有明确描述。([RFC 编辑器][9])

## 19.2 WebDAVProvider 接口

```swift
actor WebDAVProvider: RemoteProvider {
    let account: RemoteAccount
    let credentialStore: KeychainStore
    let session: URLSession

    func list(path: String) async throws -> [RemoteItem]
    func mkdir(path: String) async throws
    func delete(path: String) async throws
    func move(from: String, to: String) async throws
    func copy(from: String, to: String) async throws
    func upload(localURL: URL, remotePath: String) async throws -> TaskID
    func download(remotePath: String, localURL: URL) async throws -> TaskID
}
```

## 19.3 目录 listing

请求：

```http
PROPFIND /remote/path/ HTTP/1.1
Depth: 1
Content-Type: application/xml; charset=utf-8
```

body：

```xml
<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
    <D:getetag/>
    <D:getcontenttype/>
    <D:displayname/>
  </D:prop>
</D:propfind>
```

解析：

* `resourcetype` contains `collection` → directory；
* `getcontentlength` → size；
* `getlastmodified` → modification date；
* `getcontenttype` → MIME；
* `href` → remote path；
* 注意第一个 response 通常是当前目录本身，要过滤掉。

## 19.4 WebDAV 风险

必须提前设计容错：

* 不同 WebDAV server 的 XML namespace 细节不同；
* 有的 server 对 `Depth: infinity` 限制严格；
* `MOVE` / `COPY` 可能返回多状态错误；
* 路径 URL encoding 容易出 bug；
* 大文件上传需要进度、取消、重试；
* HTTPS 证书错误不要默认忽略；
* token / password 必须放 Keychain；
* remote preview 应该下载到临时 cache，不要直接当本地文件。

---

# 20. rclone 集成方案

## 20.1 定位

rclone 不要第一阶段做成 mount。先把它作为一个 **RemoteProvider backend**：

```text
App UI
  -> RcloneProvider
     -> ProcessExecutor
        -> rclone lsjson / copyto / moveto / deletefile / mkdir
```

rclone 官方说明它是管理 cloud storage 的 command-line program，支持 S3、WebDAV、SFTP 等大量存储，也有 `lsjson` 这类机器可读命令；`rclone lsjson` 输出 JSON 数组，包含 Name、Path、Size、MimeType、ModTime、IsDir 等字段，适合作为远程目录 listing 的数据源。([Rclone][10])

## 20.2 第一阶段命令映射

| App 操作           | rclone 命令                                    |
| ---------------- | -------------------------------------------- |
| list directory   | `rclone lsjson remote:path --max-depth 1`    |
| mkdir            | `rclone mkdir remote:path/newdir`            |
| upload           | `rclone copyto /local/file remote:path/file` |
| download         | `rclone copyto remote:path/file /local/file` |
| move             | `rclone moveto remote:old remote:new`        |
| delete file      | `rclone deletefile remote:path/file`         |
| delete directory | `rclone purge remote:path/dir`               |

## 20.3 进度与日志

rclone 全局 flags 支持 logging、progress、stats 和 JSON log；可以用 `--use-json-log` 让日志更容易解析，用 `--stats` 控制输出频率。([Rclone][11])

建议：

```text
rclone copyto ... --use-json-log --stats 1s --log-level INFO
```

App 读取 stdout/stderr：

* JSON log → task log；
* stats → progress；
* exit code → task result。

## 20.4 rclone config 管理

不要一开始接管用户全局 `~/.config/rclone/rclone.conf`。建议：

```text
~/Library/Application Support/ExtFM/rclone/rclone.conf
```

更安全的做法：

* RemoteAccount 中只保存非敏感配置；
* secret 放 Keychain；
* 执行前生成临时 rclone config；
* task 结束后删除临时 config；
* 文件权限设成 owner read/write。

后期如果用户希望复用已有 rclone config，再支持导入。

## 20.5 什么时候考虑 rclone mount

后期再做。`rclone mount` 可以在 macOS 上通过 FUSE 挂载云存储，但这会引入 macFUSE 安装、系统权限、卸载、崩溃恢复、后台进程管理等问题。([Rclone][12])

---

# 21. 配置与密钥管理方案

## 21.1 文件位置

```text
~/Library/Application Support/ExtFM/
  config.json
  database.sqlite
  Plugins/
  Logs/
  TaskLogs/
  Runtimes/
  rclone/
  Caches/
```

## 21.2 Keychain

用 Keychain 保存：

* WebDAV password；
* WebDAV token；
* SFTP password；
* SFTP private key passphrase；
* S3 access key secret；
* 图床 token；
* 插件 secret config。

Apple 有 Keychain Services 官方文档页面；在 macOS app 中，secret 不要放普通 JSON / SQLite 明文字段。([Apple Developer][13])

Keychain key 命名：

```text
service: dev.extfm
account: remote.webdav.<accountUUID>.password
account: plugin.<pluginID>.<configKey>
```

## 21.3 普通配置

普通配置可以 JSON：

```json
{
  "defaultShowHiddenFiles": false,
  "confirmBeforePermanentDelete": true,
  "maxConcurrentTasks": 2,
  "python3Path": "/opt/homebrew/bin/python3",
  "nodePath": "/opt/homebrew/bin/node"
}
```

## 21.4 数据库

建议第一版用 SQLite，而不是一堆 JSON 文件。保存：

* task history；
* plugin grants；
* remote accounts；
* bookmarks；
* recent locations；
* pane restore state；
* operation history。

你可以直接用 SQLite C API，也可以用轻量 Swift wrapper。一个人开发时，先封装 `PersistenceStore`，后面换底层不影响业务层。

---

# 22. 项目目录结构

推荐一开始就这么拆：

```text
ExtFM/
  ExtFM.xcodeproj
  ExtFMApp/
    App/
      ExtFMApp.swift
      AppDelegate.swift
      Commands.swift
    Features/
      FileBrowser/
        Views/
          DualPaneView.swift
          FilePaneView.swift
          PathBarView.swift
          FileTableRepresentable.swift
        Controllers/
          PaneController.swift
          FileCommandRouter.swift
        Models/
          FileItem.swift
          Location.swift
          FileSort.swift
      Plugins/
        Views/
          PluginSettingsView.swift
          PluginConfigFormView.swift
        Models/
          PluginManifest.swift
          PluginActionManifest.swift
          PluginPermission.swift
          PluginInput.swift
          PluginOutputEvent.swift
        Services/
          PluginRegistry.swift
          PluginMatcher.swift
          PluginRunner.swift
      Tasks/
        Views/
          TaskQueueView.swift
          TaskLogView.swift
        Models/
          TaskRecord.swift
          TaskStatus.swift
          TaskLogLine.swift
        Services/
          TaskQueueService.swift
      Remote/
        Views/
          RemoteAccountListView.swift
          WebDAVAccountFormView.swift
        Models/
          RemoteAccount.swift
          RemoteItem.swift
        Providers/
          WebDAVProvider.swift
          RcloneProvider.swift
      Settings/
        SettingsView.swift
    Core/
      FileSystem/
        LocalFileProvider.swift
        FileOperationPlanner.swift
        DirectoryWatcher.swift
      Security/
        BookmarkStore.swift
        KeychainStore.swift
        PermissionPrompter.swift
      Process/
        ProcessExecutor.swift
        ProcessOutputParser.swift
      Persistence/
        Database.swift
        Migrations.swift
      Platform/
        ClipboardService.swift
        NotificationService.swift
        QuickLookBridge.swift
        TerminalService.swift
      Utilities/
        Logger.swift
        URLNormalizer.swift
        MimeTypeResolver.swift
  PluginRunnerXPC/
    PluginRunnerNoNetwork/
    PluginRunnerNetwork/
  ExamplePlugins/
    image-upload.plugin/
      manifest.json
      upload.py
  Tests/
    ExtFMCoreTests/
    PluginSystemTests/
    WebDAVProviderTests/
  scripts/
    build.sh
    format.sh
  docs/
    plugin-api.md
    webdav-notes.md
```

XPC helper 可以后期再建，第一版先保留目录或 TODO。

---

# 23. 分阶段开发路线

## Phase 0：工程骨架

产出：

* Xcode macOS app；
* SwiftUI 主窗口；
* AppKit `NSTableView` bridge 空表格；
* basic logging；
* basic settings；
* SQLite / JSON persistence 二选一；
* `FileItem`、`Location`、`TaskRecord` 基础模型。

验收：

* App 能启动；
* 双栏空 UI 正常；
* 能保存窗口状态和基础设置。

## Phase 1：本地只读浏览

产出：

* 目录 listing；
* 路径栏；
* 返回 / 前进 / 上级；
* 排序；
* 过滤；
* 显示隐藏文件；
* 双击进入目录；
* Space 预览本地文件。

验收：

* 可以当一个只读双栏浏览器使用。

## Phase 2：本地文件操作

产出：

* 新建文件夹；
* 新建文件；
* rename；
* move to Trash；
* copy / move 到另一栏；
* conflict dialog；
* refresh；
* 快捷键。

验收：

* 可以日常管理项目目录。

## Phase 3：任务队列

产出：

* TaskQueueService；
* task panel；
* running / success / failure / cancel；
* task logs；
* local copy/move 大文件进入任务队列；
* 通知；
* 历史记录。

验收：

* 复制大目录时 UI 不阻塞，日志和进度可见。

## Phase 4：插件系统 V0

产出：

* manifest 扫描；
* 插件设置页；
* action matcher；
* 右键菜单动态展示；
* shell plugin runner；
* stdin JSON；
* stdout NDJSON event；
* stderr log；
* image upload 示例插件；
* 成功后复制 clipboard。

验收：

* 选中图片，右键上传图床，任务成功后 Markdown 链接进入剪贴板。

## Phase 5：WebDAV

产出：

* WebDAV account form；
* Keychain secret；
* remote directory browsing；
* upload / download；
* mkdir / delete / rename；
* remote task queue；
* remote preview cache。

验收：

* 一栏本地、一栏 WebDAV，可以上传下载文件。

## Phase 6：权限与安全增强

产出：

* plugin grant UI；
* per-plugin secret；
* environment whitelist；
* dangerous action confirmation；
* plugin log redaction；
* optional sandbox build；
* bookmark roots；
* XPC runner prototype。

验收：

* 可以清楚看到插件要什么权限，secret 不进日志。

## Phase 7：rclone Provider

产出：

* rclone binary detection；
* rclone config form；
* `lsjson` browsing；
* copyto / moveto / deletefile；
* JSON log progress；
* optional imported rclone config。

验收：

* 通过 rclone 浏览 S3 / SFTP / OneDrive 等 remote，不做 mount。

## Phase 8：产品化

产出：

* crash handling；
* onboarding；
* plugin API docs；
* example plugins；
* notarization；
* auto update；
* signing；
* release notes；
* privacy explanation。

---

# 24. 技术风险与规避方案

## 风险 1：插件权限看起来安全，但实际不能完全隔离

规避：

* 第一版明确提示“脚本以用户权限运行”；
* 不自动安装远程插件；
* 插件源码可见；
* secret 只用 env 注入；
* App 代写剪贴板；
* 后期用 sandboxed XPC helper。

## 风险 2：Mac App Store 审核不适合开放脚本插件

规避：

* 主版本走 Developer ID notarized；
* App Store Lite 禁用任意脚本；
* 插件市场不要作为第一商业目标；
* 产品介绍避免宣称替代 Finder 或修改系统桌面环境。App Review Guidelines 明确说 app 不应创建替代 desktop/home screen environment，也不能与 Apple 产品 / Finder 造成混淆。([Apple Developer][6])

## 风险 3：SwiftUI 文件列表性能不够

规避：

* 文件列表从第一天就用 AppKit `NSTableView`；
* SwiftUI 只做容器和状态；
* 大目录分页 / lazy metadata；
* 缩略图异步加载。

## 风险 4：文件操作出错会造成数据损坏

规避：

* 默认 Move to Trash；
* copy 后校验 size；
* move 跨 volume 先 copy 成功再 delete；
* conflict dialog；
* 操作日志；
* 永久删除必须二次确认。

## 风险 5：WebDAV server 差异大

规避：

* 先支持标准 Basic Auth + HTTPS；
* 测试 Nextcloud / nginx WebDAV / Synology / 坚果云一类服务；
* XML parser 容忍 namespace；
* 所有 remote 操作进入任务队列；
* `207 Multi-Status` 必须完整解析。

## 风险 6：rclone 进程管理复杂

规避：

* 先用短生命周期命令；
* 不启动长期 `rcd`；
* 不做 mount；
* 每个任务一个 process；
* 解析 JSON log；
* 失败时展示完整命令摘要但隐藏 secret。

## 风险 7：Security-Scoped Bookmarks 学习成本

规避：

* 非 sandbox dev build 先完成主功能；
* 抽象 `BookmarkStore`；
* 后期打开 sandbox 时替换 local root 访问逻辑；
* 所有文件访问都走 `LocalFileProvider`，不要在 UI 里直接读文件。

---

# 25. 一个人开发的最小可行路径

你可以按这个顺序做，不要跳：

## 第一步：只做一个本地双栏浏览器

不要插件，不要 WebDAV。

目标：

* 左右两栏能浏览目录；
* 能排序、过滤、进入目录、返回、刷新；
* 能打开文件和 Quick Look。

这一步完成后，你已经有作品集可展示的 macOS desktop foundation。

## 第二步：加入文件操作

目标：

* 新建文件夹；
* rename；
* move to Trash；
* copy / move 到另一栏；
* conflict dialog。

这一步完成后，它已经是可用的轻量文件管理器。

## 第三步：加入任务队列

目标：

* copy 大文件进入队列；
* 显示 running / success / failure；
* 有日志；
* 能取消。

这一步是后面插件、上传、WebDAV 的基础。

## 第四步：做插件系统最小闭环

只支持 shell 或 Python 其中一个 runtime。

目标：

* 扫描 `Plugins` 目录；
* 解析 manifest；
* 根据扩展名过滤右键动作；
* 执行插件；
* stdout JSON result；
* 复制结果到剪贴板。

第一批内置插件：

```text
Open in Terminal
Copy Markdown Image Link
Zip Selected Files
Upload Image Demo
Batch Rename Demo
```

## 第五步：做 WebDAV

目标：

* 添加账号；
* Keychain 存 secret；
* 浏览；
* 上传；
* 下载；
* 删除；
* 重命名。

这一步完成后，产品定位就成立了：**本地文件 + 插件动作 + 远程存储 + 任务队列**。

## 第六步：再做安全增强和 rclone

不要一开始就做 rclone、XPC、sandbox、App Store。先让产品跑起来，再把风险点逐个补上。

---

# 26. 最终推荐版本边界

第一版可以叫：

```text
ExtFM 0.1
- Local dual-pane file manager
- Custom context actions
- Plugin manifest + script runner
- Task queue
- Image upload example plugin
- WebDAV remote browser
```

第一版不要叫：

```text
Finder replacement
Cloud sync client
Universal remote filesystem
Plugin marketplace
AI file agent
```

你的作品集亮点应该写成：

> Built a native macOS extensible file manager with SwiftUI/AppKit, custom plugin runtime, structured task queue, local file operations, WebDAV remote provider, Keychain secret storage, and a manifest-based action system.

这比“做了一个 Finder clone”强很多。

[1]: https://developer.apple.com/tutorials/data/documentation/security/app-sandbox.json "developer.apple.com"
[2]: https://tauri.app/ "Tauri 2.0 | Tauri"
[3]: https://www.electronjs.org/docs/latest/ "Introduction | Electron"
[4]: https://www.electronjs.org/docs/latest/tutorial/process-model "Process Model | Electron"
[5]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution "Notarizing macOS software before distribution | Apple Developer Documentation"
[6]: https://developer.apple.com/app-store/review/guidelines/ "App Review Guidelines - Apple Developer"
[7]: https://developer.apple.com/documentation/FileProvider "File Provider | Apple Developer Documentation"
[8]: https://developer.apple.com/documentation/coreservices/file_system_events "File System Events | Apple Developer Documentation"
[9]: https://www.rfc-editor.org/rfc/rfc4918 "RFC 4918: HTTP Extensions for Web Distributed Authoring and Versioning (WebDAV) | RFC Editor"
[10]: https://rclone.org/ "Rclone"
[11]: https://rclone.org/flags/ "Global Flags"
[12]: https://rclone.org/commands/rclone_mount/ "rclone mount"
[13]: https://developer.apple.com/documentation/security/keychain_services "Keychain services | Apple Developer Documentation"
