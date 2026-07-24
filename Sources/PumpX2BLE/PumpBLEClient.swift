import Foundation
@preconcurrency import CoreBluetooth
import PumpX2Messages

/// Events emitted by `PumpBLEClient`, delivered on the main actor.
@MainActor
public protocol PumpBLEClientDelegate: AnyObject {
    func pumpClient(_ client: PumpBLEClient, didChange state: PumpBLEClient.State)
    /// A pump was discovered during scanning.
    func pumpClient(_ client: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int)
    /// The pump is connected and all characteristics are discovered + subscribed.
    func pumpClientDidBecomeReady(_ client: PumpBLEClient)
    /// A fully-reassembled inbound message frame arrived on `characteristic`. `frame` is the
    /// concatenated packet payloads (opcode/txId/len/cargo/…/crc), ready for parsing.
    func pumpClient(_ client: PumpBLEClient, didReceiveFrame frame: [UInt8], on characteristic: Characteristic)
    func pumpClient(_ client: PumpBLEClient, didError error: Error)
}

/// Core Bluetooth central for the Tandem pump. Platform-agnostic (iOS + watchOS): imports
/// CoreBluetooth only. Mirrors the connection flow of upstream `TandemBluetoothHandler`:
/// scan for the pump service → connect → discover characteristics → request MTU → enable
/// notifications → write packetized requests / reassemble notified responses.
///
/// NOT yet hardware-tested — no pump/phone hardware available. Structure follows the
/// reference; behavior must be validated on hardware before it drives a pump.
@MainActor
public final class PumpBLEClient: NSObject {
    public enum State: Equatable, Sendable {
        case poweredOff, unauthorized, unsupported, resetting, unknown
        case idle, scanning, connecting, discovering, ready, disconnected
    }

    public enum ClientError: Error, Equatable {
        case notReady
        case unknownCharacteristic(Characteristic)
        case writeFailed(Characteristic)
        /// A message was refused by the current `writePolicy`.
        case writeBlocked(policy: WritePolicy, opcode: UInt8)
    }

    /// Graded write safety. Governs which outgoing messages `send()` permits — a defense-in-
    /// depth interlock so delivery can only happen after a deliberate, explicit opt-in. Each policy
    /// authorizes up to a maximum `OperationRisk` (audit P-01), so a caller that only needs a benign
    /// op (dismiss an alert, find-my-pump) no longer has to open the same gate as therapy-config.
    public enum WritePolicy: Sendable, Equatable {
        /// Reads + pairing only. Blocks anything on CONTROL, any signed message, or anything
        /// insulin-affecting. The safe default.
        case readOnly
        /// Allow only **benign** signed control (dismiss notification, find-my-pump, non-calibration
        /// carb/BG metadata): signed proof works, but therapy-significant config, destructive commands,
        /// and delivery are all still blocked (audit P-01).
        case allowBenignControl
        /// Allow signed CONTROL up to therapy-significant **configuration** (limits, Control-IQ, time,
        /// CGM session/alerts/calibration, reminders, IDP/profile edits), but HARD-BLOCK **destructive**
        /// commands (factory reset / shelf / disconnect-pump) *and* insulin delivery. Used to validate
        /// signing on hardware without dispensing. (PX-03: no longer authorizes destructive ops.)
        case allowNonDelivery
        /// Allow **destructive** non-dispensing commands (factory reset, shelf mode, disconnect-pump) in
        /// addition to settings — HARD-BLOCK insulin delivery. Intended to be granted **explicitly and
        /// briefly** around a single destructive action, never left standing (PX-03).
        case allowDestructive
        /// Allow everything, including insulin delivery. Experimental.
        case allowDelivery

        /// The highest `OperationRisk` this policy authorizes.
        var maxRisk: OperationRisk {
            switch self {
            case .readOnly:           return .read
            case .allowBenignControl: return .benign
            case .allowNonDelivery:   return .settings      // PX-03: settings-only (was .destructive)
            case .allowDestructive:   return .destructive
            case .allowDelivery:      return .delivery
            }
        }
        func permits(_ risk: OperationRisk) -> Bool { risk <= maxRisk }
    }

