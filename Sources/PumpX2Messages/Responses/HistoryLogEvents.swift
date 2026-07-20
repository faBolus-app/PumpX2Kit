import Foundation

/// Typed history-log events (A4). The pump keeps a rolling on-device log; each entry is a fixed
/// 26-byte record streamed inside `HistoryLogStreamResponse`. Every record starts with a common
/// header (`HistoryLog.parseBase`): typeId = short@0 & 0x0FFF, pumpTimeSec = uint32@2,
/// sequenceNum = uint32@6. `HistoryLogParser` dispatches a record to the matching event struct by
/// typeId (falling back to `UnknownHistoryLog`).
///
/// These are **decode-only** — the pump produces them, the app never sends them — so correctness =
/// our decode matching upstream's decode for the same bytes (verified via the oracle `historylog`
/// command). Most structs are scaffolded by `scripts/port_message.py` from
/// `references/pumpx2/.../response/historyLog/*` and are byte-faithful ports of upstream `parse()`.

/// A decoded history-log event. `typeId` identifies the record type; base fields are shared.
public protocol HistoryLogEvent: Sendable {
    static var typeId: Int { get }
    var cargo: [UInt8] { get }
    var pumpTimeSec: UInt32 { get }
    var sequenceNum: UInt32 { get }
    init(cargo: [UInt8])
}

public extension HistoryLogEvent {
    var typeId: Int { Self.typeId }
    /// The record's pump-clock timestamp as a `Date` (Jan 1 2008 epoch).
    var pumpTime: Date { Date(timeIntervalSince1970: HistoryLog.jan12008UnixEpoch + Double(pumpTimeSec)) }
}

/// Fallback for a record whose typeId we don't (yet) decode. Preserves the header + raw cargo.
public struct UnknownHistoryLog: HistoryLogEvent {
    public static let typeId = -1
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var rawTypeId: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 10 else { return }
        rawTypeId = Bytes.readShort(raw, 0) & 0x0FFF
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
    }
}

/// Dispatches a 26-byte history-log record to a typed `HistoryLogEvent` by typeId. Mirrors
/// upstream `HistoryLogParser` (`LOG_MESSAGE_TYPES`). Register new event types with `add(_:)`.
public enum HistoryLogParser {
    static let factories: [Int: @Sendable ([UInt8]) -> any HistoryLogEvent] = {
        var r: [Int: @Sendable ([UInt8]) -> any HistoryLogEvent] = [:]
        func add<E: HistoryLogEvent>(_ type: E.Type) { r[E.typeId] = { E(cargo: $0) } }
        add(BolusDeliveryHistoryLog.self)
        add(BolusCompletedHistoryLog.self)
        add(BolusActivatedHistoryLog.self)
        add(BolexActivatedHistoryLog.self)
        add(BolexCompletedHistoryLog.self)
        add(BolusRequestedMsg1HistoryLog.self)
        add(BolusRequestedMsg2HistoryLog.self)
        add(BolusRequestedMsg3HistoryLog.self)
        add(BasalRateChangeHistoryLog.self)
        add(DailyBasalHistoryLog.self)
        add(TempRateActivatedHistoryLog.self)
        add(TempRateCompletedHistoryLog.self)
        add(CarbEnteredHistoryLog.self)
        add(BGHistoryLog.self)
        add(DexcomG6CGMHistoryLog.self)
        add(AlarmActivatedHistoryLog.self)
        add(AlertActivatedHistoryLog.self)
        add(AlarmClearedHistoryLog.self)
        add(PumpingResumedHistoryLog.self)
        add(PumpingSuspendedHistoryLog.self)
        add(CartridgeFilledHistoryLog.self)
        add(CannulaFilledHistoryLog.self)
        add(TubingFilledHistoryLog.self)
        return r
    }()

    /// The number of distinct history-log event types currently decoded.
    public static var decodedTypeCount: Int { factories.count }

    /// Parses one 26-byte record into a typed event, or `UnknownHistoryLog` if the typeId is
    /// unknown / the record is too short.
    public static func parse(record raw: [UInt8]) -> any HistoryLogEvent {
        guard raw.count >= 10 else { return UnknownHistoryLog(cargo: raw) }
        let typeId = Bytes.readShort(raw, 0) & 0x0FFF
        if let make = factories[typeId] { return make(raw) }
        return UnknownHistoryLog(cargo: raw)
    }
}

// MARK: - Boluses

