import Foundation

/// Base protocol for all pump messages (requests and responses).
/// Port of the `com.jwoglom.pumpx2.pump.messages.Message` abstract class.
///
/// `cargo` is the message payload (without the opcode/txId/length framing or CRC — those
/// are added by `Packetize`). `props` is the static per-type metadata.
public protocol Message: Sendable {
    static var props: MessageProps { get }

    var cargo: [UInt8] { get set }

    /// Constructs an instance with empty cargo.
    init()

    /// Parses raw wire bytes into cargo/fields.
    mutating func parse(_ raw: [UInt8])
}

public extension Message {
    /// Empty cargo constant, mirroring upstream `Message.EMPTY`.
    static var empty: [UInt8] { [] }

    var props: MessageProps { Self.props }
    var opCode: UInt8 { Self.props.opCode }
    var signed: Bool { Self.props.signed }
    var stream: Bool { Self.props.stream }
    var type: MessageType { Self.props.type }
    var characteristic: Characteristic { Self.props.characteristic }
    /// Operation-risk class for authorization (audit P-01).
    var operationRisk: OperationRisk { Self.props.operationRisk }

    mutating func fillWithEmptyCargo() { cargo = [] }

    /// Strips the trailing 24-byte HMAC block from a signed request's raw bytes, if present.
    /// Mirrors `removeSignedRequestHmacBytes`.
    func removeSignedRequestHmacBytes(_ raw: [UInt8]) -> [UInt8] {
        if signed && raw.count == Self.props.size + 24 {
            return Bytes.dropLast(raw, 24)
        }
        return raw
    }
}
