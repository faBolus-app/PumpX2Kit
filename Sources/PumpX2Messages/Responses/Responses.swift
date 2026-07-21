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

/// Ack for play-sound / find-my-pump (signed CONTROL). `PlaySoundResponse` (op 0xF5, 1B).
public struct PlaySoundResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xF5, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = PlaySoundResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for set-pump-sounds (signed CONTROL). `SetPumpSoundsResponse` (op 0xE5, 1B).
public struct SetPumpSoundsResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xE5, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = SetPumpSoundsResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for change-time-date (signed CONTROL). `ChangeTimeDateResponse` (op 0xD7, 1B).
public struct ChangeTimeDateResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xD7, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = ChangeTimeDateResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for a remote carb entry (signed CONTROL). `RemoteCarbEntryResponse` (op 0xF3, 1B).
public struct RemoteCarbEntryResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xF3, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = RemoteCarbEntryResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for a remote BG entry (signed CONTROL). `RemoteBgEntryResponse` (op 0xB7, 1B).
public struct RemoteBgEntryResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xB7, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = RemoteBgEntryResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for start-G6-sensor-session (signed CONTROL). `StartDexcomG6SensorSessionResponse` (op 0xB3, 1B).
public struct StartDexcomG6SensorSessionResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xB3, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = StartDexcomG6SensorSessionResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for stop-CGM-sensor-session (signed CONTROL). `StopDexcomCGMSensorSessionResponse` (op 0xB5, 1B).
public struct StopDexcomCGMSensorSessionResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xB5, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = StopDexcomCGMSensorSessionResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for set-sensor-type (signed CONTROL). `SetSensorTypeResponse` (op 0xC1, 2B).
/// status@0, statusAcknowledgement@1.
public struct SetSensorTypeResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xC1, size: 2, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public private(set) var statusAcknowledgement = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if !raw.isEmpty { status = Int(raw[0]) }
        if raw.count >= 2 { statusAcknowledgement = Int(raw[1]) }
    }
    public mutating func parse(_ raw: [UInt8]) { self = SetSensorTypeResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for set-G7-pairing-code (signed CONTROL). `SetDexcomG7PairingCodeResponse` (op 0xFD, 2B).
public struct SetDexcomG7PairingCodeResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xFD, size: 2, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = SetDexcomG7PairingCodeResponse(cargo: raw) }
    public var accepted: Bool { status == 0 }
}

/// Ack for a cancel-bolus command (a.k.a. BolusTermination) — signed.
/// `response/control/CancelBolusResponse` (op 0xA1, 5B). statusId@0, bolusId short@1, reasonId@3.
public struct CancelBolusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xA1, size: 5, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var statusId = 0
    public private(set) var bolusId = 0
    public private(set) var reasonId = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if !raw.isEmpty { statusId = Int(raw[0]) }
        if raw.count >= 3 { bolusId = Bytes.readShort(raw, 1) }
        if raw.count >= 4 { reasonId = Int(raw[3]) }
    }
    public mutating func parse(_ raw: [UInt8]) { self = CancelBolusResponse(cargo: raw) }
    /// statusId 0 = SUCCESS, reasonId 0 = NO_ERROR (2 = invalid/already delivered).
    public var wasCancelled: Bool { statusId == 0 && reasonId == 0 }
}

/// Ack for releasing a pending bolus permission (signed). Closes out the potential bolus in the
/// history logs. `response/control/BolusPermissionReleaseResponse` (op 0xF1, 1B). status@0.
public struct BolusPermissionReleaseResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0xF1, size: 1, signed: true, type: .response, characteristic: .control)
    public var cargo: [UInt8]
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; if !raw.isEmpty { status = Int(raw[0]) } }
    public mutating func parse(_ raw: [UInt8]) { self = BolusPermissionReleaseResponse(cargo: raw) }
    /// status 0 = SUCCESS.
    public var released: Bool { status == 0 }
}

