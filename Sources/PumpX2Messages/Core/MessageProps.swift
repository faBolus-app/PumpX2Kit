import Foundation

/// Per-message metadata. In upstream this is the `@MessageProps` annotation read via
/// reflection; in Swift each message type supplies it as a static value.
///
/// `responseOpCode` / `requestOpCode` wire a request↔response pair together. They're
/// optional here and get populated as the message catalog is ported (the opcode registry
/// is built incrementally, unlike upstream's single `Messages` enum).
public struct MessageProps: Sendable {
    public let opCode: UInt8
    public let size: Int
    public let variableSize: Bool
    public let stream: Bool
    public let signed: Bool
    public let type: MessageType
    public let characteristic: Characteristic
    public let modifiesInsulinDelivery: Bool
    public let responseOpCode: UInt8?
    public let requestOpCode: UInt8?

    public init(
        opCode: UInt8,
        size: Int = 0,
        variableSize: Bool = false,
        stream: Bool = false,
        signed: Bool = false,
        type: MessageType,
        characteristic: Characteristic = .currentStatus,
        modifiesInsulinDelivery: Bool = false,
        responseOpCode: UInt8? = nil,
        requestOpCode: UInt8? = nil
    ) {
        self.opCode = opCode
        self.size = size
        self.variableSize = variableSize
        self.stream = stream
        self.signed = signed
        self.type = type
        self.characteristic = characteristic
        self.modifiesInsulinDelivery = modifiesInsulinDelivery
        self.responseOpCode = responseOpCode
        self.requestOpCode = requestOpCode
    }
}
