# OpenFinder

OpenFinder 是一个原生 macOS SwiftUI/AppKit 双栏文件工作区：它用统一能力模型浏览本地、WebDAV 和 Kodbox 文件源，通过持久任务队列执行传输与插件动作，并以 schema 驱动的工件系统呈现插件结果。

完整文档从 [`docs/README.md`](docs/README.md) 开始；[`docs/plan.md`](docs/plan.md) 是历史产品计划，不代表当前实现边界。

## 已实现范围

- SwiftPM macOS app (`OpenFinder`) and testable core library (`OpenFinderCore`).
- SwiftUI main window, commands, settings, dual-pane layout, task queue panel.
- AppKit `NSTableView` bridge for file listing, multi-selection, double-click navigation, desktop context menus, and a resizable Tags column with a scoped multi-item tag editor.
- Local file provider: list/stat, hidden filtering, sorting, create file/folder, rename, trash/delete fallback, copy, move, and Finder-compatible tag-name read/write through Apple's public file-resource APIs.
- Plugin system: manifest decoding, action matching by selection/extension/UTType/MIME, right-click plugin actions, streaming NDJSON output events, shell/python/node process runner, example plugins.
- Task queue: queued/running/succeeded/failed/cancelled state, live progress/log polling, cancel/retry/log actions, history, clipboard result support.
- WebDAV remote browser: settings account form, Keychain-backed password storage, active-pane navigation, remote list/mkdir/delete/rename, upload/download/copy/move through the task queue, HTTPS credential guard, no silent overwrite, and multistatus failure validation.
- Kodbox browser and tags: personal and team-public tag display, personal catalog management, permission-gated team tag management, and scoped file/folder association. See [`docs/kodbox-tag-support.md`](docs/kodbox-tag-support.md) for the API and safety boundaries. Generic WebDAV remains intentionally tag-unsupported.
- Security/persistence seams: bookmark records, in-memory and macOS Keychain stores, JSON config store.
- Durable GRDB task and artifact persistence with roll-forward recovery and safe startup failure.
- Schema-driven plugin results: `mediaAnalysis.v1` uses one shared renderer across plugin IDs;
  unknown schemas use generic artifact presentation.

## 构建与测试

```bash
swift test
swift build
```

## 运行应用

```bash
./script/build_and_run.sh
```

脚本会构建 SwiftPM GUI executable，组装并签名 `dist/OpenFinder.app`，把 `ExamplePlugins` 复制为内置插件，然后启动 app bundle。

常用模式：

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

## 插件开发

先阅读 [插件机制](docs/plugin-system.md)，字段参考见 [插件 API](docs/plugin-api.md)，HTTP 服务实现必须遵循 [HTTP 插件协议 v1](docs/plugins/http-plugin-v1.md)。用户插件目录：

```text
~/Library/Application Support/OpenFinder/Plugins/
```

开发时还会扫描仓库内 `ExamplePlugins/`；通过运行脚本生成的 app 会扫描 bundle 内 `Contents/Resources/BuiltinPlugins/`。

## 文档导航

- [`docs/README.md`](docs/README.md)：文档中心、旧内容处理决策、维护触发矩阵
- [`docs/architecture.md`](docs/architecture.md)
- [`docs/module-reference.md`](docs/module-reference.md)
- [`docs/plugin-system.md`](docs/plugin-system.md)
- [`docs/plugin-api.md`](docs/plugin-api.md)
- [`docs/development.md`](docs/development.md)
- [`docs/task-recovery.md`](docs/task-recovery.md)
- [`docs/renderer-catalog.md`](docs/renderer-catalog.md)

## 路线图边界

当前实现覆盖本地双栏浏览、上下文动作、process/HTTP 插件、持久任务、工件与结构化结果、WebDAV/Kodbox 远端浏览和标签能力。逐字节传输进度、XPC/sandbox 插件隔离、rclone、正式签名/公证与 onboarding 等仍是后续方向，不能从历史计划推断为已实现。

## 许可证

OpenFinder 采用 [MIT License](LICENSE) 开源。
