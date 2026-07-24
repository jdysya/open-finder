import OpenFinderCore
import SwiftUI

struct MediaAnalysisResultView: View {
    let document: MediaAnalysisDocument
    let artifactResults: ArtifactResultService?
    let resolvedAssetURL: (ConfinedAssetReference) -> URL?
    let onDismiss: () -> Void

    @State private var selectedMediaID: String?
    @State private var filtersByMedia: [String: Set<MediaFacetSelection>] = [:]
    @State private var finderTagsByMedia: [String: Set<String>] = [:]
    @State private var managedTagsByMedia: [String: Set<String>]
    @State private var previewMomentIndex: Int?
    @State private var isApplying = false
    @State private var message: String?

    init(
        document: MediaAnalysisDocument,
        artifactResults: ArtifactResultService? = nil,
        resolvedAssetURL: @escaping (ConfinedAssetReference) -> URL? = { _ in nil },
        onDismiss: @escaping () -> Void
    ) {
        self.document = document
        self.artifactResults = artifactResults
        self.resolvedAssetURL = resolvedAssetURL
        self.onDismiss = onDismiss
        _selectedMediaID = State(initialValue: document.items.first?.media.stableID)
        _managedTagsByMedia = State(initialValue: Dictionary(
            uniqueKeysWithValues: document.managedTagLedger.mediaEntries.map {
                ($0.stableMediaID, $0.tagNames)
            }
        ))
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("媒体")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                List(selection: $selectedMediaID) {
                    ForEach(document.items, id: \.media.stableID) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.media.displayName)
                                .lineLimit(2)
                            Text("\(item.moments.count) 个时刻")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(item.media.stableID)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(MediaPresentationSemantics.mediaAccessibilityLabel(
                            name: item.media.displayName,
                            keyframeCount: item.moments.count
                        ))
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            detail
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 640, idealHeight: 760)
        .onChange(of: selectedMediaID) { _, _ in
            previewMomentIndex = nil
            message = nil
        }
        .sheet(isPresented: Binding(
            get: { previewMomentIndex != nil },
            set: { if !$0 { previewMomentIndex = nil } }
        )) {
            if let item = selectedItem,
               let moment = filteredMoments(for: item).first(where: { $0.index == previewMomentIndex }) {
                MediaAnalysisMomentPreviewView(
                    moment: moment,
                    moments: filteredMoments(for: item),
                    artifactResults: artifactResults,
                    resolvedAssetURL: resolvedAssetURL,
                    previewMomentIndex: $previewMomentIndex
                )
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            VStack(spacing: 0) {
                MediaAnalysisWorkspaceView(
                    item: item,
                    artifactResults: artifactResults,
                    resolvedAssetURL: resolvedAssetURL,
                    filters: filtersBinding(for: item.media.stableID),
                    finderTags: finderTagsBinding(for: item.media.stableID),
                    previewMomentIndex: $previewMomentIndex
                )
                Divider()
                footer
            }
        } else {
            ContentUnavailableView(MediaPresentationSemantics.emptyTitle, systemImage: "film")
        }
    }

    private var selectedItem: MediaAnalysisItem? {
        let stableID = MediaPresentationSemantics.selectedPath(
            in: document.items.map(\.media.stableID),
            requested: selectedMediaID
        )
        return document.items.first { $0.media.stableID == stableID }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("已选择 \(finderTagCount) 个 Finder 标签")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(MediaPresentationSemantics.closeTitle, action: onDismiss)
                .keyboardShortcut(.cancelAction)
            Button("应用 Finder 标签选择") {
                Task {
                    isApplying = true
                    message = await applySelectedTags()
                    isApplying = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isApplying || finderTagCount == 0)
        }
        .padding(12)
        .background(.bar)
    }

    private var finderTagCount: Int {
        finderTagsByMedia.values.reduce(0) { $0 + $1.count }
    }

    private var tagSelections: [MediaAnalysisTagSelection] {
        document.items.map {
            .init(
                stableMediaID: $0.media.stableID,
                selectedNames: finderTagsByMedia[$0.media.stableID, default: []]
            )
        }
    }

    private func filtersBinding(for stableID: String) -> Binding<Set<MediaFacetSelection>> {
        Binding(
            get: { filtersByMedia[stableID, default: []] },
            set: { filtersByMedia[stableID] = $0 }
        )
    }

    private func finderTagsBinding(for stableID: String) -> Binding<Set<String>> {
        Binding(
            get: { finderTagsByMedia[stableID, default: []] },
            set: { finderTagsByMedia[stableID] = $0 }
        )
    }

    private func filteredMoments(for item: MediaAnalysisItem) -> [MediaAnalysisMoment] {
        MediaAnalysisPresentationService().moments(
            in: item,
            matching: filtersByMedia[item.media.stableID, default: []]
        )
    }

    private func applySelectedTags() async -> String {
        let provider = LocalFileProvider()
        let ledger = MediaAnalysisTagLedgerService()
        let selections = Dictionary(
            uniqueKeysWithValues: tagSelections.map { ($0.stableMediaID, $0.selectedNames) }
        )
        var applied = 0
        var failures: [String] = []
        for item in document.items {
            do {
                let file = try await provider.stat(.local(path: item.media.sourcePath))
                let currentLedger = ManagedTagLedger(mediaEntries: managedTagsByMedia.map {
                    .init(stableMediaID: $0.key, tagNames: $0.value)
                })
                let update = ledger.update(
                    ledger: currentLedger,
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
        if failures.isEmpty { return "已将所选标签应用到 \(applied) 个媒体文件。" }
        return "已更新 \(applied) 个媒体文件。\(failures.joined(separator: " "))"
    }
}
