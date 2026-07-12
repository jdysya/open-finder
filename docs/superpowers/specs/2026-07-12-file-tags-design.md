# OpenFinder Scoped File Tags Design

Date: 2026-07-12

## Goal

Add Finder-style tag display and editing to OpenFinder for local files and Kodbox resources. Local tag names must round-trip through Apple's public file-resource APIs. Kodbox personal tags and team public tags must map into one provider-neutral, permission-aware model without introducing Kodbox-specific branches into the presentation layer.

The user-visible result is a resizable Tags column and a compact Tags sheet opened from the file table's context menu. The sheet supports multi-selection, scoped personal/team catalogs, free-form creation where permitted, catalog management, and honest partial-failure reporting.

## Scope

This feature includes:

- Local file and directory tag-name display and mutation through `URLResourceKey.tagNamesKey`.
- Public system-label color mapping through `NSWorkspace.fileLabels` and `NSWorkspace.fileLabelColors` in the app layer.
- Kodbox personal tag display, catalog management, and file association.
- Kodbox team public tag display, grouped catalog management, permissions, and file association.
- Provider-neutral tag scope, catalog, capability, mutation, and multi-selection change models.
- A Finder-like AppKit table column and a compact SwiftUI editing sheet.
- Unit, contract, integration, regression, and real macOS GUI verification.

The feature does not:

- Read or write private Finder metadata such as `_kMDItemUserTags` or `com.apple.metadata:*` directly.
- Promise exact colors for arbitrary local custom tags that Apple does not expose through public tag-name resource values.
- Claim WebDAV tag support.
- Make remote multi-item changes appear transactional when the provider offers no transaction.
- Add tags to the plugin input schema without a separate schema-version decision.

## Design principles

1. Tagging is an optional provider capability, not a mandatory file-provider method.
2. A tag's identity includes its scope; equal names in local, personal, and team scopes are distinct.
3. Catalog-management permissions and file-association permissions are separate.
4. Multi-selection changes are expressed as additions and removals, never replacement of every selected item's full tag set.
5. The server remains authoritative after every remote mutation.
6. Core remains independent of AppKit. AppKit renders and forwards actions; `BrowserPaneModel` owns orchestration and refresh.

## Domain model

### FileTag

`FileTag` is a Codable, Hashable value containing:

- `id`: an opaque provider-scoped tag identifier.
- `scopeID`: the identifier of the catalog or namespace that owns the tag.
- `name`: the user-visible full tag name.
- `color`: a canonical optional color used for provider-supplied styles; `.none` means neutral presentation.
- `groupID`: an optional catalog group/category identifier, used by Kodbox team tags without leaking Kodbox types into UI code.

Tag IDs are never inferred from names for remote providers. Local tags use a stable namespaced identity derived from the exact tag name because Apple's public API exposes names rather than persistent tag IDs.

### TagScope

`TagScope` contains:

- An opaque `id`.
- A semantic kind: local, personal, or team.
- A display name such as Local, Kodbox Personal, or a team name.
- Capabilities: associate, create, rename, update style, delete, and organize groups.

The semantic kind supports consistent ordering and language in the UI. Behavior is controlled by capabilities, not by switching on the provider name.

### TagCatalog

`TagCatalog` contains its scopes, catalog groups, tags, and optional provider state needed to build safe mutations. A catalog can be displayed even when all management capabilities are false.

### TagChangeSet

`TagChangeSet` holds disjoint additions and removals grouped by scope. Construction removes duplicates and rejects the same identity appearing in both sets. An empty change set causes no filesystem or network mutation.

### TagCatalogMutation

Catalog mutations are typed operations:

- Create a tag in a scope and optional group.
- Rename a tag.
- Update a supported style.
- Move a tag between supported catalog groups.
- Delete a tag after explicit confirmation.

The provider returns a refreshed catalog or a created/updated tag with its server-assigned identity. The UI never invents a remote ID.

## Provider capability boundary

Introduce a dedicated asynchronous `TagProvider` protocol implemented by `LocalFileProvider` and `KodboxProvider`. Other file and remote providers remain unchanged and can adopt the capability later.

The capability provides operations to:

- Load a tag catalog for a location.
- Apply a scoped tag change set to selected items.
- Mutate a tag catalog when allowed.

