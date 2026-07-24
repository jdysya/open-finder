# OpenFinder

OpenFinder is a native macOS SwiftUI/AppKit prototype for the product described in `docs/plan.md`: a developer-oriented extensible file manager with local dual-pane browsing, plugin actions, a task queue, and a WebDAV provider foundation.

## Implemented scope

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

## Build and test

```bash
swift test
swift build
```

## Run the app

```bash
./script/build_and_run.sh
```

The script builds a SwiftPM GUI executable, stages `dist/OpenFinder.app`, copies `ExamplePlugins` into app resources as built-in plugins, and launches the app as a foreground macOS bundle.

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

## Plugin development

See `docs/architecture.md` for the code-level architecture/design guide and `docs/plugin-api.md` for plugin development. Put user plugins under:

```text
~/Library/Application Support/OpenFinder/Plugins/
```

The app also scans the repo-local `ExamplePlugins/` during development and bundled `Contents/Resources/BuiltinPlugins/` when launched through the run script.

Architecture references:

- [`docs/architecture.md`](docs/architecture.md)
- [`docs/task-recovery.md`](docs/task-recovery.md)
- [`docs/renderer-catalog.md`](docs/renderer-catalog.md)

## Roadmap alignment

This repository implements the Phase 0–5 foundation from `docs/plan.md`, including the 0.1 boundary of local dual-pane browsing, custom context actions, plugin manifest + script runner, task queue, image-upload example plugin, and WebDAV remote browser. Later production hardening should add byte-level transfer progress, richer conflict dialogs, sandbox/security-scoped bookmark flows, XPC plugin runners, rclone provider support, signing/notarization, and onboarding.
