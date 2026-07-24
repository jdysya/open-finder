import OpenFinderCore
import SwiftUI

struct PluginResultView: View {
    let projection: PluginResultProjection
    let catalog: PluginRendererCatalog
    let artifactResults: ArtifactResultService?
    let resolvedAssetURL: (ConfinedAssetReference) -> URL?
    let onDismiss: () -> Void

    init(
        projection: PluginResultProjection,
        catalog: PluginRendererCatalog,
        artifactResults: ArtifactResultService? = nil,
        resolvedAssetURL: @escaping (ConfinedAssetReference) -> URL? = { _ in nil },
        onDismiss: @escaping () -> Void
    ) {
        self.projection = projection
        self.catalog = catalog
        self.artifactResults = artifactResults
        self.resolvedAssetURL = resolvedAssetURL
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            switch catalog.renderer(for: projection).identifier {
            case .mediaAnalysis:
                if let document = projection.project(MediaAnalysisDocument.self) {
                    MediaAnalysisResultView(
                        document: document,
                        artifactResults: artifactResults,
                        resolvedAssetURL: resolvedAssetURL,
                        onDismiss: onDismiss
                    )
                } else {
                    genericResult
                }
            case .unknown:
                genericResult
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var genericResult: some View {
        GenericArtifactResultView(
            presentation: GenericArtifactPresentation(projection: projection),
            onDismiss: onDismiss
        )
    }
}

private struct GenericArtifactResultView: View {
    let presentation: GenericArtifactPresentation?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("插件产物")
                        .font(.title2.weight(.semibold))
                    Text(presentation?.schemaID ?? "unknown")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(MediaPresentationSemantics.closeTitle, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            if let message = presentation?.message, !message.isEmpty {
                Text(message)
                    .textSelection(.enabled)
            }
            if let artifacts = presentation?.artifacts, !artifacts.isEmpty {
                List(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artifact.type)
                            .font(.headline)
                        switch artifact.payload {
                        case .inline(let content):
                            Text(content)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        case .file(let file):
                            Text(file.relativePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("\(file.mediaType) · \(file.byteCount.formatted()) 字节")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                ContentUnavailableView(
                    GenericArtifactPresentation.emptyTitle,
                    systemImage: "shippingbox"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
    }
}