Remote directory and item metadata exposes whether tags are present and which scope context applies, but it does not fake support for providers that do not implement `TagProvider`. `BrowserPaneModel` resolves the current provider and uses the capability only when available.

## Local Finder interoperability

`LocalFileProvider.list` and `stat` request `.tagNamesKey` alongside existing URL resource keys. `makeItem` maps exact names to local `FileTag` values. File and directory mutations read the latest tag names, apply only requested additions/removals, preserve unrelated names and order where possible, deduplicate exact matches, and write through the public resource-value setter on the existing file-I/O queue.

Local color presentation is deliberately app-layer behavior. The app compares local tag names with the public `NSWorkspace.fileLabels` array and uses the corresponding public `fileLabelColors` entry. Names without a public match render with a neutral semantic color. Core never imports AppKit or reads private xattrs.

For a local selection, the editor catalog contains:

- Public system label names.
- Tags currently visible in the pane.
- Tags present on selected items even if filtered out of the visible list.

Free-form local tag creation is always allowed for writable items and becomes an addition in the pending change set.

## Kodbox personal tags

The list decoder maps `sourceInfo.tagInfo`, accepting the server's absent, null, numeric-zero, empty-array, and valid-array forms. Valid entries provide `tagID`, `name`, and `style`. Malformed entries are ignored without failing the directory listing; duplicate identities are stably deduplicated.

Personal catalog operations use the official routes:

- `explorer/tag/get`
- `explorer/tag/add`
- `explorer/tag/edit`
- `explorer/tag/remove`
- `explorer/tag/filesAddToTag`
- `explorer/tag/filesRemoveFromTag`

Kodbox style names map to canonical colors. Unknown styles remain neutral while preserving the tag name and identity. Personal catalog responses are the source of truth for order and server-assigned IDs.

## Kodbox team public tags

The list decoder maps:

- `sourceInfo.groupTagInfo` to tags associated with a file or folder.
- `sourceInfo.groupTagList` to a team catalog when the server includes it at the team root.
- `sourceInfo.isGroupRoot` and item permission data to management/association capabilities.
- `targetType` and `targetID` to the team scope and required `groupID`.

When the current listing does not include the full team catalog, the provider loads it with `explorer/tagGroup/get` and `groupID`.

Team file association uses:

- `explorer/tagGroup/filesAddToTag`
- `explorer/tagGroup/filesRemoveFromTag`

Both routes receive `groupID`, `tagID`, and the file identifier. Association is available only when the item is writable and belongs to the same team scope.

Team catalog management uses `explorer/tagGroup/set` with `groupID` and a JSON `diff`. OpenFinder emits the smallest typed diff for the requested operation:

- Array additions for new groups or tags.
- Element edits for names, supported metadata, or group assignment.
- Array removals for deletion.
- Sort changes only when the user explicitly reorders catalog entries.

The provider fetches the latest catalog before constructing the diff. Kodbox applies that minimal diff to its current server-side catalog, assigns numeric IDs, validates unique tag IDs and names, removes document associations for deleted tags, and returns the resulting catalog. The returned catalog replaces local editor state.

Team catalog management is enabled only for team administrators. A non-admin with write access to a file may still associate existing public tags. Deleting a public tag requires a warning that every association for that team tag will be removed.

## File table presentation

The AppKit table adds a resizable Tags column. A dedicated reusable cell renders compact colored dots and names, truncates without altering the underlying value, shows `+N` when tags overflow the available width, and exposes the complete names through a tooltip and accessibility label. Reused cells clear previous tag state before rendering a new row.

The context menu adds Tags… for a nonempty selection whose items support editing. Context-clicking an unselected row first makes that row the selection. Empty-area context clicks do not offer a tag action.

Existing selection, double-click, drag, file-promise, keyboard, Quick Look, rename, transfer, and plugin-menu behavior remains unchanged.

## Compact scoped editor

The approved layout is a compact assignment-focused sheet with one searchable list divided into Local, Kodbox Personal, and Team Public sections.

For each tag, the selection state is:

- Checked when every selected item has it.
- Mixed when only some selected items have it.
- Empty when no selected item has it.

Clicking changes only the pending add/remove delta. It does not rewrite tags unique to individual items.

When search has no exact match, the editor offers Create in… choices only for scopes with creation permission. Remote creation completes before association, returns the server-assigned identity, returns to the assignment view, and selects the new tag.

