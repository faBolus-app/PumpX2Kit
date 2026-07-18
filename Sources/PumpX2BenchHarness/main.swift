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
//   (no args)            serialization self-check (no BLE) — always works
//   scan                 scan for pumps and print discoveries
//   status               connect to first pump, read API version + status, print frames
//   bolus <milliunits>   connect, pair, permission → initiate → status → cancel
//
// Signed operations require env: PUMP_PAIRING_CODE (16-char legacy), and once known,
// PUMP_TIME_SINCE_RESET. JPAKE pairing is not yet supported (see docs/OPEN_QUESTIONS.md).

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

/// Drives the pump over BLE. Runs on the main RunLoop.
final class Harness: NSObject, PumpBLEClientDelegate {
    let client = PumpBLEClient()
    let mode: String
    let bolusMilliunits: UInt32?
    let pairingCode = ProcessInfo.processInfo.environment["PUMP_PAIRING_CODE"]
    let pumpTimeSinceReset = UInt32(ProcessInfo.processInfo.environment["PUMP_TIME_SINCE_RESET"] ?? "0") ?? 0

    init(mode: String, bolusMilliunits: UInt32? = nil) {
        self.mode = mode
        self.bolusMilliunits = bolusMilliunits
        super.init()
        client.delegate = self
    }

    var authKey: [UInt8] { pairingCode.map { Array($0.utf8) } ?? [] }

    func pumpClient(_ client: PumpBLEClient, didChange state: PumpBLEClient.State) {
        print("[state] \(state)")
        if state == .idle { client.startScan() }
    }

    func pumpClient(_ client: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        print("[discover] \(peripheral.name ?? "unknown") rssi=\(rssi)")
        if mode != "scan" { client.connect(peripheral) }
    }

    func pumpClientDidBecomeReady(_ client: PumpBLEClient) {
        print("[ready] connected + characteristics discovered")
        do {
            try client.send(ApiVersionRequest())
            try client.send(InsulinStatusRequest())
            try client.send(ControlIQIOBRequest())
            if mode == "bolus", let mu = bolusMilliunits {
                print("[bolus] requesting permission for \(Double(mu)/1000.0) u (saline!)")
                try client.send(BolusPermissionRequest(), authenticationKey: authKey,
                                pumpTimeSinceReset: pumpTimeSinceReset)
                // NOTE: initiate must use the bolusId from BolusPermissionResponse (needs
                // response parsing) — wired once response parsing + a bench pump are available.
                print("[bolus] TODO: parse BolusPermissionResponse.bolusId, then InitiateBolusRequest")
            }
        } catch {
            print("[error] send failed: \(error)")
        }
    }

    func pumpClient(_ client: PumpBLEClient, didReceiveFrame frame: [UInt8], on characteristic: Characteristic) {
        let opcode = frame.count >= 3 ? frame[2] : 0
        print("[frame] \(characteristic.name) opcode=\(opcode) hex=\(Hex.encode(frame))")
    }

    func pumpClient(_ client: PumpBLEClient, didError error: Error) {
        print("[error] \(error)")
    }
}

switch args.first {
case nil, "":
    serializationSelfCheck()
case "scan", "status":
    let h = Harness(mode: args[0])
    _ = h
    print("Starting \(args[0]) — requires a paired test pump and Bluetooth permission. Ctrl-C to stop.")
    RunLoop.main.run()
case "bolus":
    guard args.count >= 2, let mu = UInt32(args[1]) else {
        print("usage: bolus <milliunits>   (e.g. 1000 = 1.0 u)"); exit(2)
    }
    let h = Harness(mode: "bolus", bolusMilliunits: mu)
    _ = h
    print("Starting SALINE bolus of \(Double(mu)/1000.0) u — bench pump only. Ctrl-C to stop.")
    RunLoop.main.run()
default:
    print("unknown command: \(args[0])")
    print("commands: (none)=self-check, scan, status, bolus <milliunits>")
    exit(2)
}
