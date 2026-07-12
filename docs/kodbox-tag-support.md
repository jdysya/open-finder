# Finder and Kodbox tag support

OpenFinder exposes one scoped tag model across local files and Kodbox while preserving each provider's identity and permission rules. A tag identity is its opaque provider ID plus its scope; equal names in local, personal, and team scopes are not interchangeable.

The file table shows a resizable Tags column. The context-menu action `标签…` opens a multi-selection editor with empty, mixed, and checked states. Assignment and catalog management are separate operations, and the provider is refreshed after a mutation so the filesystem or server remains authoritative.

## Local Finder interoperability

Local file and directory tag names are read with `URLResourceKey.tagNamesKey` and written with `NSURL.setResourceValue(_:forKey: .tagNamesKey)`. Updates are deltas: OpenFinder re-reads the latest names, removes only requested names, appends new names, and preserves unrelated tags. Tag mutations are serialized to prevent concurrent edits from overwriting one another.

This boundary uses Apple public APIs only. OpenFinder does not read or write `_kMDItemUserTags`, `com.apple.metadata:*`, or Finder metadata extended attributes directly.

Apple's public file-resource value exposes tag names, not a complete custom-tag color catalog. For display, the app matches a local name against `NSWorkspace.fileLabels` and uses the corresponding `NSWorkspace.fileLabelColors` entry. An unmatched local name is rendered with a neutral marker. Local free-form names can be associated with writable items, but OpenFinder does not claim a public Finder catalog create, rename, or delete API.

## Kodbox personal tags

Directory listings map `sourceInfo.tagInfo` into the personal scope. Absent, `null`, numeric zero, empty-array, and malformed entry shapes are treated as no usable tag data; invalid IDs and empty names are ignored, and duplicate identities are stably deduplicated.

Supported personal routes and form fields:

| Operation | Route | Form fields |
| --- | --- | --- |
| Load catalog | `explorer/tag/get` | none |
| Create tag | `explorer/tag/add` | `name`, `style` |
| Rename tag | `explorer/tag/edit` | `tagID`, `name` |
| Change style | `explorer/tag/edit` | `tagID`, `style` |
| Delete tag | `explorer/tag/remove` | `tagID` |
| Associate with item | `explorer/tag/filesAddToTag` | `tagID`, `files` |
| Remove from item | `explorer/tag/filesRemoveFromTag` | `tagID`, `files` |

Personal tags belong to the signed-in user's catalog, so the personal scope advertises create, rename, style, delete, and association capabilities. File or folder association still requires a writable Kodbox item in the same account and personal scope. Personal tags do not support groups or group moves.

## Kodbox team public tags

A listing is recognized as a team scope only when `targetType` is `group` and `targetID` is a canonical positive integer. `sourceInfo.groupTagInfo` maps item associations, while the catalog is loaded from `explorer/tagGroup/get`. The required `groupID` is carried in the scope and is never inferred from a tag name.

Supported team routes and form fields:

| Operation | Route | Form fields |
| --- | --- | --- |
| Load catalog | `explorer/tagGroup/get` | `groupID` |
| Create, rename, move, or delete a tag | `explorer/tagGroup/set` | `groupID`, JSON `diff` |
| Associate with item | `explorer/tagGroup/filesAddToTag` | `groupID`, `tagID`, `files` |
| Remove from item | `explorer/tagGroup/filesRemoveFromTag` | `groupID`, `tagID`, `files` |

OpenFinder reads the current team catalog before a catalog mutation and sends the smallest supported `diff`: add one tag to an existing group, edit its name or group, or remove one tag. Creating a team tag therefore requires an existing catalog group. Team style mutation is not exposed because the implemented team payload has no supported style contract. Deleting a team tag is treated as removing its existing associations on the server.

Team catalog management and item association have separate permissions:

- `sourceInfo.isGroupRoot == true` enables team tag creation, rename, move, and delete for that scope.
- Item `canWrite == true` enables association, provided the item belongs to the same account and `groupID` as the tag.
- A writable non-admin can associate existing team tags without receiving catalog-management capabilities.
- An admin cannot associate a tag with a read-only item or with an item from another team scope.

## Kodbox style mapping

Personal Kodbox styles map as follows:

| Kodbox style | OpenFinder color |
| --- | --- |
| `label-red-normal` | red |
| `label-orange-normal` | orange |
| `label-yellow-normal` | yellow |
| `label-green-normal` | green |
| `label-blue-normal` | blue |
| `label-purple-normal` | purple |
| `label-gray-normal`, `label-grey-normal`, `label-black-normal` | gray |
| absent or unknown value | neutral |

When writing a personal style, neutral and gray both encode as `label-grey-normal`; the other canonical colors use their corresponding `label-<color>-normal` value. Unknown read styles preserve the tag ID and name and render neutrally. Team tags currently render neutrally because the supported team payload does not provide a style mapping.

## Association safety and failure behavior

Kodbox's association endpoints encode one or more paths in the `files` form field using server-reserved delimiters. OpenFinder therefore rejects the following before sending any association request for that item:

- an empty change set;
- the OpenFinder synthetic Kodbox root or `/`;
- any path containing `,`;
- any path containing `__*@*__`;
- a read-only or non-tag-editable item;
- an item from another account, scope, or team `groupID`;
- an empty or zero tag ID, or a non-canonical team/group ID.

Accepted paths are treated as opaque strings and sent unchanged. Changes from different Kodbox scopes are not combined. Multi-item remote updates are best-effort, not transactional: successful item IDs and per-item failures are reported separately, then the pane refreshes from the server. Authentication failure triggers one token refresh and one retry through the shared Kodbox API session.

## WebDAV boundary

`WebDAVProvider` does not conform to the optional tag-provider protocol, its directory capabilities do not advertise tag support, and WebDAV items do not enable tag editing. OpenFinder does not emulate tags with WebDAV properties or sidecar files.

## Verification status

The repository's Core and App tests cover public local tag-name round trips, delta updates, concurrent local writes, malformed Kodbox tag data, exact personal/team routes and form fields, unsafe-path preflight, permission gating, multi-selection state, presentation, and WebDAV non-support. Automated verification evidence is stored under `artifacts/tag-qa/` when the verification workflow is run.

Live Kodbox verification status: **NOT EXECUTED — no disposable Kodbox account supplied**. Fixture-backed tests are not presented as proof of a live Kodbox server mutation.
