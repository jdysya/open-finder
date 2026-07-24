import Foundation

public enum TransferTaskEnvelopeError: Error, Equatable, Sendable {
    case unsupportedHandler(DurableTaskHandlerID)
    case missingPayload
    case malformedPayload
}

extension TransferTaskEnvelopeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedHandler(let handlerID):
            "Unsupported transfer handler: \(handlerID.rawValue)"
        case .missingPayload:
            "The transfer task payload is missing"
        case .malformedPayload:
            "The transfer task payload is malformed"
        }
    }
}

public struct TransferTaskEnvelope: Codable, Hashable, Sendable {
    public static let payloadKey = "transfer"

    public let entries: [TransferEntrySnapshot]
    public let source: Location
    public let destination: Location
    public let overwrite: TransferOverwritePolicy
    public let destinationSnapshots: [TransferEntrySnapshot?]
    public let sourceRevision: String
    public let destinationRevision: String

    public init(
        entries: [TransferEntrySnapshot],
        source: Location,
        destination: Location,
        overwrite: TransferOverwritePolicy,
        destinationSnapshots: [TransferEntrySnapshot?]? = nil,
        sourceRevision: String = "0",
        destinationRevision: String = "0"
    ) {
        self.entries = entries
        self.source = source
        self.destination = destination
        self.overwrite = overwrite
        self.destinationSnapshots = destinationSnapshots
            ?? Array(repeating: nil, count: entries.count)
        self.sourceRevision = sourceRevision
        self.destinationRevision = destinationRevision
    }

    public func makeDescriptor(
        taskID: UUID,
        handlerID: DurableTaskHandlerID,
        resourceKey: String,
        idempotencyKey: String,
        lineage: TaskAttemptLineage,
        queueOrdinal: UInt64
    ) throws -> TaskDescriptorEnvelope {
        guard handlerID == .transferCopy || handlerID == .transferMove else {
            throw TransferTaskEnvelopeError.unsupportedHandler(handlerID)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw TransferTaskEnvelopeError.malformedPayload
        }
        return TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: handlerID.rawValue,
            payloadVersion: 1,
            resourceKey: resourceKey,
            idempotencyKey: idempotencyKey,
            lineage: lineage,
            queueOrdinal: queueOrdinal,
            redactedPayload: [Self.payloadKey: payload]
        )
    }

    public func idempotencyKey(for handlerID: DurableTaskHandlerID) throws -> String {
        guard handlerID == .transferCopy || handlerID == .transferMove else {
            throw TransferTaskEnvelopeError.unsupportedHandler(handlerID)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "\(handlerID.rawValue):\(try encoder.encode(self).base64EncodedString())"
    }

    public static func decode(
        from descriptor: TaskDescriptorEnvelope
    ) throws -> TransferTaskEnvelope {
        guard let payload = descriptor.redactedPayload[payloadKey] else {
            throw TransferTaskEnvelopeError.missingPayload
        }
        guard let data = payload.data(using: .utf8) else {
            throw TransferTaskEnvelopeError.malformedPayload
        }
        do {
            let envelope = try JSONDecoder().decode(Self.self, from: data)
            guard !envelope.entries.isEmpty,
                  envelope.destinationSnapshots.count == envelope.entries.count
            else {
                throw TransferTaskEnvelopeError.malformedPayload
            }
            return envelope
        } catch let error as TransferTaskEnvelopeError {
            throw error
        } catch {
            throw TransferTaskEnvelopeError.malformedPayload
        }
    }
}
