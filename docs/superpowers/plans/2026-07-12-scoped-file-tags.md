# Scoped File Tags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Finder-compatible local tag names plus scoped Kodbox personal/team tag display, association, and catalog management to OpenFinder.

**Architecture:** Introduce a Core-only optional `TagProvider` capability and scoped `FileTag` domain model. Local and Kodbox providers implement it; `BrowserPaneModel` resolves it, owns refresh/error/selection recovery, and passes presentation state to a compact AppKit/SwiftUI editor. The UI never switches on a Kodbox-specific type; scope capabilities decide available actions.

**Tech Stack:** Swift 6, macOS 14, Foundation URL resource values, SwiftUI, AppKit `NSTableView`, XCTest, `URLProtocol` Kodbox fixtures, SwiftPM.

## Global Constraints

- Use only Apple public APIs for local tags: `URLResourceKey.tagNamesKey`, `NSURL.setResourceValue`, `NSWorkspace.fileLabels`, and `NSWorkspace.fileLabelColors`.
- Do not read/write `_kMDItemUserTags`, `com.apple.metadata:*`, Finder preferences, or private xattrs.
- Keep `OpenFinderCore` AppKit-free; all `NSColor`/`NSWorkspace` use is in `OpenFinderApp`.
- Scope identity is opaque; never infer a Kodbox `tagID` from a tag name.
- Personal and team catalog management are distinct from association permissions.
- Express multi-selection mutations as disjoint adds/removes. Never replace a selected item's entire tag list.
- Reject Kodbox association paths containing `,` or `__*@*__` before a network request.
- Remote and local partial failures must be shown honestly and followed by a refresh. Do not implement rollback.
- Keep WebDAV unsupported for tags; default capability behavior must be explicit and safe.
- No `.skip`, `.only`, `xfail`, or lint suppression may be added.
- Capture each RED result before production code, then capture its corresponding GREEN result under `artifacts/tag-qa/`.
- Do not create an implementation commit without a new explicit user authorization. Stage only the proposed atomic group if a handoff requires it.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/OpenFinderCore/Domain/FileTag.swift` | Provider-neutral scope, tag, catalog, permissions, delta, catalog mutation, capability protocol, and typed outcomes. |
| `Sources/OpenFinderCore/Domain/FileItem.swift` | Persisted item tags and tagability metadata with legacy-decoding defaults. |
| `Sources/OpenFinderCore/FileSystem/LocalFileProvider.swift` | Public Finder tag-name read/write implementation. |
| `Sources/OpenFinderCore/Remote/RemoteModels.swift` | Remote tags, tag-scope metadata, directory capability defaults, and remote item compatibility decoding. |
| `Sources/OpenFinderCore/Remote/KodboxHTTPClient.swift` | Official personal/team tag endpoint identifiers. |
| `Sources/OpenFinderCore/Remote/KodboxProvider.swift` | Personal/team list DTO decoding, scoped catalogs, safe association and catalog mutations. |
| `Sources/OpenFinderApp/Models/AppModel.swift` | `BrowserPaneModel` tag-editor lifecycle, provider resolution, refresh and selection recovery. |
| `Sources/OpenFinderApp/Support/FileTagPresentation.swift` | AppKit-free deterministic tag-cell descriptors and editor tri-state reducers. |
| `Sources/OpenFinderApp/Views/FileTagCellView.swift` | Reusable AppKit Tags cell with overflow/tooltip/accessibility rendering. |
| `Sources/OpenFinderApp/Views/TagEditorView.swift` | Compact scoped SwiftUI assignment sheet and management subview. |
| `Sources/OpenFinderApp/Views/FileTableRepresentable.swift` | Tags column, context action, and AppKit event forwarding. |
| `Sources/OpenFinderApp/Views/FilePaneView.swift` | Sheet state and action routing only. |
| `Tests/OpenFinderCoreTests/FileTagTests.swift` | Core invariants and legacy Codable coverage. |
| `Tests/OpenFinderCoreTests/LocalFileProviderTests.swift` | Finder public-API read/write coverage. |
| `Tests/OpenFinderCoreTests/RemoteContractsTests.swift` | Safe default remote tag contracts. |
| `Tests/OpenFinderCoreTests/KodboxProviderTests.swift` | Kodbox personal/team route, DTO, diff, safety, and partial-failure fixtures. |
| `Tests/OpenFinderAppTests/FileTagPresentationTests.swift` | Pure presentation/tri-state/overflow/accessibility tests. |
| `Tests/OpenFinderAppTests/AppInteractionTests.swift` | Pane orchestration, remote propagation, context-action and selection tests. |

## Task 1: Capture the unchanged characterization baseline

**Files:**

- Create: `artifacts/tag-qa/baseline.txt` (verification artifact; do not stage)
- Modify: none

**Interfaces:**

- Consumes: current SwiftPM package and existing test targets.
- Produces: a pre-feature regression baseline and exact XCTest count.

- [ ] **Step 1: Create the QA evidence directory**

```bash
mkdir -p artifacts/tag-qa
```

- [ ] **Step 2: Run the existing full test suite before changing tests or source**

Run:

```bash
swift test --parallel | tee artifacts/tag-qa/baseline.txt
```

Expected: exit code `0`, all pre-existing tests pass, and the output records the existing 92-test baseline.

- [ ] **Step 3: Record the baseline in the ultrawork notepad**

Append the exact command, exit code, test count, and artifact path. Do not treat a child-agent report as baseline evidence.

## Task 2: Add the Core scoped-tag domain model with a RED→GREEN contract

**Files:**

- Create: `Sources/OpenFinderCore/Domain/FileTag.swift`
- Create: `Tests/OpenFinderCoreTests/FileTagTests.swift`
- Modify: `Sources/OpenFinderCore/Domain/FileItem.swift:11-58`

**Interfaces:**

- Produces `FileTagScopeKind`, `FileTagScopeCapabilities`, `FileTagScope`, `FileTagColor`, `FileTagGroup`, `FileTag`, `FileTagCatalog`, `FileTagChangeSet`, `FileTagCatalogMutation`, `TagApplyFailure`, `TagApplyResult`, and `TagProvider`.
- Produces trailing `FileItem` fields `tags`, `tagScopes`, and `supportsTagEditing`, all defaulted for source compatibility and custom-decoded for persisted JSON compatibility.
- Consumes only `Foundation`, `Location`, and `FileItem`; it must not import AppKit.

- [ ] **Step 1: Write failing Core contract tests**

Create tests that compile against the intended API:

```swift
func testChangeSetDeduplicatesAndKeepsAddsAndRemovesDisjoint() {
    let scope = FileTagScope.local
    let red = FileTag.local(name: "Red")
    let result = FileTagChangeSet(add: [red, red], remove: [red])

    XCTAssertTrue(result.additions.isEmpty)
    XCTAssertEqual(result.removals, [red])
    XCTAssertTrue(result.isEmpty == false)
    XCTAssertEqual(scope.kind, .local)
}

