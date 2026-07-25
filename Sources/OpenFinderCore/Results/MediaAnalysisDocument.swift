import Foundation

public struct MediaAnalysisDocument: Codable, Hashable, Sendable {
    public static let schemaIdentifier = "mediaAnalysis.v1"
    public static let currentSchemaVersion = 1

    public let schemaID: String
    public let schemaVersion: Int
    public let documentID: UUID
    public let taskID: UUID
    public let items: [MediaAnalysisItem]
    public let suggestedTags: [MediaSuggestedTag]
    public let actions: [MediaAnalysisAction]
    public let managedTagLedger: ManagedTagLedger
    public let createdAt: Date

    public init(
        documentID: UUID,
        taskID: UUID,
        items: [MediaAnalysisItem],
        suggestedTags: [MediaSuggestedTag],
        actions: [MediaAnalysisAction],
        managedTagLedger: ManagedTagLedger,
        createdAt: Date,
        schemaID: String = MediaAnalysisDocument.schemaIdentifier,
        schemaVersion: Int = MediaAnalysisDocument.currentSchemaVersion
    ) {
        self.schemaID = schemaID
        self.schemaVersion = schemaVersion
        self.documentID = documentID
        self.taskID = taskID
        self.items = items
        self.suggestedTags = suggestedTags
        self.actions = actions
        self.managedTagLedger = managedTagLedger
        self.createdAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaID, schemaVersion, documentID, taskID, items, suggestedTags
        case actions, managedTagLedger, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaID = try container.decode(String.self, forKey: .schemaID)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaID == Self.schemaIdentifier else {
            throw MediaAnalysisValidationError.unsupportedSchemaID(schemaID)
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MediaAnalysisValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaID = schemaID
        self.schemaVersion = schemaVersion
        documentID = try container.decode(UUID.self, forKey: .documentID)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        items = try container.decode([MediaAnalysisItem].self, forKey: .items)
        suggestedTags = try container.decode([MediaSuggestedTag].self, forKey: .suggestedTags)
        actions = try container.decode([MediaAnalysisAction].self, forKey: .actions)
        managedTagLedger = try container.decode(ManagedTagLedger.self, forKey: .managedTagLedger)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func validate(artifacts: [UUID: ArtifactRecord]) throws {
        guard schemaID == Self.schemaIdentifier else {
            throw MediaAnalysisValidationError.unsupportedSchemaID(schemaID)
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MediaAnalysisValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        for item in items {
            guard !item.media.stableID.isEmpty else {
                throw MediaAnalysisValidationError.missingStableMediaID
            }
            for reference in item.assetReferences {
                try reference.validate(artifacts: artifacts)
            }
        }
    }

    func replacingAssetPaths(_ pathsByArtifactID: [UUID: String]) throws -> Self {
        Self(
            documentID: documentID,
            taskID: taskID,
            items: try items.map { try $0.replacingAssetPaths(pathsByArtifactID) },
            suggestedTags: suggestedTags,
            actions: actions,
            managedTagLedger: managedTagLedger,
            createdAt: createdAt,
            schemaID: schemaID,
            schemaVersion: schemaVersion
        )
    }
}

public struct MediaAnalysisItem: Codable, Hashable, Sendable {
    public let media: StableMediaIdentity
    public let summaryMetrics: [MediaSummaryMetric]
    public let facets: [MediaFacet]
    public let moments: [MediaAnalysisMoment]
    public let suggestedTags: [MediaSuggestedTag]
    public let report: ConfinedAssetReference?

    public init(
        media: StableMediaIdentity,
        summaryMetrics: [MediaSummaryMetric],
        facets: [MediaFacet],
        moments: [MediaAnalysisMoment],
        suggestedTags: [MediaSuggestedTag],
        report: ConfinedAssetReference?
    ) {
        self.media = media
        self.summaryMetrics = summaryMetrics
        self.facets = facets
        self.moments = moments
        self.suggestedTags = suggestedTags
        self.report = report
    }

    fileprivate var assetReferences: [ConfinedAssetReference] {
        moments.flatMap(\.assets) + [report].compactMap { $0 }
    }

    fileprivate func replacingAssetPaths(_ pathsByArtifactID: [UUID: String]) throws -> Self {
        Self(
            media: media,
            summaryMetrics: summaryMetrics,
            facets: facets,
            moments: try moments.map { try $0.replacingAssetPaths(pathsByArtifactID) },
            suggestedTags: suggestedTags,
            report: try report.map { try $0.replacingAssetPath(pathsByArtifactID) }
        )
    }
}

public struct StableMediaIdentity: Codable, Hashable, Sendable {
    public let stableID: String
    public let sourcePath: String
    public let displayName: String

    public init(stableID: String, sourcePath: String, displayName: String) {
        self.stableID = stableID
        self.sourcePath = sourcePath
        self.displayName = displayName
    }
}

public struct MediaSummaryMetric: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, Hashable, Sendable {
        case count
        case ratio
        case seconds
        case score
    }

    public let key: String
    public let value: Double
    public let unit: Unit

    public init(key: String, value: Double, unit: Unit) {
        self.key = key
        self.value = value
        self.unit = unit
    }
}

public struct MediaFacet: Codable, Hashable, Sendable {
    public let key: String
    public let value: MediaFacetValue

    public init(key: String, value: MediaFacetValue) {
        self.key = key
        self.value = value
    }
}

public enum MediaFacetValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .text(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }
}

public struct MediaAnalysisMoment: Codable, Hashable, Sendable {
    public let index: Int
    public let timestamp: Double
    public let summary: String
    public let facets: [MediaFacet]
    public let assets: [ConfinedAssetReference]
    public let suggestedTags: [MediaSuggestedTag]

