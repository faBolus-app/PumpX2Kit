import Foundation
import PumpX2Messages

/// Owns the lifecycle of an in-flight pump request/response pair (audit PX-08).
///
/// The Tandem protocol has no per-request response channel: a reply arrives as a notified frame on a
/// characteristic, identified only by its `(characteristic, opCode)`. Historically each caller
/// (`TandemBackend`) hand-rolled a single mutable continuation slot per response type, with no deadline,
/// no correlation to the request that is actually in flight, and no guaranteed resumption when the link
/// drops — so a lost reply could suspend a bolus forever and leave an elevated write policy standing
/// (audit A-03 / FB-02). This coordinator centralizes that ownership:
///
/// - **Correlated:** each `perform` registers the `(characteristic, responseOpCode)` it awaits; an
///   ingested frame resolves the oldest matching pending transaction (FIFO), never an unrelated one.
/// - **Deadline:** every transaction has a bounded response deadline; on expiry it resolves as
///   `.timedOut` (a stale deadline for an already-resolved transaction is a no-op — resolution is keyed
///   by a unique, monotonic transaction id, so it can't misfire onto a later transaction).
/// - **Fail-closed completion:** `failAll` resolves *every* outstanding transaction with
///   `.connectionLost` on disconnect / parser error / teardown, so no caller hangs.
///
/// It is transport-agnostic: `perform` takes a `write` thunk that actually emits the bytes (normally
/// `PumpBLEClient.send`), so it is unit-testable with a fake writer + manual `ingest` — no CoreBluetooth.
@MainActor
public final class PumpTransactionCoordinator {

    public enum TxError: Error, Equatable {
        /// No response within the deadline. The request may or may not have been acted on by the pump —
        /// callers of a delivery transaction MUST treat this as *indeterminate*, not failed (FB-02).
        case timedOut(characteristic: Characteristic, opCode: UInt8)
        /// The link dropped / was torn down / a frame failed to parse before the response arrived.
        case connectionLost
        /// The transaction was explicitly cancelled by the owner.
        case cancelled
    }

    private struct Pending {
        let id: UInt64
        let expectedCharacteristic: Characteristic
        let expectedOpCode: UInt8
        /// The wire txId returned by the writer, for logging/ownership (correlation is by response
        /// opcode; txId is retained so a future stricter match can assert it).
        let txId: UInt8
        let continuation: CheckedContinuation<[UInt8], Error>
        var deadline: Task<Void, Never>?
    }

    private var pending: [Pending] = []
    private var nextId: UInt64 = 1

    public init() {}

    /// Number of transactions currently awaiting a response (for tests / diagnostics).
    public var inFlightCount: Int { pending.count }

    /// Sends a request and awaits its correlated response frame.
    ///
    /// - Parameters:
    ///   - expectedResponseOn: the characteristic the reply is expected on.
    ///   - opCode: the response opcode to correlate (normally `request.props.responseOpCode`).
    ///   - deadline: seconds before the transaction resolves `.timedOut`.
    ///   - write: emits the request bytes and returns the wire txId. Runs *before* the continuation
    ///     suspends, so a synchronous failure (authorization / not-ready) is thrown to the caller and
    ///     never registers a pending transaction.
    /// - Returns: the reassembled response frame `[opcode, txId, length, cargo…, crc]`.
    public func perform(
        expectedResponseOn characteristic: Characteristic,
        opCode: UInt8,
        deadline: TimeInterval,
        write: () throws -> UInt8
    ) async throws -> [UInt8] {
        let txId = try write()   // may throw synchronously (authorization/notReady) → no pending registered
        let id = nextId
        nextId &+= 1
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            var entry = Pending(id: id, expectedCharacteristic: characteristic, expectedOpCode: opCode,
                                txId: txId, continuation: cont, deadline: nil)
            entry.deadline = Task { [weak self] in
                let ns = UInt64((deadline * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled else { return }
                self?.resolve(id: id, with: .failure(TxError.timedOut(characteristic: characteristic, opCode: opCode)))
            }
            pending.append(entry)
        }
    }

    /// Deliver an inbound frame. If it matches the oldest pending transaction awaiting this
    /// `(characteristic, opCode)`, that transaction resolves and this returns `true` (the frame was
    /// consumed). Returns `false` if no transaction awaited it (the caller should route it elsewhere,
    /// e.g. an unsolicited stream/status frame to a delegate).
    @discardableResult
    public func ingest(frame: [UInt8], on characteristic: Characteristic) -> Bool {
        guard let opCode = frame.first else { return false }
        guard let idx = pending.firstIndex(where: {
            $0.expectedCharacteristic == characteristic && $0.expectedOpCode == opCode
        }) else { return false }
        let entry = pending[idx]
        resolve(id: entry.id, with: .success(frame))
        return true
    }

    /// Fail every outstanding transaction (disconnect / parser error / teardown). Fail-closed: nothing
    /// is left suspended.
    public func failAll(_ error: TxError = .connectionLost) {
        let all = pending
        pending.removeAll()
        for entry in all {
            entry.deadline?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    /// Cancel every outstanding transaction as `.cancelled`.
    public func cancelAll() { failAll(.cancelled) }

    private func resolve(id: UInt64, with result: Result<[UInt8], Error>) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }   // already resolved → no-op
        let entry = pending.remove(at: idx)
        entry.deadline?.cancel()
        entry.continuation.resume(with: result)
    }
}
