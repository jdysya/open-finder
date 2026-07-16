import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func remoteLocation(for location: Location) throws -> RemoteLocation {
        switch location {
        case .remote(let remoteLocation):
            return remoteLocation
        case .webDAV(let accountID, let path):
            return .init(
                accountID: accountID,
                connectorID: .webDAV,
                path: .init(identifier: path, displayPath: path)
            )
        case .local, .rclone:
            throw OpenFinderError.unsupportedLocation(location)
        }
    }

    func remoteProvider(
        for remoteLocation: RemoteLocation
    ) async throws -> any RemoteProvider {
        try await remoteProviderResolver(remoteLocation)
    }

    func materializeRemoteFile(_ item: FileItem) async throws -> URL {
        let remoteLocation = try remoteLocation(for: item.location)
        let remote = try await remoteProvider(for: remoteLocation)
        try FileManager.default.createDirectory(
            at: remoteMaterializationDirectory,
            withIntermediateDirectories: true
        )
        let name = try safeRemoteFileName(item.name)
        let destination = remoteMaterializationDirectory
            .appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        _ = try await remote.download(item: remoteLocation.path, to: destination)
        return destination
    }

    func downloadRemoteFile(_ item: FileItem, to destination: URL) async throws {
        guard !item.isDirectory, item.localURL == nil else {
            throw OpenFinderError.operationFailed("Only remote files can be dragged out")
        }
        _ = try safeRemoteFileName(item.name)
        let remoteLocation = try remoteLocation(for: item.location)
        let remote = try await remoteProvider(for: remoteLocation)
        _ = try await remote.download(item: remoteLocation.path, to: destination)
    }

    private func safeRemoteFileName(_ name: String) throws -> String {
        let baseName = URL(fileURLWithPath: name).lastPathComponent
        guard baseName == name,
              !name.contains("/"),
              !name.contains("\\"),
              !baseName.isEmpty,
              baseName != ".",
              baseName != ".."
        else {
            throw OpenFinderError.operationFailed("Remote file has an unsafe name")
        }
        return baseName
    }
}