    public init(
        index: Int,
        timestamp: Double,
        summary: String,
        facets: [MediaFacet],
        assets: [ConfinedAssetReference],
        suggestedTags: [MediaSuggestedTag]
    ) {
        self.index = index
        self.timestamp = timestamp
        self.summary = summary
        self.facets = facets
        self.assets = assets
        self.suggestedTags = suggestedTags
    }

    fileprivate func replacingAssetPaths(_ pathsByArtifactID: [UUID: String]) throws -> Self {
        Self(
            index: index,
            timestamp: timestamp,
            summary: summary,
            facets: facets,
            assets: try assets.map { try $0.replacingAssetPath(pathsByArtifactID) },
            suggestedTags: suggestedTags
        )
    }
}

public struct ConfinedAssetReference: Codable, Hashable, Sendable {
    public let artifactID: UUID
    public let relativePath: String

    public init(artifactID: UUID, relativePath: String) {
        self.artifactID = artifactID
        self.relativePath = relativePath
    }

    fileprivate func validate(artifacts: [UUID: ArtifactRecord]) throws {
        try validateConfinement()
        guard let artifact = artifacts[artifactID] else {
            throw MediaAnalysisValidationError.unknownArtifact(artifactID)
        }
        try artifact.validate()
        guard artifact.state == .committed else {
            throw MediaAnalysisValidationError.artifactNotCommitted(artifactID)
        }
        guard artifact.schemaID == MediaAnalysisDocument.schemaIdentifier else {
            throw MediaAnalysisValidationError.artifactSchemaMismatch(artifactID)
        }
        guard artifact.relativePath == relativePath else {
            throw MediaAnalysisValidationError.artifactPathMismatch(artifactID)
        }
    }

    fileprivate func replacingAssetPath(_ pathsByArtifactID: [UUID: String]) throws -> Self {
        try validateConfinement()
        guard let relativePath = pathsByArtifactID[artifactID] else {
            throw MediaAnalysisValidationError.unknownArtifact(artifactID)
        }
        return Self(artifactID: artifactID, relativePath: relativePath)
    }

    private func validateConfinement() throws {
        guard !NSString(string: relativePath).isAbsolutePath else {
            throw MediaAnalysisValidationError.absoluteAssetPath(relativePath)
        }
        let components = NSString(string: relativePath).pathComponents
        guard !relativePath.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw MediaAnalysisValidationError.unconfinedAssetPath(relativePath)
        }
    }
}

public struct MediaSuggestedTag: Codable, Hashable, Sendable {
    public let name: String
    public let category: String
    public let confidence: Double
    public let frameRatio: Double
    public let source: String
    public let modelVersion: String

    public init(
        name: String,
        category: String,
        confidence: Double,
        frameRatio: Double,
        source: String,
        modelVersion: String
    ) {
        self.name = name
        self.category = category
        self.confidence = confidence
        self.frameRatio = frameRatio
        self.source = source
        self.modelVersion = modelVersion
    }
}

public struct MediaAnalysisAction: Codable, Hashable, Sendable {
    public enum Identifier: String, Codable, Hashable, Sendable {
        case applySuggestedTags
        case openMoment
        case revealAsset
        case exportReport
    }

    public static let standard = Identifier.allCases.map(Self.init)

    public let id: Identifier

    public init(id: Identifier) {
        self.id = id
    }
}

extension MediaAnalysisAction.Identifier: CaseIterable {}

public struct ManagedTagLedger: Codable, Hashable, Sendable {
    public let mediaEntries: [ManagedTagLedgerEntry]

    public init(mediaEntries: [ManagedTagLedgerEntry]) {
        self.mediaEntries = mediaEntries
    }

    public func reconcile(
        stableMediaID: String,
        currentTagNames: Set<String>,
        suggestedTagNames: Set<String>
    ) -> ManagedTagReconciliation {
        let previouslyManaged = Set(
            mediaEntries.first { $0.stableMediaID == stableMediaID }?.tagNames ?? []
        )
        return ManagedTagReconciliation(
            add: suggestedTagNames.subtracting(currentTagNames),
            remove: previouslyManaged.subtracting(suggestedTagNames),
            nextManaged: suggestedTagNames
        )
    }
}

public struct ManagedTagLedgerEntry: Codable, Hashable, Sendable {
    public let stableMediaID: String
    public let tagNames: Set<String>

    public init(stableMediaID: String, tagNames: Set<String>) {
        self.stableMediaID = stableMediaID
        self.tagNames = tagNames
    }
}

public struct ManagedTagReconciliation: Codable, Hashable, Sendable {
    public let add: Set<String>
    public let remove: Set<String>
    public let nextManaged: Set<String>

    public init(add: Set<String>, remove: Set<String>, nextManaged: Set<String>) {
        self.add = add
        self.remove = remove
        self.nextManaged = nextManaged
    }
}

public enum MediaAnalysisValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaID(String)
    case unsupportedSchemaVersion(Int)
    case missingStableMediaID
    case absoluteAssetPath(String)
    case unconfinedAssetPath(String)
    case unknownArtifact(UUID)
    case artifactNotCommitted(UUID)
    case artifactSchemaMismatch(UUID)
    case artifactPathMismatch(UUID)
    case missingAssetReference(String)
}
