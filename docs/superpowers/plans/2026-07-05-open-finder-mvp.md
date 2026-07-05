# OpenFinder MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build the first working Swift-native OpenFinder implementation described by `docs/plan.md`: dual-pane local file manager foundation, plugin actions with task queue, WebDAV provider, persistence/security seams, example plugins, tests, and a reproducible macOS SwiftPM app run loop.

**Architecture:** SwiftPM package with `OpenFinderCore` library for testable domain/services and `OpenFinder` SwiftUI executable for the macOS UI shell. SwiftUI owns the window, toolbar, settings, and task panel; a narrow AppKit `NSTableView` bridge owns desktop-grade file tables. Providers, plugins, and tasks are abstractions in core so UI is not coupled to local files or WebDAV.

**Tech Stack:** Swift 6 / macOS 14, SwiftUI, AppKit, Foundation `FileManager`, `Process`, `URLSession`, XMLParser, XCTest.

---

## Task 1: Package and failing core tests

**Files:**
- Create: `Package.swift`
- Create: `Tests/OpenFinderCoreTests/LocalFileProviderTests.swift`
- Create: `Tests/OpenFinderCoreTests/PluginSystemTests.swift`
- Create: `Tests/OpenFinderCoreTests/TaskQueueTests.swift`
- Create: `Tests/OpenFinderCoreTests/WebDAVProviderTests.swift`

- [x] Write tests for local listing/filtering/sorting and file operations.
- [x] Write tests for plugin manifest decoding, action matching, NDJSON parsing, and shell runner result events.
- [x] Write tests for task queue lifecycle, retry, cancellation, and history.
- [x] Write tests for WebDAV PROPFIND parsing and request methods through a mock `URLProtocol`.
- [x] Run `swift test` and confirm tests fail because production types do not exist.

## Task 2: Core domain and local provider

**Files:**
- Create/modify: `Sources/OpenFinderCore/Domain/*.swift`
- Create: `Sources/OpenFinderCore/FileSystem/LocalFileProvider.swift`
- Create: `Sources/OpenFinderCore/FileSystem/FileBrowserSupport.swift`

- [x] Implement `Location`, `FileItem`, `FileProvider`, `FileSort`, `PaneState`, and file operation support.
- [x] Implement local directory listing with hidden filtering, stable sorting, metadata, create file/folder, rename, trash/delete fallback, copy, move.
- [x] Run targeted local provider tests.

## Task 3: Task queue and plugin runtime

**Files:**
- Create: `Sources/OpenFinderCore/Tasks/*.swift`
- Create: `Sources/OpenFinderCore/Plugins/*.swift`
- Create: `ExamplePlugins/*`

- [x] Implement task records/statuses, in-memory queue, cancellation, retry, logs, history snapshots.
- [x] Implement manifest models, plugin registry scanning, matcher rules, plugin input/output models, NDJSON parser.
- [x] Implement `ProcessPluginRunner` for shell/python/node with stdin JSON, stdout event parsing, stderr logs, restricted environment, termination status mapping.
- [x] Add example plugin manifests/scripts for markdown image links, zip selected files, and upload demo.
- [x] Run targeted plugin and task tests.

## Task 4: WebDAV and security/persistence seams

**Files:**
- Create: `Sources/OpenFinderCore/Remote/*.swift`
- Create: `Sources/OpenFinderCore/Security/*.swift`
- Create: `Sources/OpenFinderCore/Persistence/*.swift`

- [x] Implement `RemoteAccount`, `RemoteItem`, `RemoteProvider`, `WebDAVProvider` with PROPFIND/MKCOL/DELETE/MOVE/COPY/upload/download.
- [x] Implement XML multistatus parser tolerant of namespaces and current-directory filtering.
- [x] Add `KeychainStore` protocol plus in-memory and macOS Keychain-backed implementations.
- [x] Add bookmark/config/persistence seams used by the app.
- [x] Run targeted WebDAV/security tests.

## Task 5: macOS app UI shell and AppKit table bridge

**Files:**
- Create: `Sources/OpenFinderApp/App/OpenFinderApp.swift`
- Create: `Sources/OpenFinderApp/Views/*.swift`
- Create: `Sources/OpenFinderApp/Support/*.swift`
- Create: `Sources/OpenFinderApp/App/Commands.swift`

- [x] Implement SwiftUI `WindowGroup` app, activation policy, commands, settings scene.
- [x] Implement `AppModel`, dual-pane layout, path bars, toolbar, task queue panel, plugin/settings surfaces.
- [x] Implement `NSViewRepresentable` AppKit file table with multi-selection, double-click directory navigation, context menu actions.
- [x] Wire file commands: refresh, back/forward/up, show hidden, filter, create file/folder, rename, trash, copy/move to other pane, reveal in Finder, open in Terminal, Quick Look stub/bridge.
- [x] Run `swift build`.

## Task 6: Run loop, docs, and final verification

**Files:**
- Create: `script/build_and_run.sh`
- Create: `.codex/environments/environment.toml`
- Create: `docs/plugin-api.md`
- Create: `docs/webdav-notes.md`
- Create/update: `README.md`

- [x] Add SwiftPM GUI app bundle run script and Codex Run action.
- [x] Document plugin API, WebDAV behavior, scope boundaries, and build/run commands.
- [x] Run `swift test` and `swift build`.
- [x] Run `./script/build_and_run.sh --verify` where the local macOS session permits foreground app launch.
