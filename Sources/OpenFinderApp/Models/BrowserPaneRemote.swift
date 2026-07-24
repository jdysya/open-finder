import Foundation
import OpenFinderCore

extension BrowserPaneModel {
    func materializeRemoteFile(_ item: FileItem) async throws -> URL {
        let source = try await resolvedFileSource(for: item.location)
        guard source.location.sourceID.isRemote else {
            throw FileCapabilityUnsupportedReason.operationUnavailable(
                sourceID: source.location.sourceID,
                operation: .quickLook
            )
        }
        let lease = try await fileBrowserService.materialize(
            item.location,
            revision: source.adapter.providerRevision
        )
        materializationLeases.append(lease)
        return lease.url
    }

    func downloadRemoteFile(_ item: FileItem, to destination: URL) async throws {
        guard !item.isDirectory, item.localURL == nil else {
            throw OpenFinderError.operationFailed("Only remote files can be dragged out")
        }
        _ = try safeRemoteFileName(item.name)
        let source = try await resolvedFileSource(for: item.location)
        try await source.download(item, to: destination)
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
