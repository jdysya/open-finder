import Combine
import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

@MainActor
final class AppModelFacadeCompatibilityTests: XCTestCase {
    func testPublishedSurfaceWithMediaPresentationException() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let app = fixture.makeApp()

        XCTAssertEqual(app.leftPane.id, PaneID.left)
        XCTAssertEqual(app.rightPane.id, PaneID.right)
        XCTAssertEqual(app.activePane, .left)
        XCTAssertTrue(app.activeBrowser === app.leftPane)
        XCTAssertTrue(app.inactiveBrowser === app.rightPane)
        XCTAssertTrue(app.taskRecords.isEmpty)
        XCTAssertTrue(app.taskLogs.isEmpty)
        XCTAssertTrue(app.loadedPlugins.isEmpty)
        XCTAssertTrue(app.pluginLoadDiagnostics.isEmpty)
        XCTAssertTrue(app.remoteAccounts.isEmpty)
        XCTAssertEqual(app.statusMessage, "Ready")
        XCTAssertNil(app.pendingTransferOverwrite)
        XCTAssertTrue(app.pluginConnectionStatuses.isEmpty)

        var changeCount = 0
        let observation = app.objectWillChange.sink { changeCount += 1 }
        app.activePane = .right
        XCTAssertGreaterThan(changeCount, 0)
        XCTAssertTrue(app.activeBrowser === app.rightPane)
        XCTAssertTrue(app.inactiveBrowser === app.leftPane)
        XCTAssertTrue(app.browser(for: .left) === app.leftPane)
        XCTAssertTrue(app.browser(for: .right) === app.rightPane)
        withExtendedLifetime(observation) {}
    }

    func testInitialLoadAppliesConfigurationBeforePanePresentation() async throws {
        let fixture = try FacadeFixture(
            configuration: .init(defaultShowHiddenFiles: true, maxConcurrentTasks: 3)
        )
        defer { fixture.cleanup() }
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let app = fixture.makeApp(taskQueue: queue)

        await app.loadInitialState()
        await app.loadInitialState()

        XCTAssertTrue(app.leftPane.showHiddenFiles)
        XCTAssertTrue(app.rightPane.showHiddenFiles)
        let concurrency = await queue.currentMaxConcurrentTasks()
        let loadCount = await fixture.configurationStore.loadCount()
        XCTAssertEqual(concurrency, 3)
        XCTAssertEqual(loadCount, 1)
    }

    func testDirectorySizeCancellationRemovesObsoleteTask() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let pane = fixture.makeApp().leftPane
        let cancellation = CancellationProbe()
        pane.directorySizeTasks["obsolete"] = Task {
            await cancellation.waitUntilCancelled()
        }
        await Task.yield()

        pane.refreshDirectorySizeCalculations(for: [])

        XCTAssertNil(pane.directorySizeTasks["obsolete"])
        try await waitUntil { await cancellation.wasCancelled() }
    }

    func testCurrentMediaSurfaceKeepsTwoVideoSelectionSummaryAndAndFacets() {
        let result = Self.mediaResult
        XCTAssertEqual(result.videos.map(\.name), ["First.mov", "Second.mov"])
        XCTAssertEqual(
            MediaPresentationSemantics.selectedPath(
                in: result.videos.map(\.path),
                requested: nil
            ),
            "/tmp/First.mov"
        )
        XCTAssertEqual(result.videos[0].summary.totalFrames, 2)
        XCTAssertEqual(result.videos[0].summary.faceVisible, 1)
        XCTAssertEqual(result.videos[0].summary.explicit, 1)
        XCTAssertEqual(
            VideoAnalysisPresentation.frames(
                in: result.videos[0],
                matching: ["露脸", "完全裸露"]
            ).map(\.index),
            [1]
        )
        XCTAssertEqual(
            VideoAnalysisPresentation.frames(
                in: result.videos[0],
                matching: ["露脸", "完全穿着"]
            ).map(\.index),
            []
        )
        XCTAssertEqual(
            VideoAnalysisPresentation.finderTagSuggestions(
                in: result.videos[0],
                selectedNames: ["Review"]
            ).map(\.name),
            ["Review"]
        )
        XCTAssertEqual(
            MediaPresentationSemantics.previewIndex(
                from: 0,
                offset: 1,
                available: result.videos[0].frames.map(\.index)
            ),
            1
        )
        XCTAssertNil(MediaPresentationSemantics.previewIndex(
            from: 1,
            offset: 1,
            available: result.videos[0].frames.map(\.index)
        ))
        XCTAssertEqual(MediaPresentationSemantics.closeTitle, "关闭")
        XCTAssertEqual(MediaPresentationSemantics.emptyTitle, "没有分析结果")
        XCTAssertEqual(
            MediaPresentationSemantics.mediaAccessibilityLabel(
                name: result.videos[0].name,
                keyframeCount: result.videos[0].frames.count
            ),
            "First.mov，2 个关键帧"
        )
        XCTAssertEqual(
            MediaPresentationSemantics.frameAccessibilityLabel(
                timestamp: "00:00:10",
                summary: "Subject"
            ),
            "00:00:10，Subject"
        )
    }

    private static let mediaResult = VideoAnalysisResult(
        taskID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        videos: [
            .init(
                path: "/tmp/First.mov",
                name: "First.mov",
                summary: .init(
                    totalFrames: 2,
                    faceVisible: 1,
                    explicit: 1,
                    moderate: 0,
                    partial: 0,
                    none: 1
                ),
                frames: [
                    .init(
                        index: 0,
                        timestamp: 0,
                        imagePath: "/tmp/first-0.jpg",
                        faceVisible: false,
                        faceCount: 0,
                        nudityLevel: .none,
                        summary: "Opening",
                        tags: []
                    ),
                    .init(
                        index: 1,
                        timestamp: 10,
                        imagePath: "/tmp/first-1.jpg",
                        faceVisible: true,
                        faceCount: 1,
                        nudityLevel: .explicit,
                        summary: "Subject",
                        tags: []
                    ),
                ],
                suggestedTags: [
                    .init(
                        name: "Review",
                        category: "Workflow",
                        confidence: 0.9,
                        frameRatio: 0.5,
                        source: "fixture",
                        modelVersion: "1"
                    ),
                ],
                reportPath: nil
            ),
            .init(
                path: "/tmp/Second.mov",
                name: "Second.mov",
                summary: .init(
                    totalFrames: 0,
                    faceVisible: 0,
                    explicit: 0,
                    moderate: 0,
                    partial: 0,
                    none: 0
                ),
                frames: [],
                suggestedTags: [],
                reportPath: nil
            ),
        ]
    )

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for deterministic state transition")
    }
}

private final class FacadeFixture {
    let root: URL
    let configurationStore: FacadeConfigurationStore

    init(configuration: AppConfiguration = .init()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelFacade-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configurationStore = FacadeConfigurationStore(configuration: configuration)
    }

    @MainActor
    func makeApp(taskQueue: TaskQueueService? = nil) -> AppModel {
        AppModel(
            remoteDirectory: RemoteAccountDirectory(storageURL: root.appendingPathComponent("accounts.json")),
            configurationStore: configurationStore,
            keychainStore: InMemoryKeychainStore(),
            taskQueue: taskQueue,
            startAutomatically: false
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FacadeConfigurationStore: AppConfigurationStore {
    private let configuration: AppConfiguration
    private var loads = 0

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func load() async throws -> AppConfiguration {
        loads += 1
        return configuration
    }

    func save(_ configuration: AppConfiguration) async throws {}
    func loadCount() -> Int { loads }
}

private actor CancellationProbe {
    private var cancelled = false

    func waitUntilCancelled() async {
        do {
            while true {
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            cancelled = true
        }
    }

    func wasCancelled() -> Bool { cancelled }
}
