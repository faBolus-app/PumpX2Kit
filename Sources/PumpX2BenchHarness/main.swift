import Foundation
import CoreBluetooth
import PumpX2Messages
import PumpX2Auth
import PumpX2BLE

// PumpX2BenchHarness — the oracle/test CLI (Milestone 1e).
//
// SAFETY: experimental software in development; not FDA-cleared. Use at your own
// responsibility.
//
// Modes:
//   (no args)   serialization self-check (no BLE) — always works
//   scan        scan for pumps and print discoveries
//   monitor     READ-ONLY: connect → JPAKE pair (6-digit) → poll status reads. Writes that
//               could change pump state are hard-blocked (client.readOnly). This is the safe
//               first hardware test. Set PUMP_PAIRING_CODE=<6 digits>.
//
// A bolus/delivery mode is intentionally NOT provided here yet — deliver via the app once the
// read-only monitor is validated on hardware.

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
    enum Mode: Equatable {
        case scan, monitor, permissionTest
        case deliverBolus(milliunits: UInt32)
        case carbBolus(carbs: Double, bg: Int?)
    }
    let mode: Mode
    var pollTimer: Timer?
    var authKey: [UInt8] = []
    var signingTimestamp: UInt32 = 0
    var permissionSent = false
    var currentBolusId: Int = 0
    // Bolus type bits (controlX2 convention): FOOD2 always; +FOOD1 carbs; +CORRECTION.
    static let food2 = 8, food1 = 1, correction = 2

    // Carb-bolus computed plan (milliunits) + inputs collected from the pump.
    var carbGrams: Double = 0
    var carbBg: Int?
    var calc: BolusCalcDataSnapshotResponse?
    var iobMilliunits: UInt32?
    var haveTime = false
    var planTotalMU: UInt32 = 0, planFoodMU: UInt32 = 0, planCorrectionMU: UInt32 = 0, planBits = 0

    init(mode: Mode) {
        self.mode = mode
        super.init()
        switch mode {
        case .permissionTest: client.writePolicy = .allowNonDelivery
        case .deliverBolus, .carbBolus: client.writePolicy = .allowDelivery   // experimental delivery
        default: client.writePolicy = .readOnly
        }
        client.delegate = self
    }

    var isBolusMode: Bool {
        switch mode { case .deliverBolus, .carbBolus: return true; default: return false }
    }
    var isCarbMode: Bool { if case .carbBolus = mode { return true } else { return false } }

    func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        print("[state] \(state)")
        if state == .idle { c.startScan() }
    }

    func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        print("[discover] \(peripheral.name ?? "unknown") rssi=\(rssi)")
        if mode != .scan { c.connect(peripheral) }
    }

    func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        print("[ready] connected + characteristics discovered")
        guard !pairingCode.isEmpty else {
            print("[warn] PUMP_PAIRING_CODE not set — cannot pair; reads will be rejected by the pump")
            return
        }
        do {
            let coord = try PairingCoordinator(pairingCode: pairingCode)
            coord.onSendRequest = { msg in try? c.send(msg) }   // AUTHORIZATION msgs pass the interlock
            coord.onError = { print("[pairing] error: \($0)") }
            coord.onPaired = { [weak self] authKey, _ in
                guard let self else { return }
                self.authKey = authKey
                print("[paired] JPAKE complete; signing key derived (\(authKey.count) bytes).")
                switch self.mode {
                case .monitor: self.startPolling()
                case .permissionTest, .deliverBolus:
                    print("[write] reading pump time for signing…")
                    try? c.send(TimeSinceResetRequest())   // read (allowed); triggers the signed flow
                case .carbBolus:
                    print("[carb-bolus] reading pump time + calculator settings (carb ratio/ISF/target) + IOB…")
                    try? c.send(TimeSinceResetRequest())
                    try? c.send(BolusCalcDataSnapshotRequest())
                    try? c.send(ControlIQIOBRequest())
                case .scan: break
                }
            }
            coordinator = coord
            print("[pairing] starting JPAKE (6-digit)…")
            coord.start()
        } catch {
            print("[pairing] failed to start: \(error)")
        }
    }

    /// Signature test: send a SIGNED BolusPermissionRequest (does NOT dispense) to prove the
    /// pump accepts our HMAC, then release. Delivery is still hard-blocked by writePolicy.
    func sendSignedPermission() {
        permissionSent = true
        print(isBolusMode
            ? "[bolus] requesting SIGNED bolus permission…"
            : "[permission-test] sending SIGNED BolusPermissionRequest (no insulin delivered)…")
        do {
            try client.send(BolusPermissionRequest(), authenticationKey: authKey,
                            pumpTimeSinceReset: signingTimestamp)
        } catch { print("[permission-test] send failed: \(error)") }
    }

    func releasePermission(bolusId: Int) {
        print("[permission-test] releasing bolus permission id \(bolusId)…")
        try? client.send(BolusPermissionReleaseRequest(bolusID: bolusId),
                         authenticationKey: authKey, pumpTimeSinceReset: signingTimestamp)
    }

    /// Phase B: initiate a SALINE bolus of `milliunits` for the granted `bolusId`. Signed +
    /// delivery-enabled. FOOD2 (manual units-only) type.
    func initiateBolus(milliunits: UInt32, bolusId: Int) {
        currentBolusId = bolusId
        print("[bolus] initiating \(Double(milliunits)/1000.0) u SALINE (bolusId \(bolusId))…")
        do {
            try client.send(
                InitiateBolusRequest(totalVolume: milliunits, bolusID: bolusId,
                                     bolusTypeBitmask: Self.food2),
                authenticationKey: authKey, pumpTimeSinceReset: signingTimestamp,
                allowInsulinDelivery: true)
        } catch { print("[bolus] initiate failed: \(error)") }
    }

    /// Once pump time + calculator snapshot + IOB are all in, compute the carb-bolus plan and
    /// begin the signed permission→initiate flow (carbs → units, the way controlX2 does).
    func maybeComputeCarbBolus() {
        guard isCarbMode, !permissionSent, haveTime, let calc, let iobMU = iobMilliunits else { return }
        let carbRatio = Double(calc.carbRatio)                 // ×1000 g/u
        let foodMU = carbRatio > 0 ? Int((carbGrams * 1_000_000 / carbRatio).rounded()) : 0
        var rawCorrMU = 0
        if let bg = carbBg, calc.isf > 0 {
            rawCorrMU = max(0, Int((Double(bg - calc.targetBg) * 1000 / Double(calc.isf)).rounded()))
        }
        let corrAfterIob = max(0, rawCorrMU - Int(iobMU))
        var total = Int((Double(foodMU + corrAfterIob) / 50).rounded()) * 50   // 0.05 u step
        total = min(max(total, 0), 2000)                       // bench clamp
        planFoodMU = UInt32(min(foodMU, total))
        planCorrectionMU = UInt32(total) - planFoodMU
        planTotalMU = UInt32(total)
        planBits = Self.food2 | (carbGrams > 0 ? Self.food1 : 0) | (corrAfterIob > 0 ? Self.correction : 0)

        print(String(format: "[carb-bolus] carbs=%.0fg bg=%@ | carbRatio=%.1f g/u ISF=%d target=%d IOB=%.2fu",
                     carbGrams, carbBg.map { "\($0)" } ?? "—",
                     calc.carbRatioGramsPerUnit, calc.isf, calc.targetBg, Double(iobMU) / 1000.0))
        print(String(format: "[carb-bolus] → food %.2fu + correction %.2fu = TOTAL %.2f u (verify against the pump's calculator)",
                     Double(planFoodMU) / 1000.0, Double(planCorrectionMU) / 1000.0, Double(planTotalMU) / 1000.0))
        guard planTotalMU >= 50 else {
            print("[carb-bolus] computed dose < 0.05 u — nothing to deliver. Stopping.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
            return
        }
        sendSignedPermission()
    }

    /// Deliver the computed carb bolus with full metadata (food/correction/carbs/bg/iob).
    func initiateCarbBolus(bolusId: Int) {
        currentBolusId = bolusId
        print(String(format: "[carb-bolus] initiating %.2f u SALINE (bolusId %d)…", Double(planTotalMU) / 1000.0, bolusId))
        do {
            try client.send(
                InitiateBolusRequest(totalVolume: planTotalMU, bolusID: bolusId, bolusTypeBitmask: planBits,
                                     foodVolume: planFoodMU, correctionVolume: planCorrectionMU,
                                     bolusCarbs: Int(carbGrams), bolusBG: carbBg ?? 0,
                                     bolusIOB: iobMilliunits ?? 0),
                authenticationKey: authKey, pumpTimeSinceReset: signingTimestamp, allowInsulinDelivery: true)
        } catch { print("[carb-bolus] initiate failed: \(error)") }
    }

    /// Cancel an in-progress bolus (SIGINT / Ctrl-C).
    func cancelBolus() {
        guard currentBolusId != 0 else { return }
        print("[bolus] CANCELLING bolus id \(currentBolusId)…")
        try? client.send(CancelBolusRequest(bolusId: currentBolusId),
                         authenticationKey: authKey, pumpTimeSinceReset: signingTimestamp)
    }

    /// After initiate, poll last-bolus status to watch delivered volume grow.
    func startBolusStatusPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { _ = try? self.client.send(LastBolusStatusV2Request()) }
        }
    }

    func poll() {
        try? client.send(ControlIQIOBRequest())
        try? client.send(InsulinStatusRequest())
        try? client.send(CurrentBatteryV2Request())
        try? client.send(CurrentEgvGuiDataV2Request())
        try? client.send(CurrentBasalStatusRequest())
        try? client.send(LastBolusStatusV2Request())
        try? client.send(BolusCalcDataSnapshotRequest())
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
            case let m as ControlIQIOBResponse:
                // iobUnits uses swan6hrIOB (matches the pump display, verified on hardware).
                print("[status] IOB = \(m.iobUnits) u")
                if isCarbMode { iobMilliunits = m.swan6hrIOB; maybeComputeCarbBolus() }
            case let m as InsulinStatusResponse: print("[status] insulin remaining = \(m.currentInsulinAmount) u")
            case let m as CurrentBatteryV2Response: print("[status] battery = \(m.batteryPercent)%")
            case let m as CurrentEgvGuiDataV2Response:
                print("[status] glucose = \(m.hasValidReading ? "\(m.cgmReading)" : "--") mg/dL \(m.trendArrow) (status=\(m.egvStatusId) trendRate=\(m.trendRate))")
            case let m as CurrentBasalStatusResponse:
                print("[status] basal = \(m.currentBasalUnitsPerHour) u/hr")
            case let m as LastBolusStatusV2Response:
                print("[status] last bolus = \(m.deliveredUnits) u (id \(m.bolusId))")
            case let m as BolusCalcDataSnapshotResponse:
                print("[status] calc — carbRatio raw=\(m.carbRatio) (~\(m.carbRatioGramsPerUnit) g/u) "
                    + "isf/correctionFactor=\(m.isf) mg/dL/u targetBG=\(m.targetBg) mg/dL "
                    + "carbEntryEnabled=\(m.carbEntryEnabled) maxBolus=\(Double(m.maxBolusAmount)/1000.0)u")
                if isCarbMode { calc = m; maybeComputeCarbBolus() }
            case let m as TimeSinceResetResponse:
                signingTimestamp = m.signingTimestamp
                print("[time] currentTime=\(m.currentTime) pumpTimeSinceReset=\(m.pumpTimeSinceReset) → signing with \(signingTimestamp)")
                if isCarbMode {
                    haveTime = true; maybeComputeCarbBolus()
                } else if (mode == .permissionTest || isBolusMode) && !permissionSent {
                    sendSignedPermission()
                }
            case let m as BolusPermissionResponse:
                print("[permission] status=\(m.status) granted=\(m.granted) bolusId=\(m.bolusId) nackReason=\(m.nackReasonId)")
                guard m.granted else { print("[permission] ❌ not granted — check signature/timestamp or pump state"); break }
                if case let .deliverBolus(mu) = mode {
                    print("[permission] ✅ granted — proceeding to SALINE delivery")
                    initiateBolus(milliunits: mu, bolusId: m.bolusId)
                } else if isCarbMode {
                    print("[permission] ✅ granted — proceeding to carb-bolus SALINE delivery")
                    initiateCarbBolus(bolusId: m.bolusId)
                } else {
                    print("[permission] ✅ pump ACCEPTED the signature and granted permission (no insulin delivered)")
                    releasePermission(bolusId: m.bolusId)
                }
            case let m as InitiateBolusResponse:
                print("[bolus] initiate response — status=\(m.status) accepted=\(m.accepted) bolusId=\(m.bolusId) statusType=\(m.statusTypeId)")
                if m.accepted {
                    print("[bolus] ✅ pump accepted the bolus — delivering SALINE. Weigh the container; Ctrl-C cancels.")
                    startBolusStatusPolling()
                } else {
                    print("[bolus] ❌ initiate not accepted")
                }
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
    let m = Monitor(mode: .scan); _ = m
    print("Scanning for pumps — Ctrl-C to stop.")
    RunLoop.main.run()
case "monitor":
    let m = Monitor(mode: .monitor); _ = m
    print("READ-ONLY monitor — connect, JPAKE pair, poll status. No writes that change pump state. Ctrl-C to stop.")
    RunLoop.main.run()
case "permission-test":
    // Signed-write validation that delivers NO insulin: pair → sign a BolusPermissionRequest
    // → release. Delivery (InitiateBolus) is still hard-blocked (writePolicy .allowNonDelivery).
    let m = Monitor(mode: .permissionTest); _ = m
    print("SIGNATURE TEST — pair, then send a SIGNED bolus-permission (NO insulin delivered) to")
    print("prove the pump accepts our HMAC. Delivery is hard-blocked. Ctrl-C to stop.")
    RunLoop.main.run()
case "bolus":
    // PHASE B — ACTUALLY DELIVERS. Bench saline only. Guarded so it can't run by accident.
    guard args.count >= 2, let mu = UInt32(args[1]) else {
        print("usage: bolus <milliunits>   e.g. 'bolus 100' = 0.10 u"); exit(2)
    }
    guard ProcessInfo.processInfo.environment["PUMPX2_DELIVER_SALINE"] == "1" else {
        print("REFUSED. This mode delivers a real bolus. Set PUMPX2_DELIVER_SALINE=1 to confirm")
        print("the pump has a SALINE cartridge dispensing into a container on a scale — never on a body.")
        exit(2)
    }
    guard mu >= 50 && mu <= 2000 else {
        print("REFUSED. Bench limit is 50–2000 milliunits (0.05–2.0 u). Got \(mu)."); exit(2)
    }
    let monitor = Monitor(mode: .deliverBolus(milliunits: mu)); _ = monitor
    // Ctrl-C cancels the in-progress bolus, then exits shortly after.
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        MainActor.assumeIsolated { monitor.cancelBolus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
    sigint.resume()
    print("⚠️  SALINE BOLUS \(Double(mu)/1000.0) u — bench only. Pump must dispense saline into a")
    print("container on a scale. Weigh before/after. Ctrl-C cancels mid-delivery.")
    RunLoop.main.run()
case "carb-bolus":
    // Carbs → units using the pump's carb ratio / ISF / target + IOB, then deliver. SALINE ONLY.
    guard args.count >= 2, let carbs = Double(args[1]) else {
        print("usage: carb-bolus <grams> [bg]   e.g. 'carb-bolus 30' or 'carb-bolus 30 160'"); exit(2)
    }
    let bg = args.count >= 3 ? Int(args[2]) : nil
    guard ProcessInfo.processInfo.environment["PUMPX2_DELIVER_SALINE"] == "1" else {
        print("REFUSED. Delivers a real bolus. Set PUMPX2_DELIVER_SALINE=1 to confirm SALINE on a scale.")
        exit(2)
    }
    guard carbs > 0 && carbs <= 200 else { print("REFUSED. Enter 1–200 g."); exit(2) }
    let monitor = Monitor(mode: .carbBolus(carbs: carbs, bg: bg))
    monitor.carbGrams = carbs; monitor.carbBg = bg
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        MainActor.assumeIsolated { monitor.cancelBolus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
    sigint.resume()
    print("⚠️  CARB BOLUS \(carbs) g\(bg.map { ", BG \($0)" } ?? "") — computes units from the pump's")
    print("carb ratio/ISF/target, then delivers SALINE (bench, on a scale, capped 2.0 u). Ctrl-C cancels.")
    RunLoop.main.run()
default:
    print("unknown command: \(args[0])")
    print("commands: (none)=self-check, scan, monitor, permission-test, bolus <milliunits>, carb-bolus <grams> [bg]")
    exit(2)
}
