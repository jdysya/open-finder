# Video Analyzer Plugin

This built-in plugin sends selected local videos to an independently running Video Analyzer HTTP
service. The plugin is loopback-only: the default endpoint is `http://127.0.0.1:8765`, and the
matching bearer token is a dedicated local secret.

OpenFinder stores `serverToken` in its secured local Application Support `config.json`, not in macOS Keychain.
The file is atomically maintained with mode `0600`.
The token remains outside generic plugin configuration and HTTP request JSON.

OpenFinder never installs or starts Video Analyzer, never runs `uv`, and does not need `uv` on its
`PATH`. The Video Analyzer repository owns its Python environment, dependencies, models, process,
logs, and macOS permissions.

## Canonical setup

### 1. Install the analyzer environment once

Run this in the Video Analyzer repository, replacing the example path with its real location:

```bash
cd /absolute/path/to/video-analyzer
uv sync --frozen
```

`uv sync --frozen` is an installation/update step only. It creates the repository's `.venv` from
the checked-in lockfile; it is not part of normal OpenFinder use or normal server startup.

### 2. Generate a token and start the service

Run the following in a Terminal window that will remain open. `ANALYZER_REPO` becomes an absolute
path, and `openssl` produces an ASCII token68 accepted by the server. A newly generated token must
also replace the value saved in OpenFinder.

```bash
cd /absolute/path/to/video-analyzer
ANALYZER_REPO="$(pwd -P)"
export VIDEO_ANALYZER_OPENFINDER_TOKEN="$(/usr/bin/openssl rand -base64 32 | tr -d '\n')"
printf '%s' "$VIDEO_ANALYZER_OPENFINDER_TOKEN" | /usr/bin/pbcopy
printf 'Token copied to the clipboard for OpenFinder serverToken.\n'
"$ANALYZER_REPO/.venv/bin/python" -m analyzer.openfinder_server --host 127.0.0.1 --port 8765
```

Do not use `uv run` for this normal service startup. Keep the token private; never paste it into a
bug report, README, command log, or OpenFinder's non-secret configuration. Because OpenFinder's
Application Support `config.json` contains the token in a dedicated sensitive map, do not share
that file. Stop the service with Control-C.

When upgrading from an older build, OpenFinder migrates a legacy Video Analyzer Keychain value only
when no local value exists and the secured config write succeeds.
OpenFinder keeps the old Keychain item after a successful local migration.
If the local write fails, the bounded legacy fallback stays available and the Keychain item is never
deleted.

### 3. Configure and test OpenFinder

1. Open **OpenFinder Settings → Plugins → Video Analyzer**.
2. Set `serverURL` to `http://127.0.0.1:8765`.
3. Paste the exact generated token into the secured-local-config `serverToken` field and save it.
4. Choose whether to enable `useJoyTag`.
5. Click **Test Connection**. Start analysis only when the status is **Ready**.

The service startup terminal must remain running during analysis. OpenFinder is only the client; it
will not repair the environment or restart a stopped service.

## First analysis, models, and macOS privacy

The first analysis is slower because NudeNet initializes its model and, when `useJoyTag` is enabled,
JoyTag may download `config.json`, `top_tags.txt`, and `model.safetensors` into the Hugging Face
cache. Network access can therefore be required during initial warm-up; later inference remains
local once the required files are cached. The `model-cache` health check reports `warn` with
“JoyTag model cache is cold” before that download. This warning alone does not make the current
server health status degraded.

macOS TCC access belongs to the independently running repository `.venv/bin/python` process and the
Terminal application that launched it, not to OpenFinder. If a selected video is under Desktop,
Documents, Downloads, an external volume, or another protected location, grant the launching
Terminal/Python process the relevant **Privacy & Security → Files and Folders** permission (or Full
Disk Access when appropriate), then restart the service and retry.

## Health and troubleshooting

Authenticated **Test Connection** displays the server's overall status (`ready`, `degraded`, or
`unavailable`) and these exact environment check IDs:

- `python`: requires Python 3.11 from the repository `.venv`.
- `required-dependencies`: `jinja2`, `nudenet`, `rich`, and `scenedetect`; a missing import is
  `fail` and makes health `unavailable`.
- `optional-dependencies`: `huggingface_hub`, `PIL`, `safetensors`, and `torch`; a missing import is
  `warn` and makes health `degraded`.
- `output` and `cache`: both must be writable; failure makes health `unavailable`.
- `model-cache`: reports whether the JoyTag cache directory is present (`pass`) or cold (`warn`).

