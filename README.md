# OpenFinder

OpenFinder is a native macOS SwiftUI/AppKit prototype for the product described in `docs/plan.md`: a developer-oriented extensible file manager with local dual-pane browsing, plugin actions, a task queue, and a WebDAV provider foundation.

## Implemented scope

- SwiftPM macOS app (`OpenFinder`) and testable core library (`OpenFinderCore`).
- SwiftUI main window, commands, settings, dual-pane layout, task queue panel.
- AppKit `NSTableView` bridge for file listing, multi-selection, double-click navigation, and desktop context menus.
- Local file provider: list/stat, hidden filtering, sorting, create file/folder, rename, trash/delete fallback, copy, move.
- Plugin system: manifest decoding, action matching by selection/extension/UTType/MIME, right-click plugin actions, streaming NDJSON output events, shell/python/node process runner, example plugins.
- Task queue: queued/running/succeeded/failed/cancelled state, live progress/log polling, cancel/retry/log actions, history, clipboard result support.
- WebDAV remote browser: settings account form, Keychain-backed password storage, active-pane navigation, remote list/mkdir/delete/rename, upload/download/copy/move through the task queue, HTTPS credential guard, no silent overwrite, and multistatus failure validation.
- Security/persistence seams: bookmark records, in-memory and macOS Keychain stores, JSON config store.

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

See `docs/plugin-api.md`. Put user plugins under:

```text
~/Library/Application Support/OpenFinder/Plugins/
```

The app also scans the repo-local `ExamplePlugins/` during development and bundled `Contents/Resources/BuiltinPlugins/` when launched through the run script.

## Roadmap alignment

This repository implements the Phase 0–5 foundation from `docs/plan.md`, including the 0.1 boundary of local dual-pane browsing, custom context actions, plugin manifest + script runner, task queue, image-upload example plugin, and WebDAV remote browser. Later production hardening should add byte-level transfer progress, richer conflict dialogs, durable SQLite persistence, sandbox/security-scoped bookmark flows, XPC plugin runners, rclone provider support, signing/notarization, and onboarding.
