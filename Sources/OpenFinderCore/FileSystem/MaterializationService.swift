import CryptoKit
import Foundation

public struct MaterializationRequest: Sendable {
    public let sourceID: FileSourceID
    public let path: RemotePath
    public let requestID: UUID

    public init(
        sourceID: FileSourceID,
        path: RemotePath,
        requestID: UUID = UUID()
    ) {
        self.sourceID = sourceID
        self.path = path
        self.requestID = requestID
    }
}

public actor MaterializationService {
    private let root: URL

    public init(root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenFinderMaterializations", isDirectory: true)) {
        self.root = root
    }

    public func materialize(
        _ request: MaterializationRequest,
        provider: any RemoteProvider
    ) async throws -> MaterializationLease {
        let fileManager = FileManager.default
        let namespace = root.appendingPathComponent(
            namespaceName(for: request),
            isDirectory: true
        )
        let destination = namespace.appendingPathComponent(
            try safeFileName(for: request.path),
            isDirectory: false
        )
        let partial = namespace.appendingPathComponent(
            ".partial-\(UUID().uuidString)",
            isDirectory: false
        )

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: namespace, withIntermediateDirectories: false)
        do {
            _ = try await provider.download(item: request.path, to: partial)
            try Task.checkCancellation()
            try synchronize(partial)
            try Task.checkCancellation()
            try fileManager.moveItem(at: partial, to: destination)
            try Task.checkCancellation()
            return MaterializationLease(
                url: destination,
                ownedNamespaceURL: namespace
            )
        } catch {
            try? fileManager.removeItem(at: namespace)
            throw error
        }
    }

    private func namespaceName(for request: MaterializationRequest) -> String {
        "remote-\(digest(sourceIdentity(for: request.sourceID)))-\(digest(request.path.identifier))-\(request.requestID.uuidString)"
    }

    private func sourceIdentity(for sourceID: FileSourceID) -> String {
        switch sourceID {
        case .local:
            "local"
        case .remote(let accountID, let connectorID):
            "\(connectorID.rawValue):\(accountID.uuidString)"
        }
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func safeFileName(for path: RemotePath) throws -> String {
        let name = URL(fileURLWithPath: path.displayPath).lastPathComponent
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\")
        else {
            throw OpenFinderError.operationFailed(
                "Remote file has an unsafe materialization name"
            )
        }
        return name
    }

    private func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}
