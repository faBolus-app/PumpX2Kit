import Foundation
import CoreBluetooth
import PumpX2Messages
import PumpX2Auth
import PumpX2BLE

// PumpX2BenchHarness — the bench/oracle CLI (Milestone 1e).
//
// SAFETY: bench proof-of-concept only. Every run must target a dedicated test pump
// dispensing saline into a container on a scale — NEVER on a body.
//
// Modes:
//   (no args)   serialization self-check (no BLE) — always works
//   scan        scan for pumps and print discoveries
//   monitor     READ-ONLY: connect → JPAKE pair (6-digit) → poll status reads. Writes that
//               could change pump state are hard-blocked (client.readOnly). This is the safe
//               first hardware test. Set PUMP_PAIRING_CODE=<6 digits>.
//
// A bolus/delivery mode is intentionally NOT provided here yet — deliver via the app once the
// read-only monitor is validated on the bench.

let args = Array(CommandLine.arguments.dropFirst())

func serializationSelfCheck() {
    print("PumpX2BenchHarness — serialization self-check (no BLE)")
    if let packets = try? Packetize.packetize(ApiVersionRequest(), txId: 0) {
        print("  ApiVersionRequest(txId=0): \(packets.map { Hex.encode($0.build()) })")
    }
    print("  Bolus opcodes: permission=0x\(String(BolusPermissionRequest.props.opCode, radix: 16)) "
        + "initiate=0x\(String(InitiateBolusRequest.props.opCode, radix: 16)) "
        + "cancel=0x\(String(CancelBolusRequest.props.opCode, radix: 16))")
}

/// Read-only pump monitor: connect, pair over JPAKE, and poll status. Never writes a control
/// or insulin-affecting message (enforced by `client.readOnly`).
@MainActor
final class Monitor: NSObject, PumpBLEClientDelegate {
    let client = PumpBLEClient()
    let pairingCode = ProcessInfo.processInfo.environment["PUMP_PAIRING_CODE"] ?? ""
    var coordinator: PairingCoordinator?
    let scanOnly: Bool
    var pollTimer: Timer?

    init(scanOnly: Bool) {
        self.scanOnly = scanOnly
        super.init()
        client.readOnly = true            // hard safety: no state-changing writes
        client.delegate = self
    }

    func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        print("[state] \(state)")
        if state == .idle { c.startScan() }
    }

    func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        print("[discover] \(peripheral.name ?? "unknown") rssi=\(rssi)")
        if !scanOnly { c.connect(peripheral) }
    }

    func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        print("[ready] connected + characteristics discovered")
        guard !pairingCode.isEmpty else {
            print("[warn] PUMP_PAIRING_CODE not set — cannot pair; reads will be rejected by the pump")
            return
        }
        do {
            let coord = try PairingCoordinator(pairingCode: pairingCode)
            coord.onSendRequest = { msg in try? c.send(msg) }   // AUTHORIZATION msgs pass the read-only gate
            coord.onError = { print("[pairing] error: \($0)") }
            coord.onPaired = { [weak self] authKey, _ in
                print("[paired] JPAKE complete; signing key derived (\(authKey.count) bytes). Read-only — not used for writes.")
                self?.startPolling()
            }
            coordinator = coord
            print("[pairing] starting JPAKE (6-digit)…")
            coord.start()
        } catch {
            print("[pairing] failed to start: \(error)")
        }
    }

    func poll() {
        try? client.send(ControlIQIOBRequest())
        try? client.send(InsulinStatusRequest())
        try? client.send(CurrentBatteryV2Request())
    }

    func startPolling() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { self.poll() }
        }
    }

    func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {
        if ch == .authorization {
            coordinator?.handle(frame: frame)
        } else if let parsed = try? ResponseParser.parse(frame: frame) {
            switch parsed.message {
            case let m as ControlIQIOBResponse: print("[status] IOB = \(m.iobUnits) u")
            case let m as InsulinStatusResponse: print("[status] insulin remaining = \(m.currentInsulinAmount) u")
            case let m as CurrentBatteryV2Response: print("[status] battery = \(m.batteryPercent)%")
            default: print("[status] opcode \(parsed.opCode)")
            }
        } else {
            print("[frame] \(ch.name) hex=\(Hex.encode(frame))")
        }
    }

    func pumpClient(_ c: PumpBLEClient, didError error: Error) { print("[error] \(error)") }
}

switch args.first {
case nil, "":
    serializationSelfCheck()
case "scan":
    let m = Monitor(scanOnly: true); _ = m
    print("Scanning for pumps — Ctrl-C to stop.")
    RunLoop.main.run()
case "monitor":
    let m = Monitor(scanOnly: false); _ = m
    print("READ-ONLY monitor — connect, JPAKE pair, poll status. No writes that change pump state. Ctrl-C to stop.")
    RunLoop.main.run()
default:
    print("unknown command: \(args[0])")
    print("commands: (none)=self-check, scan, monitor")
    exit(2)
}
