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
    /// IOB in insulin units.
    public var iobUnits: Double { Double(mudaliarIOB) / 1000.0 }
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
