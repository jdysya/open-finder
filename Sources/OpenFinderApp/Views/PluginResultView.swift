import OpenFinderCore
import SwiftUI

struct PluginResultView: View {
    let projection: PluginResultProjection
    let renderer: PluginRendererDescriptor
    let artifactURL: @Sendable (UUID) async -> URL?
    let resolvedAssetURL: (ConfinedAssetReference) -> URL?
    let onAction: @MainActor (PresentedPluginResultAction) async
        -> PresentedPluginResultActionOutcome
    let onDismiss: () -> Void

    init(
        projection: PluginResultProjection,
        renderer: PluginRendererDescriptor,
        artifactURL: @escaping @Sendable (UUID) async -> URL? = { _ in nil },
        resolvedAssetURL: @escaping (ConfinedAssetReference) -> URL? = { _ in nil },
        onAction: @escaping @MainActor (PresentedPluginResultAction) async
            -> PresentedPluginResultActionOutcome = { _ in
                .init(message: "", managedTagsByMedia: [:])
            },
        onDismiss: @escaping () -> Void
    ) {
        self.projection = projection
        self.renderer = renderer
        self.artifactURL = artifactURL
        self.resolvedAssetURL = resolvedAssetURL
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            switch renderer.identifier {
            case .mediaAnalysis:
                if let document = projection.project(MediaAnalysisDocument.self) {
                    MediaAnalysisResultView(
                        document: document,
                        artifactURL: artifactURL,
                        resolvedAssetURL: resolvedAssetURL,
                        onAction: onAction,
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
