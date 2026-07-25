import AppKit
import CryptoKit
import Foundation
import OpenFinderCore
import SwiftUI
import XCTest
@testable import OpenFinderApp

@MainActor
final class MediaAnalysisVisualTests: XCTestCase {
    func testCaptureMediaAnalysisRendererStates() async throws {
        let outputDirectory = try evidenceDirectory()
        let mediaURL = outputDirectory.appendingPathComponent("media-analysis.png")
        let previewURL = outputDirectory.appendingPathComponent("media-analysis-preview.png")
        let unknownURL = outputDirectory.appendingPathComponent("unknown-artifacts.png")
        let zeroSelectionURL = outputDirectory.appendingPathComponent("media-analysis-zero-selection-remove.png")
        let taskID = UUID(uuidString: "28282828-2828-2828-2828-282828282828")!
        let (artifactResults, asset) = try await committedPreviewAsset(
            taskID: taskID,
            under: outputDirectory
        )
        let resolvedAssetURL = try await artifactResults.fileURL(for: asset.artifactID)
        let tag = MediaSuggestedTag(
            name: "Review",
            category: "workflow",
            confidence: 0.92,
            frameRatio: 0.5,
            source: "fixture",
            modelVersion: "1"
        )
        let item = MediaAnalysisItem(
            media: .init(
                stableID: "stable-media-28",
                sourcePath: "/Volumes/Media/Interview.mov",
                displayName: "Interview.mov"
            ),
            summaryMetrics: [
                .init(key: "关键帧", value: 2, unit: .count),
                .init(key: "露脸", value: 1, unit: .count),
            ],
            facets: [],
            moments: [
                .init(
                    index: 0,
                    timestamp: 0,
                    summary: "开场画面",
                    facets: [
                        .init(key: "场景", value: .text("演播室")),
                        .init(key: "露脸", value: .bool(false)),
                    ],
                    assets: [asset],
                    suggestedTags: []
                ),
                .init(
                    index: 1,
                    timestamp: 10,
                    summary: "人物访谈",
                    facets: [
                        .init(key: "场景", value: .text("演播室")),
                        .init(key: "露脸", value: .bool(true)),
                    ],
                    assets: [asset],
                    suggestedTags: [tag]
                ),
            ],
            suggestedTags: [tag],
            report: nil
        )
        let document = MediaAnalysisDocument(
            documentID: UUID(),
            taskID: taskID,
            items: [item],
            suggestedTags: [tag],
            actions: MediaAnalysisAction.standard,
            managedTagLedger: .init(mediaEntries: []),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let media = PluginResultProjection(
            resultSchemaID: MediaAnalysisDocument.schemaIdentifier,
            handlerIdentifier: .mediaAnalysis,
            value: document
        )
        let unknown = PluginResultProjection(
            resultSchemaID: "vendor.future.v9",
            handlerIdentifier: .unknown,
            value: UnknownPluginResult(
                schemaID: "vendor.future.v9",
                taskID: taskID,
                outputDirectory: FileManager.default.temporaryDirectory,
                artifacts: [
                    .init(type: "report", content: "Generic report content"),
                    .init(type: "metadata", content: #"{"ready":true}"#),
                ],
                message: "插件返回了当前版本尚未识别的 schema。"
            )
        )

        try render(
            PluginResultView(
                projection: media,
                renderer: PluginRendererCatalog.standard.renderer(for: media),
                artifactURL: { _ in resolvedAssetURL },
                resolvedAssetURL: { _ in resolvedAssetURL },
                onDismiss: {}
            ),
            to: mediaURL,
            size: .init(width: 1120, height: 760)
        )
        var previewIndex: Int? = 0
        try render(
            MediaAnalysisMomentPreviewView(
                moment: item.moments[0],
                moments: item.moments,
                artifactURL: { _ in resolvedAssetURL },
                resolvedAssetURL: { _ in resolvedAssetURL },
                previewMomentIndex: Binding(
                    get: { previewIndex },
                    set: { previewIndex = $0 }
                )
            ),
            to: previewURL,
            size: .init(width: 800, height: 600)
        )
        try render(
            PluginResultView(
                projection: unknown,
                renderer: PluginRendererCatalog.standard.renderer(for: unknown),
                onDismiss: {}
            ),
            to: unknownURL,
            size: .init(width: 760, height: 520)
        )

        let managedDocument = MediaAnalysisDocument(
            documentID: document.documentID,
            taskID: document.taskID,
            items: document.items,
            suggestedTags: document.suggestedTags,
            actions: document.actions,
            managedTagLedger: .init(mediaEntries: [
                .init(stableMediaID: item.media.stableID, tagNames: [tag.name]),
            ]),
            createdAt: document.createdAt
        )
        XCTAssertTrue(
            MediaAnalysisResultView.isFinderTagApplyEnabled(
                selectedTagsByMedia: [item.media.stableID: []],
                managedTagsByMedia: [item.media.stableID: [tag.name]]
            )
        )
        try render(
            PluginResultView(
                projection: .init(
                    resultSchemaID: MediaAnalysisDocument.schemaIdentifier,
                    handlerIdentifier: .mediaAnalysis,
                    value: managedDocument
                ),
                renderer: PluginRendererCatalog.standard.renderer(
                    forSchemaID: MediaAnalysisDocument.schemaIdentifier
                ),
                resolvedAssetURL: { _ in resolvedAssetURL },
                onDismiss: {}
            ),
            to: zeroSelectionURL,
            size: .init(width: 1120, height: 760)
        )

        XCTAssertGreaterThan(try Data(contentsOf: mediaURL).count, 0)
        XCTAssertGreaterThan(try Data(contentsOf: previewURL).count, 0)
        XCTAssertGreaterThan(try Data(contentsOf: unknownURL).count, 0)
        XCTAssertGreaterThan(try Data(contentsOf: zeroSelectionURL).count, 0)
        print(
            "TASK28_VISUAL media=\(mediaURL.path) preview=\(previewURL.path) "
                + "unknown=\(unknownURL.path) zeroSelection=\(zeroSelectionURL.path) "
                + "zeroSelectionApplyEnabled=true"
        )
    }

    private func evidenceDirectory() throws -> URL {
        let configured = ProcessInfo.processInfo.environment["TASK28_EVIDENCE_DIR"]
        let directory = configured.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "openfinder-task28-visual",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func render<ViewType: View>(
        _ view: ViewType,
        to destination: URL,
        size: CGSize
    ) throws {
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: .init(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw VisualHarnessError.imageEncodingFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw VisualHarnessError.imageEncodingFailed
        }
        try png.write(to: destination, options: .atomic)
    }

    private func committedPreviewAsset(
        taskID: UUID,
        under root: URL
    ) async throws -> (ArtifactResultService, ConfinedAssetReference) {
        let workspace = root.appendingPathComponent("visual-workspace", isDirectory: true)
        let storeRoot = root.appendingPathComponent("visual-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let image = NSImage(size: .init(width: 640, height: 360))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: .init(x: 0, y: 0, width: 640, height: 360)).fill()
        "已提交媒体预览".draw(
            at: .init(x: 190, y: 165),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw VisualHarnessError.imageEncodingFailed
        }
        let filename = "preview.png"
        try png.write(to: workspace.appendingPathComponent(filename), options: .atomic)
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let metadata = InMemoryArtifactMetadataBackend()
        let store = try ArtifactStore(root: storeRoot, metadata: metadata)
        let service = ArtifactResultService(store: store, metadata: metadata)
        let records = try await service.commit(
            taskID: taskID,
            schemaID: MediaAnalysisDocument.schemaIdentifier,
            artifacts: [.init(
                artifactID: UUID(),
                relativePath: filename,
                mediaType: "image/png",
                byteCount: png.count,
                sha256: digest
            )],
            from: ConfinedArtifactReader(root: workspace),
            markEffectsCommitted: {},
            cleanupWorkspace: {}
        )
        let record = try XCTUnwrap(records.first)
        return (
            service,
            .init(artifactID: record.id, relativePath: record.relativePath)
        )
    }
}

private enum VisualHarnessError: Error {
    case imageEncodingFailed
}