func testLegacyFileItemDecodesWithoutTagKeys() throws {
    let data = Data(#"{"id":"local:/tmp/a","name":"a","location":{"local":{"path":"/tmp/a"}},"kind":"file","size":null,"modificationDate":null,"creationDate":null,"uti":null,"mimeType":null,"fileExtension":null,"isHidden":false,"isReadable":true,"isWritable":true}"#.utf8)
    let item = try JSONDecoder().decode(FileItem.self, from: data)
    XCTAssertEqual(item.tags, [])
    XCTAssertEqual(item.tagScopes, [])
    XCTAssertFalse(item.supportsTagEditing)
}
```

Add tests for opaque identity (`scopeID + id`), stable exact-name local identity, known Kodbox style colors, unknown style `.none`, empty change sets, and capability flags.

- [ ] **Step 2: Capture the expected RED output**

Run:

```bash
swift test --filter FileTagTests | tee artifacts/tag-qa/contracts-red.txt
```

Expected: compile/test failure because the scoped tag types and `FileItem` fields do not exist. Confirm the failure is missing behavior, not malformed fixture JSON.

- [ ] **Step 3: Implement the minimal Core values and protocol**

Create the values with Foundation-only types and these signatures:

```swift
public protocol TagProvider: Sendable {
    func tagCatalog(for location: Location) async throws -> FileTagCatalog
    func apply(_ changes: FileTagChangeSet, to items: [FileItem]) async throws -> TagApplyResult
    func mutate(_ mutation: FileTagCatalogMutation, in scope: FileTagScope) async throws -> FileTagCatalog
}

public struct FileTagChangeSet: Codable, Hashable, Sendable {
    public let additions: [FileTag]
    public let removals: [FileTag]
    public var isEmpty: Bool { additions.isEmpty && removals.isEmpty }
}
```

Normalize additions/removals by identity in the initializer. When an identity appears in both inputs, retain it only in `removals`, making the resulting state unambiguous. Give `FileItem` a custom `init(from:)` that uses `decodeIfPresent([FileTag].self, forKey: .tags) ?? []`, `decodeIfPresent([FileTagScope].self, forKey: .tagScopes) ?? []`, and `decodeIfPresent(Bool.self, forKey: .supportsTagEditing) ?? false`.

- [ ] **Step 4: Run the Core contract tests GREEN**

Run:

```bash
swift test --filter FileTagTests | tee artifacts/tag-qa/contracts-green.txt
```

Expected: all `FileTagTests` pass.

- [ ] **Step 5: Run the Core package compatibility check**

Run:

```bash
swift test --filter PluginSystemTests
swift test --filter RemoteContractsTests
```

Expected: existing `FileItem` callers remain source-compatible because new initializer parameters are trailing defaults.

## Task 3: Implement Finder-compatible local tag names

**Files:**

- Modify: `Sources/OpenFinderCore/FileSystem/LocalFileProvider.swift:21-45,187-237`
- Modify: `Tests/OpenFinderCoreTests/LocalFileProviderTests.swift`

**Interfaces:**

- Consumes `FileTag.local(name:)`, `FileTagScope.local`, `FileTagChangeSet`, and `TagApplyResult` from Task 2.
- Produces `LocalFileProvider: TagProvider` using only public Foundation URL resource values.

- [ ] **Step 1: Write failing local tag tests**

Add tests that use the public URL resource API rather than private xattrs:

```swift
func testListAndStatReadFinderTags() async throws {
    let file = tempRoot.appendingPathComponent("tagged.txt")
    try Data().write(to: file)
    try (file as NSURL).setResourceValue(["Important", "客户"], forKey: .tagNamesKey)

    let provider = LocalFileProvider()
    let listed = try await provider.list(.local(path: tempRoot.path), options: .init(showHiddenFiles: true, sort: .name(ascending: true)))
    let stated = try await provider.stat(.local(path: file.path))

    XCTAssertEqual(listed.single?.tags.map(\.name), ["Important", "客户"])
    XCTAssertEqual(stated.tags.map(\.name), ["Important", "客户"])
    XCTAssertTrue(stated.supportsTagEditing)
}

func testApplyTagChangesAddsAndRemovesWithoutDroppingUnrelatedTags() async throws {
    // Seed ["Keep", "Remove"], remove only Remove, add Added, then read tagNamesKey.
}
```

Also cover a tagged folder, an empty change set, duplicate names, and rejecting a remote `FileItem` before any URL mutation.

- [ ] **Step 2: Capture local RED evidence**

Run:

```bash
swift test --filter LocalFileProviderTests/testListAndStatReadFinderTags | tee artifacts/tag-qa/local-red.txt
swift test --filter LocalFileProviderTests/testApplyTagChangesAddsAndRemovesWithoutDroppingUnrelatedTags | tee -a artifacts/tag-qa/local-red.txt
```

Expected: failure because `.tagNamesKey` is neither requested nor exposed and `LocalFileProvider` lacks `TagProvider` methods.

- [ ] **Step 3: Read public tags in list/stat and apply deltas**

Extend both resource-key collections with `.tagNamesKey`; construct tags with:

```swift
let tags = (values.tagNames ?? []).map(FileTag.local(name:))
```

Add `tagScopes: [.local]` and `supportsTagEditing: values.isWritable ?? false` to local `FileItem` construction. In `apply(_:to:)`, run on `runFileIO`, reject nonlocal/read-only items, retrieve `tagNames`, remove exact requested local names, append missing additions in request order, and write:

```swift
try (url as NSURL).setResourceValue(resultingNames, forKey: .tagNamesKey)
```

Return a `TagApplyResult` containing per-item failures rather than discarding successful mutations. An empty change set returns without obtaining resource values or writing metadata.

- [ ] **Step 4: Run the local suite GREEN**

Run:

```bash
swift test --filter LocalFileProviderTests | tee artifacts/tag-qa/local-green.txt
```

Expected: all local provider tests pass, including file/folder tags and no-loss delta behavior.

- [ ] **Step 5: Verify the public-API boundary**

Run:

```bash
rg -n '_kMDItemUserTags|com\.apple\.metadata' Sources/OpenFinderCore Tests/OpenFinderCoreTests
```

Expected: no matches.

## Task 4: Carry scoped tags through remote contracts without faking WebDAV support

**Files:**

- Modify: `Sources/OpenFinderCore/Remote/RemoteModels.swift:53-113`
- Modify: `Sources/OpenFinderCore/Remote/WebDAVProvider.swift`
- Modify: `Tests/OpenFinderCoreTests/RemoteContractsTests.swift`

**Interfaces:**

- Consumes domain values from Task 2.
- Produces `RemoteItem.tags`, `RemoteItem.tagScopes`, `RemoteItem.supportsTagEditing`, and `RemoteDirectoryCapabilities.supportsTags` with compatibility-safe defaults.
- Keeps `RemoteProvider` unchanged; callers use `as? any TagProvider` for optional support.

- [ ] **Step 1: Write failing remote contract tests**

Add a fixture remote item with a team-scoped tag and assert round-trip behavior. Add a legacy JSON decode test and an unsupported provider test:

```swift
func testWebDAVDoesNotConformToTagProvider() {
    let account = RemoteAccount(
        name: "WebDAV",
        provider: .webDAV,
        baseURL: URL(string: "https://webdav.test/")!,
        username: "alice",
        secretKeychainRef: nil,
        options: ["connectorID": RemoteConnectorID.webDAV.rawValue]
    )
    let provider = WebDAVProvider(account: account, credentialStore: InMemoryKeychainStore())
    XCTAssertNil(provider as? any TagProvider)
}
```

Also construct `RemoteDirectoryCapabilities(isReadable: true, isWritable: true)` and assert `supportsTags == false`; construct a legacy `RemoteItem` without tag arguments and assert `tags == []`, `tagScopes == []`, and `supportsTagEditing == false`.

- [ ] **Step 2: Capture remote-contract RED output**

Run:

```bash
swift test --filter RemoteContractsTests | tee artifacts/tag-qa/remote-contracts-red.txt
```

Expected: failure because remote tag fields and capability defaults are absent.

- [ ] **Step 3: Add backward-compatible remote metadata**

Add trailing-default initializer arguments and custom decoding defaults for `RemoteItem` and `RemoteDirectoryCapabilities`. Defaults must be `tags: []`, `tagScopes: []`, `supportsTagEditing: false`, and `supportsTags: false`. Preserve all existing constructor call sites.

- [ ] **Step 4: Run contracts and WebDAV regression GREEN**

Run:

```bash
swift test --filter RemoteContractsTests | tee artifacts/tag-qa/remote-contracts-green.txt
swift test --filter WebDAVProviderTests
```

Expected: remote metadata tests pass and WebDAV remains explicitly unsupported.

## Task 5: Add Kodbox personal-tag decoding, catalog management, and safe association

**Files:**

- Modify: `Sources/OpenFinderCore/Remote/KodboxHTTPClient.swift:3-16`
- Modify: `Sources/OpenFinderCore/Remote/KodboxProvider.swift:1-233`
- Modify: `Tests/OpenFinderCoreTests/KodboxProviderTests.swift`
- Modify: `Tests/OpenFinderCoreTests/KodboxAPIClientTests.swift`

**Interfaces:**

- Consumes `TagProvider` and scoped Core values from Tasks 2 and 4.
- Produces `KodboxProvider: TagProvider` for personal catalog scope `kodbox:<account>:personal`.
- Uses official endpoint cases `explorer/tag/get`, `explorer/tag/add`, `explorer/tag/edit`, `explorer/tag/remove`, `explorer/tag/filesAddToTag`, and `explorer/tag/filesRemoveFromTag`.

- [ ] **Step 1: Write failing personal-tag list and catalog fixtures**

Extend the existing list fixture to include a valid and invalid `sourceInfo.tagInfo`:

```json
{"name":"notes.txt","path":"{source:5}/notes.txt","size":42,"modifyTime":1700000010,
 "sourceInfo":{"tagInfo":[{"tagID":"7","name":"Review","style":"label-blue-normal"},{"tagID":7,"name":"Review","style":"label-blue-normal"},{"tagID":"bad"}]}}
```

Assert one stable `Review` tag with an opaque personal ID. Add fixtures for omitted `sourceInfo`, `tagInfo: null`, `tagInfo: 0`, `[]`, unknown style, and malformed tag objects. Add request-recorder tests for `tagCatalog`, create, rename, delete, add association, remove association, empty changes, and unsafe path refusal.

- [ ] **Step 2: Capture personal-tag RED output**

Run:

```bash
swift test --filter KodboxProviderTests/testListMapsPersonalTags | tee artifacts/tag-qa/kodbox-personal-red.txt
swift test --filter KodboxProviderTests/testPersonalTagCatalogAndAssociationRoutes | tee -a artifacts/tag-qa/kodbox-personal-red.txt
```

Expected: failures because no tag DTOs/endpoints/capability methods exist.

- [ ] **Step 3: Implement loss-tolerant DTOs and catalog operations**

Add endpoint enum cases and private DTOs that decode numeric or string `tagID` values and treat absent/null/zero tag collections as empty. Map known `label-*-normal` styles to `FileTagColor`; map unknown values to `.none`.

Implement `tagCatalog(for:)` with `session.perform(.tagGet, form: [:], response: KodboxPersonalTagCatalogPayload.self)`. Implement personal create/rename/delete through the official catalog endpoints. Implement association as one item/tag operation. Before every association request, reject synthetic root, `/`, unknown scope/ID, `,`, and `__*@*__` in the opaque path. Return failures by item/tag and continue later operations.

- [ ] **Step 4: Verify session retry behavior for tag routes**

Add a `KodboxAPIClientTests` fixture that returns an expired-auth envelope on a tag request, then a login response, then success. Assert exactly one retry and that diagnostics do not contain fixture password or access token.

- [ ] **Step 5: Run personal Kodbox tests GREEN**

Run:

```bash
swift test --filter KodboxProviderTests | tee artifacts/tag-qa/kodbox-personal-green.txt
swift test --filter KodboxAPIClientTests
```

Expected: all existing Kodbox file-operation tests and new personal-tag tests pass.

## Task 6: Add Kodbox team public-tag scope and minimal-diff catalog mutations

**Files:**

- Modify: `Sources/OpenFinderCore/Remote/KodboxHTTPClient.swift`
- Modify: `Sources/OpenFinderCore/Remote/KodboxProvider.swift`
- Modify: `Tests/OpenFinderCoreTests/KodboxProviderTests.swift`

**Interfaces:**

- Produces a team `FileTagScope` whose ID includes the account and Kodbox `groupID`.
- Uses `explorer/tagGroup/get`, `explorer/tagGroup/set`, `explorer/tagGroup/filesAddToTag`, and `explorer/tagGroup/filesRemoveFromTag`.
- Produces a private Codable representation of Kodbox `group`/`list` catalog data and a private typed diff encoder.

- [ ] **Step 1: Write failing team-scope fixtures**

Add a Kodbox item fixture with `targetType: "group"`, `targetID: "42"`, writable permissions, and:

```json
"sourceInfo": {
  "isGroupRoot": true,
  "isGroupHasTag": true,
  "groupTagInfo": [{"id":9,"name":"Approved","groupInfo":{"id":2,"name":"Status"}}]
}
```

Assert that its tag scope is team `42`, an administrator receives manage capabilities, and a non-admin writable fixture receives associate-only capabilities. Add route/form tests for team catalog load and per-item association requiring the same group ID.

- [ ] **Step 2: Write failing minimal-diff tests**

For a catalog with groups and tags, assert exact JSON for:

```swift
.createTag(name: "Blocked", groupID: "2")
.renameTag(id: "9", name: "Reviewed")
.moveTag(id: "9", groupID: "3")
.deleteTag(id: "9")
```

The deletion fixture must verify the UI-facing mutation outcome advertises association removal. Add a stale-catalog fixture where the server has an unrelated tag; assert a rename diff changes only tag `9` and retains the unrelated tag after server application.

- [ ] **Step 3: Capture team-tag RED output**

Run:

```bash
swift test --filter KodboxProviderTests/testListMapsTeamTagsAndPermissions | tee artifacts/tag-qa/kodbox-team-red.txt
swift test --filter KodboxProviderTests/testTeamTagCatalogMutationsUseMinimalDiff | tee -a artifacts/tag-qa/kodbox-team-red.txt
```

Expected: failures due to missing team DTOs, route cases, scope mapping, and diff encoder.

- [ ] **Step 4: Implement team decoding and capability rules**

Decode group item context (`targetType`, `targetID`, `sourceInfo.groupTagInfo`, `sourceInfo.groupTagList`, `sourceInfo.isGroupRoot`, `sourceInfo.isGroupHasTag`) without making list failures fatal for unknown/missing optional data. Mark association allowed only for a writable item whose target is the requested team; mark catalog management from `isGroupRoot` only.

- [ ] **Step 5: Implement a private minimal-diff encoder and routes**

Fetch the latest `tagGroup/get` response immediately before any `tagGroup/set`. Encode a top-level diff containing only required `group`/`list` additions, element edits, removals, and explicit sort modifications. Include `groupID` in every team form. Decode the returned catalog and replace editor state with it. Never send a full replacement snapshot.

- [ ] **Step 6: Run all Kodbox team and adjacent regression tests GREEN**

Run:

```bash
swift test --filter KodboxProviderTests | tee artifacts/tag-qa/kodbox-team-green.txt
swift test --filter RemoteContractsTests
swift test --filter WebDAVProviderTests
```

Expected: personal/team mapping and route tests pass while WebDAV behavior remains unchanged.

## Task 7: Orchestrate tag editing in BrowserPaneModel

**Files:**

- Modify: `Sources/OpenFinderApp/Models/AppModel.swift:557-862`
- Modify: `Sources/OpenFinderApp/Support/AppInteractionSupport.swift`
- Modify: `Tests/OpenFinderAppTests/AppInteractionTests.swift`

**Interfaces:**

- Consumes `TagProvider`, `FileTagCatalog`, `FileTagChangeSet`, and `TagApplyResult`.
- Produces `TagEditorContext`, `TagSelectionState`, `BrowserPaneModel.prepareTagEditor()`, `applyTagChanges(_:)`, `mutateTagCatalog(_:)`, and `reloadTagCatalog()`.
- `TagEditorContext` holds selected item IDs, selected items, catalog, per-tag tri-state, operation state, and errors; it never owns an AppKit view.

- [ ] **Step 1: Write failing pane orchestration tests**

Add a tag-capable recording fixture provider and assert:

```swift
func testRemoteListingPropagatesTagsAndActualReadWriteFlags() async throws {
    // RemoteItem tags/scopes/false writable reaches FileItem unchanged.
}

func testApplyingTagChangesRefreshesAndPreservesExistingSelection() async throws {
    // Select stable IDs, apply a delta, fixture returns refreshed list, selection intersects correctly.
}

func testUnsupportedWebDAVSelectionDoesNotOpenEditor() async throws {
    // Nil context, no provider mutation.
}
```

Cover mixed state calculation, catalog read failure with Retry, partial failures in `errorMessage`, non-admin team association versus management gating, and stale selected items.

- [ ] **Step 2: Capture AppModel RED evidence**

Run:

```bash
swift test --filter AppInteractionTests/testRemoteListingPropagatesTagsAndActualReadWriteFlags | tee artifacts/tag-qa/pane-red.txt
swift test --filter AppInteractionTests/testApplyingTagChangesRefreshesAndPreservesExistingSelection | tee -a artifacts/tag-qa/pane-red.txt
```

Expected: missing editor context/tag provider behavior or failed propagation assertions.

- [ ] **Step 3: Propagate remote metadata correctly**

Update `listItems(at:)` to copy `remoteItem.tags`, `remoteItem.tagScopes`, `remoteItem.supportsTagEditing`, `isReadable`, and `isWritable` rather than hard-coding read/write `true` at lines 854-855. Keep remote locations and stable IDs unchanged.

- [ ] **Step 4: Implement context, provider resolution, and refresh behavior**

`prepareTagEditor()` must reject an empty selection and any selection without a common editable scope. It resolves local `provider` or casts the resolved remote actor to `any TagProvider`. Loading failure creates a read-only context with `Retry`; it must not erase visible file tags.

Apply/mutate methods must set in-progress state, preserve successes/failures, always `await refresh()`, and let the existing `selection.formIntersection` preserve surviving IDs. Do not create a second tag source of truth in the view.

- [ ] **Step 5: Run AppModel tests GREEN**

Run:

```bash
swift test --filter AppInteractionTests | tee artifacts/tag-qa/pane-green.txt
```

Expected: existing interaction coverage and new scoped tag orchestration tests pass.

## Task 8: Add deterministic tag presentation and the AppKit Tags column

**Files:**

- Create: `Sources/OpenFinderApp/Support/FileTagPresentation.swift`
- Create: `Sources/OpenFinderApp/Views/FileTagCellView.swift`
- Create: `Tests/OpenFinderAppTests/FileTagPresentationTests.swift`
- Modify: `Sources/OpenFinderApp/Views/FileTableRepresentable.swift:5-280`
- Modify: `Sources/OpenFinderApp/Support/AppInteractionSupport.swift`

**Interfaces:**

- Produces `FileTagPresentation`, `FileTagCellDescriptor`, `TagSelectionState`, and pure `TagSelectionReducer`.
- Produces `FileTagCellView.configure(tags:availableWidth:)` and `FileTableAction.editTags`.
- Consumes Core tags and app-only public `NSWorkspace` label/color lookup.

- [ ] **Step 1: Write failing pure presentation tests**

Add tests for exact deterministic ordering (local, personal, team; then catalog order/name), overflow, accessibility, and tri-state:

```swift
func testDescriptorShowsVisibleTagsThenOverflowCountAndFullAccessibilityLabel() {
    let descriptor = FileTagPresentation.descriptor(tags: fixtureTags, maxVisibleTags: 2)
    XCTAssertEqual(descriptor.visible.map(\.name), ["重要", "Review"])
    XCTAssertEqual(descriptor.overflowCount, 2)
    XCTAssertEqual(descriptor.accessibilityLabel, "标签：重要、Review、✅、客户")
}
```

Cover empty tags, 20+ tags, long CJK, emoji, RTL names, unknown style neutral color, and a local label name matched to a public `NSWorkspace` slot through an injected lookup closure.

- [ ] **Step 2: Capture presentation RED output**

Run:

```bash
swift test --filter FileTagPresentationTests | tee artifacts/tag-qa/presentation-red.txt
```

Expected: missing presentation/reducer symbols.

- [ ] **Step 3: Implement AppKit-free descriptors and a reusable cell**

Keep `FileTagPresentation` value-only. Inject the local label color lookup from the AppKit cell rather than importing AppKit into Core. `FileTagCellView` clears all arranged subviews, tooltips, and accessibility values on every `configure` call; then creates compact dot/name views and a `+N` label from the descriptor.

- [ ] **Step 4: Add Tags column and context action**

In `makeNSView`, add a resizable `NSTableColumn(identifier: .init("tags"))` after Name with title `标签`. In `tableView(_:viewFor:row:)`, route the `tags` identifier to the reusable cell. Add `.editTags` to `FileTableAction`; create `标签…` in `makeMenu()` only when selected items are nonempty and tag-editable; use the existing context-click selection normalization before forming the menu.

- [ ] **Step 5: Run presentation and table-selection regression tests GREEN**

Run:

```bash
swift test --filter FileTagPresentationTests | tee artifacts/tag-qa/presentation-green.txt
swift test --filter AppInteractionTests/testPointerSelectionClearsOnlyPlainEmptyAreaClicks
swift test --filter AppInteractionTests/testModifierClickSelectionSupportsCommandToggleAndShiftRange
```

Expected: presentation tests pass and existing table selection behavior is unchanged.

## Task 9: Build the compact scoped SwiftUI editor and route it from FilePaneView

**Files:**

- Create: `Sources/OpenFinderApp/Views/TagEditorView.swift`
- Modify: `Sources/OpenFinderApp/Views/FilePaneView.swift:1-220`
- Modify: `Tests/OpenFinderAppTests/AppInteractionTests.swift`

**Interfaces:**

- Consumes `TagEditorContext`, presentation descriptors, and pane callbacks from Task 7.
- Produces `TagEditorView(context:onApply:onRetry:onManage:onDismiss:)` and a `TagCatalogManagementView` secondary screen.
- `FilePaneView` owns only `@State private var tagEditorContext: TagEditorContext?` and routes `.editTags` to `pane.prepareTagEditor()`.

- [ ] **Step 1: Write failing UI-state tests through pure reducers/context**

Add testable assertions that an editor context exposes Local/Personal/Team in that order, filters search text, shows Create in… only for create-capable scopes, hides Manage… when no scope can manage, and preserves separate association/catalog operations.

- [ ] **Step 2: Capture UI-state RED output**

Run:

```bash
swift test --filter AppInteractionTests/testTagEditor | tee artifacts/tag-qa/ui-red.txt
```

Expected: missing editor-state behavior.

- [ ] **Step 3: Implement assignment view**

Build a compact `.sheet(item:)` with a searchable grouped list. Render checked/mixed/empty states from `TagSelectionReducer`; tapping one updates only pending `FileTagChangeSet`. When no exact search match exists, show Create in… buttons only for scope capability `.create`. Disable Apply while a mutation runs. Bind Return to Apply, Escape to Cancel, and return focus to the table after closing.

- [ ] **Step 4: Implement catalog management secondary view**

Management is a separate navigation state, not a replacement for assignment. It supports personal create/rename/style/delete and team create/rename/group move/delete only according to `TagScopeCapabilities`. Before team delete, present a confirmation message that associations will be removed. Save catalog mutations separately; after success call `reloadTagCatalog()` and return the newly created tag to assignment for selection.

- [ ] **Step 5: Wire FilePaneView and run App tests GREEN**

In `handleTableAction`, route `.editTags` to a pane context and set the sheet state. Surface `BrowserPaneModel.errorMessage` and partial failures without closing the sheet. Run:

```bash
swift test --filter AppInteractionTests | tee artifacts/tag-qa/ui-green.txt
swift build
```

Expected: interaction tests and the macOS executable build pass.

## Task 10: Document behavior and complete the verification/review loop

**Files:**

- Modify: `README.md:5-35`
- Create: `docs/kodbox-tag-support.md`
- Create: `artifacts/tag-qa/local-tags-before.png`, `local-tags-after.png`, `ui-tags-light.png`, `ui-tags-dark.png`, `regression.png`, `full-suite.txt`, `build-run.txt`, `private-api-scan.txt`

**Interfaces:**

- Documents supported local/public API boundary, personal/team Kodbox routes, permission boundary, unsafe delimiter restriction, and unsupported WebDAV behavior.

- [ ] **Step 1: Write documentation tests/claims from verified behavior only**

Update README implemented scope once Core/App tests are green. In `docs/kodbox-tag-support.md`, list every supported route, required `groupID` for team routes, the personal/team permission distinction, style mapping, and delimiter refusal. Do not claim live Kodbox verification without an actual disposable account artifact.

- [ ] **Step 2: Run complete automated verification**

Run:

```bash
swift test --parallel | tee artifacts/tag-qa/full-suite.txt
swift build
./script/build_and_run.sh --verify | tee artifacts/tag-qa/build-run.txt
codesign --verify --deep --strict --verbose=2 dist/OpenFinder.app
rg -n '_kMDItemUserTags|com\.apple\.metadata' Sources Tests | tee artifacts/tag-qa/private-api-scan.txt
git diff --check
```

Expected: all commands exit `0`; the private API scan has no output.

- [ ] **Step 3: Perform local Finder surface QA and capture evidence**

Create `/tmp/OpenFinderTagQA/local` containing a file and directory. In Finder, assign two tags (one long Unicode tag); capture `local-tags-before.png`. Launch `./script/build_and_run.sh --verify`, navigate OpenFinder to the fixture, verify the Tags column, then use right-click → 标签… to remove one and add one. In Finder Get Info, verify exact tag names, relaunch OpenFinder, and capture `local-tags-after.png`.

PASS: both file and directory values are visible, changed names round-trip to Finder, and they persist after app relaunch. Cleanup: quit OpenFinder and remove `/tmp/OpenFinderTagQA` after screenshots are saved.

- [ ] **Step 4: Perform UI and adjacent-action surface QA**

Use Command and Shift selection, right-click an unselected row, Apply and Cancel, resize Tags, inspect tooltip/VoiceOver label, then capture Light/Dark screenshots. Verify Rename, Quick Look, drag-out, copy/move-to-other-pane, plugin submenu, and empty-area deselection. Save `ui-tags-light.png`, `ui-tags-dark.png`, and `regression.png`.

PASS: tags do not leave reused-cell artifacts, selection remains stable, unsupported items disable the action, and every named existing action still works.

- [ ] **Step 5: Run disposable Kodbox live QA only when credentials/team are supplied**

With an explicitly disposable account/team, verify personal and team catalog create/rename/association, non-admin capability gating, expired-auth retry, and delimiter rejection; save `kodbox-live.png`. If no disposable account is available, append `NOT EXECUTED — no disposable Kodbox account supplied` to the evidence log and do not present fixture proof as live proof.

- [ ] **Step 6: Perform independent review loops**

Give two read-only visual reviewers every fresh screenshot and the source files; fix every blocking finding and recapture all states until both return PASS. Then give the HEAVY reviewer the goal, criteria, current diff, complete notepad, artifact paths, and all tests/build output. Fix every concern, rerun the full verification and surface scenarios, and resubmit until the reviewer gives unconditional approval.

- [ ] **Step 7: Cleanup and prepare handoff**

Terminate any OpenFinder QA process; assert `pgrep -x OpenFinder` has no result, remove QA temp fixtures, verify no QA port is bound, and append cleanup receipts to the notepad. Stage documentation/code only if the user explicitly authorizes an implementation commit; otherwise report the exact remaining uncommitted files.

## Plan Self-Review

### Spec coverage

- Public Finder tag-name round trip and neutral unknown colors: Tasks 2, 3, 8, and 10.
- Optional provider capability with WebDAV unsupported: Tasks 2 and 4.
- Personal Kodbox catalog and association: Task 5.
- Team catalog, permission split, minimal diff, and associations: Task 6.
- Finder-like table/context/sheet/multi-selection/management UI: Tasks 7, 8, and 9.
- Partial failures, unsafe paths, retry, refresh, stable selection, redaction: Tasks 3, 5, 6, and 7.
- Automated, real-surface, documentation, cleanup, visual, and HEAVY review gates: Tasks 1 and 10.

### Placeholder scan

Search before execution:

```bash
rg -n 'T[B]D|T[O]DO|implement[[:space:]]later|fill[[:space:]]in[[:space:]]details|appropriate[[:space:]]error[[:space:]]handling|Similar[[:space:]]to[[:space:]]Task' docs/superpowers/plans/2026-07-12-scoped-file-tags.md
```

Expected: no matches.

### Type consistency

All later tasks consume `FileTag`, `FileTagScope`, `FileTagCatalog`, `FileTagChangeSet`, `FileTagCatalogMutation`, `TagApplyResult`, and `TagProvider` introduced in Task 2. `BrowserPaneModel` is the only app-state owner; presentation code consumes its context and never mutates providers directly.
