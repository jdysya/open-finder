import AppKit
import XCTest
import OpenFinderCore
@testable import OpenFinderApp

@MainActor
final class AppInteractionTests: XCTestCase {
    func testPluginWorkspaceUsesCurrentLocalDirectoryForOutputs() {
        let currentDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let taskID = UUID()

        let workspace = PluginWorkspace.make(taskID: taskID, currentLocation: .local(path: currentDirectory.path))

        XCTAssertEqual(workspace.outputDirectory.standardizedFileURL, currentDirectory.standardizedFileURL)
        XCTAssertTrue(workspace.tempDirectory.path.contains(taskID.uuidString))
    }

    func testPluginWorkspaceFallsBackToTemporaryOutputForRemoteLocations() {
        let taskID = UUID()
        let accountID = UUID()

        let workspace = PluginWorkspace.make(taskID: taskID, currentLocation: .webDAV(accountID: accountID, path: "/remote"))

        XCTAssertTrue(workspace.outputDirectory.path.contains(taskID.uuidString))
        XCTAssertTrue(workspace.outputDirectory.lastPathComponent == "output")
    }

    func testKeyboardShortcutsMapToFileTableActions() {
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "\r", keyCode: 36, modifiers: []), .rename)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: " ", keyCode: 49, modifiers: []), .quickLook)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "\u{7F}", keyCode: 51, modifiers: []), .trash)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "\u{7F}", keyCode: 51, modifiers: [.command]), .trash)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: nil, keyCode: 120, modifiers: []), .rename)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "o", keyCode: 31, modifiers: [.command]), .open)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: nil, keyCode: 125, modifiers: [.command]), .open)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "[", keyCode: 33, modifiers: [.command]), .goBack)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "]", keyCode: 30, modifiers: [.command]), .goForward)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: nil, keyCode: 126, modifiers: [.command]), .goUp)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "r", keyCode: 15, modifiers: [.command]), .refresh)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: ".", keyCode: 47, modifiers: [.command, .shift]), .toggleHidden)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "n", keyCode: 45, modifiers: [.command]), .createFile)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "n", keyCode: 45, modifiers: [.command, .shift]), .createFolder)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "c", keyCode: 8, modifiers: [.command, .option]), .copyToOtherPane)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "v", keyCode: 9, modifiers: [.command, .option]), .moveToOtherPane)
        XCTAssertEqual(FileTableKeyboardShortcut.action(characters: "a", keyCode: 0, modifiers: [.command]), .selectAll)
    }

    func testPointerSelectionClearsOnlyPlainEmptyAreaClicks() {
        XCTAssertTrue(FileTablePointerSelection.shouldClearSelection(clickedRow: -1, modifiers: []))
        XCTAssertFalse(FileTablePointerSelection.shouldClearSelection(clickedRow: 0, modifiers: []))
        XCTAssertFalse(FileTablePointerSelection.shouldClearSelection(clickedRow: -1, modifiers: [.command]))
        XCTAssertFalse(FileTablePointerSelection.shouldClearSelection(clickedRow: -1, modifiers: [.shift]))
    }

    func testModifierClickSelectionSupportsCommandToggleAndShiftRange() {
        let commandAdded = FileTableSelectionReducer.selection(
            selectedRows: IndexSet(integer: 1),
            anchorRow: 1,
            clickedRow: 3,
            rowCount: 6,
            modifiers: [.command]
        )
        XCTAssertEqual(commandAdded.selectedRows, IndexSet([1, 3]))
        XCTAssertEqual(commandAdded.anchorRow, 3)

        let commandRemoved = FileTableSelectionReducer.selection(
            selectedRows: commandAdded.selectedRows,
            anchorRow: commandAdded.anchorRow,
            clickedRow: 1,
            rowCount: 6,
            modifiers: [.command]
        )
        XCTAssertEqual(commandRemoved.selectedRows, IndexSet(integer: 3))
        XCTAssertEqual(commandRemoved.anchorRow, 3)

        let shiftRange = FileTableSelectionReducer.selection(
            selectedRows: IndexSet(integer: 2),
            anchorRow: 2,
            clickedRow: 5,
            rowCount: 6,
            modifiers: [.shift]
        )
        XCTAssertEqual(shiftRange.selectedRows, IndexSet(integersIn: 2...5))
        XCTAssertEqual(shiftRange.anchorRow, 2)
    }

    func testTransferConflictDetectorFindsLocalNameCollisions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderTransferConflicts-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("same.txt")
        let destinationFile = destination.appendingPathComponent("same.txt")
        let uniqueFile = source.appendingPathComponent("unique.txt")
        try "source".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "destination".write(to: destinationFile, atomically: true, encoding: .utf8)
        try "unique".write(to: uniqueFile, atomically: true, encoding: .utf8)

        let provider = LocalFileProvider()
        let items = try await provider.list(.local(path: source.path), options: .init(showHiddenFiles: true, sort: .name(ascending: true)))
        let conflicts = TransferConflictDetector.conflicts(
            for: items,
            destination: .local(path: destination.path)
        )

        XCTAssertEqual(conflicts, [
            TransferConflict(itemName: "same.txt", destinationPath: destinationFile.path)
        ])
    }

    func testCopySelectionToOtherPanePromptsWhenLocalDestinationHasSameName() async throws {
        let fixture = try await makePendingOverwriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let app = AppModel()
        app.activePane = .left
        app.leftPane.location = .local(path: fixture.source.path)
        app.leftPane.items = [fixture.item]
        app.leftPane.selection = [fixture.item.id]
        app.rightPane.location = .local(path: fixture.destination.path)

        app.copySelectionToOtherPane(move: false)

        let pending = try XCTUnwrap(app.pendingTransferOverwrite)
        XCTAssertFalse(pending.move)
        XCTAssertEqual(pending.conflicts, [
            TransferConflict(itemName: "same.txt", destinationPath: fixture.destinationFile.path)
        ])
    }

    func testMoveSelectionToOtherPanePromptsWhenLocalDestinationHasSameName() async throws {
        let fixture = try await makePendingOverwriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let app = AppModel()
        app.activePane = .left
        app.leftPane.location = .local(path: fixture.source.path)
        app.leftPane.items = [fixture.item]
        app.leftPane.selection = [fixture.item.id]
        app.rightPane.location = .local(path: fixture.destination.path)

        app.copySelectionToOtherPane(move: true)

        let pending = try XCTUnwrap(app.pendingTransferOverwrite)
        XCTAssertTrue(pending.move)
        XCTAssertEqual(pending.conflicts, [
            TransferConflict(itemName: "same.txt", destinationPath: fixture.destinationFile.path)
        ])
    }

    func testDroppedLocalFileURLsBecomeLocalFileItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderDroppedFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("drop.txt")
        try "drop".write(to: file, atomically: true, encoding: .utf8)

        let items = try await DroppedLocalFileItems.resolve([file])

        XCTAssertEqual(items.map(\.name), ["drop.txt"])
        XCTAssertEqual(items.first?.location, .local(path: file.path))
    }

    func testLocalPathCompletionSuggestsMatchingDirectoriesAndPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderPathCompletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Alpha.app", isDirectory: true)
        let folder = root.appendingPathComponent("Alpha Folder", isDirectory: true)
        let ignoredFile = root.appendingPathComponent("Alpha.txt")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "ignored".write(to: ignoredFile, atomically: true, encoding: .utf8)

        let suggestions = LocalPathCompletion.suggestions(
            for: root.appendingPathComponent("Al").path,
            relativeTo: root,
            limit: 5
        )

        XCTAssertEqual(suggestions, [folder.path, app.path].sorted())
    }

    func testLocalPathCompletionResolvesRelativeInputAgainstCurrentDirectory() {
        let base = URL(fileURLWithPath: "/tmp/open-finder-base", isDirectory: true)

        let resolved = LocalPathCompletion.resolvedPath("Child", relativeTo: base)

        XCTAssertEqual(resolved, "/tmp/open-finder-base/Child")
    }

    func testAppModelAddsKodboxAccountThroughRemoteConnector() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderKodboxApp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("remote-accounts.json")),
            configurationStore: JSONConfigStore(url: root.appendingPathComponent("config.json")),
            keychainStore: InMemoryKeychainStore()
        )

        app.addRemoteAccount(
            connectorID: .kodbox,
            name: "Kodbox Local",
            endpoint: "http://127.0.0.1:18081/",
            username: "admin",
            password: "password",
            allowInsecureHTTP: true
        )

        let account = app.remoteAccounts.first
        XCTAssertEqual(account?.name, "Kodbox Local")
        XCTAssertEqual(account?.provider, .kodbox)
        XCTAssertEqual(account?.baseURL?.absoluteString, "http://127.0.0.1:18081/")
        XCTAssertEqual(account?.options["connectorID"], "kodbox")
        XCTAssertEqual(app.statusMessage, "Added Kodbox account Kodbox Local")
    }

    func testWebDAVAccountStillAcceptsItsEndpoint() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderWebDAVApp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("remote-accounts.json")),
            configurationStore: JSONConfigStore(url: root.appendingPathComponent("config.json")),
            keychainStore: InMemoryKeychainStore()
        )

        app.addRemoteAccount(
            connectorID: .webDAV,
            name: "WebDAV",
            endpoint: "https://files.example.test/dav/",
            username: "admin",
            password: "password",
            allowInsecureHTTP: false
        )

        XCTAssertEqual(app.remoteAccounts.first?.provider, .webDAV)
        XCTAssertEqual(app.remoteAccounts.first?.baseURL?.absoluteString, "https://files.example.test/dav/")
        XCTAssertEqual(app.statusMessage, "Added WebDAV account WebDAV")
    }

    func testInvalidRemoteAccountDoesNotWriteOrphanedSecret() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderInvalidRemote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = RecordingKeychainStore()
        let app = AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("remote-accounts.json")),
            configurationStore: JSONConfigStore(url: root.appendingPathComponent("config.json")),
            keychainStore: keychain
        )

        app.addRemoteAccount(
            connectorID: .kodbox,
            name: "Broken",
            endpoint: "https://box.example.test/index.php/dav/",
            username: "admin",
            password: "password",
            allowInsecureHTTP: false
        )

        XCTAssertTrue(app.remoteAccounts.isEmpty)
        XCTAssertEqual(keychain.setKeys, [])
        XCTAssertTrue(app.statusMessage.contains("server root"))
    }

    func testOpenRemoteAccountUsesRegistryProviderAtKodboxSyntheticRoot() async throws {
        let account = RemoteAccount(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            name: "Team Kodbox",
            provider: .kodbox,
            baseURL: URL(string: "https://box.example.test/")!,
            username: "admin",
            secretKeychainRef: "remote.kodbox.password",
            options: ["connectorID": RemoteConnectorID.kodbox.rawValue]
        )
        let root = RemotePath(
            identifier: KodboxProvider.syntheticRootIdentifier,
            displayPath: "/"
        )
        let provider = RecordingRemoteProvider(listings: [
            root.identifier: .init(
                current: root,
                parent: nil,
                items: [],
                capabilities: .init(isReadable: true, isWritable: false)
            )
        ])
        let factory = RecordingRemoteProviderFactory(provider: provider)
        let registry = RemoteProviderRegistry(factory: { accountID, revision in
            await factory.resolve(accountID: accountID, revision: revision)
        })
        let directory = RemoteAccountDirectory()
        directory.save(account)
        let app = AppModel(
            remoteDirectory: directory,
            configurationStore: JSONConfigStore(url: temporaryConfigurationURL()),
            keychainStore: InMemoryKeychainStore(),
            remoteProviderRegistry: registry
        )

        app.openRemoteAccountInActivePane(account)

        try await waitUntil { app.leftPane.location == .remote(.init(
            accountID: account.id,
            connectorID: .kodbox,
            path: root
        )) && app.leftPane.errorMessage == nil }
        let requests = await factory.requests()
        let listedIdentifiers = await provider.listedIdentifiers()
        XCTAssertEqual(requests, [
            .init(accountID: account.id.uuidString, revision: RemoteConnectorID.kodbox.rawValue)
        ])
        XCTAssertTrue(listedIdentifiers.contains(root.identifier))
    }

    func testLegacyWebDAVLocationResolvesThroughConfiguredRegistry() async throws {
        let accountID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let root = RemotePath(identifier: "/legacy", displayPath: "/legacy")
        let provider = RecordingRemoteProvider(listings: [
            root.identifier: .init(
                current: root,
                parent: nil,
                items: [],
                capabilities: .init(isReadable: true, isWritable: true)
            )
        ])
        let factory = RecordingRemoteProviderFactory(provider: provider)
        let registry = RemoteProviderRegistry(factory: { accountID, revision in
            await factory.resolve(accountID: accountID, revision: revision)
        })
        let app = AppModel(
            remoteDirectory: RemoteAccountDirectory(),
            configurationStore: JSONConfigStore(url: temporaryConfigurationURL()),
            keychainStore: InMemoryKeychainStore(),
            remoteProviderRegistry: registry
        )

        await app.leftPane.navigate(to: .webDAV(accountID: accountID, path: root.identifier))

        XCTAssertNil(app.leftPane.errorMessage)
        let requests = await factory.requests()
        let listedIdentifiers = await provider.listedIdentifiers()
        XCTAssertEqual(requests, [
            .init(accountID: accountID.uuidString, revision: RemoteConnectorID.webDAV.rawValue)
        ])
        XCTAssertTrue(listedIdentifiers.contains(root.identifier))
    }

    @MainActor
    func testOpaqueRemoteNavigationUsesSuppliedParentAndRefreshesDistinctMoveDestination() async throws {
        let accountID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let child = RemotePath(identifier: "source:99", displayPath: "/Personal Space/Child")
        let parent = RemotePath(identifier: "source:5", displayPath: "/Personal Space")
        let destination = RemotePath(identifier: "destination:17", displayPath: "/Shared/Renamed")
        let itemPath = RemotePath(identifier: "item:41", displayPath: "/Personal Space/Child/untitled.txt")
        let item = RemoteItem(
            id: "item:41",
            name: "untitled.txt",
            path: itemPath,
            kind: .file,
            size: nil,
            modificationDate: nil,
            etag: nil,
            mimeType: nil,
            isReadable: true,
            isWritable: true
        )
        let provider = OpaquePathProvider(
            listings: [
                child.identifier: .init(current: child, parent: parent, items: [item], capabilities: .init(isReadable: true, isWritable: true)),
                parent.identifier: .init(current: parent, parent: nil, items: [], capabilities: .init(isReadable: true, isWritable: true)),
                destination.identifier: .init(current: destination, parent: nil, items: [item], capabilities: .init(isReadable: true, isWritable: true))
            ]
        )
        let pane = BrowserPaneModel(
            id: .left,
            location: .remote(.init(accountID: accountID, connectorID: .webDAV, path: child)),
            remoteProviderResolver: { _ in provider }
        )

        await pane.refresh()
        XCTAssertEqual(pane.location, Location.remote(RemoteLocation(accountID: accountID, connectorID: .webDAV, path: child)))

        pane.goUp()
        try await waitUntil { pane.location == Location.remote(RemoteLocation(accountID: accountID, connectorID: .webDAV, path: parent)) }

        await pane.navigate(to: Location.remote(RemoteLocation(accountID: accountID, connectorID: .webDAV, path: destination)))
        let selectedItem: FileItem = try XCTUnwrap(pane.items.first)
        pane.selection = [selectedItem.id]
        pane.renameFirstSelected(to: "renamed.txt")
        try await waitUntil { await provider.hasMoveCount(1) }

        let listedIdentifiers = await provider.listedIdentifiers
        let moves = await provider.moves
        XCTAssertEqual(
            listedIdentifiers,
            [child.identifier, parent.identifier, destination.identifier, destination.identifier],
            "The destination is listed when navigated to and again after the rename refreshes the current directory."
        )
        XCTAssertEqual(moves, [OpaqueMove(itemIdentifier: itemPath.identifier, destinationIdentifier: destination.identifier, name: "renamed.txt")])
    }

    private struct PendingOverwriteFixture {
        let root: URL
        let source: URL
        let destination: URL
        let destinationFile: URL
        let item: FileItem
    }

    private func makePendingOverwriteFixture() async throws -> PendingOverwriteFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFinderPendingOverwrite-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("same.txt")
        let destinationFile = destination.appendingPathComponent("same.txt")
        try "source".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "destination".write(to: destinationFile, atomically: true, encoding: .utf8)
        let item = try await LocalFileProvider().stat(.local(path: sourceFile.path))
        return PendingOverwriteFixture(
            root: root,
            source: source,
            destination: destination,
            destinationFile: destinationFile,
            item: item
        )
    }

    private func temporaryConfigurationURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderAppTests-\(UUID().uuidString).json")
    }

    @MainActor
    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not satisfied before timeout")
    }
}