A Manage… secondary page handles catalog creation, rename, supported style changes, team group assignment, and deletion. It is hidden when no scope is manageable. Personal and team catalog saves are separate from file-association Apply so one failure cannot be presented as success for the other.

Return applies association changes, Escape cancels pending changes, and focus returns to the file table after Apply or Cancel. Selection remains stable across the refresh when item IDs still exist. All controls and tag cells provide VoiceOver labels that include scope, name, color when known, and mixed state.

## Error handling and consistency

Directory-list tags render immediately. Full catalogs load asynchronously. If catalog loading fails, existing tags remain visible while the editor becomes read-only and presents Retry.

Capabilities disable impossible operations early, but provider and server responses remain authoritative. A permission failure refreshes the current directory and catalog before the editor allows another mutation.

Remote association is performed as identifiable file/tag operations rather than one opaque batch. Successful operations remain successful; failures are collected by item and tag, shown to the user, and followed by a refresh. OpenFinder does not attempt compensating rollback because rollback can fail and obscure the actual server state.

Local multi-selection follows the same honest partial-success policy. Missing, read-only, or unsupported items fail individually while other items continue.

Kodbox's file-list form field is comma-delimited, and the personal-tag controller also substitutes the sentinel `__*@*__`. OpenFinder rejects affected opaque identifiers before sending any tag association request, preventing accidental mutation of a different resource.

Authentication expiry uses the existing session behavior: authenticate and retry exactly once. Diagnostics and user-facing errors must not contain passwords, tokens, cookie values, or credential-bearing query parameters.

## Test strategy

Every behavior change receives a failing proof before production code.

### Domain and local provider

- Scoped identity, canonical color/style mapping, capability combinations, deduplication, and disjoint change sets.
- Backward-compatible decoding when tag fields are absent.
- File and directory list/stat reads.
- Add/remove without dropping unrelated tags.
- Empty changes, duplicate/empty names, missing files, read-only items, remote-item rejection, and unsupported volumes.
- A public-API round trip that Finder can observe.

### Remote contracts and Kodbox personal tags

- Default unsupported behavior for non-tag providers.
- Personal `tagInfo` valid and malformed variants.
- Catalog order and style mapping.
- Exact create/edit/remove and association route/form payloads.
- Empty changes, invalid IDs, unsafe delimiters, synthetic roots, authentication retry, and partial failure.

### Kodbox team tags

- `groupTagInfo`, `groupTagList`, target team, and permission mapping.
- Exact `tagGroup/get` and minimal `tagGroup/set` payloads for create, rename, group move, delete, and explicit reorder.
- File association requires a matching group and writable item.
- Non-admin association versus admin catalog-management capabilities.
- A stale catalog fixture proving an unrelated concurrent change survives a minimal diff.
- Deletion behavior and warning contract.

### App behavior and presentation

- Remote-to-file-item tag and permission propagation.
- Scoped catalog loading and tri-state selection.
- Stable `+N` presentation, complete tooltips, accessibility labels, Unicode, emoji, RTL, and neutral unknown colors.
- Search/create choices, capability gating, catalog-management routing, stable selection after refresh, read-only retry, and partial-error presentation.

### Regression and real-surface QA

- Preserve the existing 92-test baseline before implementation.
- Run all targeted suites, the complete parallel suite, Swift build, app launch verification, code-signing verification, diff checks, and a private-API scan.
- On macOS, prove Finder-to-OpenFinder display and OpenFinder-to-Finder mutation for both a file and directory, including relaunch persistence and multi-selection.
- Capture Light and Dark mode, long CJK/emoji/RTL tags, 20+ tag overflow, column resize, context selection, Apply/Cancel, and adjacent table interactions.
- Use a disposable Kodbox account/team when available for live personal/team create, rename, association, permission, and authentication checks. Fixture evidence must not be reported as live integration evidence.
- Destructive team-tag deletion is live-tested only in an explicitly disposable team; otherwise it remains fixture-proven.

## Completion gate

The feature is complete only when all binding RED proofs have corresponding GREEN evidence, real macOS surface evidence is captured and cleaned up, the full regression and build/signing checks pass, private Finder metadata is absent from production code, and independent visual and code reviewers return unconditional approval on the current build.
