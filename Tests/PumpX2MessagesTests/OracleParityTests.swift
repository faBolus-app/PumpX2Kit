import Testing
@testable import PumpX2Messages

/// Byte-exact parity tests against the cliparser oracle. Every ported outgoing message must
/// serialize to the same packet bytes the upstream library produces. These are the tests
/// that make the hand-port trustworthy. Gated on the oracle being built (see OracleRunner).
@Suite(.enabled(if: OracleRunner.isAvailable))
struct OracleParityTests {

    /// Serializes `message` at `txId` via Swift Packetize and returns lowercase packet hex,
    /// matching the oracle's `packets` format.
    private func swiftPackets(_ message: Message, txId: UInt8) throws -> [String] {
        try Packetize.packetize(message, txId: txId).map { Hex.encode($0.build()) }
    }

    @Test(arguments: [UInt8(0), 5, 42, 255])
    func apiVersionRequestMatchesOracle(txId: UInt8) throws {
        let oracle = try OracleRunner.encodePackets(txId: txId, messageName: "ApiVersionRequest")
        let swift = try swiftPackets(ApiVersionRequest(), txId: txId)
        #expect(swift == oracle, "txId=\(txId): swift=\(swift) oracle=\(oracle)")
    }

    /// Sanity: the oracle also reports the characteristic our props declare.
    @Test func apiVersionRequestCharacteristic() throws {
        let result = try OracleRunner.encode(txId: 0, messageName: "ApiVersionRequest")
        #expect(result.characteristicName == ApiVersionRequest.props.characteristic.name)
        #expect(result.characteristic.lowercased()
            == ApiVersionRequest.props.characteristic.uuidString.lowercased())
    }

    // MARK: - Empty-cargo status reads

    /// (oracle message name, Swift instance) pairs for the empty-cargo CURRENT_STATUS reads.
    static let statusReads: [(String, Message)] = [
        ("ControlIQIOBRequest", ControlIQIOBRequest()),
        ("NonControlIQIOBRequest", NonControlIQIOBRequest()),
        ("InsulinStatusRequest", InsulinStatusRequest()),
        ("CurrentBatteryV2Request", CurrentBatteryV2Request()),
        ("CurrentBasalStatusRequest", CurrentBasalStatusRequest()),
        ("HomeScreenMirrorRequest", HomeScreenMirrorRequest()),
        ("PumpVersionRequest", PumpVersionRequest()),
        ("TimeSinceResetRequest", TimeSinceResetRequest()),
        ("CurrentBolusStatusRequest", CurrentBolusStatusRequest()),
        ("LastBolusStatusV2Request", LastBolusStatusV2Request()),
        ("ControlIQInfoV2Request", ControlIQInfoV2Request()),
        ("LastBGRequest", LastBGRequest()),
        ("PumpGlobalsRequest", PumpGlobalsRequest()),
        ("PumpSettingsRequest", PumpSettingsRequest()),
        ("BolusCalcDataSnapshotRequest", BolusCalcDataSnapshotRequest()),
        ("AlertStatusRequest", AlertStatusRequest()),
        ("AlarmStatusRequest", AlarmStatusRequest()),
        ("MalfunctionStatusRequest", MalfunctionStatusRequest()),
    ]

    @Test(arguments: statusReads)
    func statusReadMatchesOracle(name: String, message: Message) throws {
        let txId: UInt8 = 11
        let oracle = try OracleRunner.encodePackets(txId: txId, messageName: name)
        let swift = try swiftPackets(message, txId: txId)
        #expect(swift == oracle, "\(name): swift=\(swift) oracle=\(oracle)")
    }

    // MARK: - Authentication messages

    @Test func centralChallengeRequestMatchesOracle() throws {
        let challenge = try Hex.decode("00112233445566778899") // 10 bytes; first 8 used
        let msg = CentralChallengeRequest(appInstanceId: 0, centralChallenge: challenge)
        let oracle = try OracleRunner.encode(
            txId: 1, messageName: "CentralChallengeRequest",
            json: "{\"appInstanceId\":0,\"centralChallenge\":\"00112233445566778899\"}"
        ).packets
        #expect(try swiftPackets(msg, txId: 1) == oracle)
    }

    /// PumpChallengeRequest's 22-byte cargo spans two BLE packets — exercises chunking.
    @Test func pumpChallengeRequestMatchesOracleMultiPacket() throws {
        let hash = try Hex.decode("0102030405060708090a0b0c0d0e0f1011121314") // 20 bytes
        let msg = PumpChallengeRequest(appInstanceId: 0, pumpChallengeHash: hash)
        let oracle = try OracleRunner.encode(
            txId: 2, messageName: "PumpChallengeRequest",
            json: "{\"appInstanceId\":0,\"pumpChallengeHash\":\"0102030405060708090a0b0c0d0e0f1011121314\"}"
        ).packets
        #expect(oracle.count == 2)          // sanity: really multi-packet
        #expect(try swiftPackets(msg, txId: 2) == oracle)
    }

    // MARK: - Signed bolus flow

    /// Serializes a signed `message` with the shared test pairing code / pump time, matching
    /// the oracle env, and returns lowercase packet hex.
    private func swiftSignedPackets(_ message: Message, txId: UInt8) throws -> [String] {
        try Packetize.packetize(
            message,
            authenticationKey: Array(OracleRunner.testPairingCode.utf8),
            txId: txId,
            pumpTimeSinceReset: OracleRunner.testPumpTimeSinceReset,
            actionsAffectingInsulinDeliveryEnabled: true
        ).map { Hex.encode($0.build()) }
    }

    private func oracleSignedPackets(_ name: String, txId: UInt8, json: String = "{}") throws -> [String] {
        try OracleRunner.encode(
            txId: txId, messageName: name, json: json,
            pairingCode: OracleRunner.testPairingCode,
            pumpTimeSinceReset: OracleRunner.testPumpTimeSinceReset
        ).packets
    }

    @Test(arguments: [UInt8(0), 7, 200])
    func bolusPermissionRequestMatchesOracle(txId: UInt8) throws {
        let oracle = try oracleSignedPackets("BolusPermissionRequest", txId: txId)
        let swift = try swiftSignedPackets(BolusPermissionRequest(), txId: txId)
        #expect(swift == oracle, "txId=\(txId): swift=\(swift) oracle=\(oracle)")
    }

    @Test func cancelBolusRequestMatchesOracle() throws {
        let oracle = try oracleSignedPackets("CancelBolusRequest", txId: 3, json: "[10650]")
        let swift = try swiftSignedPackets(CancelBolusRequest(bolusId: 10650), txId: 3)
        #expect(swift == oracle, "swift=\(swift) oracle=\(oracle)")
    }

    @Test func bolusPermissionReleaseRequestMatchesOracle() throws {
        let oracle = try oracleSignedPackets("BolusPermissionReleaseRequest", txId: 4, json: "[10650]")
        let swift = try swiftSignedPackets(BolusPermissionReleaseRequest(bolusID: 10650), txId: 4)
        #expect(swift == oracle, "swift=\(swift) oracle=\(oracle)")
    }

    /// The crown jewel: a 1.0u standard bolus initiate, signed, byte-exact vs the oracle.
    @Test func initiateBolusRequestMatchesOracle() throws {
        // positional args: totalVolume, bolusID, bolusTypeBitmask, foodVolume,
        // correctionVolume, bolusCarbs, bolusBG, bolusIOB
        let json = "[1000, 42, 1, 0, 0, 0, 0, 0]"
        let oracle = try oracleSignedPackets("InitiateBolusRequest", txId: 9, json: json)
        let swift = try swiftSignedPackets(
            InitiateBolusRequest(totalVolume: 1000, bolusID: 42, bolusTypeBitmask: 1),
            txId: 9
        )
        #expect(swift == oracle, "swift=\(swift) oracle=\(oracle)")
    }
}
