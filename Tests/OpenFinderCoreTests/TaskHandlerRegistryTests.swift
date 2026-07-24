import Foundation
import XCTest
@testable import OpenFinderCore

final class TaskHandlerRegistryTests: XCTestCase {
    func testRegisteredHandlerExecutesWithOrderedEvents() async throws {
        let registry = TaskHandlerRegistry()
        let capturedSink = SinkCapture()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { descriptor, events in
            await capturedSink.store(events)
            XCTAssertEqual(descriptor.redactedPayload["displayName"], "demo.mov")
            await events.updateProgress(.init(
                fraction: 0.25,
                phase: "prepare",
                detail: "copy",
                completed: 1,
                total: 4,
                unit: "items"
            ))
            await events.appendLog("copied metadata")
            await events.updateStatus(.running)
            return .success(summary: "copied", clipboard: nil)
        })
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
        let descriptor = makeDescriptor(resourceKey: "copy:demo")

        let id = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Registry copy",
            descriptor: descriptor
        ))
        let record = try await queue.waitForTerminalStatus(id, timeout: 2)
        let captured = await capturedSink.value
        let sink = try XCTUnwrap(captured)
        let events = await sink.eventHistory()
        let lateProgressAccepted = await sink.updateProgress(0.9, "too late")
        let lateStatusAccepted = await sink.updateStatus(.running)
        let afterLateEvents = await queue.record(for: id)

        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.resultSummary, "copied")
        XCTAssertFalse(lateProgressAccepted)
        XCTAssertFalse(lateStatusAccepted)
        XCTAssertEqual(afterLateEvents, record)
        XCTAssertEqual(events, [
            .progress(.init(
                fraction: 0.25,
                phase: "prepare",
                detail: "copy",
                completed: 1,
                total: 4,
                unit: "items"
            )),
            .log(message: "copied metadata", level: "info"),
            .status(.running)
        ])
        print("EVENT_TRACE_OBSERVABLE events=\(events) terminal=\(record.status.rawValue)")
    }

    func testDuplicateAndUnknownRegistrationsFailTyped() async throws {
        let registry = TaskHandlerRegistry()
        let handler = TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { _, _ in
            .success(summary: "ok", clipboard: nil)
        }
        try await registry.register(handler)

        do {
            try await registry.register(handler)
            XCTFail("Expected duplicate registration")
        } catch {
            XCTAssertEqual(
                error as? TaskHandlerRegistryError,
                .duplicateRegistration(
                    handlerID: DurableTaskHandlerID.transferCopy.rawValue,
                    payloadVersion: 1
                )
            )
        }

        do {
            _ = try await registry.handler(for: "missing.handler.v1", payloadVersion: 1)
            XCTFail("Expected unknown handler")
        } catch {
            XCTAssertEqual(
                error as? TaskHandlerRegistryError,
                .unknownHandler(handlerID: "missing.handler.v1", payloadVersion: 1)
            )
        }

        do {
            _ = try await registry.handler(
                for: DurableTaskHandlerID.transferCopy.rawValue,
                payloadVersion: 2
            )
            XCTFail("Expected unknown version")
        } catch {
            XCTAssertEqual(
                error as? TaskHandlerRegistryError,
                .unknownHandler(
                    handlerID: DurableTaskHandlerID.transferCopy.rawValue,
                    payloadVersion: 2
                )
            )
        }
    }

    func testRegistryExecutesExactRegisteredPayloadVersion() async throws {
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 2
        ) { descriptor, _ in
            .success(summary: "version \(descriptor.payloadVersion)", clipboard: nil)
        })
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
        let descriptor = makeDescriptor(resourceKey: "versioned", payloadVersion: 2)

        let id = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Version two",
            descriptor: descriptor
        ))
        let record = try await queue.waitForTerminalStatus(id, timeout: 2)

        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.resultSummary, "version 2")
    }

    func testPrematureSucceededStatusCannotMaskHandlerFailure() async throws {
        let registry = TaskHandlerRegistry()
        try await registry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { _, events in
            let accepted = await events.updateStatus(.succeeded)
            XCTAssertFalse(accepted)
            throw OpenFinderError.operationFailed("failure after premature success")
        })
        let queue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: registry)
        let id = try await queue.enqueue(.init(
            kind: .localCopy,
            title: "Premature terminal status",
            descriptor: makeDescriptor(resourceKey: "premature-terminal")
        ))

        let record = try await queue.waitForTerminalStatus(id, timeout: 2)

        XCTAssertEqual(record.status, .failed)
        XCTAssertNotNil(record.errorMessage)
        XCTAssertNil(record.resultSummary)
        print(
            "PREMATURE_TERMINAL_OBSERVABLE terminal=\(record.status.rawValue) " +
            "error=\(record.errorMessage ?? "missing") result=\(record.resultSummary ?? "missing")"
        )
    }

    func testCancellationBeforeCommitAbortsButCancellationAfterCommitPreservesSuccess() async throws {
        let beforeGate = HandlerGate()
        let beforeRegistry = TaskHandlerRegistry()
        try await beforeRegistry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { _, events in
            await beforeGate.enterAndWait()
            try await events.markEffectsCommitted()
            return .success(summary: "must not succeed", clipboard: nil)
        })
        let beforeQueue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: beforeRegistry)
        let beforeID = try await beforeQueue.enqueue(.init(
            kind: .localCopy,
            title: "Cancel before commit",
            descriptor: makeDescriptor(resourceKey: "before")
        ))
        try await beforeGate.waitUntilEntered()
        await beforeQueue.cancel(beforeID)
        await beforeGate.release()
        let before = try await beforeQueue.waitForTerminalStatus(beforeID, timeout: 2)

        let afterGate = HandlerGate()
        let afterRegistry = TaskHandlerRegistry()
        try await afterRegistry.register(TaskHandler(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ) { _, events in
            try await events.markEffectsCommitted()
            await afterGate.enterAndWait()
            return .success(summary: "committed", clipboard: nil)
        })
        let afterQueue = TaskQueueService(maxConcurrentTasks: 1, handlerRegistry: afterRegistry)
        let afterID = try await afterQueue.enqueue(.init(
            kind: .localCopy,
            title: "Cancel after commit",
            descriptor: makeDescriptor(resourceKey: "after")
        ))
        try await afterGate.waitUntilEntered()
        await afterQueue.cancel(afterID)
        let whileCommitted = await afterQueue.record(for: afterID)
        await afterGate.release()
        let after = try await afterQueue.waitForTerminalStatus(afterID, timeout: 2)

        XCTAssertEqual(before.status, .cancelled)
        XCTAssertEqual(whileCommitted?.status, .running)
        XCTAssertEqual(after.status, .succeeded)
        XCTAssertEqual(after.resultSummary, "committed")
        print(
            "COMMIT_BOUNDARY_OBSERVABLE before=\(before.status.rawValue) " +
            "afterCancel=\(whileCommitted?.status.rawValue ?? "missing") after=\(after.status.rawValue)"
        )
    }

    private func makeDescriptor(
        resourceKey: String,
        payloadVersion: Int = 1
    ) -> TaskDescriptorEnvelope {
        let id = UUID()
        return TaskDescriptorEnvelope(
            taskID: id,
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: payloadVersion,
            resourceKey: resourceKey,
            lineage: .init(rootTaskID: id),
            queueOrdinal: 1,
            redactedPayload: ["displayName": "demo.mov"]
        )
    }
}

private actor SinkCapture {
    private(set) var value: TaskEventSink?

    func store(_ sink: TaskEventSink) {
        value = sink
    }
}

private actor HandlerGate {
    private var entered = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered(timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
        guard entered else { throw OpenFinderError.timeout("Handler did not start") }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
