import Foundation
import OpenFinderCore

extension FileTransferService {
    static func download(
        remotePath: RemotePath,
        kind: FileKind,
        named name: String,
        to destination: URL,
        remote: any RemoteProvider,
        overwriteExisting: Bool
    ) async throws {
        let fileManager = FileManager.default
        if kind == .directory || kind == .package {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw OpenFinderError.operationFailed(
                    "Replacing existing local directories is not supported yet"
                )
            }
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            let listing = try await remote.list(directory: remotePath)
            for child in listing.items {
                try await download(
                    remotePath: child.remotePath,
                    kind: child.kind,
                    named: child.name,
                    to: try safeChildURL(
                        in: destination,
                        named: child.name,
                        isDirectory: child.kind == .directory || child.kind == .package
                    ),
                    remote: remote,
                    overwriteExisting: false
                )
            }
        } else {
            if !fileManager.fileExists(atPath: destination.path) {
                _ = try await remote.download(item: remotePath, to: destination)
                return
            }
            guard overwriteExisting else {
                throw OpenFinderError.operationFailed(
                    "Local destination already contains: \(name)"
                )
            }
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".openfinder-remote-replace-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: staged) }
            _ = try await remote.download(item: remotePath, to: staged)
            try fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    static func safeChildURL(
        in parent: URL,
        named name: String,
        isDirectory: Bool
    ) throws -> URL {
        let baseName = URL(fileURLWithPath: name).lastPathComponent
        guard baseName == name,
              !name.contains("/"),
              !name.contains("\\"),
              !baseName.isEmpty,
              baseName != ".",
              baseName != ".."
        else {
            throw OpenFinderError.operationFailed("Remote item has an unsafe name")
        }
        return parent.appendingPathComponent(baseName, isDirectory: isDirectory)
    }
}