/// Bolus Delivery — history-log event (typeId 280).
public struct BolusDeliveryHistoryLog: HistoryLogEvent {
    public static let typeId = 280
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var bolusID: Int = 0
    public private(set) var bolusDeliveryStatusId: Int = 0
    public private(set) var bolusTypeBitmask: Int = 0
    public private(set) var bolusSource: Int = 0
    public private(set) var reserved: Int = 0
    public private(set) var requestedNow: Int = 0
    public private(set) var requestedLater: Int = 0
    public private(set) var correction: Int = 0
    public private(set) var extendedDurationRequested: Int = 0
    public private(set) var deliveredTotal: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        bolusID = Bytes.readShort(raw, 10)
        bolusDeliveryStatusId = Int(raw[12])
        bolusTypeBitmask = Int(raw[13])
        bolusSource = Int(raw[14])
        reserved = Int(raw[15])
        requestedNow = Bytes.readShort(raw, 16)
        requestedLater = Bytes.readShort(raw, 18)
        correction = Bytes.readShort(raw, 20)
        extendedDurationRequested = Bytes.readShort(raw, 22)
        deliveredTotal = Bytes.readShort(raw, 24)
    }
}

/// Bolus Completed — history-log event (typeId 20). iob/insulin fields are real insulin units.
public struct BolusCompletedHistoryLog: HistoryLogEvent {
    public static let typeId = 20
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var completionStatusId: Int = 0
    public private(set) var bolusId: Int = 0
    public private(set) var iob: Float = 0
    public private(set) var insulinDelivered: Float = 0
    public private(set) var insulinRequested: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        completionStatusId = Bytes.readShort(raw, 10)
        bolusId = Bytes.readShort(raw, 12)
        iob = Bytes.readFloat(raw, 14)
        insulinDelivered = Bytes.readFloat(raw, 18)
        insulinRequested = Bytes.readFloat(raw, 22)
    }
}

/// Bolus Activated — history-log event (typeId 55).
public struct BolusActivatedHistoryLog: HistoryLogEvent {
    public static let typeId = 55
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var bolusId: Int = 0
    public private(set) var iob: Float = 0
    public private(set) var bolusSize: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        bolusId = Bytes.readShort(raw, 10)
        iob = Bytes.readFloat(raw, 14)
        bolusSize = Bytes.readFloat(raw, 18)
    }
}

/// Extended Bolus Activated — history-log event (typeId 59).
public struct BolexActivatedHistoryLog: HistoryLogEvent {
    public static let typeId = 59
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var bolusId: Int = 0
    public private(set) var iob: Float = 0
    public private(set) var bolexSize: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        bolusId = Bytes.readShort(raw, 10)
        iob = Bytes.readFloat(raw, 14)
        bolexSize = Bytes.readFloat(raw, 18)
    }
}

/// Extended Bolus Portion Complete — history-log event (typeId 21).
public struct BolexCompletedHistoryLog: HistoryLogEvent {
    public static let typeId = 21
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var completionStatusId: Int = 0
    public private(set) var bolusId: Int = 0
    public private(set) var iob: Float = 0
    public private(set) var insulinDelivered: Float = 0
    public private(set) var insulinRequested: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        completionStatusId = Bytes.readShort(raw, 10)
        bolusId = Bytes.readShort(raw, 12)
        iob = Bytes.readFloat(raw, 14)
        insulinDelivered = Bytes.readFloat(raw, 18)
        insulinRequested = Bytes.readFloat(raw, 22)
    }
}

/// Bolus Requested 1/3 — history-log event (typeId 64).
public struct BolusRequestedMsg1HistoryLog: HistoryLogEvent {
    public static let typeId = 64
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var bolusId: Int = 0
    public private(set) var bolusTypeId: Int = 0
    public private(set) var correctionBolusIncluded: Bool = false
    public private(set) var carbAmount: Int = 0
    public private(set) var bg: Int = 0
    public private(set) var iob: Float = 0
    public private(set) var carbRatio: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        bolusId = Bytes.readShort(raw, 10)
        bolusTypeId = Int(raw[12])
        correctionBolusIncluded = raw[13] != 0
        carbAmount = Bytes.readShort(raw, 14)
        bg = Bytes.readShort(raw, 16)
        iob = Bytes.readFloat(raw, 18)
        carbRatio = Int(Bytes.readUint32(raw, 22))
    }
}

/// Bolus Requested 2/3 — history-log event (typeId 65).
public struct BolusRequestedMsg2HistoryLog: HistoryLogEvent {
    public static let typeId = 65
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var bolusId: Int = 0
    public private(set) var options: Int = 0
    public private(set) var standardPercent: Int = 0
    public private(set) var duration: Int = 0
    public private(set) var spare1: Int = 0
    public private(set) var isf: Int = 0
    public private(set) var targetBG: Int = 0
    public private(set) var userOverride: Bool = false
    public private(set) var declinedCorrection: Bool = false
    public private(set) var selectedIOB: Int = 0
    public private(set) var spare2: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        bolusId = Bytes.readShort(raw, 10)
        options = Int(raw[12])
        standardPercent = Int(raw[13])
        duration = Bytes.readShort(raw, 14)
        spare1 = Bytes.readShort(raw, 16)
        isf = Bytes.readShort(raw, 18)
        targetBG = Bytes.readShort(raw, 20)
        userOverride = raw[22] != 0
        declinedCorrection = raw[23] != 0
        selectedIOB = Int(raw[24])
        spare2 = Int(raw[25])
    }
}