/// Pump-wide settings: low-insulin threshold, cannula prime size, auto-shutdown, feature lock,
/// OLED timeout. `response/currentStatus/PumpSettingsResponse` (op 83, 9B).
/// lowInsulinThreshold@0, cannulaPrimeSize@1, autoShutdownEnabled@2, autoShutdownDuration short@3,
/// featureLock@5, oledTimeout@6, status short@7.
public struct PumpSettingsResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 83, size: 9, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var lowInsulinThreshold = 0
    public private(set) var cannulaPrimeSize = 0
    public private(set) var autoShutdownEnabled = 0
    public private(set) var autoShutdownDuration = 0
    public private(set) var featureLock = 0
    public private(set) var oledTimeout = 0
    public private(set) var status = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 9 else { return }
        lowInsulinThreshold = Int(raw[0])
        cannulaPrimeSize = Int(raw[1])
        autoShutdownEnabled = Int(raw[2])
        autoShutdownDuration = Bytes.readShort(raw, 3)
        featureLock = Int(raw[5])
        oledTimeout = Int(raw[6])
        status = Bytes.readShort(raw, 7)
    }
    public mutating func parse(_ raw: [UInt8]) { self = PumpSettingsResponse(cargo: raw) }
}

/// Global pump settings: quick-bolus config + per-category annunciation (audio/vibrate) modes.
/// `response/currentStatus/PumpGlobalsResponse` (op 87, 14B). quickBolusEnabled@0,
/// quickBolusIncrementUnits short@1, quickBolusIncrementCarbs short@3, quickBolusEntryType@5,
/// quickBolusStatus@6, then buttonAnnun@7…fillTubingAnnun@13.
public struct PumpGlobalsResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 87, size: 14, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var quickBolusEnabledRaw = 0
    public private(set) var quickBolusIncrementUnits = 0
    public private(set) var quickBolusIncrementCarbs = 0
    public private(set) var quickBolusEntryType = 0
    public private(set) var quickBolusStatus = 0
    public private(set) var buttonAnnun = 0
    public private(set) var quickBolusAnnun = 0
    public private(set) var bolusAnnun = 0
    public private(set) var reminderAnnun = 0
    public private(set) var alertAnnun = 0
    public private(set) var alarmAnnun = 0
    public private(set) var fillTubingAnnun = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 14 else { return }
        quickBolusEnabledRaw = Int(raw[0])
        quickBolusIncrementUnits = Bytes.readShort(raw, 1)
        quickBolusIncrementCarbs = Bytes.readShort(raw, 3)
        quickBolusEntryType = Int(raw[5])
        quickBolusStatus = Int(raw[6])
        buttonAnnun = Int(raw[7])
        quickBolusAnnun = Int(raw[8])
        bolusAnnun = Int(raw[9])
        reminderAnnun = Int(raw[10])
        alertAnnun = Int(raw[11])
        alarmAnnun = Int(raw[12])
        fillTubingAnnun = Int(raw[13])
    }
    public mutating func parse(_ raw: [UInt8]) { self = PumpGlobalsResponse(cargo: raw) }
    public var quickBolusEnabled: Bool { quickBolusEnabledRaw == 1 }
}

/// Extended (dual/square-wave) bolus status. `response/currentStatus/ExtendedBolusStatusV2Response`
/// (op 183, 22B). bolusStatus@0, bolusId short@1, timestamp uint32@5, requestedVolume uint32@9
/// (mU), duration uint32@13, bolusSource@17, secondsSincePumpReset uint32@18.
public struct ExtendedBolusStatusV2Response: ResponseMessage {
    public static let props = MessageProps(opCode: 183, size: 22, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var bolusStatus = 0
    public private(set) var bolusId = 0
    public private(set) var timestamp = 0
    public private(set) var requestedVolume = 0
    public private(set) var duration = 0
    public private(set) var bolusSource = 0
    public private(set) var secondsSincePumpReset = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 22 else { return }
        bolusStatus = Int(raw[0])
        bolusId = Bytes.readShort(raw, 1)
        timestamp = Int(Bytes.readUint32(raw, 5))
        requestedVolume = Int(Bytes.readUint32(raw, 9))
        duration = Int(Bytes.readUint32(raw, 13))
        bolusSource = Int(raw[17])
        secondsSincePumpReset = Int(Bytes.readUint32(raw, 18))
    }
    public mutating func parse(_ raw: [UInt8]) { self = ExtendedBolusStatusV2Response(cargo: raw) }
    public var requestedUnits: Double { Double(requestedVolume) / 1000.0 }
}

