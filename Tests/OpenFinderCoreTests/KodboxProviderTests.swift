import Foundation
import XCTest
@testable import OpenFinderCore

final class KodboxProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KodboxProviderURLProtocol.reset()
    }

    override func tearDown() {
        KodboxProviderURLProtocol.reset()
        super.tearDown()
    }

    func testListSyntheticRootReturnsSafeNavigationEntriesWithoutExplorerRequest() async throws {
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        let listing = try await provider.list(directory: .init(identifier: "kodbox:user-space-root", displayPath: "/"))

        XCTAssertEqual(listing.current.identifier, "kodbox:user-space-root")
        XCTAssertNil(listing.parent)
        XCTAssertEqual(listing.items.map(\.name), ["Personal", "Desktop", "Team Space", "Shared with Me", "My Shares", "Favorites"])
        XCTAssertEqual(listing.items.map(\.remotePath.identifier), ["{source:5}/", "{source:6}/", "{groupRootSelf}", "{shareToMe}", "{userShare}", "{userFav}"])
        XCTAssertTrue(listing.items.allSatisfy(\.isReadable))
        XCTAssertTrue(listing.items.allSatisfy { !$0.isWritable })
        XCTAssertTrue(recorder.values.allSatisfy { $0.url?.kodboxRoute != "explorer/list/path" })
    }

    func testListRealVirtualRootSendsItsOpaquePathAndNeverServerRoot() async throws {
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/list/path":
                return Self.response(for: request, body: #"{"code":true,"data":{"folderList":[],"fileList":[]}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        _ = try await provider.list(directory: .init(identifier: "{source:5}/", displayPath: "/Personal"))

        let explorerPaths = recorder.values
            .filter { $0.url?.kodboxRoute == "explorer/list/path" }
            .compactMap(\.bodyFormValues?["path"])
        XCTAssertEqual(explorerPaths, ["{source:5}/"])
        XCTAssertFalse(explorerPaths.contains("/"))
    }

    func testListRealVirtualRootReturnsNativeFolderAndFileItems() async throws {
        KodboxProviderURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/list/path":
                return Self.response(for: request, body: #"{"code":true,"data":{"folderList":[{"name":"Projects","path":"{source:5}/Projects/","size":null,"modifyTime":null,"isFolder":null}],"fileList":[{"name":"notes.txt","path":"{source:5}/notes.txt","size":42,"modifyTime":1700000010,"isFolder":0}]}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        let listing = try await provider.list(directory: .init(identifier: "{source:5}/", displayPath: "/Personal"))

        XCTAssertEqual(listing.items.map(\.name), ["Projects", "notes.txt"])
        XCTAssertEqual(listing.items.map(\.kind), [.directory, .file])
        XCTAssertEqual(listing.items.map(\.remotePath.identifier), ["{source:5}/Projects/", "{source:5}/notes.txt"])
        XCTAssertEqual(listing.items.map(\.size), [nil, 42])
        XCTAssertEqual(listing.items.map(\.modificationDate), [nil, Date(timeIntervalSince1970: 1_700_000_010)])
    }

    func testListMapsPersonalTags() async throws {
        let accountID = Self.fixtureAccountID
        KodboxProviderURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/list/path":
                return Self.response(
                    for: request,
                    body: #"""
                    {"code":true,"data":{"folderList":[],"fileList":[
                      {"name":"notes.txt","path":"{source:5}/notes.txt","size":42,"modifyTime":1700000010,
                       "sourceInfo":{"tagInfo":[null,0,"not-a-tag",{"tagID":"7","name":"Review","style":"label-blue-normal"},{"tagID":7,"name":"Review","style":"label-blue-normal"},{"tagID":"bad"}]}},
                      {"name":"missing.txt","path":"{source:5}/missing.txt","size":1,"modifyTime":null},
                      {"name":"null.txt","path":"{source:5}/null.txt","size":1,"modifyTime":null,"sourceInfo":{"tagInfo":null}},
                      {"name":"zero.txt","path":"{source:5}/zero.txt","size":1,"modifyTime":null,"sourceInfo":{"tagInfo":0}},
                      {"name":"empty.txt","path":"{source:5}/empty.txt","size":1,"modifyTime":null,"sourceInfo":{"tagInfo":[]}},
                      {"name":"neutral.txt","path":"{source:5}/neutral.txt","size":1,"modifyTime":null,
                       "sourceInfo":{"tagInfo":[{"tagID":"8","name":"Neutral","style":"future-style"},{"tagID":0,"name":"Invalid","style":"label-red-normal"},{"tagID":"9"}]}}
                    ]}}
                    """#
                )
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = makeProvider(accountID: accountID)

        let listing = try await provider.list(directory: .init(identifier: "{source:5}/", displayPath: "/Personal"))

        let personalScope = Self.personalScope(accountID: accountID)
        XCTAssertTrue(listing.capabilities.supportsTags)
        XCTAssertEqual(listing.items.first?.tags, [
            .init(id: "7", scopeID: personalScope.id, name: "Review", color: .blue)
        ])
        XCTAssertEqual(listing.items.first?.tagScopes, [personalScope])
        XCTAssertTrue(listing.items.first?.supportsTagEditing ?? false)
        XCTAssertTrue(listing.items.dropFirst().prefix(4).allSatisfy { $0.tags.isEmpty })
        XCTAssertEqual(listing.items.last?.tags, [
            .init(id: "8", scopeID: personalScope.id, name: "Neutral", color: .none)
        ])
    }

    func testPersonalTagCatalogAndAssociationRoutes() async throws {
        let accountID = Self.fixtureAccountID
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/tag/get", "explorer/tag/add", "explorer/tag/edit", "explorer/tag/remove":
                return Self.response(for: request, body: Self.personalTagCatalogResponse)
            case "explorer/tag/filesAddToTag", "explorer/tag/filesRemoveFromTag":
                return Self.response(for: request, body: #"{"code":true,"data":{}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = makeProvider(accountID: accountID)
        let location = Self.personalLocation(accountID: accountID, path: "{source:5}/")
        let item = Self.personalFileItem(accountID: accountID)

        let catalog = try await provider.tagCatalog(for: location)
        XCTAssertEqual(catalog.scopes.count, 1)
        let scope = try XCTUnwrap(catalog.scopes.first)
        XCTAssertEqual(scope, Self.personalScope(accountID: accountID))
        XCTAssertEqual(catalog.tags, [
            .init(id: "7", scopeID: scope.id, name: "Review", color: .blue),
            .init(id: "8", scopeID: scope.id, name: "Neutral", color: .none)
        ])

        _ = try await provider.mutate(.createTag(name: "Plan", groupID: nil), in: scope)
        _ = try await provider.mutate(.renameTag(id: "7", name: "Reviewed"), in: scope)
        _ = try await provider.mutate(.deleteTag(id: "8"), in: scope)

        let noOp = try await provider.apply(.init(), to: [item])
        XCTAssertEqual(noOp, .init())

        let result = try await provider.apply(
            .init(
                add: [.init(id: "7", scopeID: scope.id, name: "Review", color: .blue)],
                remove: [.init(id: "8", scopeID: scope.id, name: "Neutral")]
            ),
            to: [item]
        )
        XCTAssertEqual(result, TagApplyResult(appliedItemIDs: [item.id]))

        let tagRequests = recorder.values.filter { request in
            switch request.url?.kodboxRoute {
            case "explorer/tag/get", "explorer/tag/add", "explorer/tag/edit", "explorer/tag/remove", "explorer/tag/filesAddToTag", "explorer/tag/filesRemoveFromTag":
                true
            default:
                false
            }
        }
        XCTAssertEqual(tagRequests.map { $0.url?.kodboxRoute }, [
            "explorer/tag/get",
            "explorer/tag/add",
            "explorer/tag/edit",
            "explorer/tag/remove",
            "explorer/tag/filesAddToTag",
            "explorer/tag/filesRemoveFromTag"
        ])
        XCTAssertEqual(tagRequests.map(\.bodyFormValues), [
            nil,
            ["name": "Plan", "style": "label-grey-normal"],
            ["tagID": "7", "name": "Reviewed"],
            ["tagID": "8"],
            ["tagID": "7", "files": "{source:5}/notes.txt"],
            ["tagID": "8", "files": "{source:5}/notes.txt"]
        ])
    }

    func testPersonalTagAssociationRecordsFailureAndContinuesLaterItems() async throws {
        let accountID = Self.fixtureAccountID
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/tag/filesAddToTag":
                if request.bodyFormValues?["files"] == "{source:5}/denied.txt" {
                    return Self.response(for: request, body: #"{"code":false,"message":"permission denied","data":null}"#)
                }
                return Self.response(for: request, body: #"{"code":true,"data":{}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = makeProvider(accountID: accountID)
        let tag = FileTag(id: "7", scopeID: Self.personalScope(accountID: accountID).id, name: "Review")
        let denied = Self.personalFileItem(accountID: accountID, path: "{source:5}/denied.txt")
        let allowed = Self.personalFileItem(accountID: accountID, path: "{source:5}/allowed.txt")

        let result = try await provider.apply(.init(add: [tag]), to: [denied, allowed])

        XCTAssertEqual(result.appliedItemIDs, [allowed.id])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.itemID, denied.id)
        XCTAssertEqual(result.failures.first?.tag, tag)
        XCTAssertEqual(
            recorder.values.filter { $0.url?.kodboxRoute == "explorer/tag/filesAddToTag" }.compactMap(\.bodyFormValues?["files"]),
            ["{source:5}/denied.txt", "{source:5}/allowed.txt"]
        )
    }

    func testPersonalTagAssociationRejectsUnsafePathsAndUnknownScopeWithoutRequest() async throws {
        let accountID = Self.fixtureAccountID
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            throw KodboxProviderFixtureError.unexpectedRequest
        }
        let provider = makeProvider(accountID: accountID)
        let personalTag = FileTag(id: "7", scopeID: Self.personalScope(accountID: accountID).id, name: "Review")
        let unknownTag = FileTag(id: "999", scopeID: "kodbox:other:personal", name: "Unknown")
        let unsafePaths = [
            KodboxProvider.syntheticRootIdentifier,
            "/",
            "{source:5}/unsafe,comma.txt",
            "{source:5}/unsafe__*@*__sentinel.txt"
        ]

        for path in unsafePaths {
            let result = try await provider.apply(
                .init(add: [personalTag]),
                to: [Self.personalFileItem(accountID: accountID, path: path)]
            )
            XCTAssertEqual(result.appliedItemIDs, [])
            XCTAssertEqual(result.failures.count, 1, "Expected unsafe path \(path) to fail locally")
        }
        let unknownScope = try await provider.apply(
            .init(add: [unknownTag]),
            to: [Self.personalFileItem(accountID: accountID)]
        )
        XCTAssertEqual(unknownScope.appliedItemIDs, [])
        XCTAssertEqual(unknownScope.failures.count, 1)
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testListMapsTeamTagsAndPermissions() async throws {
        let accountID = Self.fixtureAccountID
        KodboxProviderURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/list/path":
                return Self.response(
                    for: request,
                    body: #"""
                    {"code":true,"data":{"folderList":[],"fileList":[
                      {"name":"admin.txt","path":"{group:42}/admin.txt","size":1,"modifyTime":null,"targetType":"group","targetID":"42","canWrite":true,
                       "sourceInfo":{"isGroupRoot":true,"isGroupHasTag":true,"groupTagInfo":[{"id":9,"name":"Approved","groupInfo":{"id":2,"name":"Status"}}]}},
                      {"name":"writer.txt","path":"{group:42}/writer.txt","size":1,"modifyTime":null,"targetType":"group","targetID":42,"canWrite":true,
                       "sourceInfo":{"isGroupRoot":false,"isGroupHasTag":true,"groupTagInfo":[]}},
                      {"name":"readonly.txt","path":"{group:42}/readonly.txt","size":1,"modifyTime":null,"targetType":"group","targetID":"42","canWrite":false,
                       "sourceInfo":{"isGroupRoot":false,"isGroupHasTag":true,"groupTagInfo":[]}}
                    ]}}
                    """#
                )
            case "explorer/tagGroup/get":
                return Self.response(for: request, body: Self.teamTagCatalogResponse)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = makeProvider(accountID: accountID)

        let directory = RemotePath(identifier: "{group:42}/", displayPath: "/Team")
        let listing = try await provider.list(directory: directory)

        let administrator = try XCTUnwrap(listing.items.first { $0.name == "admin.txt" })
        let writer = try XCTUnwrap(listing.items.first { $0.name == "writer.txt" })
        let readOnly = try XCTUnwrap(listing.items.first { $0.name == "readonly.txt" })
        let administratorScope = try XCTUnwrap(administrator.tagScopes.first { $0.kind == .team })
        let writerScope = try XCTUnwrap(writer.tagScopes.first { $0.kind == .team })
        let readOnlyScope = try XCTUnwrap(readOnly.tagScopes.first { $0.kind == .team })
        XCTAssertEqual(administrator.tags, [
            .init(id: "9", scopeID: administratorScope.id, name: "Approved", groupID: "2")
        ])
        XCTAssertEqual(administratorScope, Self.teamScope(accountID: accountID, groupID: "42", canManage: true, canAssociate: true))
        XCTAssertEqual(writerScope, Self.teamScope(accountID: accountID, groupID: "42", canManage: false, canAssociate: true))
        XCTAssertEqual(readOnlyScope, Self.teamScope(accountID: accountID, groupID: "42", canManage: false, canAssociate: false))
        XCTAssertTrue(administrator.supportsTagEditing)
        XCTAssertTrue(writer.supportsTagEditing)
        XCTAssertFalse(readOnly.supportsTagEditing)

        let catalog = try await provider.tagCatalog(for: .remote(.init(accountID: accountID, connectorID: .kodbox, path: directory)))
        XCTAssertEqual(catalog.scopes, [administratorScope])
    }

    func testTeamTagCatalogAndAssociationRoutesRequireMatchingGroup() async throws {
        let accountID = Self.fixtureAccountID
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/tagGroup/get":
                return Self.response(for: request, body: Self.teamTagCatalogResponse)
            case "explorer/tagGroup/filesAddToTag", "explorer/tagGroup/filesRemoveFromTag":
                return Self.response(for: request, body: #"{"code":true,"data":{}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = makeProvider(accountID: accountID)
        let scope = Self.teamScope(accountID: accountID, groupID: "42", canManage: true, canAssociate: true)
        let item = Self.teamFileItem(accountID: accountID, groupID: "42", scope: scope)
        let teamTag = FileTag(id: "9", scopeID: scope.id, name: "Approved", groupID: "2")

        let catalog = try await provider.tagCatalog(for: Self.teamLocation(accountID: accountID, groupID: "42"))
        XCTAssertEqual(catalog.groups, [
            .init(id: "2", scopeID: scope.id, name: "Status"),
            .init(id: "3", scopeID: scope.id, name: "Priority")
        ])
        let concurrentTag = FileTag(id: "10", scopeID: scope.id, name: "Concurrent", groupID: "2")
        XCTAssertEqual(catalog.tags, [teamTag, concurrentTag])

        let result = try await provider.apply(.init(add: [teamTag], remove: [concurrentTag]), to: [item])
        XCTAssertEqual(result, .init(appliedItemIDs: [item.id]))

        let associationRequests = recorder.values.filter { request in
            switch request.url?.kodboxRoute {
            case "explorer/tagGroup/filesAddToTag", "explorer/tagGroup/filesRemoveFromTag":
                true
            default:
                false
            }
        }
        XCTAssertEqual(associationRequests.map { $0.url?.kodboxRoute }, [
            "explorer/tagGroup/filesAddToTag",
            "explorer/tagGroup/filesRemoveFromTag"
        ])
        XCTAssertEqual(associationRequests.map(\.bodyFormValues), [
            ["groupID": "42", "tagID": "9", "files": "{group:42}/notes.txt"],
            ["groupID": "42", "tagID": "10", "files": "{group:42}/notes.txt"]
        ])

        let wrongGroup = Self.teamFileItem(accountID: accountID, groupID: "7", scope: scope)
        let mismatch = try await provider.apply(.init(add: [teamTag]), to: [wrongGroup])
        XCTAssertEqual(mismatch.appliedItemIDs, [])
        XCTAssertEqual(mismatch.failures.count, 1)
        XCTAssertEqual(associationRequests.count, 2)
    }

    func testTeamTagAssociationRejectsMixedOrForeignScopesBeforeRequests() async throws {
        let accountID = Self.fixtureAccountID
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            throw KodboxProviderFixtureError.unexpectedRequest
        }
        let provider = makeProvider(accountID: accountID)
        let teamScope = Self.teamScope(accountID: accountID, groupID: "42", canManage: true, canAssociate: true)
        let item = Self.teamFileItem(accountID: accountID, groupID: "42", scope: teamScope)
        let teamTag = FileTag(id: "9", scopeID: teamScope.id, name: "Approved", groupID: "2")
        let personalTag = FileTag(id: "7", scopeID: Self.personalScope(accountID: accountID).id, name: "Review")

        let mixed = try await provider.apply(.init(add: [teamTag, personalTag]), to: [item])
        XCTAssertEqual(mixed.appliedItemIDs, [])
        XCTAssertEqual(mixed.failures.map(\.tag), [teamTag, personalTag])
        XCTAssertTrue(recorder.values.isEmpty)

        let foreignRecorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            foreignRecorder.append(request)
            throw KodboxProviderFixtureError.unexpectedRequest
        }
        let foreign = FileTag(id: "9", scopeID: "kodbox:other-account:team:42", name: "Approved", groupID: "2")
        let foreignResult = try await provider.apply(.init(add: [foreign]), to: [item])
        XCTAssertEqual(foreignResult.appliedItemIDs, [])
        XCTAssertEqual(foreignResult.failures.map(\.tag), [foreign])
        XCTAssertTrue(foreignRecorder.values.isEmpty)
    }

    func testTeamTagCatalogMutationsUseMinimalDiff() async throws {
        let accountID = Self.fixtureAccountID
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/tagGroup/get":
                return Self.response(for: request, body: Self.teamTagCatalogResponse)
            case "explorer/tagGroup/set":
                return Self.response(for: request, body: Self.teamTagCatalogResponse)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = makeProvider(accountID: accountID)
        let scope = Self.teamScope(accountID: accountID, groupID: "42", canManage: true, canAssociate: true)

        _ = try await provider.mutate(.createTag(name: "Blocked", groupID: "2"), in: scope)
        let renamed = try await provider.mutate(.renameTag(id: "9", name: "Reviewed"), in: scope)
        _ = try await provider.mutate(.moveTag(id: "9", groupID: "3"), in: scope)
        let deleted = try await provider.mutate(.deleteTag(id: "9"), in: scope)

        let setRequests = recorder.values.filter { $0.url?.kodboxRoute == "explorer/tagGroup/set" }
        XCTAssertEqual(setRequests.compactMap { $0.bodyFormValues?["groupID"] }, ["42", "42", "42", "42"])
        XCTAssertEqual(setRequests.compactMap { $0.bodyFormValues?["diff"] }.map(Self.canonicalJSON), [
            #"{"list":{"add":[{"beforeID":"10","val":{"group":2,"name":"Blocked"}}],"edit":{},"remove":[],"sort":{"idArr":[],"isChange":false}}}"#,
            #"{"list":{"add":[],"edit":{"9":{"name":{"type":"edit","val":"Reviewed"}}},"remove":[],"sort":{"idArr":[],"isChange":false}}}"#,
            #"{"list":{"add":[],"edit":{"9":{"group":{"type":"edit","val":3}}},"remove":[],"sort":{"idArr":[],"isChange":false}}}"#,
            #"{"list":{"add":[],"edit":{},"remove":["9"],"sort":{"idArr":[],"isChange":false}}}"#
        ])
        XCTAssertEqual(renamed.tags, [
            .init(id: "9", scopeID: scope.id, name: "Approved", groupID: "2"),
            .init(id: "10", scopeID: scope.id, name: "Concurrent", groupID: "2")
        ])
        XCTAssertEqual(deleted.providerState?["kodbox.team.deleteRemovesAssociations"], "true")
        XCTAssertEqual(deleted.providerState?["kodbox.team.deletedTagID"], "9")
    }

    func testMutationsUseNativeRoutesWithOpaqueIdentifiersAndNeverServerRoot() async throws {
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/index/mkdir", "explorer/index/mkfile", "explorer/index/pathRename", "explorer/index/pathDelete", "explorer/index/pathCopyTo", "explorer/index/pathCuteTo":
                return Self.response(for: request, body: #"{"code":true,"data":{}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())
        let parent = RemotePath(identifier: "{source:5}/projects/", displayPath: "/Personal/projects")
        let source = RemotePath(identifier: "{source:5}/projects/original.txt", displayPath: "/Personal/projects/original.txt")
        let destination = RemotePath(identifier: "{source:6}/archive/", displayPath: "/Desktop/archive")

        try await provider.createDirectory(in: parent, named: "new folder")
        try await provider.createFile(in: parent, named: "draft.txt")
        try await provider.rename(item: source, named: "renamed.txt")
        try await provider.delete(item: source)
        try await provider.copy(item: source, to: destination, named: "copied.txt")
        try await provider.move(item: source, to: destination, named: "moved.txt")

        let mutations = recorder.values.filter { request in
            switch request.url?.kodboxRoute {
            case "explorer/index/mkdir", "explorer/index/mkfile", "explorer/index/pathRename", "explorer/index/pathDelete", "explorer/index/pathCopyTo", "explorer/index/pathCuteTo":
                true
            default:
                false
            }
        }
        XCTAssertEqual(mutations.map { $0.url?.kodboxRoute }, [
            "explorer/index/mkdir",
            "explorer/index/mkfile",
            "explorer/index/pathRename",
            "explorer/index/pathDelete",
            "explorer/index/pathCopyTo",
            "explorer/index/pathCuteTo"
        ])
        XCTAssertEqual(mutations.map(\.bodyFormValues), [
            ["path": "{source:5}/projects/new folder"],
            ["path": "{source:5}/projects/draft.txt"],
            ["path": "{source:5}/projects/original.txt", "newName": "renamed.txt"],
            ["dataArr": #"[{"path":"{source:5}/projects/original.txt"}]"#],
            ["dataArr": #"[{"path":"{source:5}/projects/original.txt","name":"copied.txt"}]"#, "path": "{source:6}/archive/"],
            ["dataArr": #"[{"path":"{source:5}/projects/original.txt","name":"moved.txt"}]"#, "path": "{source:6}/archive/"]
        ])
        XCTAssertFalse(mutations.contains { $0.bodyFormValues?.values.contains("/") == true })
    }

    func testMutationsRejectNavigationRootAndServerRootWithoutRequest() async throws {
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            throw KodboxProviderFixtureError.unexpectedRequest
        }
        let provider = KodboxProvider(session: makeSession())

        do {
            try await provider.createDirectory(
                in: .init(identifier: KodboxProvider.syntheticRootIdentifier, displayPath: "/"),
                named: "blocked"
            )
            XCTFail("Expected the navigation root to reject mutations")
        } catch {}
        do {
            try await provider.createFile(
                in: .init(identifier: "/", displayPath: "/"),
                named: "blocked.txt"
            )
            XCTFail("Expected the Kodbox server root to reject mutations")
        } catch {}

        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testUploadPostsMultipartFileToOpaqueParentAndNeverServerRoot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("local.txt")
        try Data("file contents".utf8).write(to: localFile)
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/upload/fileUpload":
                return Self.response(for: request, body: #"{"code":true,"data":{}}"#)
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())
        let parent = RemotePath(identifier: "{source:5}/projects/", displayPath: "/Personal/projects")

        let taskID = try await provider.upload(localURL: localFile, to: parent, named: "remote.txt")

        let upload = try XCTUnwrap(recorder.values.first { $0.url?.kodboxRoute == "explorer/upload/fileUpload" })
        XCTAssertFalse(taskID.uuidString.isEmpty)
        XCTAssertEqual(upload.httpMethod, "POST")
        XCTAssertTrue(upload.url?.path.hasSuffix("index.php") == true && upload.url?.kodboxRoute == "explorer/upload/fileUpload")
        XCTAssertTrue(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertNotEqual(upload.url?.path, "/")
    }

    func testDownloadStreamsToTemporaryFileThenPublishesAtDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/index/fileOut":
                return Self.response(for: request, contentType: "application/octet-stream", data: Data("downloaded contents".utf8))
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())
        let item = RemotePath(identifier: "{source:5}/projects/report.txt", displayPath: "/Personal/projects/report.txt")

        _ = try await provider.download(item: item, to: destination)

        let download = try XCTUnwrap(recorder.values.first { $0.url?.kodboxRoute == "explorer/index/fileOut" })
        XCTAssertEqual(download.httpMethod, "GET")
        XCTAssertEqual(download.url?.queryValue(named: "path"), "{source:5}/projects/report.txt")
        XCTAssertEqual(download.url?.queryValue(named: "download"), "1")
        XCTAssertFalse(download.url?.queryValue(named: "path") == "/")
        XCTAssertEqual(try Data(contentsOf: destination), Data("downloaded contents".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["download.txt"])
    }

    func testDownloadDoesNotFailAfterTemporaryFileIsMovedToDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        KodboxProviderURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/index/fileOut":
                return Self.response(for: request, contentType: "application/octet-stream", data: Data("downloaded contents".utf8))
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        let taskID = try await provider.download(
            item: .init(identifier: "{source:5}/projects/report.txt", displayPath: "/Personal/projects/report.txt"),
            to: destination
        )

        XCTAssertFalse(taskID.uuidString.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), Data("downloaded contents".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["download.txt"])
    }

    func testDownloadRejectsExistingDestinationWithoutRequest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        try Data("existing".utf8).write(to: destination)
        let recorder = KodboxProviderRequestRecorder()
        KodboxProviderURLProtocol.handler = { request in
            recorder.append(request)
            throw KodboxProviderFixtureError.unexpectedRequest
        }
        let provider = KodboxProvider(session: makeSession())

        do {
            _ = try await provider.download(
                item: .init(identifier: "{source:5}/projects/report.txt", displayPath: "/Personal/projects/report.txt"),
                to: destination
            )
            XCTFail("Expected existing destination to be rejected")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testDownloadFailureLeavesNoDestinationOrTemporaryFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        KodboxProviderURLProtocol.handler = { request in
            switch request.url?.kodboxRoute {
            case "user/index/loginSubmit":
                return Self.response(for: request, body: #"{"code":true,"data":{"accessToken":"fixture-access-token"}}"#)
            case "user/view/options":
                return Self.response(for: request, body: Self.optionsResponse)
            case "explorer/index/fileOut":
                return Self.response(for: request, status: 502, contentType: "text/plain", data: Data("failure".utf8))
            default:
                throw KodboxProviderFixtureError.unexpectedRequest
            }
        }
        let provider = KodboxProvider(session: makeSession())

        do {
            _ = try await provider.download(
                item: .init(identifier: "{source:5}/projects/report.txt", displayPath: "/Personal/projects/report.txt"),
                to: destination
            )
            XCTFail("Expected failed download")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func makeSession() -> KodboxAPISession {
        KodboxAPISession(
            baseURL: URL(string: "https://kodbox.test/")!,
            credentials: .init(username: "alice", password: "pass"),
            session: KodboxHTTPClient.ephemeralSession(protocolClasses: [KodboxProviderURLProtocol.self])
        )
    }

    private func makeProvider(accountID: UUID = fixtureAccountID) -> KodboxProvider {
        KodboxProvider(session: makeSession(), accountID: accountID)
    }

    private static let fixtureAccountID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private static func personalScope(accountID: UUID) -> FileTagScope {
        .init(
            id: "kodbox:\(accountID.uuidString):personal",
            kind: .personal,
            displayName: "Kodbox Personal",
            capabilities: .init(
                canAssociate: true,
                canCreate: true,
                canRename: true,
                canUpdateStyle: true,
                canDelete: true
            )
        )
    }

    private static func teamScope(accountID: UUID, groupID: String, canManage: Bool, canAssociate: Bool) -> FileTagScope {
        .init(
            id: "kodbox:\(accountID.uuidString):team:\(groupID)",
            kind: .team,
            displayName: "Kodbox Team \(groupID)",
            capabilities: .init(
                canAssociate: canAssociate,
                canCreate: canManage,
                canRename: canManage,
                canDelete: canManage,
                canOrganizeGroups: canManage
            )
        )
    }

    private static func personalLocation(accountID: UUID, path: String) -> Location {
        .remote(.init(accountID: accountID, connectorID: .kodbox, path: .init(identifier: path, displayPath: "/Personal")))
    }

    private static func personalFileItem(accountID: UUID, path: String = "{source:5}/notes.txt") -> FileItem {
        FileItem(
            id: "remote:\(accountID.uuidString):\(path)",
            name: URL(fileURLWithPath: path).lastPathComponent,
            location: personalLocation(accountID: accountID, path: path),
            kind: .file,
            size: 42,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: "text/plain",
            fileExtension: "txt",
            isHidden: false,
            isReadable: true,
            isWritable: true,
            supportsTagEditing: true
        )
    }

    private static func teamLocation(accountID: UUID, groupID: String, path: String? = nil) -> Location {
        let identifier = path ?? "{group:\(groupID)}/"
        return .remote(.init(accountID: accountID, connectorID: .kodbox, path: .init(identifier: identifier, displayPath: "/Team")))
    }

    private static func teamFileItem(accountID: UUID, groupID: String, scope: FileTagScope) -> FileItem {
        let path = "{group:\(groupID)}/notes.txt"
        return FileItem(
            id: "remote:\(accountID.uuidString):\(path)",
            name: "notes.txt",
            location: teamLocation(accountID: accountID, groupID: groupID, path: path),
            kind: .file,
            size: 42,
            modificationDate: nil,
            creationDate: nil,
            uti: nil,
            mimeType: "text/plain",
            fileExtension: "txt",
            isHidden: false,
            isReadable: true,
            isWritable: true,
            tagScopes: [scope],
            supportsTagEditing: true
        )
    }

    private static let optionsResponse = #"{"code":true,"data":{"version":"1.68.10","user":{"myhome":"{source:5}/","desktop":"{source:6}/"}}}"#
    private static let personalTagCatalogResponse = #"{"code":true,"data":[{"id":7,"name":"Review","style":"label-blue-normal"},{"id":"8","name":"Neutral","style":"future-style"},{"id":0,"name":"Invalid","style":"label-red-normal"},{"id":"bad"}]}"#
    private static let teamTagCatalogResponse = #"{"code":true,"data":{"group":[{"id":2,"name":"Status"},{"id":3,"name":"Priority"}],"list":[{"id":9,"name":"Approved","group":2},{"id":10,"name":"Concurrent","group":2}]}}"#

    private static func canonicalJSON(_ string: String) -> String {
        let object = try! JSONSerialization.jsonObject(with: Data(string.utf8))
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func response(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        response(for: request, contentType: "application/json", data: Data(body.utf8))
    }

    private static func response(for request: URLRequest, status: Int = 200, contentType: String, data: Data) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!,
            data
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderKodboxProvider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum KodboxProviderFixtureError: Error {
    case unexpectedRequest
}

private final class KodboxProviderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: KodboxProviderFixtureError.unexpectedRequest)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class KodboxProviderRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var values: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        storage.append(request)
    }
}

private extension URL {
    var kodboxRoute: String? {
        query?
            .split(separator: "&", maxSplits: 1)
            .first
            .map(String.init)
    }

    func queryValue(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
    }
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let httpBodyStream else { return nil }

        httpBodyStream.open()
        defer { httpBodyStream.close() }
        var buffer = [UInt8](repeating: 0, count: 1_024)
        var body = Data()
        while true {
            let bytesRead = httpBodyStream.read(&buffer, maxLength: buffer.count)
            guard bytesRead >= 0 else { return nil }
            guard bytesRead > 0 else { return body }
            body.append(buffer, count: bytesRead)
        }
    }

    var bodyFormValues: [String: String]? {
        guard let data = bodyData else { return nil }

        guard let body = String(data: data, encoding: .utf8) else { return nil }
        return URLComponents(string: "?\(body)")?.queryItems?.reduce(into: [:]) { result, item in
            result[item.name] = item.value
        }
    }
}
