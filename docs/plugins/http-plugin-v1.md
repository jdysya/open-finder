# OpenFinder local HTTP plugin protocol v1

Status: canonical v1 contract.

Architecture and lifecycle context: [插件机制](../plugin-system.md). Manifest and shared event/artifact fields: [插件 API](../plugin-api.md).

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, and **MAY** are normative. The machine-readable companion is [`http-plugin-v1.openapi.json`](http-plugin-v1.openapi.json).

## Transport boundary

- The base path is exactly `/openfinder/plugin/v1`.
- A configured endpoint MUST use plain HTTP and a numeric loopback host: `http://127.0.0.1:<port>` or `http://[::1]:<port>`. A server MUST bind only to loopback. `localhost`, non-loopback addresses, remote hosts, user information, query strings, and fragments are prohibited. v1 has no remote upload or download transport and no TLS configuration surface.
- Every request MUST send `OpenFinder-Plugin-Protocol: 1`. Every response, including an error response and an SSE response, MUST send the same header with value `1`. A reachable server that cannot serve version 1 returns HTTP 426 and `unsupported_protocol`.
- `GET /health` is reachable without credentials. A valid bearer token MAY add the detailed fields described by `HealthResponse`; an absent or invalid token receives only the public fields and is not a token-validity oracle. Every other route requires `Authorization: Bearer <token>` and returns HTTP 401 `unauthorized` when it is absent or invalid. The token MUST NOT appear in a JSON body, URL, log, error message, fixture, or `PluginInput`.
- JSON requests use `Content-Type: application/json` with UTF-8. JSON responses use `application/json; charset=utf-8`. A JSON-producing client SHOULD send `Accept: application/json`; an event client sends `Accept: text/event-stream`.
- Responses MUST send `Cache-Control: no-store` and MUST NOT send CORS headers.

The paths below are relative to the base path. These are the only v1 operations.

| Method | Path | Authentication | Success |
| --- | --- | --- | --- |
| `GET` | `/health` | public; bearer details optional | 200 `HealthResponse` |
| `GET` | `/capabilities` | bearer | 200 `CapabilitiesResponse` |
| `POST` | `/jobs` | bearer | 202 for a new job; 200 for an idempotent replay |
| `GET` | `/jobs/{taskID}` | bearer | 200 `JobSnapshot` |
| `GET` | `/jobs/{taskID}/events` | bearer | 200 `text/event-stream` |
| `GET` | `/jobs/{taskID}/result` | bearer | 200 terminal `ResultEvent` |
| `DELETE` | `/jobs/{taskID}` | bearer | 202 when cancellation is accepted; 200 when already observed |

## Status codes and errors

Every non-2xx JSON response uses exactly this envelope; unknown fields are not permitted:

```json
{
  "schemaVersion": 1,
  "code": "event_history_expired",
  "message": "Events before 42 are no longer retained.",
  "retryable": false
}
```

The canonical envelope is `{schemaVersion,code,message,retryable}`. `schemaVersion` is the integer `1`, `code` is a stable machine value, `message` is safe actionable text, and `retryable` tells the client whether retrying the same operation can succeed without a configuration change. Error messages MUST NOT disclose bearer tokens, tracebacks, or data outside the assigned task workspace.

| Operation | Status | Code or meaning |
| --- | --- | --- |
| every operation | 426 | `unsupported_protocol` |
| every operation | 500 | `internal_error` |
| every authenticated operation | 401 | `unauthorized` |
| `POST /jobs` | 400 | `invalid_request` |
| `POST /jobs` | 409 | `task_conflict` |
| `POST /jobs` | 413 | `request_too_large` |
| `POST /jobs` | 415 | `unsupported_media_type` |
| `POST /jobs` | 429 | `queue_full` |
| `POST /jobs` | 503 | `service_unavailable` |
| job routes | 400 | `invalid_task_id` (or `invalid_last_event_id` on the events route) |
| job routes | 404 | `job_not_found` |
| `GET /jobs/{taskID}/events` | 409 | `event_history_expired` |
| `GET /jobs/{taskID}/result` | 409 | `job_not_terminal` |

An error response is complete when written. It MUST NOT also create a job, advance a job, or open an SSE stream.

## Requests and idempotency

`POST /jobs` consumes the existing OpenFinder `PluginInput` JSON without a transport wrapper. Its required top-level fields are `schemaVersion`, `taskID`, `actionID`, `app`, `context`, `files`, `config`, `secrets`, `tempDirectory`, and `outputDirectory`. The request schema version is the integer `1`. `taskID` is a UUID and is the sole idempotency key; v1 does not use an `Idempotency-Key` header.

The server compares the fully decoded request, including `taskID`, after normal JSON decoding (object member order and insignificant whitespace therefore do not matter):

- The first valid `taskID` creates one job and returns HTTP 202.
- A later semantically identical request with that `taskID` returns the existing snapshot with HTTP 200. It MUST NOT enqueue work again or duplicate events.
- A later request with that `taskID` but any different decoded value returns HTTP 409 `task_conflict`.

The HTTP bearer credential is transport state and MUST NOT be copied into `PluginInput.secrets`. Input media remains local: `files[].path`, `tempDirectory`, and `outputDirectory` identify paths on the same Mac. v1 MUST NOT upload a selected video to any host.

## Job lifecycle

The `state` value is exactly one of:

`queued | preparing | running | finalizing | succeeded | failed | cancelling | cancelled`

The legal state graph is:

- `queued` -> `preparing` or `cancelled`
- `preparing` -> `running`, `cancelling`, or `failed`
- `running` -> `finalizing`, `cancelling`, or `failed`
- `finalizing` -> `succeeded`, `cancelling`, or `failed`
- `cancelling` -> `cancelled`
- `succeeded`, `failed`, and `cancelled` have no outgoing transition

