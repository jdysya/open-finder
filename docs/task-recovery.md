# Durable task and database recovery

Status: current explanation. System context and startup diagrams are in [系统架构](architecture.md#启动与恢复) and [`diagrams/startup-recovery.puml`](diagrams/startup-recovery.puml).

Durable task startup is gated on successful database open, migration, reconciliation, and exact
handler registration. Polling and task execution do not begin while readiness is checking or
unavailable.

Recovery is roll-forward:

- GRDB migrations remain append-only and validate future or corrupt schema states before execution.
- A future-version or malformed database causes a safe startup failure. OpenFinder does not delete,
  replace, or silently recreate the database and does not execute queued tasks from it.
- Reconciliation finishes or cleans staged artifact state using the persisted transition, without
  re-decoding plugin-specific legacy stores.
- Durable plugin descriptors retain the plugin ID, version, action, schema, credential references,
  and redacted inputs required for retry. Secret values are resolved only at execution time.
- HTTP server reconnect is limited to the same live job. Server restart or expired event history
  fails that attempt; retry receives a new task ID.

Result documents and committed artifacts outlive the temporary execution workspace. Presentation
reopens them through `ArtifactResultService`, not through a plugin-specific cache.
