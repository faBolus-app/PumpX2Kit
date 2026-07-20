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
        ("HistoryLogStatusRequest", HistoryLogStatusRequest()),
        ("CGMAlertStatusRequest", CGMAlertStatusRequest()),
        ("ProfileStatusRequest", ProfileStatusRequest()),
        ("CurrentActiveIdpValuesRequest", CurrentActiveIdpValuesRequest()),
        ("GlobalMaxBolusSettingsRequest", GlobalMaxBolusSettingsRequest()),
        ("BasalLimitSettingsRequest", BasalLimitSettingsRequest()),
        ("ControlIQInfoV1Request", ControlIQInfoV1Request()),
        ("PumpFeaturesV1Request", PumpFeaturesV1Request()),
        ("LoadStatusRequest", LoadStatusRequest()),
    ]

    @Test(arguments: statusReads)
    func statusReadMatchesOracle(name: String, message: Message) throws {
        let txId: UInt8 = 11
        let oracle = try OracleRunner.encodePackets(txId: txId, messageName: name)
        let swift = try swiftPackets(message, txId: txId)
        #expect(swift == oracle, "\(name): swift=\(swift) oracle=\(oracle)")
    }

    /// HistoryLogRequest carries a 5-byte cargo (startLog uint32 + numberOfLogs byte).
    @Test func historyLogRequestMatchesOracle() throws {
        let oracle = try OracleRunner.encode(
            txId: 8, messageName: "HistoryLogRequest", json: "[1000, 10]").packets
        let swift = try swiftPackets(HistoryLogRequest(startLog: 1000, numberOfLogs: 10), txId: 8)
        #expect(swift == oracle, "swift=\(swift) oracle=\(oracle)")
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

    // MARK: - JPAKE wire messages (framing only; EC-JPAKE bytes are non-deterministic)

    @Test func jpake1aRequestMatchesOracle() throws {
        let challenge = (0..<165).map { UInt8($0 & 0xFF) }
        let hex = Hex.encode(challenge)
        let msg = Jpake1aRequest(appInstanceId: 0, centralChallenge: challenge)
        let oracle = try OracleRunner.encode(
            txId: 0, messageName: "Jpake1aRequest",
            json: "{\"appInstanceId\":0,\"centralChallenge\":\"\(hex)\"}").packets
        #expect(try swiftPackets(msg, txId: 0) == oracle)
    }

    // Jpake3's two 1-arg constructors are ambiguous to the oracle's reflection encoder, so
    // assert its cargo directly (Packetize framing is validated by the other oracle tests).
    @Test func jpake3SessionKeyRequestCargo() {
        #expect(Jpake3SessionKeyRequest(challengeParam: 1).cargo == [0x01, 0x00])
        #expect(Jpake3SessionKeyRequest.props.opCode == 38)
    }

    @Test func jpake4KeyConfirmationRequestMatchesOracle() throws {
        let nonce = (0..<8).map { UInt8($0) }
        let reserved = [UInt8](repeating: 0, count: 8)
        let hashDigest = (0..<32).map { UInt8($0 + 100) }
        let msg = Jpake4KeyConfirmationRequest(appInstanceId: 0, nonce: nonce, reserved: reserved, hashDigest: hashDigest)
        let json = "{\"appInstanceId\":0,\"nonce\":\"\(Hex.encode(nonce))\",\"reserved\":\"\(Hex.encode(reserved))\",\"hashDigest\":\"\(Hex.encode(hashDigest))\"}"
        let oracle = try OracleRunner.encode(txId: 6, messageName: "Jpake4KeyConfirmationRequest", json: json).packets
        #expect(try swiftPackets(msg, txId: 6) == oracle)
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

    @Test func suspendPumpingRequestMatchesOracle() throws {
        let oracle = try oracleSignedPackets("SuspendPumpingRequest", txId: 5)
        let swift = try swiftSignedPackets(SuspendPumpingRequest(), txId: 5)
        #expect(swift == oracle, "swift=\(swift) oracle=\(oracle)")
    }

    @Test func resumePumpingRequestMatchesOracle() throws {
        let oracle = try oracleSignedPackets("ResumePumpingRequest", txId: 6)
        let swift = try swiftSignedPackets(ResumePumpingRequest(), txId: 6)
        #expect(swift == oracle, "swift=\(swift) oracle=\(oracle)")
    }

    @Test func setTempRateRequestMatchesOracle() throws {
        // 30 minutes at 150% — cargo: uint32 ms (30*60000) + LE uint16 percent.
        let oracle = try oracleSignedPackets("SetTempRateRequest", txId: 7, json: "[30, 150]")
        let swift = try swiftSignedPackets(SetTempRateRequest(minutes: 30, percent: 150), txId: 7)
        #expect(swift == oracle, "swift=\(swift) oracle=\(oracle)")
    }

    @Test func stopTempRateRequestMatchesOracle() throws {
        let oracle = try oracleSignedPackets("StopTempRateRequest", txId: 8)
        let swift = try swiftSignedPackets(StopTempRateRequest(), txId: 8)
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
