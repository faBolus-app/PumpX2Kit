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
        /// A delivery-class (`serialized`) transaction was requested while another was still outstanding.
        /// Round-3 §5.2.5 / R3-D: at most ONE delivery-class command may be in flight, so two identical
        /// in-flight delivery opcodes can never cross-resolve. Rejected fail-closed BEFORE any bytes are
        /// written — nothing was sent, so the caller may retry once the first resolves. Deliberately a
        /// rejection, not a queue: silently queuing a second bolus is the very hazard §5.3 forbids.
        case busy
    }

    private struct Pending {
        let id: UInt64
        let expectedCharacteristic: Characteristic
        let expectedOpCode: UInt8
        /// The wire txId returned by the writer, for logging/ownership (correlation is by response
        /// opcode; txId is retained so a future stricter match can assert it — see the R3-D note below).
        let txId: UInt8
        /// Delivery-class: at most one such transaction may be outstanding at a time (R3-D).
        let serialized: Bool
        let continuation: CheckedContinuation<[UInt8], Error>
        var deadline: Task<Void, Never>?
    }

    private var pending: [Pending] = []
    private var nextId: UInt64 = 1

    public init() {}

    /// Number of transactions currently awaiting a response (for tests / diagnostics).
    public var inFlightCount: Int { pending.count }

    /// Whether a delivery-class (`serialized`) transaction is currently outstanding (tests / diagnostics).
    public var hasSerializedInFlight: Bool { pending.contains { $0.serialized } }

    /// Sends a request and awaits its correlated response frame.
    ///
    /// - Parameters:
    ///   - expectedResponseOn: the characteristic the reply is expected on.
    ///   - opCode: the response opcode to correlate (normally `request.props.responseOpCode`).
    ///   - deadline: seconds before the transaction resolves `.timedOut`.
    ///   - serialized: delivery-class (R3-D). When true, the call is rejected with `.busy` — before any
    ///     bytes are written — if another serialized transaction is already outstanding, so at most one
    ///     delivery command is ever in flight and two identical delivery opcodes can't cross-resolve.
    ///     Non-serialized reads (status polling) are unaffected and may still run concurrently.
    ///   - write: emits the request bytes and returns the wire txId. Runs *before* the continuation
    ///     suspends, so a synchronous failure (authorization / not-ready) is thrown to the caller and
    ///     never registers a pending transaction.
    /// - Returns: the reassembled response frame `[opcode, txId, length, cargo…, crc]`.
    public func perform(
        expectedResponseOn characteristic: Characteristic,
        opCode: UInt8,
        deadline: TimeInterval,
        serialized: Bool = false,
        write: () throws -> UInt8
    ) async throws -> [UInt8] {
        // R3-D: reject a second delivery-class command BEFORE writing anything. Checked before the write
        // so no bytes go out and no pending is registered — a clean fail-closed the caller can retry.
        if serialized && pending.contains(where: { $0.serialized }) { throw TxError.busy }
        // Pre-write cancellation check: if the owning task was already cancelled, do not emit bytes.
        try Task.checkCancellation()
        let txId = try write()   // may throw synchronously (authorization/notReady) → no pending registered
        let id = nextId
        nextId &+= 1
        // Structured-cancellation aware: if the OWNING task is cancelled while awaiting, resolve ONLY this
        // transaction as `.cancelled` (never a sibling), so a cancelled bolus poll can't leak a suspended
        // continuation or misfire onto another in-flight request (§6 requirement 4).
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
                var entry = Pending(id: id, expectedCharacteristic: characteristic, expectedOpCode: opCode,
                                    txId: txId, serialized: serialized, continuation: cont, deadline: nil)
                entry.deadline = Task { [weak self] in
                    let ns = UInt64((deadline * 1_000_000_000).rounded())
                    try? await Task.sleep(nanoseconds: ns)
                    guard !Task.isCancelled else { return }
                    self?.resolve(id: id, with: .failure(TxError.timedOut(characteristic: characteristic, opCode: opCode)))
                }
                pending.append(entry)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: id, with: .failure(TxError.cancelled)) }
        }
    }

    /// Deliver an inbound frame. If it matches the oldest pending transaction awaiting this
    /// `(characteristic, opCode)`, that transaction resolves and this returns `true` (the frame was
    /// consumed). Returns `false` if no transaction awaited it (the caller should route it elsewhere,
    /// e.g. an unsolicited stream/status frame to a delegate).
    // R3-D FOLLOW-UP (needs the bench): correlation here is by `(characteristic, opCode)` FIFO. The wire
    // txId is `frame[1]`, and each `Pending` retains the request `txId`, so a STRICTER match
    // (`… && frame[1] == entry.txId`) would let two identical in-flight opcodes coexist safely and drop
    // the delivery-class serialization above. That upgrade is gated on confirming — on real hardware —
    // that a Tandem response reliably ECHOES the request txId in `frame[1]`; neither the code nor the
    // vendored oracle establishes it, and matching on a txId the pump does not echo would fail EVERY
    // correlation. Until then, delivery-class serialization is the safe closure. See WIP-REGISTER.md.
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