/// Bolus Requested 3/3 — history-log event (typeId 66). Bolus sizes are real insulin units.
public struct BolusRequestedMsg3HistoryLog: HistoryLogEvent {
    public static let typeId = 66
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var bolusId: Int = 0
    public private(set) var spare: Int = 0
    public private(set) var foodBolusSize: Float = 0
    public private(set) var correctionBolusSize: Float = 0
    public private(set) var totalBolusSize: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        bolusId = Bytes.readShort(raw, 10)
        spare = Bytes.readShort(raw, 12)
        foodBolusSize = Bytes.readFloat(raw, 14)
        correctionBolusSize = Bytes.readFloat(raw, 18)
        totalBolusSize = Bytes.readFloat(raw, 22)
    }
}

// MARK: - Basal / temp rate

/// Basal Rate Change — history-log event (typeId 3). Rates are real units/hr (IEEE floats).
public struct BasalRateChangeHistoryLog: HistoryLogEvent {
    public static let typeId = 3
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var commandBasalRate: Float = 0
    public private(set) var baseBasalRate: Float = 0
    public private(set) var maxBasalRate: Float = 0
    public private(set) var insulinDeliveryProfile: Int = 0
    public private(set) var changeTypeId: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        commandBasalRate = Bytes.readFloat(raw, 10)
        baseBasalRate = Bytes.readFloat(raw, 14)
        maxBasalRate = Bytes.readFloat(raw, 18)
        insulinDeliveryProfile = Bytes.readShort(raw, 22)
        changeTypeId = Int(raw[24])
    }
}

/// Daily Basal — history-log event (typeId 81). End-of-day totals + battery snapshot.
public struct DailyBasalHistoryLog: HistoryLogEvent {
    public static let typeId = 81
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var dailyTotalBasal: Float = 0
    public private(set) var lastBasalRate: Float = 0
    public private(set) var iob: Float = 0
    public private(set) var finalEventForDay: Bool = false
    public private(set) var batteryChargeRaw: Int = 0
    public private(set) var lipoMv: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        dailyTotalBasal = Bytes.readFloat(raw, 10)
        lastBasalRate = Bytes.readFloat(raw, 14)
        iob = Bytes.readFloat(raw, 18)
        finalEventForDay = raw[22] == 1
        batteryChargeRaw = Int(raw[23])
        lipoMv = Bytes.readShort(raw, 24)
    }
}

/// Temporary Basal Rate Activated — history-log event (typeId 2).
public struct TempRateActivatedHistoryLog: HistoryLogEvent {
    public static let typeId = 2
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var percent: Float = 0
    public private(set) var duration: Float = 0
    public private(set) var tempRateId: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        percent = Bytes.readFloat(raw, 10)
        duration = Bytes.readFloat(raw, 14)
        tempRateId = Bytes.readShort(raw, 20)
    }
}

/// Temporary Basal Rate Completed — history-log event (typeId 15).
public struct TempRateCompletedHistoryLog: HistoryLogEvent {
    public static let typeId = 15
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var tempRateId: Int = 0
    public private(set) var timeLeft: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        tempRateId = Bytes.readShort(raw, 12)
        timeLeft = Int(Bytes.readUint32(raw, 14))
    }
}

// MARK: - Carbs / BG / CGM

/// Carbs Entered — history-log event (typeId 48).
public struct CarbEnteredHistoryLog: HistoryLogEvent {
    public static let typeId = 48
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var carbs: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        carbs = Bytes.readFloat(raw, 10)
    }
}

/// BG Taken — history-log event (typeId 16).
public struct BGHistoryLog: HistoryLogEvent {
    public static let typeId = 16
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var bg: Int = 0
    public private(set) var cgmCalibration: Int = 0
    public private(set) var bgSourceId: Int = 0
    public private(set) var iob: Float = 0
    public private(set) var targetBG: Int = 0
    public private(set) var isf: Int = 0
    public private(set) var selectedIOB: Int = 0
    public private(set) var bgSourceType: Int = 0
    public private(set) var spare: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        bg = Bytes.readShort(raw, 10)
        cgmCalibration = Int(raw[12])
        bgSourceId = Int(raw[13])
        iob = Bytes.readFloat(raw, 14)
        targetBG = Bytes.readShort(raw, 18)
        isf = Bytes.readShort(raw, 20)
        selectedIOB = Int(raw[22])
        bgSourceType = Int(raw[23])
        spare = Bytes.readShort(raw, 24)
    }
}

