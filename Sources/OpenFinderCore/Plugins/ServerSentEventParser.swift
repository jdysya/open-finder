import Foundation

public enum ServerSentEventParserError: Error, Equatable, Sendable {
    case eventTooLarge(limit: Int)
    case invalidUTF8
    case invalidEventID(String)
    case duplicateSSEField(String)
    case missingSSEField(String)
    case invalidJSON
    case unsupportedSchemaVersion(Int)
    case taskIDMismatch(expected: UUID, actual: UUID)
    case eventIDMismatch(sse: Int, json: Int)
    case eventTypeMismatch(sse: String, json: String)
    case nonMonotonicEventID(previous: Int, current: Int)
    case invalidEvent(field: String)
    case duplicateTerminalEvent
    case eventAfterTerminal
    case truncatedEvent
    case missingTerminalEvent
    case parserAlreadyFailed
    case parserAlreadyFinished
}

extension ServerSentEventParserError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .eventTooLarge(let limit): "SSE event exceeds the \(limit)-byte limit."
        case .invalidUTF8: "SSE data is not valid UTF-8."
        case .invalidEventID: "SSE event ID must be a positive decimal integer."
        case .duplicateSSEField(let field): "SSE event repeats the \(field) field."
        case .missingSSEField(let field): "SSE event is missing the \(field) field."
        case .invalidJSON: "SSE data is not a valid HTTP plugin event object."
        case .unsupportedSchemaVersion(let version): "Unsupported HTTP plugin event schema \(version)."
        case .taskIDMismatch: "SSE event belongs to a different task."
        case .eventIDMismatch: "SSE and JSON event IDs do not match."
        case .eventTypeMismatch: "SSE and JSON event types do not match."
        case .nonMonotonicEventID: "SSE event IDs are not strictly increasing."
        case .invalidEvent: "HTTP plugin event does not match the v1 schema."
        case .duplicateTerminalEvent: "SSE stream contains more than one terminal event."
        case .eventAfterTerminal: "SSE stream contains an event after its terminal event."
        case .truncatedEvent: "SSE stream ended in the middle of an event."
        case .missingTerminalEvent: "SSE stream ended without a terminal event."
        case .parserAlreadyFailed: "SSE parser cannot continue after a protocol error."
        case .parserAlreadyFinished: "SSE parser has already finished."
        }
    }
}

public struct ServerSentEventParser: Sendable {
    public static let maximumEventBytes = 1_048_576

    public let expectedTaskID: UUID
    public private(set) var lastEventID: Int
    public private(set) var hasReceivedTerminalEvent = false

    public var bufferedByteCount: Int {
        frameByteCount + lineBuffer.count
    }

    private let eventByteLimit: Int
    private var lineBuffer = Data()
    private var frameByteCount = 0
    private var frameID: String?
    private var frameEvent: String?
    private var frameData = Data()
    private var dataLineCount = 0
    private var failed = false
    private var finished = false

    public init(
        expectedTaskID: UUID,
        lastEventID: Int = 0,
        maximumEventBytes: Int = ServerSentEventParser.maximumEventBytes
    ) {
        precondition(lastEventID >= 0, "Last-Event-ID cannot be negative")
        precondition(maximumEventBytes > 0, "SSE event byte limit must be positive")
        self.expectedTaskID = expectedTaskID
        self.lastEventID = lastEventID
        eventByteLimit = maximumEventBytes
    }

    public mutating func append(_ chunk: Data) throws -> [HTTPPluginEvent] {
        guard !failed else { throw ServerSentEventParserError.parserAlreadyFailed }
        guard !finished else { throw ServerSentEventParserError.parserAlreadyFinished }

        do {
            var events: [HTTPPluginEvent] = []
            for byte in chunk {
                if byte == 0x0a {
                    let addedBytes = lineBuffer.count + 1
                    guard frameByteCount <= eventByteLimit - addedBytes else {
                        throw ServerSentEventParserError.eventTooLarge(limit: eventByteLimit)
                    }
                    frameByteCount += addedBytes
                    let outcome = try processCompletedLine()
                    lineBuffer.removeAll(keepingCapacity: true)
                    if outcome.endedFrame {
                        frameByteCount = 0
                    }
                    if let event = outcome.event {
                        events.append(event)
                    }
                } else {
                    guard frameByteCount + lineBuffer.count < eventByteLimit else {
                        throw ServerSentEventParserError.eventTooLarge(limit: eventByteLimit)
                    }
                    lineBuffer.append(byte)
                }
            }
            return events
        } catch let error as ServerSentEventParserError {
            failed = true
            throw error
        } catch {
            failed = true
            throw ServerSentEventParserError.invalidJSON
        }
    }

