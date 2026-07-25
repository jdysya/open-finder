import Foundation
import OpenFinderCore
import XCTest
@testable import OpenFinderApp

final class MediaAnalysisRendererIntegrationTests: XCTestCase {
    func testFilterFacetsUseChineseVideoSemanticsAndIncludeJoyTagMomentLabels() throws {
        let joyTag = MediaSuggestedTag(
            name: "床",
            category: "scene",
            confidence: 0.82,
            frameRatio: 0.5,
            source: "joytag",
            modelVersion: "local"
        )
        let item = MediaAnalysisItem(
            media: .init(
                stableID: "filter-semantics",
                sourcePath: "/tmp/filter-semantics.mp4",
                displayName: "filter-semantics.mp4"
            ),
            summaryMetrics: [],
            facets: [],
            moments: [
                .init(
                    index: 0,
                    timestamp: 0,
                    summary: "Opening",
                    facets: [
                        .init(key: "faceVisible", value: .bool(true)),
                        .init(key: "faceCount", value: .integer(1)),
                        .init(key: "nudityLevel", value: .text("none")),
                    ],
                    assets: [],
                    suggestedTags: [joyTag]
                ),
                .init(
                    index: 1,
                    timestamp: 10,
                    summary: "Second",
                    facets: [
                        .init(key: "faceVisible", value: .bool(false)),
                        .init(key: "faceCount", value: .integer(0)),
                        .init(key: "nudityLevel", value: .text("explicit")),
                    ],
                    assets: [],
                    suggestedTags: []
                ),
            ],
            suggestedTags: [joyTag],
            report: nil
        )
        let presentation = MediaAnalysisPresentationService()

        let facets = presentation.facets(for: item)
        XCTAssertEqual(
            facets.first { $0.selection == .init(key: "faceVisible", value: .bool(true)) }?.label,
            "露脸"
        )
        XCTAssertEqual(
            facets.first { $0.selection == .init(key: "faceCount", value: .integer(1)) }?.label,
            "1 张人脸"
        )
        XCTAssertEqual(
            facets.first { $0.selection == .init(key: "nudityLevel", value: .text("none")) }?.label,
            "完全穿着"
        )
        XCTAssertEqual(
            facets.first { $0.selection == .init(key: "nudityLevel", value: .text("explicit")) }?.label,
            "完全裸露"
        )

        let bed = try XCTUnwrap(facets.first { $0.label == "床" })
        XCTAssertEqual(bed.category, "JoyTag · 场景")
        XCTAssertEqual(bed.momentCount, 1)
        XCTAssertEqual(
            presentation.moments(in: item, matching: [bed.selection]).map(\.index),
            [0]
        )
    }

    @MainActor
    func testFinderTagApplyEligibilityBaseline() {
        XCTAssertFalse(
            MediaAnalysisResultView.isFinderTagApplyEnabled(
                selectedTagsByMedia: [:],
                managedTagsByMedia: [:]
            )
        )
        XCTAssertTrue(
            MediaAnalysisResultView.isFinderTagApplyEnabled(
                selectedTagsByMedia: ["media-1": ["Review"]],
                managedTagsByMedia: [:]
            )
        )
    }

    @MainActor
    func testDeselectingOnlyManagedTagKeepsApplyEnabledAndPlansRemoval() {
        let managed = ["media-1": Set(["Review"])]
        let selected = ["media-1": Set<String>()]
        XCTAssertTrue(
            MediaAnalysisResultView.isFinderTagApplyEnabled(
                selectedTagsByMedia: selected,
                managedTagsByMedia: managed
            )
        )

        let item = Self.document(taskID: UUID()).items[0]
        let update = MediaAnalysisTagLedgerService().update(
            ledger: .init(mediaEntries: [
                .init(stableMediaID: item.media.stableID, tagNames: managed[item.media.stableID] ?? []),
            ]),
            item: item,
            currentTags: [.local(name: "Review")],
            selectedNames: selected[item.media.stableID] ?? []
        )
        XCTAssertEqual(update.changes.removals.map(\.name), ["Review"])
        XCTAssertTrue(update.changes.additions.isEmpty)
        XCTAssertTrue(update.nextManagedTagNames.isEmpty)
    }

