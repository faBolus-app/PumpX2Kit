import Foundation
import PumpX2Messages
import PumpX2Auth
import PumpX2BLE

// PumpX2BenchHarness — the bench/oracle CLI (Milestone 1e).
//
// SAFETY: bench proof-of-concept only. Every run must target a dedicated test pump
// dispensing saline into a container on a scale — NEVER on a body.
//
// Final target flow: connect → read status/IOB → deliver small saline bolus → confirm
// delivered mass via scale → cancel mid-delivery. Not yet implemented; scaffold only.

print("PumpX2BenchHarness — scaffold. Not yet connected to a pump.")

// Demonstrate the message layer end-to-end (serialization only; no BLE yet).
let apiReq = ApiVersionRequest()
if let packets = try? Packetize.packetize(apiReq, txId: 0) {
    print("ApiVersionRequest(txId=0) packets: \(packets.map { Hex.encode($0.build()) })")
}
print("Bolus-flow opcodes: permission=0x\(String(BolusPermissionRequest.props.opCode, radix: 16)), "
    + "initiate=0x\(String(InitiateBolusRequest.props.opCode, radix: 16)), "
    + "cancel=0x\(String(CancelBolusRequest.props.opCode, radix: 16))")
