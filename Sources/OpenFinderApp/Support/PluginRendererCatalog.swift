import OpenFinderCore

enum PluginRendererIdentifier: String, Equatable, Sendable {
    case mediaAnalysis = "mediaAnalysis.v1"
    case unknown = "unknown"
}

struct PluginRendererDescriptor: Equatable, Sendable {
    let identifier: PluginRendererIdentifier
}

struct PluginRendererCatalog: Sendable {
    struct Entry: Sendable {
        let resultSchemaID: String
        let descriptor: PluginRendererDescriptor
        let accepts: @Sendable (PluginResultProjection) -> Bool

        static let mediaAnalysis = Entry(
            resultSchemaID: MediaAnalysisDocument.schemaIdentifier,
            descriptor: .init(identifier: .mediaAnalysis),
            accepts: { $0.project(MediaAnalysisDocument.self) != nil }
        )
    }

    private let entries: [String: Entry]
    private let fallback = PluginRendererDescriptor(identifier: .unknown)

    init(entries: [Entry]) {
        var indexed: [String: Entry] = [:]
        for entry in entries where indexed[entry.resultSchemaID] == nil {
            indexed[entry.resultSchemaID] = entry
        }
        self.entries = indexed
    }

    func renderer(for projection: PluginResultProjection) -> PluginRendererDescriptor {
        guard let entry = entries[projection.resultSchemaID],
              entry.accepts(projection) else {
            return fallback
        }
        return entry.descriptor
    }

    static let standard = PluginRendererCatalog(entries: [.mediaAnalysis])
}
