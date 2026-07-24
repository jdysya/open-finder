import Foundation

public extension FileSourceRegistry {
    func makeTransferEnvelope(
        items: [FileItem],
        source: Location,
        destination: Location,
        overwrite: TransferOverwritePolicy
    ) async throws -> TransferTaskEnvelope {
        let entries = items.map(TransferEntrySnapshot.init)
        let draft = TransferTaskEnvelope(
            entries: entries,
            source: source,
            destination: destination,
            overwrite: overwrite
        )
        let operations = try await rebuildTransferOperations(for: draft)
        var destinationSnapshots: [TransferEntrySnapshot?] = []
        for entry in entries {
            destinationSnapshots.append(try await operations.destinationSnapshot(
                for: entry,
                at: destination
            ))
        }
        return TransferTaskEnvelope(
            entries: entries,
            source: source,
            destination: destination,
            overwrite: overwrite,
            destinationSnapshots: destinationSnapshots
        )
    }

    func rebuildTransferOperations(
        for envelope: TransferTaskEnvelope
    ) async throws -> TransferFileOperations {
        let source = try await resolve(
            envelope.source,
            revision: envelope.sourceRevision
        )
        let destination = try await resolve(
            envelope.destination,
            revision: envelope.destinationRevision
        )
        return TransferFileOperations(
            snapshotSource: { entry in
                try await TransferRegistryIO.snapshotSource(
                    entry,
                    declaredSource: source
                )
            },
            snapshotDestination: { entry, _ in
                try await TransferRegistryIO.snapshotDestination(
                    entry,
                    declaredDestination: destination
                )
            },
            execute: { operation, entry, _, overwrite in
                try await TransferRegistryIO.execute(
                    operation,
                    entry: entry,
                    source: source,
                    destination: destination,
                    overwrite: overwrite
                )
            }
        )
    }
}

enum TransferRegistryIO {
    static func snapshotSource(
        _ entry: TransferEntrySnapshot,
        declaredSource: ResolvedFileSource
    ) async throws -> TransferEntrySnapshot? {
        switch declaredSource.adapter {
        case .local(let adapter):
            guard FileManager.default.fileExists(
                atPath: entry.location.localURL?.path ?? ""
            ) else {
                return nil
            }
            return TransferEntrySnapshot(try await adapter.provider.stat(entry.location))
        case .remote(let adapter):
            let listing = try await adapter.provider.list(
                directory: declaredSource.location.path
            )
            guard let itemPath = entry.location.remotePath,
                  let item = listing.items.first(where: {
                      $0.remotePath.identifier == itemPath.identifier
                  })
            else {
                return nil
            }
            return TransferEntrySnapshot(
                try fileItem(item, sourceID: adapter.sourceID)
            )
        }
    }

    static func snapshotDestination(
        _ entry: TransferEntrySnapshot,
        declaredDestination: ResolvedFileSource
    ) async throws -> TransferEntrySnapshot? {
        switch declaredDestination.adapter {
        case .local(let adapter):
            let target = try safeChildURL(
                in: URL(fileURLWithPath: declaredDestination.location.path.identifier),
                named: entry.name,
                isDirectory: entry.item.isDirectory
            )
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            return TransferEntrySnapshot(
                try await adapter.provider.stat(.local(path: target.path))
            )
        case .remote(let adapter):
            let listing = try await adapter.provider.list(
                directory: declaredDestination.location.path
            )
            guard let item = listing.items.first(where: { $0.name == entry.name }) else {
                return nil
            }
            return TransferEntrySnapshot(
                try fileItem(item, sourceID: adapter.sourceID)
            )
        }
    }

    static func execute(
        _ operation: TransferOperation,
        entry: TransferEntrySnapshot,
        source: ResolvedFileSource,
        destination: ResolvedFileSource,
        overwrite: TransferOverwritePolicy
    ) async throws {
        switch (source.adapter, destination.adapter) {
        case (.local(let localSource), .local):
            if operation == .copy {
                _ = try await localSource.provider.copy(
                    [entry.item],
                    to: location(destination.location),
                    overwriteExisting: overwrite == .replaceExisting
                )
            } else {
                _ = try await localSource.provider.move(
                    [entry.item],
                    to: location(destination.location),
                    overwriteExisting: overwrite == .replaceExisting
                )
            }
        case (.local(let localSource), .remote(let remoteDestination)):
            guard let localURL = entry.location.localURL else {
                throw OpenFinderError.unsupportedLocation(entry.location)
            }
            try await upload(
                localURL,
                to: destination.location.path,
                remote: remoteDestination.provider
            )
            if operation == .move {
                try await localSource.provider.trashOrDelete([entry.item])
            }
        case (.remote(let remoteSource), .local):
            guard let remotePath = entry.location.remotePath else {
                throw OpenFinderError.unsupportedLocation(entry.location)
            }
            let target = try safeChildURL(
                in: URL(fileURLWithPath: destination.location.path.identifier),
                named: entry.name,
                isDirectory: entry.item.isDirectory
            )
            try await download(
                remotePath,
                kind: entry.kind,
                named: entry.name,
                to: target,
                remote: remoteSource.provider,
                overwrite: overwrite
            )
            if operation == .move {
                try await remoteSource.provider.delete(item: remotePath)
            }
        case (.remote(let remoteSource), .remote):
            guard let remotePath = entry.location.remotePath else {
                throw OpenFinderError.unsupportedLocation(entry.location)
            }
            if operation == .copy {
                try await remoteSource.provider.copy(
                    item: remotePath,
                    to: destination.location.path,
                    named: entry.name
                )
            } else {
                try await remoteSource.provider.move(
                    item: remotePath,
                    to: destination.location.path,
                    named: entry.name
                )
            }
        }
    }

}