    /// Current write policy. Defaults to `.readOnly`; callers must opt in explicitly. Reset to
    /// `.readOnly` fail-closed by the library on every disconnect/drop/restore/error (PX-04) — a caller
    /// must not rely on an elevated policy surviving a transaction or connection change.
    public var writePolicy: WritePolicy = .readOnly

    /// Pure authorization decision (PX-02), separated from readiness/transport so it is deterministically
    /// testable and cannot be masked by `.notReady`. Returns the exact `.writeBlocked` error a policy
    /// would raise for `message`, or `nil` if the policy permits it. `send()` consults this first.
    public func authorizationError(for message: Message) -> ClientError? {
        writePolicy.permits(message.operationRisk)
            ? nil
            : .writeBlocked(policy: writePolicy, opcode: message.opCode)
    }

    /// Owns in-flight request/response correlation, deadlines, and fail-closed completion (PX-08).
    /// Callers that need an awaited response use `sendAwaitingResponse`; unsolicited frames (streams,
    /// proactive status) are not consumed here and still reach the delegate.
    public let transactions = PumpTransactionCoordinator()

    public weak var delegate: PumpBLEClientDelegate?
    public private(set) var state: State = .unknown {
        didSet { if state != oldValue { notify { $0.pumpClient(self, didChange: self.state) } } }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Discovered pump characteristics keyed by our `Characteristic` enum.
    private var characteristics: [Characteristic: CBCharacteristic] = [:]
    /// Per-characteristic inbound reassembly buffers.
    private var reassembly: [Characteristic: PacketReassembler] = [:]
    private let txIds = TransactionId()

    /// Optional CoreBluetooth state-restoration identifier. When set, iOS preserves the central
    /// manager across app termination and relaunches the app on pump BLE events, calling
    /// `willRestoreState`. Requires the app's `bluetooth-central` background mode.
    public init(restoreIdentifier: String? = nil) {
        super.init()
        var options: [String: Any] = [:]
        if let restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        }
        self.central = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    // MARK: - Public API

    public func startScan() {
        wasScanning = true
        guard central.state == .poweredOn else { state = mapCentralState(central.state); return }
        state = .scanning
        central.scanForPeripherals(withServices: [CBUUID(nsuuid: ServiceUUID.pumpService)])
    }

    public func stopScan() { wasScanning = false; central.stopScan() }

    public func connect(_ peripheral: CBPeripheral) {
        stopScan()
        cancelReconnectWatchdog()
        intentionalDisconnect = false
        self.peripheral = peripheral
        reconnectTargetId = peripheral.identifier
        peripheral.delegate = self
        state = .connecting
        // Keep the connection request alive across states; iOS completes it when in range.
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    /// Set when the user (not a range/BLE drop) asks to disconnect, so we don't auto-reconnect.
    private var intentionalDisconnect = false
    /// Whether we want to be scanning (to resume after Bluetooth toggles back on).
    private var wasScanning = false

    // MARK: Reconnect watchdog
    /// A watchdog that recovers a *stalled* auto-reconnect. CoreBluetooth's pending `connect` normally
    /// completes on its own when the pump returns, but if the peripheral handle was lost or the pending
    /// connect silently died, nothing re-establishes the link — the observed symptom being that the
    /// app has to be force-quit. The watchdog re-resolves the peripheral by identifier (and rescans as
    /// a last resort) on escalating backoff until we're `.ready` again or the user disconnects.
    private var reconnectWatchdog: Timer?
    private var reconnectAttempts = 0
    /// Identifier of the peripheral we're trying to keep/recover, so we can re-resolve or re-target it.
    private var reconnectTargetId: UUID?
    private static let reconnectBackoff: [TimeInterval] = [5, 10, 20, 30]

    public func disconnect() {
        intentionalDisconnect = true
        cancelReconnectWatchdog()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    /// Arm (or restart) the reconnect watchdog. No-op if the user disconnected.
    private func startReconnectWatchdog() {
        guard !intentionalDisconnect else { return }
        reconnectTargetId = peripheral?.identifier ?? reconnectTargetId
        reconnectAttempts = 0
        scheduleNextReconnectAttempt()
    }

    private func scheduleNextReconnectAttempt() {
        let delay = Self.reconnectBackoff[min(reconnectAttempts, Self.reconnectBackoff.count - 1)]
        reconnectWatchdog?.invalidate()
        reconnectWatchdog = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectTick() }
        }
    }

    private func cancelReconnectWatchdog() {
        reconnectWatchdog?.invalidate(); reconnectWatchdog = nil
        reconnectAttempts = 0
    }

    private func reconnectTick() {
        // Recovered or the user took over → stop.
        guard !intentionalDisconnect, state != .ready else { cancelReconnectWatchdog(); return }
        // Bluetooth off → wait for `centralManagerDidUpdateState`, but keep the watchdog armed.
        guard central.state == .poweredOn else { scheduleNextReconnectAttempt(); return }
        reconnectAttempts += 1
        let pumpUUID = CBUUID(nsuuid: ServiceUUID.pumpService)
        // Re-resolve a fresh, valid handle if we lost ours.
        if peripheral == nil, let id = reconnectTargetId {
            peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
                ?? central.retrieveConnectedPeripherals(withServices: [pumpUUID]).first
            peripheral?.delegate = self
        }
        if let p = peripheral {
            if p.state == .connected {
                state = .discovering
                p.discoverServices([pumpUUID])
            } else {
                state = .connecting
                // Re-issuing connect on the same peripheral is idempotent in CoreBluetooth.
                central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            }
        } else {
            // No handle at all — rescan and auto-reconnect to the target when it reappears.
            startScan()
        }
        scheduleNextReconnectAttempt()
    }

    /// Serializes `message` (framing + optional signing) and writes it to the pump.
    /// - Parameters:
    ///   - authenticationKey/pumpTimeSinceReset: required for signed (insulin-affecting) messages.
    ///   - allowInsulinDelivery: safety gate mirrored into `Packetize`.
    /// - Returns: the transaction id used (for correlating the response).
    @discardableResult
    public func send(
        _ message: Message,
        authenticationKey: [UInt8] = [],
        pumpTimeSinceReset: UInt32 = 0,
        allowInsulinDelivery: Bool = false
    ) throws -> UInt8 {
        // Write interlock (defense in depth): refuse messages the current policy disallows. Authorize on
        // the operation-risk class (audit P-01), via the pure `authorizationError` decision (PX-02) so
        // the block is checked BEFORE readiness — a wrongly-permitted command can't be hidden by
        // `.notReady`. `.readOnly` blocks any control/signed/delivery; `.allowNonDelivery` now blocks
        // destructive too (PX-03); `.allowBenignControl` permits only benign ops.
        if let authError = authorizationError(for: message) { throw authError }
        guard state == .ready, let peripheral,
              let cbChar = characteristics[message.characteristic] else {
            throw ClientError.notReady
        }
        let txId = txIds.nextThenIncrement()
        let packets = try Packetize.packetize(
            message,
            authenticationKey: authenticationKey,
            txId: txId,
            pumpTimeSinceReset: pumpTimeSinceReset,
            actionsAffectingInsulinDeliveryEnabled: allowInsulinDelivery
        )
        for packet in packets {
            peripheral.writeValue(Data(packet.build()), for: cbChar, type: .withResponse)
        }
        return txId
    }

    /// Sends `message` and awaits its correlated response frame with a bounded deadline (PX-08).
    /// The synchronous parts of `send` (authorization + readiness + write) run before suspending, so an
    /// authorization/not-ready failure is thrown immediately and never registers a pending transaction.
    /// On disconnect/teardown the awaiting call is resumed with `TxError.connectionLost` (fail-closed);
    /// on deadline expiry with `TxError.timedOut` — which a delivery caller must treat as *indeterminate*.
    ///
    /// - Parameter responseOpCode: the opcode to correlate; defaults to `message.props.responseOpCode`.
    ///   Throws `ClientError.notReady` if the message declares no response opcode and none is given.
    @discardableResult
    public func sendAwaitingResponse(
        _ message: Message,
        authenticationKey: [UInt8] = [],
        pumpTimeSinceReset: UInt32 = 0,
        allowInsulinDelivery: Bool = false,
        responseOpCode: UInt8? = nil,
        deadline: TimeInterval
    ) async throws -> [UInt8] {
        guard let expectedOpCode = responseOpCode ?? message.props.responseOpCode else {
            throw ClientError.notReady
        }
        let characteristic = message.characteristic
        return try await transactions.perform(
            expectedResponseOn: characteristic, opCode: expectedOpCode, deadline: deadline
        ) {
            try self.send(message,
                          authenticationKey: authenticationKey,
                          pumpTimeSinceReset: pumpTimeSinceReset,
                          allowInsulinDelivery: allowInsulinDelivery)
        }
    }

    /// Fail-closed teardown (PX-04): reset the write policy to `.readOnly` and resume every outstanding
    /// transaction. Called by the library itself on every disconnect / failed connect / restoration /
    /// error — a caller must never rely on an elevated policy or a pending response surviving a link
    /// change. Prior to this the app had to reset the policy externally (audit A-03), and a missed reset
    /// left `.allowDelivery` standing into the next connection.
    private func failClosed(resumePending: Bool) {
        writePolicy = .readOnly
        if resumePending { transactions.failAll(.connectionLost) }
    }

    // MARK: - Helpers

    // The class is @MainActor; the CB delegate methods (nonisolated) hop here via
    // assumeIsolated, so this runs on the main actor and can call the @MainActor delegate.
    private func notify(_ block: (PumpBLEClientDelegate) -> Void) {
        if let d = delegate { block(d) }
    }

    private func mapCentralState(_ s: CBManagerState) -> State {
        switch s {
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting: return .resetting
        case .poweredOn: return .idle
        default: return .unknown
        }
    }
}

// MARK: - CBCentralManagerDelegate
//
// CoreBluetooth delegate methods are nonisolated by protocol, but the central is created with
// `queue: .main`, so they always run on the main thread — `MainActor.assumeIsolated` hops into
// the @MainActor instance soundly.

extension PumpBLEClient: CBCentralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            state = mapCentralState(central.state)
            // Recover after Bluetooth toggles back on: resume a pending connection (or rescan).
            if central.state == .poweredOn && !intentionalDisconnect {
                if let p = peripheral, p.state != .connected {
                    state = .connecting
                    central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
                } else if peripheral == nil && wasScanning {
                    startScan()
                }
            }
        }
    }

    /// State restoration: iOS relaunched us (e.g. after termination) with the pump connection
    /// preserved. Re-adopt the restored pump so notifications/reconnect resume without a fresh scan.
    ///
    /// We re-find it via `central.retrieveConnectedPeripherals` rather than reading the restored-
    /// state `dict`: `[String: Any]` is non-Sendable and can't be sent into the main-actor closure
    /// under Swift 6. A restore that was still mid-connection isn't "connected" yet, so it won't be
    /// returned here — but its pending connect persists across restoration and completes via
    /// `didConnect` (which adopts the peripheral). Discovery/subscription continue as normal.
    public nonisolated func centralManager(_ central: CBCentralManager,
                                           willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            failClosed(resumePending: false)   // PX-04: a relaunched central starts read-only
            let pumpUUID = CBUUID(nsuuid: ServiceUUID.pumpService)
            guard let p = central.retrieveConnectedPeripherals(withServices: [pumpUUID]).first else { return }
            self.peripheral = p
            p.delegate = self
            state = .discovering
            p.discoverServices([pumpUUID])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            // Watchdog rescan fallback: if this is the peripheral we're trying to recover, reconnect
            // to it directly rather than waiting for the app to choose again.
            if !intentionalDisconnect, state != .ready, peripheral.identifier == reconnectTargetId {
                connect(peripheral)
                return
            }
            notify { $0.pumpClient(self, didDiscover: peripheral, rssi: RSSI.intValue) }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            // Adopt the peripheral (idempotent in the normal flow where connect() already set it;
            // also covers a connect that completed after state restoration).
            self.peripheral = peripheral
            peripheral.delegate = self
            state = .discovering
            peripheral.discoverServices([CBUUID(nsuuid: ServiceUUID.pumpService)])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                           error: Error?) {
        MainActor.assumeIsolated {
            characteristics.removeAll()
            reassembly.removeAll()
            failClosed(resumePending: true)   // PX-04/PX-08: policy → .readOnly, resume all waiters
            if let error { notify { $0.pumpClient(self, didError: error) } }
            // Auto-reconnect on an unintended drop (e.g. out of range): a pending connect
            // persists in CoreBluetooth and completes when the pump comes back in range, in the
            // foreground or background — no manual "Connect" needed. Go straight to .connecting
            // (skip a .disconnected flicker) so the UI shows "reconnecting".
            if !intentionalDisconnect {
                self.peripheral = peripheral
                peripheral.delegate = self
                state = .connecting
                central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
                startReconnectWatchdog()   // recover if this pending connect stalls
            } else {
                state = .disconnected
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                           error: Error?) {
        MainActor.assumeIsolated {
            failClosed(resumePending: true)   // PX-04/PX-08: never leave policy elevated or a waiter hung
            if let error { notify { $0.pumpClient(self, didError: error) } }
            // Retry unless the user disconnected: re-issue the (persisting) connect request.
            if !intentionalDisconnect {
                state = .connecting
                central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
                startReconnectWatchdog()
            } else {
                state = .disconnected
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PumpBLEClient: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error { notify { $0.pumpClient(self, didError: error) }; return }
            let pumpUUID = CBUUID(nsuuid: ServiceUUID.pumpService)
            for service in peripheral.services ?? [] where service.uuid == pumpUUID {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                       error: Error?) {
        MainActor.assumeIsolated {
            if let error { notify { $0.pumpClient(self, didError: error) }; return }
            for cb in service.characteristics ?? [] {
                guard let mapped = Characteristic.of(uuid: cb.uuid.uuidValue) else { continue }
                characteristics[mapped] = cb
                if ServiceUUID.notificationCharacteristics.contains(mapped),
                   cb.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: cb)
                }
            }
            // Once the messaging characteristics are present, we're ready. (MTU on iOS is
            // negotiated automatically; there's no explicit requestMtu like Android.)
            if characteristics[.currentStatus] != nil && characteristics[.authorization] != nil {
                cancelReconnectWatchdog()   // link fully re-established
                state = .ready
                notify { $0.pumpClientDidBecomeReady(self) }
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        MainActor.assumeIsolated {
            if let error { notify { $0.pumpClient(self, didError: error) }; return }
            guard let mapped = Characteristic.of(uuid: characteristic.uuid.uuidValue),
                  let data = characteristic.value else { return }
            var reassembler = reassembly[mapped] ?? PacketReassembler()
            if let frame = reassembler.ingest([UInt8](data)) {
                reassembly[mapped] = PacketReassembler()
                // PX-08: if an awaited transaction correlates to this frame, it consumes it. Otherwise
                // (unsolicited stream/status, or a caller still on the delegate path) deliver as before.
                if !transactions.ingest(frame: frame, on: mapped) {
                    notify { $0.pumpClient(self, didReceiveFrame: frame, on: mapped) }
                }
            } else {
                reassembly[mapped] = reassembler
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        MainActor.assumeIsolated { if let error { notify { $0.pumpClient(self, didError: error) } } }
    }
}

private extension CBUUID {
    /// CBUUIDs from the pump are 128-bit; convert to Foundation UUID for our enum lookup.
    var uuidValue: UUID { UUID(uuidString: uuidString) ?? UUID() }
}
