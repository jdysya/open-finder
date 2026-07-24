import Foundation
import OpenFinderCore

struct ExactPluginConnectionChecker: PluginConnectionChecking {
    func check(
        manifest: PluginManifest,
        values: [String: String],
        secretReferences: [String: String]
    ) async -> PluginConnectionStatus {
        .init(
            state: .ready,
            guidance: "ready",
            protocolVersion: 1,
            pluginID: manifest.id,
            pluginVersion: manifest.version
        )
    }
}

actor MediaDocumentPluginRunner: PluginRunner {
    private var requests: [PluginRunRequest] = []

    func run(_ request: PluginRunRequest) async throws -> PluginRunResult {
        requests.append(request)
        let document = MediaAnalysisDocument(
            documentID: UUID(),
            taskID: request.input.taskID,
            items: [],
            suggestedTags: [],
            actions: MediaAnalysisAction.standard,
            managedTagLedger: .init(mediaEntries: []),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let content = String(
            decoding: try JSONEncoder.openFinder.encode(document),
            as: UTF8.self
        )
        let event = PluginOutputEvent.result(
            status: "success",
            message: "done",
            clipboard: nil,
            artifacts: [.init(type: MediaAnalysisDocument.schemaIdentifier, content: content)]
        )
        request.onEvent?(event)
        return .init(exitCode: 0, events: [event], stdout: "", stderr: "")
    }

    func cancel(taskID: UUID) async {}
    func captured() -> [PluginRunRequest] { requests }
}

extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
