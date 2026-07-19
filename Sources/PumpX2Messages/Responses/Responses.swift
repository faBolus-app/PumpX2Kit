import Foundation

/// Inbound (pump → app) response messages. Ports of `response/**`. Each parses its cargo in
/// `init(cargo:)`; parsing is validated byte-exact by encoding a response through the oracle
/// and round-tripping it back (see OracleParityTests).
public protocol ResponseMessage: Message {
    init(cargo: [UInt8])
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
    /// A coarse Loop-style trend arrow from the sign/magnitude of `trendRate`.
    public var trendArrow: String {
        switch trendRate {
        case ..<(-20): return "⇊"
        case (-20)..<(-5): return "↓"
        case (-5)..<6: return "→"
        case 6..<21: return "↑"
        default: return "⇈"
        }
    }
    /// EGV status per upstream: 0=INVALID, 1=VALID, 2=LOW, 3=HIGH, 4=UNAVAILABLE.
    public var hasValidReading: Bool {
        (egvStatusId == 1 || egvStatusId == 2 || egvStatusId == 3) && cgmReading > 0 && cgmReading < 600
    }
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