`succeeded`, `failed`, and `cancelled` are terminal. A job reaches exactly one terminal state, emits exactly one terminal `result` event, and never leaves or replaces that terminal state. The result status maps as `succeeded` -> `success`, `failed` -> `failure`, and `cancelled` -> `cancelled`.

`DELETE /jobs/{taskID}` is idempotent. A queued job MAY transition directly to `cancelled`. A job in `preparing`, `running`, or `finalizing` transitions to `cancelling`, cooperatively stops, then transitions to `cancelled`. A repeated delete or a delete after any terminal state returns HTTP 200 with the unchanged snapshot; cancellation never rewrites an existing terminal outcome.

`GET /jobs/{taskID}` is the polling fallback. Its snapshot includes the latest state, the greatest allocated event ID, and the latest progress event when one exists. `GET /jobs/{taskID}/result` returns the one terminal `ResultEvent` for any terminal outcome and returns HTTP 409 `job_not_terminal` while the job is active.

## Events and replay

Each job has its own event ID sequence. IDs are positive decimal integers, begin at `1`, and are strictly increasing; they are never reused. Gaps are allowed. A JSON event is flat: the common fields `schemaVersion`, `eventID`, `taskID`, and `type` are at the top level alongside the existing event fields, not inside a `payload` object.

The event types and fields are:

- `log`: required `level` and `message`.
- `progress`: required `fraction`; optional `message`, `phase`, `completed`, `total`, and `unit`. `fraction` is from 0 through 1. When unit counts are present, both are non-negative and `completed` MUST NOT exceed `total`.
- `result`: required `status` and `artifacts`; optional `message` and `clipboard`. `status` is `success`, `failure`, or `cancelled`. This is the job's sole terminal event.

The canonical wire form for each event is:

```text
id: <eventID>
event: <type>
data: <compact UTF-8 JSON object>

```

The empty line after `data` terminates the event; on an LF stream the frame therefore ends in `\n\n` (CRLF is also valid). The `id` field MUST equal the JSON `eventID`, the `event` field MUST equal the JSON `type`, the JSON `taskID` MUST equal the path job, and `schemaVersion` MUST be `1`. Servers emit one compact JSON `data` line. Clients MUST also implement standard SSE joining for multiple consecutive `data:` lines using a single LF, accept LF or CRLF framing and arbitrary byte chunk boundaries, and reject invalid UTF-8 or mismatched fields. A heartbeat is an SSE comment such as `: keep-alive\n\n`; it has no JSON body and does not allocate an event ID.

The server retains at most 10,000 events per job. When the cap is exceeded it discards the oldest events, never the monotonic counter. An event request without `Last-Event-ID` replays every retained event in order and then follows live events. With decimal `Last-Event-ID: N`, it replays retained events whose IDs are greater than `N`, then follows live events.

- `N = 0` is a valid cursor before the first event.
- If `N` is greater than the greatest allocated ID, the server returns HTTP 400 `invalid_last_event_id`.
- If an event greater than `N` exists but has already been discarded, the server returns HTTP 409 `event_history_expired`; it MUST NOT silently skip the gap.
- Reconnect does not duplicate a terminal event because replay uses the same retained ID and the job owns only one terminal event.

## Retention and restart behavior

A terminal job's snapshot, result, and retained events remain addressable for exactly 30 minutes (1,800 seconds) after its terminal transition. After that retention interval the server removes the job and its routes return HTTP 404 `job_not_found`. The client owns cleanup of the task workspace according to its task policy; API retention does not authorize the server to read outside that workspace.

The v1 job registry and replay history are process-local. A server restart invalidates every active job and drops existing streams. v1 explicitly prohibits server-restart recovery: it does not resume work, reconstruct job state, reuse an event sequence, or promise replay across the restart. The client reports the interrupted task as an actionable failure; a user retry creates a new `taskID`. Follow-up requests for an invalidated old ID return HTTP 404 `job_not_found` once the restarted server is reachable.

## Artifact boundary

HTTP results are file-backed. Every artifact contains `type`, `relativePath`, `mediaType`, `byteCount`, and lowercase `sha256`. `relativePath` is a non-empty relative path below the request's `outputDirectory`. Absolute artifact paths, `..` traversal, drive-qualified paths, and symlink escapes are prohibited. The client resolves the path, proves containment, checks the byte count and SHA-256, and only then reads or decodes it.

The HTTP protocol MUST NOT put artifact contents or Base64 frames in JSON or SSE. Keyframe bytes stay in files below `outputDirectory`; JSON result files refer to frame and report files by confined relative paths. A server MUST NOT return, read, or copy an arbitrary absolute artifact path even when such a path exists locally.

For a structured result, the artifact `type` MUST equal the invoking manifest action's
`output.resultType`. Media analyzers use `mediaAnalysis.v1` and return exactly one JSON document
artifact of that type. The document's `schemaID` and `schemaVersion` are validated independently of
the transport envelope. The protocol does not assign renderer behavior by server or plugin ID.

## Restart-safe client behavior (without recovery)

OpenFinder may reconnect only to the same live job using `Last-Event-ID`, and may fall back to one-second snapshot polling when capabilities advertise polling. A transport disconnect followed by `job_not_found`, a changed server process, or expired history is a failure of that attempt, not evidence of success. Retry is a new job with a new task UUID. No stdout text, HTTP 2xx alone, or stale snapshot may be treated as terminal success; success requires the single validated terminal result whose `taskID` matches the active task.
