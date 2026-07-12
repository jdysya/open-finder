import Foundation
import XCTest
@testable import OpenFinderCore

final class FileTagTests: XCTestCase {
    func testChangeSetDeduplicatesAndKeepsAddsAndRemovesDisjoint() {
        let scope = FileTagScope.local
        let red = FileTag.local(name: "Red")
        let result = FileTagChangeSet(add: [red, red], remove: [red])

        XCTAssertTrue(result.additions.isEmpty)
        XCTAssertEqual(result.removals, [red])
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(scope.kind, .local)
    }

    func testLegacyFileItemDecodesWithoutTagKeys() throws {
        let data = Data(#"{"id":"local:/tmp/a","name":"a","location":{"type":"local","path":"/tmp/a"},"kind":"file","size":null,"modificationDate":null,"creationDate":null,"uti":null,"mimeType":null,"fileExtension":null,"isHidden":false,"isReadable":true,"isWritable":true}"#.utf8)

        let item = try JSONDecoder().decode(FileItem.self, from: data)

        XCTAssertEqual(item.tags, [])
        XCTAssertEqual(item.tagScopes, [])
        XCTAssertFalse(item.supportsTagEditing)
    }

    func testTagIdentityIncludesScopeIDAndOpaqueID() {
        let original = FileTag(id: "7", scopeID: "personal", name: "Review", color: .blue)
        let renamed = FileTag(id: "7", scopeID: "personal", name: "Reviewed", color: .green)
        let sameIDInAnotherScope = FileTag(id: "7", scopeID: "team:42", name: "Review", color: .blue)

        XCTAssertEqual(original, renamed)
        XCTAssertNotEqual(original, sameIDInAnotherScope)
        XCTAssertEqual(Set([original, renamed, sameIDInAnotherScope]).count, 2)
    }

    func testLocalTagIdentityIsStableAndUsesExactName() {
        let first = FileTag.local(name: "Red")
        let repeated = FileTag.local(name: "Red")
        let differentCase = FileTag.local(name: "red")

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.scopeID, FileTagScope.local.id)
        XCTAssertNotEqual(first, differentCase)
    }

    func testKodboxStylesMapToKnownColorsAndUnknownStylesAreNeutral() {
        XCTAssertEqual(FileTagColor(kodboxStyle: "label-red-normal"), .red)
        XCTAssertEqual(FileTagColor(kodboxStyle: "label-blue-normal"), .blue)
        XCTAssertEqual(FileTagColor(kodboxStyle: "label-purple-normal"), .purple)
        XCTAssertEqual(FileTagColor(kodboxStyle: "not-a-kodbox-style"), .none)
        XCTAssertEqual(FileTagColor(kodboxStyle: nil), .none)
    }

    func testEmptyChangeSetIsEmpty() {
        let result = FileTagChangeSet()

        XCTAssertTrue(result.additions.isEmpty)
        XCTAssertTrue(result.removals.isEmpty)
        XCTAssertTrue(result.isEmpty)
    }

    func testScopeCapabilitiesExposeIndependentPermissionFlags() {
        let capabilities = FileTagScopeCapabilities(
            canAssociate: true,
            canCreate: true,
            canRename: false,
            canUpdateStyle: true,
            canDelete: false,
            canOrganizeGroups: true
        )
        let scope = FileTagScope(
            id: "team:42",
            kind: .team,
            displayName: "Team 42",
            capabilities: capabilities
        )

        XCTAssertTrue(scope.capabilities.canAssociate)
        XCTAssertTrue(scope.capabilities.canCreate)
        XCTAssertFalse(scope.capabilities.canRename)
        XCTAssertTrue(scope.capabilities.canUpdateStyle)
        XCTAssertFalse(scope.capabilities.canDelete)
        XCTAssertTrue(scope.capabilities.canOrganizeGroups)
    }

    func testCatalogMutationsAndApplyResultsUseTypedValues() {
        let scope = FileTagScope(id: "team:42", kind: .team, displayName: "Team 42", capabilities: .none)
        let group = FileTagGroup(id: "2", scopeID: scope.id, name: "Status")
        let tag = FileTag(id: "9", scopeID: scope.id, name: "Approved", groupID: group.id)
        let catalog = FileTagCatalog(scopes: [scope], groups: [group], tags: [tag])
        let mutation = FileTagCatalogMutation.moveTag(id: tag.id, groupID: "3")
        let failure = TagApplyFailure(itemID: "remote:1", tag: tag, message: "Permission denied")
        let result = TagApplyResult(appliedItemIDs: ["remote:2"], failures: [failure])

        XCTAssertEqual(catalog.tags, [tag])
        XCTAssertEqual(mutation, .moveTag(id: "9", groupID: "3"))
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(result.appliedItemIDs, ["remote:2"])
        XCTAssertEqual(result.failures, [failure])
    }
}
