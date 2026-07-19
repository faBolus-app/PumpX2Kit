import Foundation

/// Pump notifications (alerts / alarms / CGM alerts) and the signed request to dismiss one.
/// Ports of `response/currentStatus/AlertStatusResponse` (69), `AlarmStatusResponse` (71),
/// `CGMAlertStatusResponse` (75), and `request/control/DismissNotificationRequest` (184, signed).
///
/// Each status response is an 8-byte little-endian uint64 bitmap: bit N set = the notification
/// with id N is active. Dismissing uses that same id N with the matching notification kind.

/// Notification category. Raw value is the `notificationTypeId` in DismissNotificationRequest.
public enum NotificationKind: Int, Sendable {
    case reminder = 0, alert = 1, alarm = 2, cgmAlert = 3
}

/// A single active pump notification.
public struct PumpNotification: Sendable, Equatable, Identifiable {
    public let id: Int            // bit index in the status bitmap == dismiss notificationId
    public let kind: NotificationKind
    public let title: String
    public let detail: String?
    public init(id: Int, kind: NotificationKind, title: String, detail: String?) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
    }
}

/// Decodes the active bits of a bitmap into `PumpNotification`s using a name table.
enum NotificationBitmap {
    static func decode(_ bitmap: UInt64, kind: NotificationKind, names: [Int: (String, String?)]) -> [PumpNotification] {
        var out: [PumpNotification] = []
        for bit in 0..<64 where (bitmap >> UInt64(bit)) & 1 == 1 {
            let info = names[bit]
            let label = kind == .alarm ? "Alarm" : (kind == .cgmAlert ? "CGM alert" : "Alert")
            out.append(PumpNotification(id: bit, kind: kind,
                                        title: info?.0 ?? "\(label) \(bit)", detail: info?.1))
        }
        return out
    }
}

/// Active pump alerts (opcode 69).
public struct AlertStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 69, size: 8, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var bitmap: UInt64 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; bitmap = Bytes.readUint64(raw, 0) }
    public mutating func parse(_ raw: [UInt8]) { self = AlertStatusResponse(cargo: raw) }
    public var notifications: [PumpNotification] {
        NotificationBitmap.decode(bitmap, kind: .alert, names: Self.names)
    }
    // Named alerts (bit → title, detail). Unnamed bits render as "Alert N".
    static let names: [Int: (String, String?)] = [
        0: ("Low insulin", "Low amount of insulin remaining in the cartridge."),
        1: ("USB connection", "Pump is not charging over USB."),
        2: ("Low power", "Power level is low and the pump needs to be charged."),
        3: ("Low power", "Power level is low and the pump needs to be charged."),
        5: ("Auto-off", "The pump is about to turn off due to the configured auto-off interval."),
        6: ("Max basal rate", "The pump is delivering at the maximum allowed basal rate."),
        7: ("Power source", "The power source provided is not able to charge the pump."),
        8: ("Min basal rate", "The pump is delivering at the minimum allowed basal rate."),
        11: ("Incomplete bolus", "The bolus window was opened but a bolus was not started."),
        12: ("Incomplete temp rate", "The temp rate window was opened but the temp rate was not started."),
        13: ("Incomplete cartridge change", "The cartridge change was started but not completed."),
        14: ("Incomplete fill tubing", "Fill tubing was started but not completed."),
        15: ("Incomplete fill cannula", "Fill cannula was started but not completed."),
        17: ("Low insulin", "Low amount of insulin remaining in the cartridge."),
        18: ("Max basal", "The maximum basal was reached."),
        19: ("Low transmitter", "The CGM transmitter battery is low."),
        20: ("Transmitter alert", "There is an alert from the CGM transmitter."),
        22: ("Sensor expiring", "The CGM sensor is expiring soon."),
        23: ("Pump rebooting", "The pump is rebooting."),
        26: ("Min basal", "The pump is delivering at the minimum allowed basal rate."),
        27: ("Incomplete calibration", "The CGM calibration was incomplete."),
        28: ("Calibration timeout", "The timeout was reached for CGM calibration."),
        29: ("Invalid transmitter ID", "The Dexcom G6 or G7 transmitter ID is invalid."),
        33: ("Button alert", "The pump button was held down too long and is temporarily disabled."),
        34: ("Quick bolus", "Quick bolus mode was entered but no bolus was started."),
        35: ("Basal-IQ", "Basal-IQ has reduced basal insulin to avoid a low."),
        39: ("Transmitter end of life", "The CGM transmitter is reaching its end of life."),
        40: ("CGM error", "CGM error reported."),
        44: ("Transmitter expiring", "The CGM transmitter is expiring soon."),
        48: ("CGM unavailable", "The CGM is unavailable due to a problem with the sensor."),
        51: ("Control-IQ low", "Control-IQ has reduced basal insulin due to a low or predicted low."),
    ]
}

