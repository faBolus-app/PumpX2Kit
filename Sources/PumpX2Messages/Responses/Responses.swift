import Foundation

/// Inbound (pump → app) response messages. Ports of `response/**`. Each parses its cargo in
/// `init(cargo:)`; parsing is validated byte-exact by encoding a response through the oracle
/// and round-tripping it back (see OracleParityTests).
public protocol ResponseMessage: Message {
    init(cargo: [UInt8])
}

/// Pump API version (major/minor). `response/currentStatus/ApiVersionResponse` (opcode 33, 4 bytes).
/// The API version identifies the pump family — t:slim X2 is 2.x–3.4, **Mobi is 3.5+** (mirrors
/// jwoglom `KnownApiVersion`), so this is a first-class pump-model signal.
public struct ApiVersionResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 33, size: 4, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var majorVersion: Int = 0
    public private(set) var minorVersion: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 4 {
            majorVersion = Bytes.readShort(raw, 0)
            minorVersion = Bytes.readShort(raw, 2)
        }
    }
    public mutating func parse(_ raw: [UInt8]) { self = ApiVersionResponse(cargo: raw) }
    /// True when the pump is a Tandem Mobi (API 3.5+); t:slim X2 is 2.x–3.4.
    public var isMobi: Bool { majorVersion > 3 || (majorVersion == 3 && minorVersion >= 5) }
}

/// IOB read for non-Control-IQ pumps. `response/currentStatus/NonControlIQIOBResponse` (op 39, 12B).
public struct NonControlIQIOBResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 39, size: 12, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var iob: UInt32 = 0                 // milliunits
    public private(set) var timeRemainingSeconds: UInt32 = 0
    public private(set) var totalIOB: UInt32 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 12 {
            iob = Bytes.readUint32(raw, 0)
            timeRemainingSeconds = Bytes.readUint32(raw, 4)
            totalIOB = Bytes.readUint32(raw, 8)
        }
    }
    public mutating func parse(_ raw: [UInt8]) { self = NonControlIQIOBResponse(cargo: raw) }
    public var iobUnits: Double { Double(iob) / 1000.0 }
}

/// Control-IQ info (closed-loop state, current user mode). `response/currentStatus/ControlIQInfoV2Response`
/// (op 179, 19B). `currentUserModeType`/`controlStateType` expose Sleep/Exercise + CIQ activity.
public struct ControlIQInfoV2Response: ResponseMessage {
    public static let props = MessageProps(opCode: 179, size: 19, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var closedLoopEnabled = false
    public private(set) var currentUserModeType = 0
    public private(set) var controlStateType = 0
    public private(set) var exerciseChoice = 0
    public private(set) var exerciseTimeRemainingSeconds: UInt32 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 19 {
            closedLoopEnabled = raw[0] != 0
            currentUserModeType = Int(raw[5])
            controlStateType = Int(raw[9])
            exerciseChoice = Int(raw[10])
            exerciseTimeRemainingSeconds = Bytes.readUint32(raw, 15)
        }
    }
    public mutating func parse(_ raw: [UInt8]) { self = ControlIQInfoV2Response(cargo: raw) }
}

/// Last fingerstick blood-glucose entered on the pump. `response/currentStatus/LastBGResponse` (op 51, 7B).
public struct LastBGResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 51, size: 7, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var bgTimestamp: UInt32 = 0
    public private(set) var bgValue: Int = 0
    public private(set) var bgSourceId: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 7 {
            bgTimestamp = Bytes.readUint32(raw, 0)
            bgValue = Bytes.readShort(raw, 4)
            bgSourceId = Int(raw[6])
        }
    }
    public mutating func parse(_ raw: [UInt8]) { self = LastBGResponse(cargo: raw) }
}

/// Ack for a suspend-pumping command (signed). `response/control/SuspendPumpingResponse` (op 0x9D, 1B).
public struct SuspendPumpingResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0x9D, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = SuspendPumpingResponse(cargo: raw) }
    /// status 0 = accepted.
    public var accepted: Bool { status == 0 }
}

