import Foundation

/// Parses a reassembled inbound frame into a typed `ResponseMessage`.
///
/// Frame layout (produced by `Packetize`, reassembled by `PumpX2BLE.PacketReassembler`):
/// `[opcode, txId, length, cargo(length bytes), crc0, crc1]`. Validates the CRC-16 and cargo
/// length before dispatching by opcode.
public enum ResponseParser {
    public enum ParseError: Error, Equatable {
        case frameTooShort
        case crcMismatch(expected: [UInt8], actual: [UInt8])
        case unknownOpcode(UInt8)
        case cargoLengthMismatch(opcode: UInt8, expected: Int, got: Int)
    }

    public struct Parsed {
        public let opCode: UInt8
        public let txId: UInt8
        public let message: any Message
    }

    /// Registry of known response opcodes → factory. Extend as more responses are ported.
    static let factories: [UInt8: @Sendable ([UInt8]) -> any Message] = [
        ApiVersionResponse.props.opCode:      { ApiVersionResponse(cargo: $0) },
        NonControlIQIOBResponse.props.opCode: { NonControlIQIOBResponse(cargo: $0) },
        ControlIQInfoV2Response.props.opCode: { ControlIQInfoV2Response(cargo: $0) },
        LastBGResponse.props.opCode:          { LastBGResponse(cargo: $0) },
        PumpVersionResponse.props.opCode:     { PumpVersionResponse(cargo: $0) },
        HomeScreenMirrorResponse.props.opCode: { HomeScreenMirrorResponse(cargo: $0) },
        TempRateStatusResponse.props.opCode:  { TempRateStatusResponse(cargo: $0) },
        CurrentBatteryV1Response.props.opCode: { CurrentBatteryV1Response(cargo: $0) },
        ControlIQIOBResponse.props.opCode:    { ControlIQIOBResponse(cargo: $0) },
        InsulinStatusResponse.props.opCode:   { InsulinStatusResponse(cargo: $0) },
        CurrentBatteryV2Response.props.opCode: { CurrentBatteryV2Response(cargo: $0) },
        CurrentEgvGuiDataV2Response.props.opCode: { CurrentEgvGuiDataV2Response(cargo: $0) },
        CurrentBasalStatusResponse.props.opCode: { CurrentBasalStatusResponse(cargo: $0) },
        LastBolusStatusV2Response.props.opCode: { LastBolusStatusV2Response(cargo: $0) },
        TimeSinceResetResponse.props.opCode: { TimeSinceResetResponse(cargo: $0) },
        BolusCalcDataSnapshotResponse.props.opCode: { BolusCalcDataSnapshotResponse(cargo: $0) },
        BolusPermissionResponse.props.opCode: { BolusPermissionResponse(cargo: $0) },
        InitiateBolusResponse.props.opCode:   { InitiateBolusResponse(cargo: $0) },
        HistoryLogStatusResponse.props.opCode: { HistoryLogStatusResponse(cargo: $0) },
        HistoryLogResponse.props.opCode:      { HistoryLogResponse(cargo: $0) },
        // Variable-size stream frame on the HISTORY_LOG characteristic — no fixed expectedSize.
        HistoryLogStreamResponse.props.opCode: { HistoryLogStreamResponse(cargo: $0) },
        AlertStatusResponse.props.opCode:     { AlertStatusResponse(cargo: $0) },
        AlarmStatusResponse.props.opCode:     { AlarmStatusResponse(cargo: $0) },
        CGMAlertStatusResponse.props.opCode:  { CGMAlertStatusResponse(cargo: $0) },
        ReminderStatusResponse.props.opCode:  { ReminderStatusResponse(cargo: $0) },
        MalfunctionBitmaskStatusResponse.props.opCode: { MalfunctionBitmaskStatusResponse(cargo: $0) },
        CurrentBolusStatusResponse.props.opCode: { CurrentBolusStatusResponse(cargo: $0) },
        DismissNotificationResponse.props.opCode: { DismissNotificationResponse(cargo: $0) },
        SuspendPumpingResponse.props.opCode:  { SuspendPumpingResponse(cargo: $0) },
        ResumePumpingResponse.props.opCode:   { ResumePumpingResponse(cargo: $0) },
    ]

