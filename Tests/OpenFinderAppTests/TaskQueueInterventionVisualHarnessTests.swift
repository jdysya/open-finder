import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import OpenFinderApp
@testable import OpenFinderCore

@MainActor
final class TaskQueueInterventionVisualHarnessTests: XCTestCase {
    func testCaptureTaskQueueIntervention() throws {
        // Given
        let taskID = UUID(uuidString: "19191919-1919-1919-1919-191919191919")!
        let record = TaskRecord(
            id: taskID,
            kind: .localMove,
            title: "Move 1 item",
            status: .failed,
            createdAt: Date(timeIntervalSince1970: 1_735_689_600),
            finishedAt: Date(timeIntervalSince1970: 1_735_689_601),
            inputSummary: "item.txt",
            errorMessage: "Transfer requires intervention for item.txt: alreadyMoved",
            reasonCode: .alreadyMoved
        )
        let view = TaskQueueView(
            records: [record],
            logs: [:],
            statusMessage: "",
            onCancel: { _ in },
            onRetry: { _ in },
            onCopyLogs: { _ in }
        )
        let outputDirectory = try artifactDirectory()
        let imageURL = outputDirectory.appendingPathComponent("task-queue-intervention.png")

        // When
        try render(view: view, to: imageURL)

        // Then
        let imageData = try Data(contentsOf: imageURL)
        XCTAssertGreaterThan(imageData.count, 0)
        print("TASK19_QUEUE_VISUAL image=\(imageURL.path) bytes=\(imageData.count)")
    }

    private func artifactDirectory() throws -> URL {
        let configured = ProcessInfo.processInfo.environment["TASK19_EVIDENCE_DIR"]
        let directory = configured.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "openfinder-task19-visual-harness",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func render(view: TaskQueueView, to destination: URL) throws {
        let hostingView = NSHostingView(rootView: view.frame(width: 760, height: 260))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 760, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.imageEncodingFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.imageEncodingFailed
        }
        try png.write(to: destination, options: .atomic)
    }
}

private enum RenderError: Error {
    case imageEncodingFailed
}