/// CGM session status. `response/currentStatus/CGMStatusResponse` (op 81, 10B). sessionStateId@0,
/// lastCalibrationTimestamp uint32@1, sensorStartedTimestamp uint32@5, transmitterBatteryStatusId@9.
public struct CGMStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 81, size: 10, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var sessionStateId = 0
    public private(set) var lastCalibrationTimestamp = 0
    public private(set) var sensorStartedTimestamp = 0
    public private(set) var transmitterBatteryStatusId = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 10 else { return }
        sessionStateId = Int(raw[0])
        lastCalibrationTimestamp = Int(Bytes.readUint32(raw, 1))
        sensorStartedTimestamp = Int(Bytes.readUint32(raw, 5))
        transmitterBatteryStatusId = Int(raw[9])
    }
    public mutating func parse(_ raw: [UInt8]) { self = CGMStatusResponse(cargo: raw) }
    /// sessionStateId 1 = active (per upstream SessionState).
    public var sessionActive: Bool { sessionStateId == 1 }
}

/// CGM session status, v2 (adds session duration/remaining, sensor type, grace period).
/// `response/currentStatus/CgmStatusV2Response` (op 191, 20B). sessionStateId@0,
/// lastCalibrationTimestamp uint32@1, sensorStartedTimestamp uint32@5, transmitterBatteryStatusId@9,
/// sessionDurationSeconds uint32@10, sessionTimeRemainingSeconds uint32@14, cgmSensorTypeId@18,
/// gracePeriod@19.
public struct CgmStatusV2Response: ResponseMessage {
    public static let props = MessageProps(opCode: 191, size: 20, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var sessionStateId = 0
    public private(set) var lastCalibrationTimestamp = 0
    public private(set) var sensorStartedTimestamp = 0
    public private(set) var transmitterBatteryStatusId = 0
    public private(set) var sessionDurationSeconds = 0
    public private(set) var sessionTimeRemainingSeconds = 0
    public private(set) var cgmSensorTypeId = 0
    public private(set) var gracePeriod = false
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 20 else { return }
        sessionStateId = Int(raw[0])
        lastCalibrationTimestamp = Int(Bytes.readUint32(raw, 1))
        sensorStartedTimestamp = Int(Bytes.readUint32(raw, 5))
        transmitterBatteryStatusId = Int(raw[9])
        sessionDurationSeconds = Int(Bytes.readUint32(raw, 10))
        sessionTimeRemainingSeconds = Int(Bytes.readUint32(raw, 14))
        cgmSensorTypeId = Int(raw[18])
        gracePeriod = (raw[19] & 0xFF) != 0
    }
    public mutating func parse(_ raw: [UInt8]) { self = CgmStatusV2Response(cargo: raw) }
    public var sessionActive: Bool { sessionStateId == 1 }
}

/// CGM transmitter/sensor hardware identifier string. `response/currentStatus/CGMHardwareInfoResponse`
/// (op 97, 17B). hardwareInfoString = 16-byte string@0, lastByte@16.
public struct CGMHardwareInfoResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 97, size: 17, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var hardwareInfoString = ""
    public private(set) var lastByte = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 17 else { return }
        hardwareInfoString = Bytes.readString(raw, 0, 16)
        lastByte = Int(raw[16])
    }
    public mutating func parse(_ raw: [UInt8]) { self = CGMHardwareInfoResponse(cargo: raw) }
}

/// Settings for one insulin-delivery profile. `response/currentStatus/IDPSettingsResponse`
/// (op 65, 23B). idpId@0, name=16-byte string@1, numberOfProfileSegments@17,
/// insulinDuration short@18 (min), maxBolus short@20 (mU), carbEntry@22.
public struct IDPSettingsResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 65, size: 23, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var idpId = 0
    public private(set) var name = ""
    public private(set) var numberOfProfileSegments = 0
    public private(set) var insulinDuration = 0             // minutes
    public private(set) var maxBolus = 0                    // milliunits
    public private(set) var carbEntry = false
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 23 else { return }
        idpId = Int(raw[0])
        name = Bytes.readString(raw, 1, 16)
        numberOfProfileSegments = Int(raw[17])
        insulinDuration = Bytes.readShort(raw, 18)
        maxBolus = Bytes.readShort(raw, 20)
        carbEntry = raw[22] != 0
    }
    public mutating func parse(_ raw: [UInt8]) { self = IDPSettingsResponse(cargo: raw) }
    public var maxBolusUnits: Double { Double(maxBolus) / 1000.0 }
}

