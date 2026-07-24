import Foundation

public enum PluginResultHandlerIdentifier: String, Hashable, Sendable {
    case mediaAnalysis = "mediaAnalysis.v1"
    case unknown = "unknown"
}

public enum PluginResultHandlingError: Error, Equatable, Sendable {
    case duplicateSchema(String)
    case schemaMismatch(expected: String, actual: String)
    case missingSchemaArtifact(String)
    case malformedSchemaArtifact(String)
    case taskIDMismatch(expected: UUID, actual: UUID)
}

public struct PluginResultHandlingContext: Sendable {
    public let resultSchemaID: String
    public let pluginID: String
    public let pluginVersion: String
    public let actionID: String
    public let taskID: UUID
    public let events: [PluginOutputEvent]
    public let outputDirectory: URL

    public init(
        resultSchemaID: String,
        pluginID: String,
        pluginVersion: String,
        actionID: String,
        taskID: UUID,
        events: [PluginOutputEvent],
        outputDirectory: URL
    ) {
        self.resultSchemaID = resultSchemaID
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.actionID = actionID
        self.taskID = taskID
        self.events = events
        self.outputDirectory = outputDirectory
    }
}

public struct UnknownPluginResult: Hashable, Sendable {
    public let schemaID: String
    public let taskID: UUID
    public let outputDirectory: URL
    public let artifacts: [PluginArtifact]
    public let message: String?

    public init(
        schemaID: String,
        taskID: UUID,
        outputDirectory: URL,
        artifacts: [PluginArtifact],
        message: String?
    ) {
        self.schemaID = schemaID
        self.taskID = taskID
        self.outputDirectory = outputDirectory
        self.artifacts = artifacts
        self.message = message
    }
}

public struct PluginResultProjection: Sendable {
    public let resultSchemaID: String
    public let handlerIdentifier: PluginResultHandlerIdentifier
    private let value: any Sendable

    public init<Value: Sendable>(
        resultSchemaID: String,
        handlerIdentifier: PluginResultHandlerIdentifier,
        value: Value
    ) {
        self.resultSchemaID = resultSchemaID
        self.handlerIdentifier = handlerIdentifier
        self.value = value
    }

    public func project<Value: Sendable>(_ type: Value.Type) -> Value? {
        value as? Value
    }
}

public struct PluginResultHandler: Sendable {
    public typealias Operation = @Sendable (
        PluginResultHandlingContext
    ) async throws -> PluginResultProjection

    public let schemaID: String
    public let identifier: PluginResultHandlerIdentifier
    private let operation: Operation

    public init(
        schemaID: String,
        identifier: PluginResultHandlerIdentifier,
        operation: @escaping Operation
    ) {
        self.schemaID = schemaID
        self.identifier = identifier
        self.operation = operation
    }

    public func handle(_ context: PluginResultHandlingContext) async throws -> PluginResultProjection {
        guard context.resultSchemaID == schemaID else {
            throw PluginResultHandlingError.schemaMismatch(
                expected: schemaID,
                actual: context.resultSchemaID
            )
        }
        return try await operation(context)
    }
}

public struct PluginResultHandlerRegistry: Sendable {
    private let handlers: [String: PluginResultHandler]

    private init(indexedHandlers: [String: PluginResultHandler]) {
        handlers = indexedHandlers
    }

    public init(handlers: [PluginResultHandler] = []) throws {
        var indexed: [String: PluginResultHandler] = [:]
        for handler in handlers {
            guard indexed[handler.schemaID] == nil else {
                throw PluginResultHandlingError.duplicateSchema(handler.schemaID)
            }
            indexed[handler.schemaID] = handler
        }
        self.handlers = indexed
    }

    public func handle(
        _ context: PluginResultHandlingContext
    ) async throws -> PluginResultProjection {
        if let handler = handlers[context.resultSchemaID] {
            return try await handler.handle(context)
        }
        let artifacts = context.events.flatMap(\.resultArtifacts)
        let message = context.events.compactMap(\.resultMessage).last
        return .init(
            resultSchemaID: context.resultSchemaID,
            handlerIdentifier: .unknown,
            value: UnknownPluginResult(
                schemaID: context.resultSchemaID,
                taskID: context.taskID,
                outputDirectory: context.outputDirectory,
                artifacts: artifacts,
                message: message
            )
        )
    }

    public static let mediaAnalysis = PluginResultHandler(
        schemaID: MediaAnalysisDocument.schemaIdentifier,
        identifier: .mediaAnalysis
    ) { context in
        let artifacts = context.events
            .flatMap(\.resultArtifacts)
            .filter { $0.type == context.resultSchemaID }
        guard artifacts.count == 1, let artifact = artifacts.first else {
            throw PluginResultHandlingError.missingSchemaArtifact(context.resultSchemaID)
        }
        let data: Data
        switch artifact.payload {
        case .inline(let content):
            data = Data(content.utf8)
        case .file(let file):
            guard file.mediaType == "application/json" else {
                throw PluginResultHandlingError.malformedSchemaArtifact(context.resultSchemaID)
            }
            do {
                data = try ConfinedArtifactReader(root: context.outputDirectory).read(file)
            } catch {
                throw PluginResultHandlingError.malformedSchemaArtifact(context.resultSchemaID)
            }
        }
        let document: MediaAnalysisDocument
        do {
            document = try JSONDecoder.openFinder.decode(MediaAnalysisDocument.self, from: data)
        } catch {
            throw PluginResultHandlingError.malformedSchemaArtifact(context.resultSchemaID)
        }
        guard document.taskID == context.taskID else {
            throw PluginResultHandlingError.taskIDMismatch(
                expected: context.taskID,
                actual: document.taskID
            )
        }
        return .init(
            resultSchemaID: context.resultSchemaID,
            handlerIdentifier: .mediaAnalysis,
            value: document
        )
    }

    public static let standard = PluginResultHandlerRegistry(indexedHandlers: [
        MediaAnalysisDocument.schemaIdentifier: mediaAnalysis
    ])
}

private extension PluginOutputEvent {
    var resultArtifacts: [PluginArtifact] {
        guard case .result(_, _, _, let artifacts) = self else { return [] }
        return artifacts
    }
}
