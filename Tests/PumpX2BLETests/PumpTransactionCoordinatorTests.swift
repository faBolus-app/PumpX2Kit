import Testing
import Foundation
import PumpX2Messages
@testable import PumpX2BLE

/// PX-08: the transaction coordinator is the deterministic, CoreBluetooth-free "fake transport" the
/// remediation plan requires for FB-02. A `write` thunk stands in for the BLE write; `ingest` stands in
/// for a notified response frame. Every property the plan asks for — correlation, deadline, fail-closed
/// completion, no-misfire on a stale deadline — is asserted here without hardware.
@Suite struct PumpTransactionCoordinatorTests {

    /// Drive `perform` to the point where its pending transaction is registered.
    @MainActor private func launchAndRegister(
        _ coord: PumpTransactionCoordinator, on ch: Characteristic, opCode: UInt8,
        deadline: TimeInterval = 5, txId: UInt8 = 7
    ) async -> Task<[UInt8], Error> {
        let before = coord.inFlightCount
        let task = Task { @MainActor in
            try await coord.perform(expectedResponseOn: ch, opCode: opCode, deadline: deadline) { txId }
        }
        while coord.inFlightCount == before { await Task.yield() }   // wait until THIS transaction registers
        return task
    }

    @MainActor @Test func responseResolvesTheAwaitingTransaction() async throws {
        let coord = PumpTransactionCoordinator()
        let task = await launchAndRegister(coord, on: .control, opCode: 0x03)
        let consumed = coord.ingest(frame: [0x03, 7, 0], on: .control)
        #expect(consumed)
        let frame = try await task.value
        #expect(frame == [0x03, 7, 0])
        #expect(coord.inFlightCount == 0)
    }

    /// A frame nobody awaits is not consumed (so the BLE layer routes it to the delegate instead).
    @MainActor @Test func unawaitedFrameIsNotConsumed() {
        let coord = PumpTransactionCoordinator()
        #expect(coord.ingest(frame: [0x99, 1, 0], on: .currentStatus) == false)
    }

    /// A synchronous write failure (authorization / not-ready) is rethrown and never registers a pending
    /// transaction — so it can't leak or later mis-resolve.
    @MainActor @Test func synchronousWriteFailureRegistersNothing() async {
        let coord = PumpTransactionCoordinator()
        await #expect(throws: PumpBLEClient.ClientError.self) {
            try await coord.perform(expectedResponseOn: .control, opCode: 0x03, deadline: 5) {
                throw PumpBLEClient.ClientError.writeBlocked(policy: .readOnly, opcode: 0x1C)
            }
        }
        #expect(coord.inFlightCount == 0)
    }

    @MainActor @Test func deadlineResolvesTimedOut() async {
        let coord = PumpTransactionCoordinator()
        await #expect(throws: PumpTransactionCoordinator.TxError.timedOut(characteristic: .currentStatus, opCode: 0x99)) {
            try await coord.perform(expectedResponseOn: .currentStatus, opCode: 0x99, deadline: 0.02) { 7 }
        }
        #expect(coord.inFlightCount == 0)
    }

    /// Fail-closed: a disconnect resumes the pending transaction with `.connectionLost`, never hangs.
    @MainActor @Test func failAllResumesPending() async {
        let coord = PumpTransactionCoordinator()
        let task = await launchAndRegister(coord, on: .control, opCode: 0x03)
        coord.failAll(.connectionLost)
        #expect(coord.inFlightCount == 0)
        let result = await task.result
        if case .success = result { Issue.record("expected connectionLost, got success") }
    }

    /// Correlation: two transactions awaiting different opcodes resolve independently to their own frame.
    @MainActor @Test func correlatesByOpcode() async throws {
        let coord = PumpTransactionCoordinator()
        let a = await launchAndRegister(coord, on: .control, opCode: 0x03, txId: 1)
        let b = await launchAndRegister(coord, on: .control, opCode: 0x05, txId: 2)
        #expect(coord.inFlightCount == 2)
        // Resolve the second one first; the first stays pending.
        #expect(coord.ingest(frame: [0x05, 2, 0], on: .control))
        let bFrame = try await b.value
        #expect(bFrame.first == 0x05)
        #expect(coord.inFlightCount == 1)
        #expect(coord.ingest(frame: [0x03, 1, 0], on: .control))
        let aFrame = try await a.value
        #expect(aFrame.first == 0x03)
    }

    /// A response that arrives before the deadline resolves the transaction; the (now-stale) deadline
    /// task firing afterward is a no-op (the id is gone) — it cannot mis-resolve a later transaction.
    @MainActor @Test func staleDeadlineDoesNotMisfire() async throws {
        let coord = PumpTransactionCoordinator()
        let task = await launchAndRegister(coord, on: .control, opCode: 0x03, deadline: 0.05)
        #expect(coord.ingest(frame: [0x03, 7, 42], on: .control))
        _ = try await task.value
        // Start a fresh transaction and let the previous (already-cancelled) deadline window elapse.
        let task2 = await launchAndRegister(coord, on: .control, opCode: 0x03, deadline: 5, txId: 9)
        try? await Task.sleep(nanoseconds: 80_000_000)   // > the first deadline
        #expect(coord.inFlightCount == 1)                // task2 still awaiting — not killed by a stale timer
        coord.ingest(frame: [0x03, 9, 1], on: .control)
        _ = try await task2.value
    }

    /// Two transactions sharing the SAME (characteristic, opcode) resolve FIFO: the first-registered gets
    /// the first matching frame. (The Tandem wire has no per-request response tag, so same-opcode requests
    /// are serialized in practice; this documents the ordering the delivery flow relies on — §6 req 3.)
    @MainActor @Test func sameOpcodeResolvesFIFO() async throws {
        let coord = PumpTransactionCoordinator()
        let a = await launchAndRegister(coord, on: .control, opCode: 0x03, txId: 1)
        let b = await launchAndRegister(coord, on: .control, opCode: 0x03, txId: 2)
        #expect(coord.inFlightCount == 2)
        #expect(coord.ingest(frame: [0x03, 1, 0xAA], on: .control))   // first frame → oldest (a)
        let aFrame = try await a.value
        #expect(aFrame == [0x03, 1, 0xAA])
        #expect(coord.inFlightCount == 1)
        #expect(coord.ingest(frame: [0x03, 2, 0xBB], on: .control))   // next frame → b
        let bFrame = try await b.value
        #expect(bFrame == [0x03, 2, 0xBB])
    }

    /// Cancelling ONE awaiting task resolves only that transaction (`.cancelled`); a sibling keeps
    /// awaiting and still resolves normally — no leaked continuation, no misfire (§6 req 4).
    @MainActor @Test func cancellingOneTaskResolvesOnlyThatTransaction() async throws {
        let coord = PumpTransactionCoordinator()
        let a = await launchAndRegister(coord, on: .control, opCode: 0x03, txId: 1)
        let b = await launchAndRegister(coord, on: .control, opCode: 0x05, txId: 2)
        #expect(coord.inFlightCount == 2)
        a.cancel()
        let aResult = await a.result
        if case .success = aResult { Issue.record("expected the cancelled task to throw") }
        #expect(coord.inFlightCount == 1)                             // only a was resolved
        #expect(coord.ingest(frame: [0x05, 2, 0], on: .control))      // b unaffected
        let bFrame = try await b.value
        #expect(bFrame.first == 0x05)
    }
}