    func testTwoPluginsShareRendererAndInteractions() async throws {
        let processRunner = MediaDocumentPluginRunner()
        let httpRunner = MediaDocumentPluginRunner()
        let keychain = InMemoryKeychainStore()
        try keychain.setSecret("fixture-token", for: "fixture.http.token")
        let coordinator = PluginExecutionCoordinator(
            runner: PluginRunnerRouter(processRunner: processRunner, httpRunner: httpRunner),
            connectionChecker: ExactPluginConnectionChecker(),
            credentialResolver: .init(
                keychainStore: keychain,
                localStore: LocalPluginCredentialStore()
            )
        )
        let processPlugin = Self.plugin(
            id: "fixture.process.media",
            actionID: "analyze",
            execution: .process(runtime: .shell, entry: "fixture.sh")
        )
        let httpPlugin = Self.plugin(
            id: "fixture.http.media",
            actionID: "inspect",
            execution: .http(
                protocolVersion: 1,
                endpointConfigurationKey: "serverURL",
                tokenSecretKey: "serverToken"
            )
        )
        let process = try await coordinator.execute(
            Self.request(plugin: processPlugin, taskID: UUID())
        ).projection
        let http = try await coordinator.execute(
            Self.request(
                plugin: httpPlugin,
                taskID: UUID(),
                configuration: ["serverURL": "http://127.0.0.1:8765"],
                secretReferences: ["serverToken": "fixture.http.token"]
            )
        ).projection

        let catalog = PluginRendererCatalog.standard
        XCTAssertEqual(
            catalog.renderer(forSchemaID: MediaAnalysisDocument.schemaIdentifier).identifier,
            .mediaAnalysis
        )
        XCTAssertEqual(catalog.renderer(for: process), catalog.renderer(for: http))
        XCTAssertEqual(catalog.renderer(for: process).identifier, .mediaAnalysis)

        XCTAssertNotNil(process.project(MediaAnalysisDocument.self))
        XCTAssertNotNil(http.project(MediaAnalysisDocument.self))
        let decoded = Self.document(taskID: UUID())
        let item = try XCTUnwrap(decoded.items.first)
        let presentation = MediaAnalysisPresentationService()
        XCTAssertEqual(presentation.summary(for: item).map(\.key), ["totalFrames", "faceVisible"])
        XCTAssertEqual(presentation.facets(for: item).first(where: {
            $0.selection == .init(key: "scene", value: .text("studio"))
        })?.momentCount, 2)
        XCTAssertEqual(
            presentation.moments(
                in: item,
                matching: [
                    .init(key: "faceVisible", value: .bool(true)),
                    .init(key: "scene", value: .text("studio")),
                ]
            ).map(\.index),
            [1]
        )
        XCTAssertEqual(
            presentation.suggestedTags(in: item, selectedNames: ["Review"]).map(\.name),
            ["Review"]
        )
        let ledgerUpdate = MediaAnalysisTagLedgerService().update(
            document: decoded,
            item: item,
            currentTags: [.local(name: "Old"), .local(name: "Keep")],
            selectedNames: ["Review"]
        )
        XCTAssertEqual(ledgerUpdate.changes.additions.map(\.name), ["Review"])
        XCTAssertEqual(ledgerUpdate.changes.removals.map(\.name), [])
        XCTAssertEqual(ledgerUpdate.nextManagedTagNames, ["Review"])
        let removalUpdate = MediaAnalysisTagLedgerService().update(
            ledger: .init(mediaEntries: [
                .init(stableMediaID: item.media.stableID, tagNames: ledgerUpdate.nextManagedTagNames),
            ]),
            item: item,
            currentTags: [.local(name: "Review")],
            selectedNames: []
        )
        XCTAssertEqual(removalUpdate.changes.additions.map(\.name), [])
        XCTAssertEqual(removalUpdate.changes.removals.map(\.name), ["Review"])
        XCTAssertEqual(removalUpdate.nextManagedTagNames, [])
        XCTAssertEqual(
            MediaPresentationSemantics.previewIndex(
                from: 0,
                offset: 1,
                available: item.moments.map(\.index)
            ),
            1
        )
    }

