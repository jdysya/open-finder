import Foundation
import XCTest
@testable import OpenFinderCore

final class TaskDescriptorContractTests: XCTestCase {
    private let taskID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let rootTaskID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let parentTaskID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let fixtureSecret = "fixture-secret-must-never-persist"

    func testAllApprovedHandlersRoundTrip() throws {
        XCTAssertEqual(DurableTaskHandlerID.allCases.map(\.rawValue), [
            "plugin.execute.v1",
            "transfer.copy.v1",
            "transfer.move.v1"
        ])

        for handler in DurableTaskHandlerID.allCases {
            let descriptor = makeDescriptor(handlerID: handler.rawValue)
            let data = try encoder.encode(descriptor)
            let decoded = try JSONDecoder().decode(TaskDescriptorEnvelope.self, from: data)

            XCTAssertEqual(decoded, descriptor)
            XCTAssertEqual(decoded.availability, .available(handler))
            XCTAssertNil(data.range(of: Data(fixtureSecret.utf8)))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixtureSecret"))
            XCTAssertEqual(String(decoding: data, as: UTF8.self), goldenJSON(handlerID: handler.rawValue))
            print(
                "DESCRIPTOR_OBSERVABLE handler=\(decoded.handlerID) payloadVersion=\(decoded.payloadVersion) " +
                "attempt=\(decoded.lineage.attempt) queueOrdinal=\(decoded.queueOrdinal) secretBytesPresent=false"
            )
        }
    }

    func testUnknownHandlerRemainsVisibleAndDoesNotExecute() async throws {
        let unknownJSON = goldenJSON(handlerID: "third-party.execute.v9")
        let decoded = try JSONDecoder().decode(
            TaskDescriptorEnvelope.self,
            from: Data(unknownJSON.utf8)
        )
        let executions = ExecutionCounter()
        let queue = TaskQueueService(maxConcurrentTasks: 1)

        let id = try await queue.enqueue(.init(
            kind: .plugin(pluginID: "third-party", actionID: "run"),
            title: "Unavailable fixture",
            descriptor: decoded
        ) { _ in
            await executions.increment()
            return .success(summary: "must not execute", clipboard: nil)
        })
        let record = try await queue.waitForTerminalStatus(id, timeout: 2)

        XCTAssertEqual(decoded.handlerID, "third-party.execute.v9")
        XCTAssertEqual(decoded.availability, .unavailable(.unknownHandler))
        XCTAssertEqual(record.status, .unavailable)
        XCTAssertEqual(record.reasonCode, .unknownHandler)
        XCTAssertEqual(record.descriptor, decoded)
        let executionCount = await executions.value
        XCTAssertEqual(executionCount, 0)
        print(
            "UNAVAILABLE_OBSERVABLE handler=\(decoded.handlerID) reason=\(record.reasonCode?.rawValue ?? "missing") " +
            "status=\(record.status.rawValue) executionCount=\(executionCount)"
        )
    }