/// Ack for a resume-pumping command (signed). `response/control/ResumePumpingResponse` (op 0x9B, 1B).
public struct ResumePumpingResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0x9B, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = ResumePumpingResponse(cargo: raw) }
    /// status 0 = accepted.
    public var accepted: Bool { status == 0 }
}

/// Ack for a set-temp-rate command (signed). `response/control/SetTempRateResponse` (op 0xA5, 4B).
/// `tempRateId` cross-references the `TempRateActivatedHistoryLog` event.
public struct SetTempRateResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xA5, size: 4, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public private(set) var tempRateId = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if !raw.isEmpty { status = Int(raw[0]) }
        if raw.count >= 3 { tempRateId = Bytes.readShort(raw, 1) }
    }
    public mutating func parse(_ raw: [UInt8]) { self = SetTempRateResponse(cargo: raw) }
    /// status 0 = accepted.
    public var accepted: Bool { status == 0 }
}

/// Ack for a stop-temp-rate command (signed). `response/control/StopTempRateResponse` (op 0xA7, 3B).
/// `tempRateId` cross-references the `TempRateCompletedHistoryLog` event.
public struct StopTempRateResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xA7, size: 3, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public private(set) var tempRateId = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if !raw.isEmpty { status = Int(raw[0]) }
        if raw.count >= 3 { tempRateId = Bytes.readShort(raw, 1) }
    }
    public mutating func parse(_ raw: [UInt8]) { self = StopTempRateResponse(cargo: raw) }
    /// status 0 = accepted.
    public var accepted: Bool { status == 0 }
}

/// Pump firmware/hardware version + identifiers. `response/currentStatus/PumpVersionResponse`
/// (op 85, 48B).
public struct PumpVersionResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 85, size: 48, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var armSwVer: UInt32 = 0
    public private(set) var mspSwVer: UInt32 = 0
    public private(set) var serialNum: UInt32 = 0
    public private(set) var partNum: UInt32 = 0
    public private(set) var pumpRev = ""
    public private(set) var modelNum: UInt32 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 48 {
            armSwVer = Bytes.readUint32(raw, 0)
            mspSwVer = Bytes.readUint32(raw, 4)
            serialNum = Bytes.readUint32(raw, 16)
            partNum = Bytes.readUint32(raw, 20)
            pumpRev = Bytes.readString(raw, 24, 8)
            modelNum = Bytes.readUint32(raw, 44)
        }
    }
    public mutating func parse(_ raw: [UInt8]) { self = PumpVersionResponse(cargo: raw) }
}

/// What the pump home screen is showing (icon ids + CGM display flags).
/// `response/currentStatus/HomeScreenMirrorResponse` (op 57, 9B).
public struct HomeScreenMirrorResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 57, size: 9, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var cgmTrendIconId = 0
    public private(set) var cgmAlertIconId = 0
    public private(set) var bolusStatusIconId = 0
    public private(set) var basalStatusIconId = 0
    public private(set) var apControlStateIconId = 0
    public private(set) var remainingInsulinPlusIcon = false
    public private(set) var cgmDisplayData = false
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 9 {
            cgmTrendIconId = Int(raw[0])
            cgmAlertIconId = Int(raw[1])
            bolusStatusIconId = Int(raw[4])
            basalStatusIconId = Int(raw[5])
            apControlStateIconId = Int(raw[6])
            remainingInsulinPlusIcon = raw[7] != 0
            cgmDisplayData = raw[8] != 0
        }
    }
    public mutating func parse(_ raw: [UInt8]) { self = HomeScreenMirrorResponse(cargo: raw) }
}

/// Temp-basal-rate status. `response/currentStatus/TempRateStatusResponse` (op 31, 16B).
public struct TempRateStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 31, size: 16, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var active = false
    public private(set) var tempRateId = 0
    public private(set) var startTimeRaw: UInt32 = 0
    public private(set) var secondsSincePumpReset: UInt32 = 0
    public private(set) var durationSeconds: UInt32 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 16 {
            active = raw[0] != 0
            tempRateId = Bytes.readShort(raw, 1)
            startTimeRaw = Bytes.readUint32(raw, 4)
            secondsSincePumpReset = Bytes.readUint32(raw, 8)
            durationSeconds = Bytes.readUint32(raw, 12)
        }
    }
    public mutating func parse(_ raw: [UInt8]) { self = TempRateStatusResponse(cargo: raw) }
}

