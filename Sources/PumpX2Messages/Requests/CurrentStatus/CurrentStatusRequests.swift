import Foundation

/// Empty-cargo status-read requests on the CURRENT_STATUS characteristic. These are the
/// read-only messages the host/harness sends to poll pump state; each has no parameters and
/// a paired response at `opCode + 1`. Ports of the corresponding
/// `request/currentStatus/*Request` classes.
///
/// Byte-parity with the oracle is covered in OracleParityTests.
public protocol EmptyCurrentStatusRequest: Message {
    init(emptyCargo: Void)
}

public extension EmptyCurrentStatusRequest {
    init() { self.init(emptyCargo: ()) }
    mutating func parse(_ raw: [UInt8]) {
        // Request messages are only serialized; empty cargo is expected.
        if raw.isEmpty { return }
        precondition(raw.count == Self.props.size)
        cargo = Bytes.dropFirst(raw, 3)
    }
}

/// Generates an empty-cargo CURRENT_STATUS request type. `op` is the request opcode; the
/// response opcode is `op &+ 1` by the even/odd convention.
private func statusProps(_ op: UInt8) -> MessageProps {
    MessageProps(opCode: op, size: 0, type: .request,
                 characteristic: .currentStatus, responseOpCode: op &+ 1)
}

// Each type is a thin struct: opcode + empty cargo. `init(emptyCargo:)` satisfies the
// protocol extension's `init()`.
public struct ControlIQIOBRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(108)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct NonControlIQIOBRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(38)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct InsulinStatusRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(36)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct CurrentBatteryV2Request: EmptyCurrentStatusRequest {
    public static let props = statusProps(0x90) // -112
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct CurrentBasalStatusRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(40)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct HomeScreenMirrorRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(56)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct PumpVersionRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(84)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct TimeSinceResetRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(54)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct CurrentBolusStatusRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(44)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct LastBolusStatusV2Request: EmptyCurrentStatusRequest {
    public static let props = statusProps(0xA4) // -92
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct ControlIQInfoV2Request: EmptyCurrentStatusRequest {
    public static let props = statusProps(0xB2) // -78
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct LastBGRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(50)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct PumpGlobalsRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(86)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct PumpSettingsRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(82)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct BolusCalcDataSnapshotRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(114)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct AlertStatusRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(68)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct AlarmStatusRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(70)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
public struct MalfunctionStatusRequest: EmptyCurrentStatusRequest {
    public static let props = statusProps(118)
    public var cargo: [UInt8] = []
    public init(emptyCargo: Void = ()) { self.cargo = [] }
}
