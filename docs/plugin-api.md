# OpenFinder Plugin API

OpenFinder plugins are local package directories ending in `.openfinderplugin` (preferred) or the legacy `.plugin` suffix. Process plugins contain a `manifest.json` and an entry file; HTTP plugins contain a manifest that describes their loopback service connection.

```text
my-action.openfinderplugin/
  manifest.json
  run.sh | run.py | run.js
  README.md
```

The app scans built-in, user, and development locations independently. A malformed package is reported in Settings without hiding valid sibling plugins. Duplicate IDs resolve in this order: built-in, user, then development; ignored duplicates are reported as diagnostics. Package symlinks and process entries that escape the package are rejected.

## Manifests

Key fields implemented in `OpenFinderCore`:

- `schemaVersion`: `1` for process plugins and `2` for local HTTP plugins.
- `id`, `name`, `version`, `description`, `author`.
- `runtime`: `{ "type": "shell" }`, `{ "type": "python3", "minimumVersion": "3.9" }`, or `{ "type": "node" }`.
- `entry`: executable path relative to the plugin directory.
- `actions`: context-menu actions with selection rules, extension/UTType/MIME matching, and output hints.
- `permissions`: UX/audit declaration. V0 script plugins run with the user's permissions; real isolation is a later XPC/sandbox milestone.
- `configuration`: typed fields shown in plugin settings.

Schema 2 uses an `execution` object instead of top-level `runtime` and `entry`. The currently supported HTTP transport is protocol version 1. See [`plugins/http-plugin-v1.md`](plugins/http-plugin-v1.md) and the machine-readable [`plugins/http-plugin-v1.openapi.json`](plugins/http-plugin-v1.openapi.json).

### Result schemas

An action's `output.resultType` is the schema identifier used for result handling and rendering.
The current structured media contract is `mediaAnalysis.v1`. A successful producer returns exactly
one artifact whose `type` is also `mediaAnalysis.v1`; the artifact contains a UTF-8 JSON
`MediaAnalysisDocument` with `schemaID: "mediaAnalysis.v1"` and `schemaVersion: 1`.

Result routing is schema-driven, not plugin-ID-driven. The bundled Video Analyzer and the test-only
Spectrum Inspector fixture use different plugin IDs but the same result handler and Renderer Catalog
entry. A new image, audio, or video analyzer can therefore use the media renderer without adding a
plugin-specific Swift view or registration. Unknown result schemas remain available through the
generic artifact presentation and are never decoded as media analysis.

## Runtime protocol

OpenFinder sends a single JSON object to plugin stdin:

- `schemaVersion`, `taskID`, `actionID`.
- `context.activePane` and `context.currentLocation`.
- `files[]` with path, name, extension, UTI, MIME, size, and directory flag.
- `config` and `secrets` references. Secrets are represented as generated environment variable names, not plaintext values. For process plugins, OpenFinder keeps only credential references in the queue, resolves configured Keychain/local credentials when execution starts, injects their values into the child environment, and sends only the generated names in stdin.
- `tempDirectory` and `outputDirectory`.
  - For local panes, `outputDirectory` is the current directory so generated artifacts land beside the selected files.
  - For non-local panes, `outputDirectory` falls back to a task-local temporary output directory.

Plugins write newline-delimited JSON events to stdout:

```json
{"type":"log","level":"info","message":"Starting"}
{"type":"progress","fraction":0.5,"message":"Halfway"}
{"type":"result","status":"success","message":"Done","clipboard":"Text to copy"}
```

The process event stream is strict:

- Every non-empty stdout line must be one JSON event and unknown fields are rejected.
- `log.message`, `progress.fraction`, and `result.status` are required.
- Progress must be finite and between `0` and `1`; `completed` and `total` must appear together and be consistent.
- `result.status` is one of `success`, `failure`, or `cancelled`.
- A successful process exit must contain exactly one `result`, and it must be the final event.

stderr is stored as debug log text. Success requires both exit code `0` and a terminal `success` result; a non-zero exit, terminal `failure`, malformed stream, or missing terminal result fails the task. A terminal `cancelled` result cancels it. Stdout/stderr are read while the process is running so progress events can update the task queue and large-output plugins do not block on full pipes.

## Included examples

- `copy-markdown-image.plugin`: converts selected images to local Markdown image links.
- `zip-selected.plugin`: writes a zip archive to the task output directory.
- `upload-image-demo.plugin`: emits deterministic demo upload URLs without network calls.
- `batch-rename-demo.plugin`: dry-run rename preview copied to clipboard.
- `video-analyzer.plugin`: sends local video paths to a loopback HTTP service and returns
  `mediaAnalysis.v1`.

Test-only plugin packages live under `Tests/**/Fixtures`, are copied only into the test resource
bundle, and must not be placed in `ExamplePlugins`; the app packaging script rejects the known
second-media fixture ID if it appears in `BuiltinPlugins`.


## Runtime paths

The settings surface exposes Python and Node runtime paths. When configured, OpenFinder passes those paths into `ProcessPluginRunner`; otherwise it falls back to `/usr/bin/env python3` and `/usr/bin/env node`. Shell plugins use `/bin/zsh` by default.