/// Battery read for older (non-V2) pumps. `response/currentStatus/CurrentBatteryV1Response` (op 53, 2B).
public struct CurrentBatteryV1Response: ResponseMessage {
    public static let props = MessageProps(opCode: 53, size: 2, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var currentBatteryAbc = 0
    public private(set) var currentBatteryIbc = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 2 { currentBatteryAbc = Int(raw[0]); currentBatteryIbc = Int(raw[1]) }
    }
    public mutating func parse(_ raw: [UInt8]) { self = CurrentBatteryV1Response(cargo: raw) }
    public var batteryPercent: Int { currentBatteryIbc }
}

/// IOB read (Control-IQ). `response/currentStatus/ControlIQIOBResponse` (opcode 109, 17 bytes).
public struct ControlIQIOBResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 109, size: 17, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var mudaliarIOB: UInt32 = 0        // milliunits
    public private(set) var timeRemainingSeconds: UInt32 = 0
    public private(set) var mudaliarTotalIOB: UInt32 = 0
    public private(set) var swan6hrIOB: UInt32 = 0
    public private(set) var iobType: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        mudaliarIOB = Bytes.readUint32(raw, 0)
        timeRemainingSeconds = Bytes.readUint32(raw, 4)
        mudaliarTotalIOB = Bytes.readUint32(raw, 8)
        swan6hrIOB = Bytes.readUint32(raw, 12)
        iobType = Int(raw[16])
    }
    public mutating func parse(_ raw: [UInt8]) { self = ControlIQIOBResponse(cargo: raw) }
    /// IOB in insulin units. Uses `swan6hrIOB` — verified on hardware (t:slim X2, Control-IQ+
    /// 7.10.2) to match the value the pump displays, unlike `mudaliarIOB`.
    public var iobUnits: Double { Double(swan6hrIOB) / 1000.0 }
}

/// In-progress bolus status. `response/currentStatus/CurrentBolusStatusResponse` (opcode 45,
/// 15 bytes). `statusId`: 0 = already delivered / invalid (none active), 1 = delivering,
/// 2 = requesting. Used to detect when a bolus finishes so the UI can keep a live cancel window.
public struct CurrentBolusStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 45, size: 15, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var statusId: Int = 0
    public private(set) var bolusId: Int = 0
    public private(set) var requestedVolume: UInt32 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 15 {
            statusId = Int(raw[0])
            bolusId = Bytes.readShort(raw, 1)
            requestedVolume = Bytes.readUint32(raw, 9)
        }
    }
    public mutating func parse(_ raw: [UInt8]) { self = CurrentBolusStatusResponse(cargo: raw) }
    /// True while the pump is still requesting or delivering this bolus.
    public var isActive: Bool { statusId == 1 || statusId == 2 }
}

/// Insulin remaining. `response/currentStatus/InsulinStatusResponse` (opcode 37, 4 bytes).
public struct InsulinStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 37, size: 4, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var currentInsulinAmount: Int = 0   // units remaining
    public private(set) var isEstimate: Int = 0
    public private(set) var insulinLowAmount: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        currentInsulinAmount = Bytes.readShort(raw, 0)
        isEstimate = Int(raw[2])
        insulinLowAmount = Int(raw[3])
    }
    public mutating func parse(_ raw: [UInt8]) { self = InsulinStatusResponse(cargo: raw) }
}