/// Active pump alarms (opcode 71) — more serious than alerts.
public struct AlarmStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 71, size: 8, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var bitmap: UInt64 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; bitmap = Bytes.readUint64(raw, 0) }
    public mutating func parse(_ raw: [UInt8]) { self = AlarmStatusResponse(cargo: raw) }
    public var notifications: [PumpNotification] {
        NotificationBitmap.decode(bitmap, kind: .alarm, names: Self.names)
    }
    static let names: [Int: (String, String?)] = [
        0: ("Cartridge", "Cartridge alarm."),
        1: ("Cartridge", "Cartridge alarm."),
        2: ("Occlusion", "A blockage was detected; insulin delivery has stopped."),
        3: ("Pump reset", "The pump reset."),
        7: ("Auto-off", "The pump turned off due to the auto-off interval."),
        8: ("Empty cartridge", "The cartridge is empty."),
        10: ("Temperature", "The pump temperature is out of range."),
        12: ("Battery shutdown", "The pump shut down due to a depleted battery."),
        14: ("Invalid date", "The pump date/time is invalid."),
        18: ("Resume pump", "Insulin delivery is stopped — resume the pump."),
        21: ("Altitude", "The altitude is out of the supported range."),
        22: ("Stuck button", "A pump button appears stuck."),
        24: ("Pressure out of range", "Atmospheric pressure is out of range."),
        25: ("Cartridge removed", "The cartridge was removed."),
        26: ("Occlusion", "A blockage was detected; insulin delivery has stopped."),
    ]
}

/// Active CGM alerts (opcode 75).
public struct CGMAlertStatusResponse: ResponseMessage {
    public static let props = MessageProps(opCode: 75, size: 8, type: .response, characteristic: .currentStatus)
    public var cargo: [UInt8]
    public private(set) var bitmap: UInt64 = 0
    public init() { cargo = [] }
    public init(cargo raw: [UInt8]) { cargo = raw; bitmap = Bytes.readUint64(raw, 0) }
    public mutating func parse(_ raw: [UInt8]) { self = CGMAlertStatusResponse(cargo: raw) }
    public var notifications: [PumpNotification] {
        NotificationBitmap.decode(bitmap, kind: .cgmAlert, names: Self.names)
    }
    static let names: [Int: (String, String?)] = [
        0: ("Low glucose", "Glucose is below the low alert threshold."),
        1: ("High glucose", "Glucose is above the high alert threshold."),
        2: ("Urgent low", "Glucose is urgently low."),
        3: ("Urgent low predicted", "An urgent low is predicted soon."),
        4: ("Falling fast", "Glucose is falling rapidly."),
        5: ("Rising fast", "Glucose is rising rapidly."),
        6: ("Out of range", "The CGM is out of range."),
        7: ("Signal loss", "The CGM signal was lost."),
    ]
}

/// CGM alert status request (opcode 74) — empty-cargo read paired with CGMAlertStatusResponse.
public struct CGMAlertStatusRequest: EmptyCurrentStatusRequest {
    public static let props = MessageProps(opCode: 74, size: 0, type: .request,
                                           characteristic: .currentStatus, responseOpCode: 75)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}

/// Dismisses one notification (opcode 184, **signed** CONTROL). Cargo: notificationId (uint32) +
/// notificationTypeId (byte) + executeExtraAction (byte). The id/kind come from the matching
/// status response. Signed like a bolus, but it does not modify insulin delivery.
public struct DismissNotificationRequest: Message {
    public static let props = MessageProps(opCode: 184, size: 6, signed: true, type: .request,
                                           characteristic: .control, responseOpCode: 185)
    public var cargo: [UInt8]
    public private(set) var notificationId: Int = 0
    public private(set) var kind: NotificationKind = .alert
    public init() { cargo = [] }
    public init(kind: NotificationKind, notificationId: Int, executeExtraAction: Bool = false) {
        self.kind = kind
        self.notificationId = notificationId
        self.cargo = Bytes.combine(Bytes.toUint32(UInt32(truncatingIfNeeded: notificationId)),
                                   [UInt8(kind.rawValue & 0xFF)],
                                   [executeExtraAction ? 1 : 0])
    }
    public mutating func parse(_ raw: [UInt8]) {
        let body = removeSignedRequestHmacBytes(raw)
        let c = body.count == Self.props.size ? body : Bytes.dropFirst(body, 3)
        cargo = c
        notificationId = Int(Bytes.readUint32(c, 0))
        kind = NotificationKind(rawValue: Int(c[4])) ?? .alert
    }
}