/// One time-segment of an insulin-delivery profile. `response/currentStatus/IDPSegmentResponse`
/// (op 67, 15B). idpId@0, segmentIndex@1, profileStartTime short@2 (min-of-day),
/// profileBasalRate short@4 (mU/hr), profileCarbRatio uint32@6 (1000-inc), profileTargetBG
/// short@10 (mg/dL), profileISF short@12 (mg/dL/U), idpStatusId@14.
public struct IDPSegmentResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 67, size: 15, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var idpId = 0
    public private(set) var segmentIndex = 0
    public private(set) var profileStartTime = 0            // minutes past midnight
    public private(set) var profileBasalRate = 0            // milliunits/hr
    public private(set) var profileCarbRatio = 0            // 1000-increments
    public private(set) var profileTargetBG = 0             // mg/dL
    public private(set) var profileISF = 0                  // mg/dL per unit
    public private(set) var idpStatusId = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 15 else { return }
        idpId = Int(raw[0])
        segmentIndex = Int(raw[1])
        profileStartTime = Bytes.readShort(raw, 2)
        profileBasalRate = Bytes.readShort(raw, 4)
        profileCarbRatio = Int(Bytes.readUint32(raw, 6))
        profileTargetBG = Bytes.readShort(raw, 10)
        profileISF = Bytes.readShort(raw, 12)
        idpStatusId = Int(raw[14])
    }
    public mutating func parse(_ raw: [UInt8]) { self = IDPSegmentResponse(cargo: raw) }
    public var basalRateUnitsPerHour: Double { Double(profileBasalRate) / 1000.0 }
    public var carbRatioGramsPerUnit: Double { Double(profileCarbRatio) / 1000.0 }
}

/// Control-IQ info, v1 firmware. `response/currentStatus/ControlIQInfoV1Response` (op 105, 10B).
/// closedLoop@0, weight short@1, weightUnit@3, totalDailyInsulin@4, currentUserModeType@5,
/// controlStateType@9. (V2 at op 179 carries exercise fields; this is the older layout.)
public struct ControlIQInfoV1Response: ResponseMessage {
    public static let props = MessageProps(opCode: 105, size: 10, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var closedLoopEnabled = false
    public private(set) var weight = 0
    public private(set) var weightUnit = 0
    public private(set) var totalDailyInsulin = 0
    public private(set) var currentUserModeType = 0
    public private(set) var controlStateType = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 10 else { return }
        closedLoopEnabled = raw[0] != 0
        weight = Bytes.readShort(raw, 1)
        weightUnit = Int(raw[3])
        totalDailyInsulin = Int(raw[4])
        currentUserModeType = Int(raw[5])
        controlStateType = Int(raw[9])
    }
    public mutating func parse(_ raw: [UInt8]) { self = ControlIQInfoV1Response(cargo: raw) }
}

/// Pump feature bitmask (which capabilities the pump firmware supports).
/// `response/currentStatus/PumpFeaturesV1Response` (op 79, 8B). uint64 bitmask@0.
public struct PumpFeaturesV1Response: ResponseMessage {
    public static let props = MessageProps(opCode: 79, size: 8, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var featureBitmask: UInt64 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        if raw.count >= 8 { featureBitmask = Bytes.readUint64(raw, 0) }
    }
    public mutating func parse(_ raw: [UInt8]) { self = PumpFeaturesV1Response(cargo: raw) }
    private func has(_ bit: UInt64) -> Bool { featureBitmask & bit != 0 }
    public var dexcomG5Supported: Bool { has(1) }
    public var dexcomG6Supported: Bool { has(2) }
    public var basalIQSupported: Bool { has(4) }
    public var controlIQSupported: Bool { has(1024) }
    public var basalLimitSupported: Bool { has(262144) }
    public var controlIQProSupported: Bool { has(8388608) }
    public var blePumpControlSupported: Bool { has(268435456) }
    public var pumpSettingsInIdpGuiSupported: Bool { has(536870912) }
}

/// Cartridge-load / prime-tubing status. `response/currentStatus/LoadStatusResponse` (op 21, 3B).
/// isLoadingActive@0, loadStateId@1, primeStatusId@2.
public struct LoadStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 21, size: 3, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var isLoadingActiveId = 0
    public private(set) var loadStateId = 0
    public private(set) var primeStatusId = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 3 else { return }
        isLoadingActiveId = Int(raw[0])
        loadStateId = Int(raw[1])
        primeStatusId = Int(raw[2])
    }
    public mutating func parse(_ raw: [UInt8]) { self = LoadStatusResponse(cargo: raw) }
    public var isLoadingActive: Bool { isLoadingActiveId != 0 }
}