/// Battery. `response/currentStatus/CurrentBatteryV2Response` (opcode 145, 11 bytes).
public struct CurrentBatteryV2Response: ResponseMessage {
    public static let props = MessageProps(opCode: 145, size: 11, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var currentBatteryAbc: Int = 0
    public private(set) var currentBatteryIbc: Int = 0      // battery percent
    public private(set) var chargingStatus: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        currentBatteryAbc = Int(raw[0])
        currentBatteryIbc = Int(raw[1])
        chargingStatus = Int(raw[2])
    }
    public mutating func parse(_ raw: [UInt8]) { self = CurrentBatteryV2Response(cargo: raw) }
    public var batteryPercent: Int { currentBatteryIbc }
}

/// Current CGM reading + trend (GUI data, V2). `response/currentStatus/CurrentEgvGuiDataV2Response`
/// (opcode 193, 8 bytes). `cgmReading` is mg/dL; `trendRate` is a signed rate (sign → arrow).
public struct CurrentEgvGuiDataV2Response: ResponseMessage {
    public static let props = MessageProps(opCode: 193, size: 8, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var bgReadingTimestampSeconds: UInt32 = 0
    public private(set) var cgmReading: Int = 0        // mg/dL
    public private(set) var egvStatusId: Int = 0
    public private(set) var trendRate: Int = 0         // signed (Int8)
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        bgReadingTimestampSeconds = Bytes.readUint32(raw, 0)
        cgmReading = Bytes.readShort(raw, 4)
        egvStatusId = Int(raw[6])
        trendRate = Int(Int8(bitPattern: raw[7]))
    }
    public mutating func parse(_ raw: [UInt8]) { self = CurrentEgvGuiDataV2Response(cargo: raw) }
    /// `trendRate` is a signed byte in 0.1 mg/dL/min units (matches the pump's ±12.7 range).
    public var trendRateMgDlPerMin: Double { Double(trendRate) / 10.0 }
    /// Dexcom-style 7-category trend arrow, matching the pump display.
    public var trendArrow: String {
        let r = trendRateMgDlPerMin
        switch r {
        case ..<(-3): return "⇊"   // falling rapidly (> 3 mg/dL/min down)
        case (-3)..<(-2): return "↓"   // falling
        case (-2)..<(-1): return "↘"   // falling slightly
        case (-1)...1: return "→"      // steady
        case 1..<2: return "↗"         // rising slightly
        case 2..<3: return "↑"         // rising
        default: return "⇈"            // rising rapidly
        }
    }
    /// EGV status per upstream: 0=INVALID, 1=VALID, 2=LOW, 3=HIGH, 4=UNAVAILABLE.
    public var hasValidReading: Bool {
        (egvStatusId == 1 || egvStatusId == 2 || egvStatusId == 3) && cgmReading > 0 && cgmReading < 600
    }
}

/// Pump clock. `response/currentStatus/TimeSinceResetResponse` (opcode 55, 8 bytes).
/// `currentTime` is what the Android reference embeds into signed-message HMACs, so it's the
/// value to use as `pumpTimeSinceReset` when signing (verified against upstream TandemBluetoothHandler).
public struct TimeSinceResetResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 55, size: 8, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var currentTime: UInt32 = 0
    public private(set) var pumpTimeSinceReset: UInt32 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        currentTime = Bytes.readUint32(raw, 0)
        pumpTimeSinceReset = Bytes.readUint32(raw, 4)
    }
    public mutating func parse(_ raw: [UInt8]) { self = TimeSinceResetResponse(cargo: raw) }
    /// The timestamp to embed when signing (matches the Android app, which uses currentTime).
    public var signingTimestamp: UInt32 { currentTime }
}

/// Basal rate. `response/currentStatus/CurrentBasalStatusResponse` (opcode 41, 9 bytes).
/// Rates are in milliunits/hour.
public struct CurrentBasalStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 41, size: 9, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var profileBasalRate: UInt32 = 0
    public private(set) var currentBasalRate: UInt32 = 0
    public private(set) var basalModifiedBitmask: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        profileBasalRate = Bytes.readUint32(raw, 0)
        currentBasalRate = Bytes.readUint32(raw, 4)
        basalModifiedBitmask = Int(raw[8])
    }
    public mutating func parse(_ raw: [UInt8]) { self = CurrentBasalStatusResponse(cargo: raw) }
    public var currentBasalUnitsPerHour: Double { Double(currentBasalRate) / 1000.0 }
}