    static let expectedSizes: [UInt8: Int] = [
        ApiVersionResponse.props.opCode: ApiVersionResponse.props.size,
        NonControlIQIOBResponse.props.opCode: NonControlIQIOBResponse.props.size,
        ControlIQInfoV2Response.props.opCode: ControlIQInfoV2Response.props.size,
        LastBGResponse.props.opCode: LastBGResponse.props.size,
        PumpVersionResponse.props.opCode: PumpVersionResponse.props.size,
        HomeScreenMirrorResponse.props.opCode: HomeScreenMirrorResponse.props.size,
        TempRateStatusResponse.props.opCode: TempRateStatusResponse.props.size,
        CurrentBatteryV1Response.props.opCode: CurrentBatteryV1Response.props.size,
        ControlIQIOBResponse.props.opCode: ControlIQIOBResponse.props.size,
        InsulinStatusResponse.props.opCode: InsulinStatusResponse.props.size,
        CurrentBatteryV2Response.props.opCode: CurrentBatteryV2Response.props.size,
        CurrentEgvGuiDataV2Response.props.opCode: CurrentEgvGuiDataV2Response.props.size,
        CurrentBasalStatusResponse.props.opCode: CurrentBasalStatusResponse.props.size,
        LastBolusStatusV2Response.props.opCode: LastBolusStatusV2Response.props.size,
        TimeSinceResetResponse.props.opCode: TimeSinceResetResponse.props.size,
        BolusCalcDataSnapshotResponse.props.opCode: BolusCalcDataSnapshotResponse.props.size,
        BolusPermissionResponse.props.opCode: BolusPermissionResponse.props.size,
        InitiateBolusResponse.props.opCode: InitiateBolusResponse.props.size,
        HistoryLogStatusResponse.props.opCode: HistoryLogStatusResponse.props.size,
        HistoryLogResponse.props.opCode: HistoryLogResponse.props.size,
        // HistoryLogStreamResponse omitted: variable-size stream frame.
        AlertStatusResponse.props.opCode: AlertStatusResponse.props.size,
        AlarmStatusResponse.props.opCode: AlarmStatusResponse.props.size,
        CGMAlertStatusResponse.props.opCode: CGMAlertStatusResponse.props.size,
        ReminderStatusResponse.props.opCode: ReminderStatusResponse.props.size,
        MalfunctionBitmaskStatusResponse.props.opCode: MalfunctionBitmaskStatusResponse.props.size,
        CurrentBolusStatusResponse.props.opCode: CurrentBolusStatusResponse.props.size,
        DismissNotificationResponse.props.opCode: DismissNotificationResponse.props.size,
        SuspendPumpingResponse.props.opCode: SuspendPumpingResponse.props.size,
        ResumePumpingResponse.props.opCode: ResumePumpingResponse.props.size,
    ]

    /// Signed responses carry a 24-byte HMAC trailer after the cargo (the declared length
    /// includes it). We strip it for field parsing; HMAC verification against the derived key
    /// is the auth/BLE layer's responsibility.
    static let signedOpcodes: Set<UInt8> = [
        BolusPermissionResponse.props.opCode,
        InitiateBolusResponse.props.opCode,
        SuspendPumpingResponse.props.opCode,
        ResumePumpingResponse.props.opCode,
    ]

    /// Validates CRC + length and dispatches to the matching response type.
    public static func parse(frame: [UInt8]) throws -> Parsed {
        guard frame.count >= 5 else { throw ParseError.frameTooShort }
        let body = Array(frame[0..<(frame.count - 2)])
        let crc = Array(frame[(frame.count - 2)...])
        let expectedCRC = Bytes.calculateCRC16(body)
        guard crc == expectedCRC else { throw ParseError.crcMismatch(expected: expectedCRC, actual: crc) }

        let opCode = frame[0]
        let txId = frame[1]
        let length = Int(frame[2])
        guard 3 + length <= body.count else {
            throw ParseError.cargoLengthMismatch(opcode: opCode, expected: length, got: body.count - 3)
        }
        // Signed responses append a 24-byte HMAC to the cargo; strip it for field parsing.
        let cargoLen = signedOpcodes.contains(opCode) ? max(0, length - 24) : length
        let cargo = Array(body[3..<(3 + cargoLen)])

        guard let make = factories[opCode] else { throw ParseError.unknownOpcode(opCode) }
        // Require at least the expected cargo, but tolerate extra trailing bytes: newer pump
        // firmware (e.g. Control-IQ+ 7.10.x EGV) appends fields we don't parse. Parsers only
        // read known offsets, so longer cargo is safe.
        if let expected = expectedSizes[opCode], cargo.count < expected {
            throw ParseError.cargoLengthMismatch(opcode: opCode, expected: expected, got: cargo.count)
        }
        return Parsed(opCode: opCode, txId: txId, message: make(cargo))
    }
}