OpenFinder represents connection problems with `PluginConnectionIssue` and request failures with
`HTTPPluginError`. Use this map rather than treating every failure as an environment reinstall:

- A public minimal `/health` is followed by authenticated `/capabilities`; HTTP 401/403 maps to `PluginConnectionIssue.authenticationFailed`.
- HTTP 426 `unsupported_protocol` maps to `PluginConnectionIssue.serverUnavailable`, with the status and code retained in guidance.

| Symptom | Actual status, code, or message class | Action |
| --- | --- | --- |
| Server is stopped or the URL/port is wrong | `PluginConnectionIssue.serverUnavailable`; during a job, `HTTPPluginError.transport` | Start the documented absolute `.venv/bin/python` command and retry **Test Connection**. |
| Server starts without the environment token | Process exits with status 2 and `VIDEO_ANALYZER_OPENFINDER_TOKEN is required.` | Export a generated token68 before starting it. Do not use `--insecure-loopback` for normal use. |
| OpenFinder has no token | `PluginConnectionIssue.missingToken` | Save the generated token in the secured local config `serverToken` field. |
| Tokens do not match | `/health` returns its public minimal body, then **Test Connection** checks authenticated `/capabilities`; its HTTP 401 `unauthorized` maps to `PluginConnectionIssue.authenticationFailed`. | Replace `serverToken` with the exact value in the server process environment. |
| Required dependency is missing | `required-dependencies=fail`, health `unavailable`; submissions are HTTP 503 `service_unavailable` | Stop the service, run `uv sync --frozen` in the analyzer repository, then restart with its absolute `.venv/bin/python`. |
| Optional model dependency is missing | `optional-dependencies=warn`, health `degraded`; OpenFinder reports `PluginConnectionIssue.environmentUnavailable` | Run `uv sync --frozen`, restart, and repeat **Test Connection**. OpenFinder deliberately does not submit while degraded. |
| JoyTag cache is cold | `model-cache=warn`; the overall health may still be `ready` | Allow the first JoyTag analysis to download and warm the model. Disable `useJoyTag` if JoyTag output is not required. |
| A model is missing, incomplete, offline, or cannot load | No model-specific HTTP error code exists. JoyTag load failure can yield no JoyTag tags; a fatal NudeNet/pipeline failure becomes terminal result status `failure` with message `Video analysis failed.` | Read the independently running server terminal, restore network/cache access, and retry. Do not assume a `model_unavailable` code exists. |
| Video is missing or unreadable, including TCC denial | Usually HTTP 400 `invalid_request` with `an input video is missing or not a regular file`; a later read failure can become terminal `failure` | Verify the file still exists and grant TCC access to the server Python/Terminal process, then restart and retry. |
| Protocol or plugin does not match | A 200 `/health` whose `protocolVersion` is not 1 maps to `PluginConnectionIssue.incompatibleProtocol`. HTTP 426 `unsupported_protocol` currently maps **Test Connection** to `PluginConnectionIssue.serverUnavailable`; its guidance includes 426 and `unsupported_protocol`. A mismatched `pluginID` maps to `PluginConnectionIssue.incompatiblePlugin`. | Update the older side, and confirm `serverURL` points to this Video Analyzer service. |
| Health is degraded or unavailable | `PluginConnectionIssue.environmentUnavailable`; checks have `pass`, `warn`, or `fail` | Follow each displayed remediation. OpenFinder enables submission only for `ready`. |
| Server dies during a job | Initially `HTTPPluginError.transport`; after restart the in-memory job is gone and can return HTTP 404 `job_not_found` | Start the server again, run **Test Connection**, then retry as a new OpenFinder task. Jobs do not survive server restart. |
| Job fails inside the analyzer | Terminal result status `failure`, message `Video analysis failed.`; OpenFinder reports an operation failure, not a model-specific server code | Inspect the server terminal and input/model/cache permissions, then retry after correcting the cause. |

Other protocol errors that can appear during recovery or load are HTTP 429 `queue_full` (retryable),
409 `job_not_terminal` (retryable), 409 `event_history_expired`, 409 `task_conflict`, 400
`invalid_last_event_id`, and 500 `internal_error` (retryable). Never include the bearer token when
sharing diagnostics; replace it with `REDACTED`.

## Deprecated process bridge

`run.py` and `worker/` are the deprecated legacy process bridge. The schema-2 HTTP manifest does
not reference or execute them. They remain in the repository only because they contain existing
dirty progress work that must not be discarded. Remove them only after the shipped HTTP integration
has demonstrated stable, real end-to-end validation across startup, analysis, cancellation, result
artifacts, server-loss recovery, and retry.