/// Last completed bolus. `response/currentStatus/LastBolusStatusV2Response` (opcode 165, 24 bytes).
public struct LastBolusStatusV2Response: ResponseMessage {
    public static let props = MessageProps(opCode: 165, size: 24, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var status: Int = 0
    public private(set) var bolusId: Int = 0
    public private(set) var timestamp: UInt32 = 0
    public private(set) var deliveredVolume: UInt32 = 0     // milliunits
    public private(set) var requestedVolume: UInt32 = 0     // milliunits
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        status = Int(raw[0])
        bolusId = Bytes.readShort(raw, 1)
        timestamp = Bytes.readUint32(raw, 5)
        deliveredVolume = Bytes.readUint32(raw, 9)
        requestedVolume = Bytes.readUint32(raw, 20)
    }
    public mutating func parse(_ raw: [UInt8]) { self = LastBolusStatusV2Response(cargo: raw) }
    public var deliveredUnits: Double { Double(deliveredVolume) / 1000.0 }
}

/// Bolus-calculator snapshot — the therapy settings needed to turn carbs/BG into units, the
/// way controlX2 does. `response/currentStatus/BolusCalcDataSnapshotResponse` (opcode 115).
/// `carbRatio` (uint32) and `isf`/`correctionFactor` (mg/dL per unit) + `targetBg` drive the
/// carb-entry bolus feature.
public struct BolusCalcDataSnapshotResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 115, size: 46, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var correctionFactor: Int = 0
    public private(set) var iob: UInt32 = 0
    public private(set) var cartridgeRemainingInsulin: Int = 0
    public private(set) var targetBg: Int = 0                // mg/dL
    public private(set) var isf: Int = 0                     // correction factor, mg/dL per unit
    public private(set) var carbEntryEnabled: Bool = false
    public private(set) var carbRatio: UInt32 = 0            // see carbRatioGramsPerUnit
    public private(set) var maxBolusAmount: Int = 0          // milliunits
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        correctionFactor = Bytes.readShort(raw, 1)
        iob = Bytes.readUint32(raw, 3)
        cartridgeRemainingInsulin = Bytes.readShort(raw, 7)
        targetBg = Bytes.readShort(raw, 9)
        isf = Bytes.readShort(raw, 11)
        carbEntryEnabled = raw[13] != 0
        carbRatio = Bytes.readUint32(raw, 14)
        maxBolusAmount = Bytes.readShort(raw, 18)
    }
    public mutating func parse(_ raw: [UInt8]) { self = BolusCalcDataSnapshotResponse(cargo: raw) }
    /// Tandem stores carbRatio scaled ×1000 (e.g. 10 g/u → 10000). VERIFY against the pump
    /// screen before relying on it for dosing.
    public var carbRatioGramsPerUnit: Double { Double(carbRatio) / 1000.0 }
}

/// Bolus permission grant. `response/control/BolusPermissionResponse` (opcode 163, 6 bytes).
/// `status == 0` = granted; `bolusId` is used for InitiateBolus/Cancel.
public struct BolusPermissionResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 163, size: 6, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status: Int = 0
    public private(set) var bolusId: Int = 0
    public private(set) var nackReasonId: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        status = Int(raw[0])
        bolusId = Bytes.readShort(raw, 1)
        nackReasonId = Int(raw[5])
    }
    public mutating func parse(_ raw: [UInt8]) { self = BolusPermissionResponse(cargo: raw) }
    public var granted: Bool { status == 0 }
}

/// Initiate-bolus ack. `response/control/InitiateBolusResponse` (opcode 159, 6 bytes).
public struct InitiateBolusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 159, size: 6, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status: Int = 0
    public private(set) var bolusId: Int = 0
    public private(set) var statusTypeId: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        status = Int(raw[0])
        bolusId = Bytes.readShort(raw, 1)
        statusTypeId = Int(raw[5])
    }
    public mutating func parse(_ raw: [UInt8]) { self = InitiateBolusResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}