    func testFuturePayloadVersionRemainsUnavailableAndDoesNotExecute() async throws {
        let futureJSON = goldenJSON(handlerID: DurableTaskHandlerID.pluginExecute.rawValue)
            .replacingOccurrences(of: #""payloadVersion":1"#, with: #""payloadVersion":2"#)
        let decoded = try JSONDecoder().decode(
            TaskDescriptorEnvelope.self,
            from: Data(futureJSON.utf8)
        )
        let executions = ExecutionCounter()
        let queue = TaskQueueService(maxConcurrentTasks: 1)

        let id = try await queue.enqueue(.init(
            kind: .plugin(pluginID: "fixture", actionID: "run"),
            title: "Future fixture",
            descriptor: decoded
        ) { _ in
            await executions.increment()
            return .success(summary: "must not execute", clipboard: nil)
        })
        let record = try await queue.waitForTerminalStatus(id, timeout: 2)

        XCTAssertEqual(decoded.availability, .unavailable(.unsupportedPayloadVersion))
        XCTAssertEqual(record.status, .unavailable)
        XCTAssertEqual(record.reasonCode, .unsupportedPayloadVersion)
        let executionCount = await executions.value
        XCTAssertEqual(executionCount, 0)
    }

    func testMalformedDescriptorJSONIsRejected() {
        let malformed = Data(#"{"handlerID":"plugin.execute.v1","payloadVersion":"one"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskDescriptorEnvelope.self, from: malformed))
    }

    func testInterruptedAndUnavailableAreImmutableTerminalStatuses() async throws {
        XCTAssertTrue(TaskStatus.interrupted.isTerminal)
        XCTAssertTrue(TaskStatus.unavailable.isTerminal)
        XCTAssertEqual(
            try JSONDecoder().decode(TaskStatus.self, from: Data(#""interrupted""#.utf8)),
            .interrupted
        )
        var interrupted = TaskRecord(kind: .localCopy, title: "Recovered")
        let interruptedAt = Date(timeIntervalSince1970: 1_735_689_600)
        interrupted.markInterrupted(at: interruptedAt)
        let firstInterruption = interrupted
        interrupted.markInterrupted(reasonCode: .handlerUnavailable, at: interruptedAt.addingTimeInterval(1))
        XCTAssertEqual(interrupted, firstInterruption)
        XCTAssertEqual(interrupted.reasonCode, .recoveryInterrupted)

        let executions = ExecutionCounter()
        let queue = TaskQueueService(maxConcurrentTasks: 1)
        let descriptor = makeDescriptor(handlerID: "missing.handler.v1")
        let id = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Terminal fixture",
            descriptor: descriptor
        ) { _ in
            await executions.increment()
            return .success(summary: "must not execute", clipboard: nil)
        })
        let terminal = try await queue.waitForTerminalStatus(id, timeout: 2)

        await queue.cancel(id)
        await queue.cancel(id)
        await queue.updateProgress(id, 0.5, message: "late mutation")
        let afterInterruptions = await queue.record(for: id)
        let logs = await queue.logs(for: id)
        XCTAssertEqual(afterInterruptions, terminal)
        XCTAssertTrue(logs.isEmpty)
        let executionCount = await executions.value
        XCTAssertEqual(executionCount, 0)
    }

    func testFixedGoldenDescriptorDecodesIdenticallyTwice() throws {
        let data = Data(goldenJSON(handlerID: DurableTaskHandlerID.transferCopy.rawValue).utf8)
        let first = try JSONDecoder().decode(TaskDescriptorEnvelope.self, from: data)
        let second = try JSONDecoder().decode(TaskDescriptorEnvelope.self, from: data)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lineage.attempt, 2)
        XCTAssertEqual(first.queueOrdinal, 42)
        XCTAssertEqual(first.redactedPayload, ["displayName": "demo.mov"])
    }

    private func makeDescriptor(handlerID: String) -> TaskDescriptorEnvelope {
        TaskDescriptorEnvelope(
            taskID: taskID,
            handlerID: handlerID,
            payloadVersion: 1,
            resourceKey: "media:demo",
            idempotencyKey: "copy:demo",
            lineage: .init(rootTaskID: rootTaskID, parentTaskID: parentTaskID, attempt: 2),
            queueOrdinal: 42,
            redactedPayload: [
                "displayName": "demo.mov",
                "fixtureSecret": fixtureSecret
            ]
        )
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func goldenJSON(handlerID: String) -> String {
        #"{"handlerID":"\#(handlerID)","idempotencyKey":"copy:demo","lineage":{"attempt":2,"parentTaskID":"33333333-3333-3333-3333-333333333333","rootTaskID":"22222222-2222-2222-2222-222222222222"},"payloadVersion":1,"queueOrdinal":42,"redactedPayload":{"displayName":"demo.mov"},"resourceKey":"media:demo","taskID":"11111111-1111-1111-1111-111111111111"}"#
    }
}

private actor ExecutionCounter {
    private var count = 0
    var value: Int { count }
    func increment() { count += 1 }
}
