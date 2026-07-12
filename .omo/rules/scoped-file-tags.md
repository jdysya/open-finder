# Scoped file tag constraints

Apply these rules whenever changing file tags, tag-capable providers, Kodbox tag routes, tag-editor state, or table tag presentation.

## Architecture

- Keep `FileTag`, `FileTagScope`, `TagCatalog`, `TagChangeSet`, and provider contracts free of AppKit and Kodbox DTO types.
- Treat tags as an optional `TagProvider` capability. Do not make WebDAV or another provider appear tag-capable unless it implements the capability and has contract coverage.
- Keep AppKit/SwiftUI limited to rendering and forwarding. `BrowserPaneModel` owns mutations, refreshes, selection preservation, and user-visible failure state.

## Local Finder tags

- Use only public Apple file-resource APIs: `URLResourceKey.tagNamesKey` and its resource-value setters. Never read/write Finder private metadata, xattrs, `_kMDItemUserTags`, or `com.apple.metadata:*`.
- Apply local mutations as add/remove deltas: re-read current names, preserve unrelated names, deduplicate exact names, and leave empty deltas as no-ops.
- Serialize the complete local tag read-modify-write operation. Do not rely on a concurrent file-I/O queue to preserve overlapping tag updates.
- After an asynchronous Foundation write, verify through a fresh `URL`/resource read; do not treat a cached `NSURL` value as authoritative.

## Remote and Kodbox safety

- External list decoders must ignore malformed sibling tag records and continue mapping valid later records; stably deduplicate usable tag identities.
- Validate remote account, tag scope, team group, opaque item path, and write permission before a mutation request. Reject roots and paths containing Kodbox delimiter/sentinel hazards before any request.
- Treat absent, malformed, or false remote permission data as denied. Team association and catalog management require explicit write permission; management additionally requires the server's administrator signal.
- Keep tag IDs opaque. Never infer a remote tag or group identifier from its name.
- Lock Kodbox route and request-body behavior with request-shape tests, including required `diffArr` wrappers for team catalog mutations. A decoded fixture result alone is insufficient proof of wire compatibility.
- Keep live-server claims separate from fixture coverage. If a disposable Kodbox account is unavailable, record the scenario as unexecuted rather than passing it by inference.

## Async state and editing

- Guard tag loading, application, catalog mutation, and reload by the active pane/session identity. A late response must not overwrite a newer navigation state.
- Prevent a second tag apply, catalog mutation, or catalog reload from re-entering while a write and its authoritative refresh are in progress.
- Keep assignment drafts, catalog-mutation results, and catalog-reload results separate. A successful mutation must not be reported as failed solely because a follow-up reload failed; successful deletions must still reconcile pending drafts.
- For multi-selection, represent changes as disjoint additions/removals. Do not replace each item's full tag set or erase tags unique to one item.

## Native table and accessibility

- A reusable tag cell clears arranged subviews, tooltip, and accessibility value before configuration.
- At narrow widths, keep the first tag visible and truncatable; `+N` counts only additional hidden tags. Tooltip and VoiceOver output retain every full name.
- Context-clicking an unselected row must normalize selection first. Empty-area and unsupported/readonly selections must not expose an actionable tag command.
- Preserve Command/Shift selection, Rename, Quick Look, drag/drop, copy/move, plugin actions, and empty-area deselection when changing table coordination.

## Required evidence for tag changes

- Add a failing-first test for the touched contract or state boundary before production changes, then keep its green result.
- Cover at least the relevant happy path, malformed/permission or concurrency edge, and adjacent table/pane regression.
- For desktop QA, target the exact staged `dist/OpenFinder.app` bundle path and record the process/path used; do not rely on the installed application selected by display name.
- Preserve evidence truthfully: distinguish fixture, public-API round-trip, desktop interaction, and live-provider verification.