private actor OpaquePathProvider: RemoteProvider {
    private let listings: [String: RemoteDirectoryListing]
    private(set) var listedIdentifiers: [String] = []
    private(set) var moves: [OpaqueMove] = []

    init(listings: [String: RemoteDirectoryListing]) {
        self.listings = listings
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        listedIdentifiers.append(directory.identifier)
        guard let listing = listings[directory.identifier] else {
            throw OpenFinderError.itemNotFound(directory.identifier)
        }
        return listing
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}
    func delete(item: RemotePath) async throws {}

    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {
        moves.append(.init(itemIdentifier: item.identifier, destinationIdentifier: destination.identifier, name: name))
    }

    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID { UUID() }
    func download(item: RemotePath, to localURL: URL) async throws -> TaskID { UUID() }

    func hasMoveCount(_ count: Int) -> Bool {
        moves.count == count
    }
}

private struct OpaqueMove: Equatable, Sendable {
    let itemIdentifier: String
    let destinationIdentifier: String
    let name: String
}

private struct RemoteProviderRequest: Equatable, Sendable {
    let accountID: String
    let revision: String
}

private actor RecordingRemoteProviderFactory {
    private let provider: any RemoteProvider
    private var recordedRequests: [RemoteProviderRequest] = []

    init(provider: any RemoteProvider) {
        self.provider = provider
    }

    func resolve(accountID: String, revision: String) -> any RemoteProvider {
        recordedRequests.append(.init(accountID: accountID, revision: revision))
        return provider
    }

    func requests() -> [RemoteProviderRequest] {
        recordedRequests
    }
}

private actor RecordingRemoteProvider: RemoteProvider {
    private let listings: [String: RemoteDirectoryListing]
    private var recordedListedIdentifiers: [String] = []

    init(listings: [String: RemoteDirectoryListing]) {
        self.listings = listings
    }

    func list(directory: RemotePath) async throws -> RemoteDirectoryListing {
        recordedListedIdentifiers.append(directory.identifier)
        guard let listing = listings[directory.identifier] else {
            throw OpenFinderError.itemNotFound(directory.identifier)
        }
        return listing
    }

    func createDirectory(in parent: RemotePath, named name: String) async throws {}
    func delete(item: RemotePath) async throws {}
    func move(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func copy(item: RemotePath, to destination: RemotePath, named name: String) async throws {}
    func upload(localURL: URL, to parent: RemotePath, named name: String) async throws -> TaskID { UUID() }
    func download(item: RemotePath, to localURL: URL) async throws -> TaskID { UUID() }

    func listedIdentifiers() -> [String] {
        recordedListedIdentifiers
    }
}

private final class RecordingKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    var setKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return keys
    }

    func secret(for key: String) throws -> String? {
        nil
    }

    func setSecret(_ secret: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys.append(key)
    }

    func deleteSecret(for key: String) throws {}
}