    public mutating func finish() throws {
        guard !failed else { throw ServerSentEventParserError.parserAlreadyFailed }
        guard !finished else { return }

        do {
            guard lineBuffer.isEmpty, frameByteCount == 0, frameID == nil, frameEvent == nil,
                  frameData.isEmpty, dataLineCount == 0
            else {
                throw ServerSentEventParserError.truncatedEvent
            }
            guard hasReceivedTerminalEvent else {
                throw ServerSentEventParserError.missingTerminalEvent
            }
            finished = true
        } catch let error as ServerSentEventParserError {
            failed = true
            throw error
        }
    }

    private mutating func processCompletedLine() throws -> (endedFrame: Bool, event: HTTPPluginEvent?) {
        var bytes = lineBuffer
        if bytes.last == 0x0d {
            bytes.removeLast()
        }
        guard let line = String(data: bytes, encoding: .utf8) else {
            throw ServerSentEventParserError.invalidUTF8
        }

        guard !line.isEmpty else {
            let event = try dispatchFrame()
            resetFrame()
            return (true, event)
        }
        guard !line.hasPrefix(":") else {
            return (false, nil)
        }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " {
                value.removeFirst()
            }
        } else {
            field = line[...]
            value = ""
        }

        switch field {
        case "id":
            guard frameID == nil else {
                throw ServerSentEventParserError.duplicateSSEField("id")
            }
            let id = String(value)
            _ = try parseEventID(id)
            frameID = id
        case "event":
            guard frameEvent == nil else {
                throw ServerSentEventParserError.duplicateSSEField("event")
            }
            frameEvent = String(value)
        case "data":
            if dataLineCount > 0 {
                frameData.append(0x0a)
            }
            frameData.append(contentsOf: value.utf8)
            dataLineCount += 1
        default:
            break
        }
        return (false, nil)
    }

    private mutating func dispatchFrame() throws -> HTTPPluginEvent? {
        let hasProtocolFields = frameID != nil || frameEvent != nil || dataLineCount > 0
        guard hasProtocolFields else { return nil }
        guard let rawID = frameID else {
            throw ServerSentEventParserError.missingSSEField("id")
        }
        guard let eventType = frameEvent, !eventType.isEmpty else {
            throw ServerSentEventParserError.missingSSEField("event")
        }
        guard dataLineCount > 0 else {
            throw ServerSentEventParserError.missingSSEField("data")
        }

        let eventID = try parseEventID(rawID)
        guard eventID > lastEventID else {
            throw ServerSentEventParserError.nonMonotonicEventID(previous: lastEventID, current: eventID)
        }
        let event = try HTTPPluginEvent.decode(
            frameData,
            sseEventID: eventID,
            sseEventType: eventType,
            expectedTaskID: expectedTaskID
        )

        if hasReceivedTerminalEvent {
            if event.type == .result {
                throw ServerSentEventParserError.duplicateTerminalEvent
            }
            throw ServerSentEventParserError.eventAfterTerminal
        }
        if event.type == .result {
            hasReceivedTerminalEvent = true
        }
        lastEventID = eventID
        return event
    }

    private mutating func resetFrame() {
        frameID = nil
        frameEvent = nil
        frameData.removeAll(keepingCapacity: true)
        dataLineCount = 0
    }

    private func parseEventID(_ value: String) throws -> Int {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              let eventID = Int(value),
              eventID > 0
        else {
            throw ServerSentEventParserError.invalidEventID(value)
        }
        return eventID
    }
}
