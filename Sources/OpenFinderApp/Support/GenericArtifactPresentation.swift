import OpenFinderCore

struct GenericArtifactPresentation: Sendable {
    static let emptyTitle = "没有可显示的产物"

    let schemaID: String
    let message: String?
    let artifacts: [PluginArtifact]

    var emptyTitle: String { Self.emptyTitle }

    init?(projection: PluginResultProjection) {
        guard let result = projection.project(UnknownPluginResult.self) else { return nil }
        schemaID = result.schemaID
        message = result.message
        artifacts = result.artifacts
    }
}
