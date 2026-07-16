import Foundation
import OpenFinderCore

extension AppModel {
    func dismissVideoAnalysis() {
        presentedVideoAnalysis = nil
    }

    func applySelectedVideoTags(
        _ selections: [VideoAnalysisTagSelection],
        from result: VideoAnalysisResult
    ) async -> String {
        let provider = LocalFileProvider()
        var applied = 0
        var failures: [String] = []
        let selectionsByPath = Dictionary(
            uniqueKeysWithValues: selections.map { ($0.videoPath, $0.selectedNames) }
        )
        for video in result.videos {
            guard let selectedNames = selectionsByPath[video.path] else { continue }
            do {
                let item = try await provider.stat(.local(path: video.path))
                let fingerprint = try videoFingerprint(
                    for: item,
                    analyzerVersion: Self.videoAnalyzerVersion
                )
                let stored = try await videoAnalysisStore.load(for: fingerprint)
                let selectedSuggestions = VideoAnalysisPresentation.finderTagSuggestions(
                    in: video,
                    selectedNames: selectedNames
                )
                let reconciliation = ManagedAnalysisTagLedger.reconcile(
                    current: item.tags,
                    suggested: selectedSuggestions,
                    previouslyManaged: stored?.managedTagNames ?? []
                )
                let changes = FileTagChangeSet(
                    add: reconciliation.additions.map(FileTag.local(name:)),
                    remove: reconciliation.removals.map(FileTag.local(name:))
                )
                let outcome = try await provider.apply(changes, to: [item])
                if let failure = outcome.failures.first {
                    failures.append("\(video.name): \(failure.message)")
                    continue
                }
                try await videoAnalysisStore.save(.init(
                    fingerprint: fingerprint,
                    result: result,
                    analyzedAt: Date(),
                    managedTagNames: reconciliation.nextManaged
                ))
                applied += 1
            } catch {
                failures.append("\(video.name): \(error.localizedDescription)")
            }
        }
        await leftPane.refresh()
        await rightPane.refresh()
        if failures.isEmpty { return "已将所选标签应用到 \(applied) 个视频。" }
        return "已更新 \(applied) 个视频。\(failures.joined(separator: " "))"
    }

    func cacheVideoAnalysis(_ result: VideoAnalysisResult, analyzerVersion: String) async {
        let provider = LocalFileProvider()
        for video in result.videos {
            guard let item = try? await provider.stat(.local(path: video.path)),
                  let fingerprint = try? videoFingerprint(
                    for: item,
                    analyzerVersion: analyzerVersion
                  )
            else {
                continue
            }
            let previous = try? await videoAnalysisStore.load(for: fingerprint)
            try? await videoAnalysisStore.save(.init(
                fingerprint: fingerprint,
                result: result,
                analyzedAt: Date(),
                managedTagNames: previous?.managedTagNames ?? []
            ))
        }
    }

    private func videoFingerprint(
        for item: FileItem,
        analyzerVersion: String
    ) throws -> VideoFileFingerprint {
        guard let path = item.location.localURL?.standardizedFileURL.path,
              let size = item.size,
              let modificationDate = item.modificationDate
        else {
            throw OpenFinderError.operationFailed(
                "Cannot fingerprint \(item.name) for video analysis"
            )
        }
        return .init(
            canonicalPath: path,
            size: size,
            modificationDate: modificationDate,
            analyzerVersion: analyzerVersion
        )
    }
}
