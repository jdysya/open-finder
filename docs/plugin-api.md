# OpenFinder Plugin API

OpenFinder plugins are local directories ending in `.plugin` with a `manifest.json` and an executable entry file.

```text
my-action.plugin/
  manifest.json
  run.sh | run.py | run.js
  README.md
```

## Manifest

Key fields implemented in `OpenFinderCore`:

- `schemaVersion`: currently `1`.
- `id`, `name`, `version`, `description`, `author`.
- `runtime`: `{ "type": "shell" }`, `{ "type": "python3", "minimumVersion": "3.9" }`, or `{ "type": "node" }`.
- `entry`: executable path relative to the plugin directory.
- `actions`: context-menu actions with selection rules, extension/UTType/MIME matching, and output hints.
- `permissions`: UX/audit declaration. V0 script plugins run with the user's permissions; real isolation is a later XPC/sandbox milestone.
- `configuration`: typed config field metadata for future settings UI.

## Runtime protocol

OpenFinder sends a single JSON object to plugin stdin:

- `schemaVersion`, `taskID`, `actionID`.
- `context.activePane` and `context.currentLocation`.
- `files[]` with path, name, extension, UTI, MIME, size, and directory flag.
- `config` and `secrets` references. Secrets are represented as environment variable names, not plaintext values.
- `tempDirectory` and `outputDirectory`.

Plugins write newline-delimited JSON events to stdout:

```json
{"type":"log","level":"info","message":"Starting"}
{"type":"progress","fraction":0.5,"message":"Halfway"}
{"type":"result","status":"success","message":"Done","clipboard":"Text to copy"}
```

stderr is stored as debug log text. Exit code `0` means success; non-zero means failure even if stdout contains events. Stdout/stderr are read while the process is running so progress events can update the task queue and large-output plugins do not block on full pipes.

## Included examples

- `copy-markdown-image.plugin`: converts selected images to local Markdown image links.
- `zip-selected.plugin`: writes a zip archive to the task output directory.
- `upload-image-demo.plugin`: emits deterministic demo upload URLs without network calls.
- `batch-rename-demo.plugin`: dry-run rename preview copied to clipboard.


## Runtime paths

The settings surface exposes Python and Node runtime paths. When configured, OpenFinder passes those paths into `ProcessPluginRunner`; otherwise it falls back to `/usr/bin/env python3` and `/usr/bin/env node`. Shell plugins use `/bin/zsh` by default.
