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

    public enum ClientError: Error {
        case notReady
        case unknownCharacteristic(Characteristic)
        case writeFailed(Characteristic)
        /// A message was refused by the current `writePolicy`.
        case writeBlocked(policy: WritePolicy, opcode: UInt8)
    }

    /// Graded write safety. Governs which outgoing messages `send()` permits — a defense-in-
    /// depth interlock so delivery can only happen after a deliberate, explicit opt-in.
    public enum WritePolicy: Sendable, Equatable {
        /// Reads + pairing only. Blocks anything on CONTROL, any signed message, or anything
        /// insulin-affecting. The safe default.
        case readOnly
        /// Allow signed CONTROL messages that do NOT dispense (bolus permission/release,
        /// cancel), but still HARD-BLOCK insulin delivery (`modifiesInsulinDelivery`). Used to
        /// validate signing on hardware without dispensing.
        case allowNonDelivery
        /// Allow everything, including insulin delivery. Experimental.
        case allowDelivery
    }

    /// Current write policy. Defaults to `.readOnly`; callers must opt in explicitly.
    public var writePolicy: WritePolicy = .readOnly

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
        // Write interlock (defense in depth): refuse messages the current policy disallows.
        switch writePolicy {
        case .readOnly:
            if message.characteristic == .control || message.signed || message.props.modifiesInsulinDelivery {
                throw ClientError.writeBlocked(policy: writePolicy, opcode: message.opCode)
            }
        case .allowNonDelivery:
            if message.props.modifiesInsulinDelivery {
                throw ClientError.writeBlocked(policy: writePolicy, opcode: message.opCode)
            }
        case .allowDelivery:
            break
        }
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
                notify { $0.pumpClient(self, didReceiveFrame: frame, on: mapped) }
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