/// Dexcom G6 CGM Data — history-log event (typeId 256). `currentGlucoseDisplayValue` is the mg/dL.
public struct DexcomG6CGMHistoryLog: HistoryLogEvent {
    public static let typeId = 256
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var glucoseValueStatusRaw: Int = 0
    public private(set) var cgmDataTypeRaw: Int = 0
    public private(set) var rate: Int = 0
    public private(set) var algorithmState: Int = 0
    public private(set) var rssi: Int = 0
    public private(set) var currentGlucoseDisplayValue: Int = 0
    public private(set) var timeStampSeconds: Int = 0
    public private(set) var egvInfoBitmaskRaw: Int = 0
    public private(set) var interval: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        glucoseValueStatusRaw = Bytes.readShort(raw, 10)
        cgmDataTypeRaw = Int(raw[12])
        rate = Int(raw[13])
        algorithmState = Int(raw[14])
        rssi = Int(raw[15])
        currentGlucoseDisplayValue = Bytes.readShort(raw, 16)
        timeStampSeconds = Int(Bytes.readUint32(raw, 18))
        egvInfoBitmaskRaw = Bytes.readShort(raw, 22)
        interval = Int(raw[24])
    }
}

// MARK: - Alarms / alerts

/// Alarm Activated — history-log event (typeId 5).
public struct AlarmActivatedHistoryLog: HistoryLogEvent {
    public static let typeId = 5
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var alarmId: Int = 0
    public private(set) var faultLocatorData: Int = 0
    public private(set) var param1: Int = 0
    public private(set) var param2: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        alarmId = Int(Bytes.readUint32(raw, 10))
        faultLocatorData = Int(Bytes.readUint32(raw, 14))
        param1 = Int(Bytes.readUint32(raw, 18))
        param2 = Bytes.readFloat(raw, 22)
    }
}

/// Alert Activated — history-log event (typeId 4).
public struct AlertActivatedHistoryLog: HistoryLogEvent {
    public static let typeId = 4
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var alertId: Int = 0
    public private(set) var faultLocatorData: Int = 0
    public private(set) var param1: Int = 0
    public private(set) var param2: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        alertId = Int(Bytes.readUint32(raw, 10))
        faultLocatorData = Int(Bytes.readUint32(raw, 14))
        param1 = Int(Bytes.readUint32(raw, 18))
        param2 = Bytes.readFloat(raw, 22)
    }
}

/// Alarm Cleared — history-log event (typeId 28).
public struct AlarmClearedHistoryLog: HistoryLogEvent {
    public static let typeId = 28
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var alarmId: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        alarmId = Int(Bytes.readUint32(raw, 10))
    }
}

// MARK: - Pumping / cartridge / cannula

/// Pumping Resumed — history-log event (typeId 12).
public struct PumpingResumedHistoryLog: HistoryLogEvent {
    public static let typeId = 12
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var insulinAmount: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        insulinAmount = Bytes.readShort(raw, 14)
    }
}

/// Pumping Suspended — history-log event (typeId 11).
public struct PumpingSuspendedHistoryLog: HistoryLogEvent {
    public static let typeId = 11
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var insulinAmount: Int = 0
    public private(set) var reasonId: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        insulinAmount = Bytes.readShort(raw, 14)
        reasonId = Int(raw[16])
    }
}

/// Cartridge Filled — history-log event (typeId 33).
public struct CartridgeFilledHistoryLog: HistoryLogEvent {
    public static let typeId = 33
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var insulinDisplay: Int = 0
    public private(set) var insulinActual: Float = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        insulinDisplay = Int(Bytes.readUint32(raw, 10))
        insulinActual = Bytes.readFloat(raw, 14)
    }
}

/// Cannula Filled — history-log event (typeId 61).
public struct CannulaFilledHistoryLog: HistoryLogEvent {
    public static let typeId = 61
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var primeSize: Float = 0
    public private(set) var completionStatus: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        primeSize = Bytes.readFloat(raw, 10)
        completionStatus = Int(Bytes.readUint32(raw, 14))
    }
}

/// Tubing Filled — history-log event (typeId 63).
public struct TubingFilledHistoryLog: HistoryLogEvent {
    public static let typeId = 63
    public var cargo: [UInt8]
    public private(set) var pumpTimeSec: UInt32 = 0
    public private(set) var sequenceNum: UInt32 = 0
    public private(set) var primeSize: Float = 0
    public private(set) var completionStatus: Int = 0
    public private(set) var position: Int = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 26 else { return }
        pumpTimeSec = Bytes.readUint32(raw, 2)
        sequenceNum = Bytes.readUint32(raw, 6)
        primeSize = Bytes.readFloat(raw, 10)
        completionStatus = Int(Bytes.readUint32(raw, 14))
        position = Int(Bytes.readUint32(raw, 18))
    }
}
