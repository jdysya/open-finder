import Foundation
import OpenFinderCore

enum PresentedPluginResultAction: Sendable {
    case applyMediaAnalysisTags(
        document: MediaAnalysisDocument,
        selections: [MediaAnalysisTagSelection],
        managedTagsByMedia: [String: Set<String>]
    )
}

struct PresentedPluginResultActionOutcome: Sendable {
    let message: String
    let managedTagsByMedia: [String: Set<String>]
}

struct PresentedPluginResultActionBridge: Sendable {
    private let action: @MainActor @Sendable (PresentedPluginResultAction) async
        -> PresentedPluginResultActionOutcome

    init(
        action: @escaping @MainActor @Sendable (PresentedPluginResultAction) async
            -> PresentedPluginResultActionOutcome
    ) {
        self.action = action
    }

    @MainActor
    func callAsFunction(
        _ action: PresentedPluginResultAction
    ) async -> PresentedPluginResultActionOutcome {
        await self.action(action)
    }

    @MainActor
    static let noAction = Self(action: { _ in
        .init(message: "", managedTagsByMedia: [:])
    })
}

@MainActor
extension ApplicationServices {
    func renderer(for projection: PluginResultProjection) -> PluginRendererDescriptor {
        rendererCatalog.renderer(for: projection)
    }

    func artifactURL(for id: UUID) async -> URL? {
        guard let artifactResults else { return nil }
        return try? await artifactResults.fileURL(for: id)
    }

    func perform(
        _ action: PresentedPluginResultAction
    ) async -> PresentedPluginResultActionOutcome {
        switch action {
        case .applyMediaAnalysisTags(let document, let selections, let managedTagsByMedia):
            return await applyMediaAnalysisTags(
                document: document,
                selections: selections,
                managedTagsByMedia: managedTagsByMedia
            )
        }
    }
}

private extension ApplicationServices {
    func applyMediaAnalysisTags(
        document: MediaAnalysisDocument,
        selections: [MediaAnalysisTagSelection],
        managedTagsByMedia initialManagedTagsByMedia: [String: Set<String>]
    ) async -> PresentedPluginResultActionOutcome {
        let provider = LocalFileProvider()
        let ledger = MediaAnalysisTagLedgerService()
        let selections = Dictionary(
            uniqueKeysWithValues: selections.map { ($0.stableMediaID, $0.selectedNames) }
        )
        var applied = 0
        var failures: [String] = []
        var managedTagsByMedia = initialManagedTagsByMedia
        for item in document.items {
            do {
                let file = try await provider.stat(.local(path: item.media.sourcePath))
                let update = ledger.update(
                    ledger: ManagedTagLedger(mediaEntries: managedTagsByMedia.map {
                        .init(stableMediaID: $0.key, tagNames: $0.value)
                    }),
                    item: item,
                    currentTags: file.tags,
                    selectedNames: selections[item.media.stableID, default: []]
                )
                let outcome = try await provider.apply(update.changes, to: [file])
                if let failure = outcome.failures.first {
                    failures.append("\(item.media.displayName): \(failure.message)")
                } else {
                    managedTagsByMedia[item.media.stableID] = update.nextManagedTagNames
                    applied += 1
                }
            } catch {
                failures.append("\(item.media.displayName): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            return .init(
                message: "已将所选标签应用到 \(applied) 个媒体文件。",
                managedTagsByMedia: managedTagsByMedia
            )
        }
        return .init(
            message: "已更新 \(applied) 个媒体文件。\(failures.joined(separator: " "))",
            managedTagsByMedia: managedTagsByMedia
        )
    }
}
