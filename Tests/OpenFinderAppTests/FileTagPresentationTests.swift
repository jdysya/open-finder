import AppKit
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class FileTagPresentationTests: XCTestCase {
    func testDescriptorOrdersByScopeThenCatalogOrderAndPreservesFullAccessibilityText() {
        let scopes = Self.scopes
        let important = FileTag.local(name: "重要")
        let review = FileTag(id: "personal-review", scopeID: scopes[1].id, name: "Review", color: .blue)
        let emoji = FileTag(id: "team-emoji", scopeID: scopes[2].id, name: "✅", color: .green)
        let customer = FileTag(id: "team-customer", scopeID: scopes[2].id, name: "客户", color: .orange)

        let descriptor = FileTagPresentation.descriptor(
            tags: [customer, emoji, review, important],
            scopes: scopes,
            catalogOrder: [important, review, emoji, customer],
            maxVisibleTags: 2
        )

        XCTAssertEqual(descriptor.visible.map(\.name), ["重要", "Review"])
        XCTAssertEqual(descriptor.overflowCount, 2)
        XCTAssertEqual(descriptor.accessibilityLabel, "标签：重要、Review、✅、客户")
        XCTAssertEqual(descriptor.toolTip, "重要、Review、✅、客户")
    }

    func testDescriptorUsesDeterministicNameFallbackWithinScope() {
        let personal = Self.scopes[1]
        let tags = [
            FileTag(id: "z", scopeID: personal.id, name: "Zulu"),
            FileTag(id: "a", scopeID: personal.id, name: "Alpha"),
            FileTag(id: "m", scopeID: personal.id, name: "Middle")
        ]

        let descriptor = FileTagPresentation.descriptor(tags: tags, scopes: [personal], maxVisibleTags: 3)

        XCTAssertEqual(descriptor.visible.map(\.name), ["Alpha", "Middle", "Zulu"])
    }

    func testDescriptorStablyDeduplicatesRepeatedCatalogIdentities() {
        let personal = Self.scopes[1]
        let first = FileTag(id: "same", scopeID: personal.id, name: "First")
        let duplicate = FileTag(id: "same", scopeID: personal.id, name: "Duplicate")

        let descriptor = FileTagPresentation.descriptor(
            tags: [first, duplicate],
            scopes: [personal, personal],
            catalogOrder: [first, duplicate],
            maxVisibleTags: 2
        )

        XCTAssertEqual(descriptor.visible.map(\.name), ["First"])
        XCTAssertEqual(descriptor.overflowCount, 0)
    }

    func testDescriptorHandlesEmptyAndTwentyPlusTagsWithoutLosingNames() {
        let empty = FileTagPresentation.descriptor(tags: [], maxVisibleTags: 3)
        XCTAssertTrue(empty.visible.isEmpty)
        XCTAssertEqual(empty.overflowCount, 0)
        XCTAssertEqual(empty.accessibilityLabel, "标签：无")
        XCTAssertNil(empty.toolTip)

        let tags = (0..<24).map { FileTag.local(name: "标签\($0)") }
        let crowded = FileTagPresentation.descriptor(tags: tags, maxVisibleTags: 3)
        XCTAssertEqual(crowded.visible.count, 3)
        XCTAssertEqual(crowded.overflowCount, 21)
        XCTAssertEqual(crowded.accessibilityLabel.components(separatedBy: "、").count, 24)
        XCTAssertTrue(crowded.accessibilityLabel.contains("标签23"))
    }

    func testDescriptorPreservesLongCJKEmojiAndRTLNamesVerbatim() {
        let names = [
            "这是一个非常长但不应在辅助功能内容中截断的标签名称",
            "🧪👩🏽‍💻",
            "مراجعة المستند"
        ]
        let tags = names.map(FileTag.local(name:))

        let descriptor = FileTagPresentation.descriptor(
            tags: tags,
            catalogOrder: tags,
            maxVisibleTags: 1
        )

        XCTAssertEqual(descriptor.accessibilityLabel, "标签：" + names.joined(separator: "、"))
        XCTAssertEqual(descriptor.toolTip, names.joined(separator: "、"))
    }

    func testDescriptorUsesInjectedPublicLocalLabelSlotAndNeutralUnknownStyle() {
        let local = FileTag.local(name: "工作")
        let unknownRemote = FileTag(id: "unknown", scopeID: Self.scopes[1].id, name: "Unknown")

        let descriptor = FileTagPresentation.descriptor(
            tags: [unknownRemote, local],
            scopes: Self.scopes,
            maxVisibleTags: 2,
            localLabelIndex: { $0 == "工作" ? 4 : nil }
        )

        XCTAssertEqual(descriptor.visible.map(\.marker), [.localLabel(index: 4), .neutral])
    }

    func testSelectionReducerCalculatesEmptyMixedAndCheckedStates() {
        let tag = FileTag.local(name: "重要")

        XCTAssertEqual(TagSelectionReducer.state(for: tag, itemTags: []), .empty)
        XCTAssertEqual(TagSelectionReducer.state(for: tag, itemTags: [[], []]), .empty)
        XCTAssertEqual(TagSelectionReducer.state(for: tag, itemTags: [[tag], []]), .mixed)
        XCTAssertEqual(TagSelectionReducer.state(for: tag, itemTags: [[tag], [tag]]), .checked)
    }

    func testSelectionReducerTogglesOnlyTheRequestedPendingDelta() {
        let existing = FileTag.local(name: "现有")
        let requested = FileTag.local(name: "请求")
        let pending = FileTagChangeSet(add: [existing], remove: [requested])

        let checked = TagSelectionReducer.toggling(requested, from: .mixed, pending: pending)
        XCTAssertEqual(checked.additions, [existing, requested])
        XCTAssertTrue(checked.removals.isEmpty)

        let emptied = TagSelectionReducer.toggling(requested, from: .checked, pending: checked)
        XCTAssertEqual(emptied.additions, [existing])
        XCTAssertEqual(emptied.removals, [requested])
    }

    func testReusableCellClearsRenderedTagsTooltipAndAccessibilityOnReuse() {
        let cell = FileTagCellView()
        cell.configure(tags: [FileTag.local(name: "重要"), FileTag.local(name: "Review")], availableWidth: 240)

        XCTAssertFalse(cell.contentStack.arrangedSubviews.isEmpty)
        XCTAssertNotNil(cell.toolTip)
        XCTAssertEqual(cell.accessibilityLabel(), "标签：Review、重要")

        cell.configure(tags: [], availableWidth: 240)

        XCTAssertTrue(cell.contentStack.arrangedSubviews.isEmpty)
        XCTAssertNil(cell.toolTip)
        XCTAssertEqual(cell.accessibilityLabel(), "标签：无")
    }

    func testReusableCellRecomputesOverflowWhenColumnResizes() {
        let cell = FileTagCellView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let tags = ["Alpha", "Bravo", "Charlie"].map(FileTag.local(name:))
        cell.configure(tags: tags, availableWidth: 260)
        XCTAssertEqual(cell.contentStack.arrangedSubviews.count, 3)

        cell.frame.size.width = 54
        cell.layoutSubtreeIfNeeded()

        XCTAssertEqual(cell.contentStack.arrangedSubviews.count, 1)
        XCTAssertEqual((cell.contentStack.arrangedSubviews.first as? NSTextField)?.stringValue, "+3")
    }

    func testTagActionRequiresWritableSelectionWithCommonAssociableScope() {
        let personal = Self.scopes[1]
        let writable = Self.item(id: "one", scopes: [personal])
        let secondWritable = Self.item(id: "two", scopes: [personal])
        let localOnly = Self.item(id: "local", scopes: [.local])
        let readOnly = Self.item(id: "readonly", scopes: [personal], isWritable: false)

        XCTAssertEqual(FileTableTagActionAvailability.commonEditableScope(for: [writable, secondWritable]), personal)
        XCTAssertNil(FileTableTagActionAvailability.commonEditableScope(for: []))
        XCTAssertNil(FileTableTagActionAvailability.commonEditableScope(for: [writable, localOnly]))
        XCTAssertNil(FileTableTagActionAvailability.commonEditableScope(for: [writable, readOnly]))
    }

    private static let scopes = [
        FileTagScope.local,
        FileTagScope(
            id: "personal",
            kind: .personal,
            displayName: "个人",
            capabilities: .init(canAssociate: true)
        ),
        FileTagScope(
            id: "team",
            kind: .team,
            displayName: "团队",
            capabilities: .init(canAssociate: true)
        )
    ]

    private static func item(
        id: String,
        scopes: [FileTagScope],
        isWritable: Bool = true
    ) -> FileItem {
        FileItem(
            id: id,
            name: id,
            location: .local(path: "/tmp/\(id)"),
            kind: .file,
            size: nil,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: nil,
            fileExtension: nil,
            isHidden: false,
            isReadable: true,
            isWritable: isWritable,
            tagScopes: scopes,
            supportsTagEditing: true
        )
    }
}