    func testUnknownSchemaUsesGenericArtifactView() async throws {
        let projection = try await PluginResultHandlerRegistry.standard.handle(.init(
            resultSchemaID: "vendor.future.v9",
            pluginID: "fixture.future",
            pluginVersion: "9.0.0",
            actionID: "run",
            taskID: UUID(),
            events: [.result(
                status: "success",
                message: "generic result",
                clipboard: nil,
                artifacts: [
                    .init(type: "report", content: "hello"),
                    .init(type: "metadata", content: #"{"ok":true}"#),
                ]
            )],
            outputDirectory: FileManager.default.temporaryDirectory
        ))

        XCTAssertEqual(PluginRendererCatalog.standard.renderer(for: projection).identifier, .unknown)
        XCTAssertEqual(
            PluginRendererCatalog.standard.renderer(forSchemaID: "vendor.future.v9").identifier,
            .unknown
        )
        let model = try XCTUnwrap(GenericArtifactPresentation(projection: projection))
        XCTAssertEqual(model.schemaID, "vendor.future.v9")
        XCTAssertEqual(model.message, "generic result")
        XCTAssertEqual(model.artifacts.map(\.type), ["report", "metadata"])
        XCTAssertEqual(model.emptyTitle, "没有可显示的产物")
    }

    private static func document(taskID: UUID) -> MediaAnalysisDocument {
        let review = MediaSuggestedTag(
            name: "Review",
            category: "workflow",
            confidence: 0.9,
            frameRatio: 0.5,
            source: "fixture",
            modelVersion: "1"
        )
        let moments = [
            MediaAnalysisMoment(
                index: 0,
                timestamp: 0,
                summary: "Opening",
                facets: [
                    .init(key: "faceVisible", value: .bool(false)),
                    .init(key: "scene", value: .text("studio")),
                ],
                assets: [],
                suggestedTags: []
            ),
            MediaAnalysisMoment(
                index: 1,
                timestamp: 10,
                summary: "Subject",
                facets: [
                    .init(key: "faceVisible", value: .bool(true)),
                    .init(key: "scene", value: .text("studio")),
                ],
                assets: [],
                suggestedTags: [review]
            ),
        ]
        return .init(
            documentID: UUID(),
            taskID: taskID,
            items: [.init(
                media: .init(
                    stableID: "media-1",
                    sourcePath: "/tmp/First.mov",
                    displayName: "First.mov"
                ),
                summaryMetrics: [
                    .init(key: "totalFrames", value: 2, unit: .count),
                    .init(key: "faceVisible", value: 1, unit: .count),
                ],
                facets: [],
                moments: moments,
                suggestedTags: [review],
                report: nil
            )],
            suggestedTags: [review],
            actions: MediaAnalysisAction.standard,
            managedTagLedger: .init(mediaEntries: []),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
    }

    private static func plugin(
        id: String,
        actionID: String,
        execution: PluginExecution
    ) -> LoadedPlugin {
        let isHTTP = if case .http = execution { true } else { false }
        return LoadedPlugin(
            manifest: .init(
                schemaVersion: isHTTP ? 2 : 1,
                id: id,
                name: id,
                version: "1.0.0",
                description: nil,
                author: nil,
                execution: execution,
                actions: [.init(
                    id: actionID,
                    title: actionID,
                    category: nil,
                    selection: .init(),
                    match: nil,
                    output: .init(
                        resultType: MediaAnalysisDocument.schemaIdentifier,
                        canCopyToClipboard: false
                    )
                )],
                permissions: .init(
                    readFiles: "selected",
                    writeFiles: "taskOutput",
                    network: .init(
                        required: isHTTP,
                        hosts: isHTTP ? ["127.0.0.1"] : []
                    ),
                    clipboardWrite: false,
                    clipboardRead: false,
                    keychainSecrets: isHTTP ? ["serverToken"] : [],
                    remoteAccounts: false,
                    runExternalCommands: !isHTTP
                ),
                configuration: isHTTP
                    ? [.init(key: "serverURL", type: "url", title: "Server")]
                    : []
            ),
            directory: FileManager.default.temporaryDirectory
        )
    }

    private static func request(
        plugin: LoadedPlugin,
        taskID: UUID,
        configuration: [String: String] = [:],
        secretReferences: [String: String] = [:]
    ) -> PluginExecutionRequest {
        .init(
            plugin: plugin,
            pluginVersion: plugin.manifest.version,
            action: plugin.manifest.actions[0],
            taskID: taskID,
            app: .init(name: "OpenFinder", version: "test"),
            context: .init(activePane: "left", currentLocation: .local(path: "/tmp")),
            files: [],
            configurationValues: configuration,
            secretReferences: secretReferences
        )
    }
}
