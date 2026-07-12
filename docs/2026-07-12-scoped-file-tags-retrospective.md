# Scoped file tags development retrospective

Date: 2026-07-12

This document records the implementation branches, review discoveries, and preventive controls from the Finder-style scoped-tag feature. It is a maintenance record, not an API contract; the supported behavior is documented in [`kodbox-tag-support.md`](kodbox-tag-support.md), the design rationale is in [`superpowers/specs/2026-07-12-file-tags-design.md`](superpowers/specs/2026-07-12-file-tags-design.md), and the reusable project constraints are enforced from [`.omo/rules/scoped-file-tags.md`](../.omo/rules/scoped-file-tags.md).

## Delivered branches

| Branch | Purpose | Key commits |
| --- | --- | --- |
| Domain and local provider | Provider-neutral scoped tag model; public Finder tag-name read/write with serialized read-modify-write | `bd3cf27`, `da22b29`, `2da3673` |
| Remote capability contract | Optional tag metadata and `TagProvider`, while keeping unsupported providers unsupported | `22cda44` |
| Kodbox personal tags | Tolerant list mapping, catalog CRUD, associations, safe opaque-path validation, and auth retry | `67f469c`, `8564058` |
| Kodbox team public tags | Team scopes, permission-aware catalog/association operations, and minimal server diffs | `cf26935`, `93671d6` |
| Pane orchestration | Stale-session handling, loading-state parent behavior, and write-operation reentry guards | `725d447` through `664b120` |
| File-table presentation | Resizable 标签 column, AppKit reusable tag cell, context-menu selection behavior, overflow and accessibility | `224d390`, `54565f8` |
| Scoped editor | Multi-select tri-state editing, local/remote creation, catalog management, selection reconciliation, and independent refresh outcomes | `03af057` through `85cc216` |
| Safety and documentation | Explicit Kodbox permission default-deny behavior plus user/developer documentation | `e2cce2d`, `61a96b6`, `9fe5e25` |

## What blocked progress, what fixed it, and what to repeat next time

| Discovery | Root cause | Fix in this work | Preventive rule |
| --- | --- | --- | --- |
| A directory tag test read an old value after a provider write | The test helper reused a stale `NSURL`; the public API write itself had succeeded | Re-read through a fresh URL in the test helper and retained an end-to-end public-API round trip | Treat cached Foundation resource objects as potentially stale after an asynchronous write; confirm with a fresh URL before changing production code. |
| Two overlapping local updates dropped one tag | Tag changes were a read-modify-write sequence on a concurrent I/O queue | Serialize only the complete local tag RMW critical section | Every filesystem metadata RMW needs an explicit concurrency test with overlapping operations. |
| A malformed Kodbox `tagInfo` element hid valid later tags | The decoder stopped iterating at an unexpected element shape | Consume invalid entries and continue, then stably deduplicate usable tags | External list DTOs must tolerate bad sibling records without losing later valid records. |
| Team catalog mutations looked valid in fixtures but Kodbox ignored them | The server expects a top-level `diffArr` wrapper around list changes | Match the exact wrapper and lock it with request-shape fixtures | For third-party mutation APIs, assert the complete serialized body, not only decoded result state. |
| A late remote response or catalog reload replaced newer pane/editor state | Tag work had multiple async paths without one session/reentry boundary | Guard sessions, clear stale parents while loading, and hold write state through refresh | Every async UI mutation needs tests for navigation, reload, and a second action while the first is suspended. |
| Narrow tag columns showed only `+N` and hid the only useful name | Overflow logic counted the first tag as hidden | Always render a truncatable first tag; count only remaining hidden tags | Table overflow tests must cover one long tag and several long tags at narrow widths. |
| Catalog updates could revive deleted or pending editor state | Assignment deltas and catalog mutations/reloads shared state too loosely | Reconcile pending identities after successful mutations and separate mutation success from reload success | Model user draft state, server mutation state, and reload state separately; test reload failure after a successful mutation. |
| Missing or malformed `canWrite` elevated a team item to writable | Listing code used `canWrite ?? true` | Default denied and require explicit writability for association and management | Permission fields from remote APIs are fail-closed. Test absent, false, and malformed values, including admin-looking metadata. |
| Desktop QA initially addressed the installed application instead of the new worktree build | App name lookup selected `/Applications/OpenFinder.app`, not the staged worktree bundle | Target the exact `dist/OpenFinder.app` path for desktop automation | GUI QA scripts must record the exact bundle path and process ID they exercise. |

## Verification boundaries

- Automated contracts, app interaction tests, build/signing checks, and public-API scans are recorded in `artifacts/tag-qa/` and are intentionally not committed.
- Local manual verification used a disposable `/tmp/OpenFinderTagQA` fixture and public Foundation tag-name readback. The user subsequently accepted the implemented functionality after manual testing.
- A real disposable Kodbox account was not available during development. Live Kodbox Web UI synchronization therefore remains an environment-specific acceptance check; fixture coverage must never be represented as live-server proof.
- Dark-mode evidence was not retained because noninteractive appearance switching did not reliably change the app process. Future appearance QA should change the actual macOS appearance through a permitted interactive session, capture a full window frame, then restore the user setting.

## Pre-flight checklist for future tag changes

1. Keep `FileTag` and tag contracts provider-neutral; do not introduce AppKit or Kodbox DTOs into Core public types.
2. Add a failing-first test for the precise mutation or decoding boundary before implementation.
3. For local Finder tags, use public `URLResourceKey.tagNamesKey` APIs only; never infer private metadata or use xattrs.
4. For Kodbox, validate scope, account, group, opaque path, delimiter hazards, and permission before sending a request.
5. Refresh from the authoritative filesystem/server after mutation, but do not let stale reloads overwrite newer editor state.
6. Exercise table reuse, narrow columns, VoiceOver labels, multi-selection, context selection, and non-tag adjacent actions in the real desktop bundle.
7. Keep live-provider claims separate from fixture evidence and record the exact bundle/process used for desktop QA.