/// Insulin-delivery-profile (IDP) slot overview. `response/currentStatus/ProfileStatusResponse`
/// (op 63, 8B). Slot 0 is always the active profile; a slot value of -1 (0xFF) means empty.
/// numberOfProfiles@0, then slot0..slot5 @1..6, activeSegmentIndex@7. Query slot details with
/// an IDPSettingsRequest for that id.
public struct ProfileStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 63, size: 8, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var numberOfProfiles = 0
    public private(set) var idpSlotIds: [Int] = []        // all six raw slot ids (may be -1)
    public private(set) var activeSegmentIndex = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 8 else { return }
        numberOfProfiles = Int(Int8(bitPattern: raw[0]))
        idpSlotIds = (1...6).map { Int(Int8(bitPattern: raw[$0])) }   // -1 sentinel for empty slots
        activeSegmentIndex = Int(Int8(bitPattern: raw[7]))
    }
    public mutating func parse(_ raw: [UInt8]) { self = ProfileStatusResponse(cargo: raw) }
    /// The active profile id (always slot 0), or -1 if no profiles exist.
    public var activeIdpId: Int { idpSlotIds.first ?? -1 }
    /// Present slot ids restricted to numberOfProfiles.
    public var presentIdpIds: [Int] { Array(idpSlotIds.prefix(max(0, numberOfProfiles))) }
}

/// Currently-active IDP parameter values for the active time segment.
/// `response/currentStatus/CurrentActiveIdpValuesResponse` (op 0x97, 10B). carbRatio uint32@0
/// (1000-increments), targetBg byte@5, insulinDuration uint16@6 (min), ISF uint16@8.
///
/// Byte 6 is shared: upstream reads targetBg as `readShort(raw,5)` and insulinDuration as
/// `readShort(raw,6)`, which overlap and corrupt targetBg once insulinDuration ≥ 256. targetBg is
/// always < 256, so we read only its low byte (raw[5]); that keeps both fields correct regardless
/// of duration (upstream's overlapping short read is effectively a bug for durations ≥ 256 min).
public struct CurrentActiveIdpValuesResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0x97, size: 10, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var currentCarbRatio = 0            // 1000-increments (10000 = 10 g/U)
    public private(set) var currentTargetBg = 0             // mg/dL (< 256)
    public private(set) var currentInsulinDuration = 0      // minutes
    public private(set) var currentIsf = 0                  // mg/dL per unit
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 10 else { return }
        currentCarbRatio = Int(Bytes.readUint32(raw, 0))
        currentTargetBg = Int(raw[5])
        currentInsulinDuration = Bytes.readShort(raw, 6)
        currentIsf = Bytes.readShort(raw, 8)
    }
    public mutating func parse(_ raw: [UInt8]) { self = CurrentActiveIdpValuesResponse(cargo: raw) }
    /// Carb ratio in grams per unit.
    public var carbRatioGramsPerUnit: Double { Double(currentCarbRatio) / 1000.0 }
}

/// Global max-bolus limit + factory default (milliunits). `GlobalMaxBolusSettingsResponse`
/// (op 0x8D, 4B). maxBolus short@0, maxBolusDefault short@2.
public struct GlobalMaxBolusSettingsResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0x8D, size: 4, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var maxBolus = 0                    // milliunits
    public private(set) var maxBolusDefault = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 4 else { return }
        maxBolus = Bytes.readShort(raw, 0)
        maxBolusDefault = Bytes.readShort(raw, 2)
    }
    public mutating func parse(_ raw: [UInt8]) { self = GlobalMaxBolusSettingsResponse(cargo: raw) }
    public var maxBolusUnits: Double { Double(maxBolus) / 1000.0 }
}

/// Max basal-rate limit + factory default (milliunits/hr). `BasalLimitSettingsResponse`
/// (op 0x8B, 8B). basalLimit uint32@0, basalLimitDefault uint32@4.
public struct BasalLimitSettingsResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 0x8B, size: 8, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var basalLimit = 0                  // milliunits/hr
    public private(set) var basalLimitDefault = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) {
        cargo = raw
        guard raw.count >= 8 else { return }
        basalLimit = Int(Bytes.readUint32(raw, 0))
        basalLimitDefault = Int(Bytes.readUint32(raw, 4))
    }
    public mutating func parse(_ raw: [UInt8]) { self = BasalLimitSettingsResponse(cargo: raw) }
    public var basalLimitUnitsPerHour: Double { Double(basalLimit) / 1000.0 }
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
