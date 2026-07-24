import Foundation

public enum PluginTaskEnvelopeError: Error, Equatable, Sendable {
    case unsupportedHandler(String)
    case unsupportedPayloadVersion(Int)
    case missingPayload
    case malformedPayload
    case emptyIdentity(String)
    case emptyResultSchemaID
    case configurationContainsSecretKey(String)
}

extension PluginTaskEnvelopeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedHandler(let handlerID):
            "Unsupported plugin task handler: \(handlerID)"
        case .unsupportedPayloadVersion(let version):
            "Unsupported plugin task payload version: \(version)"
        case .missingPayload:
            "The plugin task payload is missing"
        case .malformedPayload:
            "The plugin task payload is malformed"
        case .emptyIdentity(let field):
            "The plugin task \(field) must not be empty"
        case .emptyResultSchemaID:
            "The plugin task result schema snapshot must not be empty"
        case .configurationContainsSecretKey(let key):
            "Plugin configuration must not persist credential key \(key)"
        }
    }
}

public struct PluginTaskOutputPolicy: Codable, Hashable, Sendable {
    public let canCopyToClipboard: Bool

    public init(canCopyToClipboard: Bool) {
        self.canCopyToClipboard = canCopyToClipboard
    }
}

public enum PluginTaskWorkspacePolicy: String, Codable, Hashable, Sendable {
    case taskScopedTemporary
}

public struct PluginTaskAppSnapshot: Codable, Hashable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct PluginTaskContextSnapshot: Codable, Hashable, Sendable {
    public let activePane: String
    public let currentLocation: Location

    public init(activePane: String, currentLocation: Location) {
        self.activePane = activePane
        self.currentLocation = currentLocation
    }
}

public struct PluginTaskFileIdentity: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: FileKind
    public let size: Int64?
    public let modificationDate: Date?
    public let uti: String?
    public let mimeType: String?
    public let fileExtension: String?

    public init(
        id: String,
        name: String,
        kind: FileKind,
        size: Int64?,
        modificationDate: Date?,
        uti: String?,
        mimeType: String?,
        fileExtension: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.uti = uti
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }

    public init(_ item: FileItem) {
        self.init(
            id: item.id,
            name: item.name,
            kind: item.kind,
            size: item.size,
            modificationDate: item.modificationDate,
            uti: item.uti,
            mimeType: item.mimeType,
            fileExtension: item.fileExtension
        )
    }
}

public struct PluginTaskInputSnapshot: Codable, Hashable, Sendable {
    public let location: Location
    public let identity: PluginTaskFileIdentity

    public init(location: Location, identity: PluginTaskFileIdentity) {
        self.location = location
        self.identity = identity
    }

    public init(_ item: FileItem) {
        self.init(location: item.location, identity: .init(item))
    }

    var pluginInputFile: PluginInputFile {
        PluginInputFile(item: FileItem(
            id: identity.id,
            name: identity.name,
            location: location,
            kind: identity.kind,
            size: identity.size,
            modificationDate: identity.modificationDate,
            creationDate: nil,
            uti: identity.uti,
            mimeType: identity.mimeType,
            fileExtension: identity.fileExtension,
            isHidden: false,
            isReadable: true,
            isWritable: false
        ))
    }
}

public struct PluginTaskEnvelope: Codable, Hashable, Sendable {
    public static let payloadKey = "plugin"

    public let pluginID: String
    public let pluginVersion: String
    public let actionID: String
    public let resultSchemaID: String
    public let outputPolicy: PluginTaskOutputPolicy
    public let app: PluginTaskAppSnapshot
    public let context: PluginTaskContextSnapshot
    public let inputs: [PluginTaskInputSnapshot]
    public let configuration: [String: String]
    public let secretReferences: [String: String]
    public let workspacePolicy: PluginTaskWorkspacePolicy

    public init(
        pluginID: String,
        pluginVersion: String,
        actionID: String,
        resultSchemaID: String,
        outputPolicy: PluginTaskOutputPolicy,
        app: PluginTaskAppSnapshot,
        context: PluginTaskContextSnapshot,
        inputs: [PluginTaskInputSnapshot],
        configuration: [String: String],
        secretReferences: [String: String],
        workspacePolicy: PluginTaskWorkspacePolicy
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.actionID = actionID
        self.resultSchemaID = resultSchemaID
        self.outputPolicy = outputPolicy
        self.app = app
        self.context = context
        self.inputs = inputs
        self.configuration = configuration
        self.secretReferences = secretReferences
        self.workspacePolicy = workspacePolicy
    }

    @discardableResult
    public func validated() throws -> Self {
        for (value, field) in [
            (pluginID, "plugin ID"),
            (pluginVersion, "plugin version"),
            (actionID, "action ID"),
            (app.name, "app name"),
            (app.version, "app version"),
            (context.activePane, "active pane")
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PluginTaskEnvelopeError.emptyIdentity(field)
        }
        guard !resultSchemaID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginTaskEnvelopeError.emptyResultSchemaID
        }
        let secretLookingConfigurationKey = configuration.keys.sorted().first {
            let normalized = $0.lowercased()
            return ["secret", "token", "password", "credential", "apikey", "authorization"]
                .contains(where: normalized.contains)
        }
        if let key = Set(configuration.keys).intersection(secretReferences.keys).sorted().first
            ?? secretLookingConfigurationKey {
            throw PluginTaskEnvelopeError.configurationContainsSecretKey(key)
        }
        for input in inputs {
            guard !input.identity.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginTaskEnvelopeError.emptyIdentity("input identity")
            }
            guard !input.identity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginTaskEnvelopeError.emptyIdentity("input name")
            }
        }
        return self
    }

    public func makeDescriptor(
        taskID: UUID,
        resourceKey: String,
        idempotencyKey: String,
        lineage: TaskAttemptLineage,
        queueOrdinal: UInt64
    ) throws -> TaskDescriptorEnvelope {
        try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw PluginTaskEnvelopeError.malformedPayload
        }
        return TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1,
            resourceKey: resourceKey,
            idempotencyKey: idempotencyKey,
            lineage: lineage,
            queueOrdinal: queueOrdinal,
            redactedPayload: [Self.payloadKey: payload]
        )
    }

    public func idempotencyKey() throws -> String {
        try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "plugin:\(try encoder.encode(self).base64EncodedString())"
    }

    public static func decode(from descriptor: TaskDescriptorEnvelope) throws -> Self {
        guard descriptor.handlerID == DurableTaskHandlerID.pluginExecute.rawValue else {
            throw PluginTaskEnvelopeError.unsupportedHandler(descriptor.handlerID)
        }
        guard descriptor.payloadVersion == 1 else {
            throw PluginTaskEnvelopeError.unsupportedPayloadVersion(descriptor.payloadVersion)
        }
        guard let payload = descriptor.redactedPayload[payloadKey] else {
            throw PluginTaskEnvelopeError.missingPayload
        }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(payload.utf8)).validated()
        } catch let error as PluginTaskEnvelopeError {
            throw error
        } catch {
            throw PluginTaskEnvelopeError.malformedPayload
        }
    }
}

public typealias PluginExecuteTaskDescriptor = PluginTaskEnvelope
