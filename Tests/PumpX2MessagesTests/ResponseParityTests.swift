import Testing
@testable import PumpX2Messages

/// Validates response *parsing* byte-exact against the oracle: encode a response through the
/// cliparser (Java buildCargo), reassemble the packets into a frame, parse it in Swift, and
/// assert the fields round-trip.
@Suite(.enabled(if: OracleRunner.isAvailable)) struct ResponseParityTests {

    /// Reassemble oracle packet hex into a single frame (drop each packet's 2-byte header).
    private func frame(_ packets: [String]) throws -> [UInt8] {
        var out: [UInt8] = []
        for hex in packets {
            let bytes = try Hex.decode(hex)
            out.append(contentsOf: bytes.dropFirst(2))
        }
        return out
    }

    /// Reassemble + parse on a given characteristic (defaults to CURRENT_STATUS, where most reads
    /// arrive). Dispatch is now (characteristic, opcode)-keyed, so control responses pass `.control`.
    private func parse(_ packets: [String], on characteristic: Characteristic = .currentStatus) throws -> ResponseParser.Parsed {
        try ResponseParser.parse(frame: frame(packets), characteristic: characteristic)
    }

    @Test func apiVersionResponseParsesAndDetectsModel() throws {
        // Mobi = API 3.5+; t:slim X2 = 2.x–3.4.
        let mobi = try OracleRunner.encode(txId: 6, messageName: "ApiVersionResponse", json: "[3, 5]").packets
        let m = try #require(try parse(mobi).message as? ApiVersionResponse)
        #expect(m.majorVersion == 3 && m.minorVersion == 5)
        #expect(m.isMobi)
        let tslim = try OracleRunner.encode(txId: 6, messageName: "ApiVersionResponse", json: "[3, 2]").packets
        let t = try #require(try parse(tslim).message as? ApiVersionResponse)
        #expect(!t.isMobi)
    }

    @Test func nonControlIQIOBResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 8, messageName: "NonControlIQIOBResponse", json: "[240, 17940, 240]").packets
        let msg = try #require(try parse(packets).message as? NonControlIQIOBResponse)
        #expect(msg.iob == 240)
        #expect(msg.timeRemainingSeconds == 17940)
        #expect(msg.iobUnits == 0.240)
    }

    @Test func controlIQInfoV2ResponseParses() throws {
        // [closedLoop, weight, weightUnit, TDI, userMode, b6, b7, b8, controlState, exChoice, exDur, exRem]
        let packets = try OracleRunner.encode(
            txId: 9, messageName: "ControlIQInfoV2Response", json: "[true, 70, 0, 40, 2, 0, 0, 0, 1, 0, 0, 0]").packets
        let msg = try #require(try parse(packets).message as? ControlIQInfoV2Response)
        #expect(msg.closedLoopEnabled)
        #expect(msg.currentUserModeType == 2)
        #expect(msg.controlStateType == 1)
    }

    // NOTE: LastBGResponse is verified in ResponseDirectTests — its upstream class has two 3-arg
    // constructors ((long,int,int) and (long,int,BgSource)) and the oracle's reflection picks
    // between them nondeterministically (Java getConstructors() order), so oracle encoding flakes.

    @Test func pumpVersionResponseParses() throws {
        // [armSwVer, mspSwVer, configA, configB, serialNum, partNum, pumpRev, pcbaSN, pcbaRev, modelNum]
        let packets = try OracleRunner.encode(
            txId: 11, messageName: "PumpVersionResponse",
            json: "[1, 2, 0, 0, 123456, 7890, \"abc\", 111, \"def\", 1001]").packets
        let msg = try #require(try parse(packets).message as? PumpVersionResponse)
        #expect(msg.serialNum == 123456)
        #expect(msg.partNum == 7890)
        #expect(msg.pumpRev == "abc")
        #expect(msg.modelNum == 1001)
    }

    @Test func homeScreenMirrorResponseParses() throws {
        // [cgmTrend, cgmAlert, statusIcon0, statusIcon1, bolusStatus, basalStatus, apControlState, remInsulinPlus, cgmDisplay]
        let packets = try OracleRunner.encode(
            txId: 12, messageName: "HomeScreenMirrorResponse", json: "[1, 2, 3, 4, 5, 6, 7, true, false]").packets
        let msg = try #require(try parse(packets).message as? HomeScreenMirrorResponse)
        #expect(msg.cgmTrendIconId == 1)
        #expect(msg.cgmAlertIconId == 2)
        #expect(msg.bolusStatusIconId == 5)
        #expect(msg.apControlStateIconId == 7)
        #expect(msg.remainingInsulinPlusIcon)
        #expect(!msg.cgmDisplayData)
    }

    @Test func pumpSettingsResponseParses() throws {
        // [lowInsulinThreshold, cannulaPrimeSize, autoShutdownEnabled, autoShutdownDuration,
        //  featureLock, oledTimeout, status]
        let packets = try OracleRunner.encode(
            txId: 19, messageName: "PumpSettingsResponse", json: "[20, 30, 1, 720, 0, 30, 0]").packets
        let msg = try #require(try parse(packets).message as? PumpSettingsResponse)
        #expect(msg.lowInsulinThreshold == 20)
        #expect(msg.cannulaPrimeSize == 30)
        #expect(msg.autoShutdownEnabled == 1)
        #expect(msg.autoShutdownDuration == 720)
        #expect(msg.oledTimeout == 30)
    }

    @Test func pumpGlobalsResponseParses() throws {
        // [quickBolusEnabled, incUnits, incCarbs, entryType, status, buttonAnnun, quickBolusAnnun,
        //  bolusAnnun, reminderAnnun, alertAnnun, alarmAnnun, fillTubingAnnun]
        let packets = try OracleRunner.encode(
            txId: 20, messageName: "PumpGlobalsResponse", json: "[1, 1000, 0, 0, 0, 0, 1, 2, 3, 0, 1, 2]").packets
        let msg = try #require(try parse(packets).message as? PumpGlobalsResponse)
        #expect(msg.quickBolusEnabled)
        #expect(msg.quickBolusIncrementUnits == 1000)
        #expect(msg.quickBolusAnnun == 1)
        #expect(msg.bolusAnnun == 2)
        #expect(msg.fillTubingAnnun == 2)
    }

    @Test func cancelBolusResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 21, messageName: "CancelBolusResponse", json: "[0, 10650, 0]").packets
        let msg = try #require(try parse(packets, on: .control).message as? CancelBolusResponse)
        #expect(msg.bolusId == 10650)
        #expect(msg.wasCancelled)
        // A non-zero reason marks a failed cancel (e.g. already delivered).
        let failed = try OracleRunner.encode(
            txId: 22, messageName: "CancelBolusResponse", json: "[1, 10650, 2]").packets
        let fm = try #require(try parse(failed, on: .control).message as? CancelBolusResponse)
        #expect(!fm.wasCancelled)
    }

    @Test func bolusPermissionReleaseResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 23, messageName: "BolusPermissionReleaseResponse", json: "[0]").packets
        let msg = try #require(try parse(packets, on: .control).message as? BolusPermissionReleaseResponse)
        #expect(msg.released)
    }

    @Test func profileStatusResponseParses() throws {
        // [numberOfProfiles, slot0, slot1, slot2, slot3, slot4, slot5, activeSegmentIndex]
        let packets = try OracleRunner.encode(
            txId: 24, messageName: "ProfileStatusResponse", json: "[2, 4, 7, -1, -1, -1, -1, 1]").packets
        let msg = try #require(try parse(packets).message as? ProfileStatusResponse)
        #expect(msg.numberOfProfiles == 2)
        #expect(msg.activeIdpId == 4)
        #expect(msg.activeSegmentIndex == 1)
        #expect(msg.presentIdpIds == [4, 7])
    }

    @Test func currentActiveIdpValuesResponseParses() throws {
        // [carbRatio(1000-inc), targetBg, insulinDuration(min), isf]
        let packets = try OracleRunner.encode(
            txId: 25, messageName: "CurrentActiveIdpValuesResponse", json: "[10000, 110, 300, 30]").packets
        let msg = try #require(try parse(packets).message as? CurrentActiveIdpValuesResponse)
        #expect(msg.currentCarbRatio == 10000)
        #expect(msg.carbRatioGramsPerUnit == 10.0)
        #expect(msg.currentTargetBg == 110)
        #expect(msg.currentInsulinDuration == 300)
        #expect(msg.currentIsf == 30)
    }

    @Test func globalMaxBolusSettingsResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 26, messageName: "GlobalMaxBolusSettingsResponse", json: "[25000, 25000]").packets
        let msg = try #require(try parse(packets).message as? GlobalMaxBolusSettingsResponse)
        #expect(msg.maxBolus == 25000)
        #expect(msg.maxBolusUnits == 25.0)
    }

    @Test func basalLimitSettingsResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 27, messageName: "BasalLimitSettingsResponse", json: "[15000, 15000]").packets
        let msg = try #require(try parse(packets).message as? BasalLimitSettingsResponse)
        #expect(msg.basalLimit == 15000)
        #expect(msg.basalLimitUnitsPerHour == 15.0)
    }

    @Test func controlIQInfoV1ResponseParses() throws {
        // [closedLoop, weight, weightUnit, TDI, userMode, b6, b7, b8, controlState]
        let packets = try OracleRunner.encode(
            txId: 28, messageName: "ControlIQInfoV1Response", json: "[true, 70, 0, 40, 2, 0, 0, 0, 1]").packets
        let msg = try #require(try parse(packets).message as? ControlIQInfoV1Response)
        #expect(msg.closedLoopEnabled)
        #expect(msg.weight == 70)
        #expect(msg.totalDailyInsulin == 40)
        #expect(msg.currentUserModeType == 2)
        #expect(msg.controlStateType == 1)
    }

    @Test func currentBatteryV1ResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 13, messageName: "CurrentBatteryV1Response", json: "[50, 78]").packets
        let msg = try #require(try parse(packets).message as? CurrentBatteryV1Response)
        #expect(msg.currentBatteryAbc == 50)
        #expect(msg.batteryPercent == 78)
    }

    @Test func suspendResumePumpingResponsesParse() throws {
        let s = try OracleRunner.encode(txId: 14, messageName: "SuspendPumpingResponse", json: "[0]").packets
        let sm = try #require(try parse(s, on: .control).message as? SuspendPumpingResponse)
        #expect(sm.status == 0 && sm.accepted)
        let r = try OracleRunner.encode(txId: 15, messageName: "ResumePumpingResponse", json: "[0]").packets
        let rm = try #require(try parse(r, on: .control).message as? ResumePumpingResponse)
        #expect(rm.status == 0 && rm.accepted)
    }

    @Test func controlIQIOBResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 1, messageName: "ControlIQIOBResponse", json: "[240, 17940, 240, 240, 0]").packets
        let parsed = try parse(packets)
        let msg = try #require(parsed.message as? ControlIQIOBResponse)
        #expect(msg.mudaliarIOB == 240)
        #expect(msg.timeRemainingSeconds == 17940)
        #expect(msg.iobType == 0)
        #expect(msg.iobUnits == 0.240)
    }

    @Test func insulinStatusResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 2, messageName: "InsulinStatusResponse", json: "[142, 0, 0]").packets
        let msg = try #require(try parse(packets).message as? InsulinStatusResponse)
        #expect(msg.currentInsulinAmount == 142)
    }

    @Test func currentBatteryV2ResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 3, messageName: "CurrentBatteryV2Response", json: "[75, 78, 0, 0, 0, 0, 0]").packets
        let msg = try #require(try parse(packets).message as? CurrentBatteryV2Response)
        #expect(msg.batteryPercent == 78)
    }

    @Test func bolusPermissionResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 4, messageName: "BolusPermissionResponse", json: "[0, 10650, 0]").packets
        let msg = try #require(try parse(packets, on: .control).message as? BolusPermissionResponse)
        #expect(msg.granted)
        #expect(msg.bolusId == 10650)
    }

    @Test func initiateBolusResponseParses() throws {
        let packets = try OracleRunner.encode(
            txId: 5, messageName: "InitiateBolusResponse", json: "[0, 10650, 0]").packets
        let msg = try #require(try parse(packets, on: .control).message as? InitiateBolusResponse)
        #expect(msg.accepted)
        #expect(msg.bolusId == 10650)
    }

    @Test func egvGuiDataV2ResponseParses() throws {
        // [bgReadingTimestampSeconds, cgmReading, egvStatusId, trendRate]
        // egvStatusId 1 = VALID
        let packets = try OracleRunner.encode(
            txId: 7, messageName: "CurrentEgvGuiDataV2Response", json: "[461589432, 142, 1, 12]").packets
        let msg = try #require(try parse(packets).message as? CurrentEgvGuiDataV2Response)
        #expect(msg.cgmReading == 142)
        #expect(msg.trendRate == 12)
        #expect(msg.egvStatusId == 1)
        #expect(msg.hasValidReading)
    }

    @Test func basalStatusResponseParses() throws {
        // [profileBasalRate, currentBasalRate, basalModifiedBitmask] — milliunits/hr
        let packets = try OracleRunner.encode(
            txId: 8, messageName: "CurrentBasalStatusResponse", json: "[850, 850, 0]").packets
        let msg = try #require(try parse(packets).message as? CurrentBasalStatusResponse)
        #expect(msg.currentBasalRate == 850)
        #expect(msg.currentBasalUnitsPerHour == 0.85)
    }

    @Test func lastBolusStatusV2ResponseParses() throws {
        // [status, bolusId, timestamp, deliveredVolume, bolusStatusId, bolusSourceId,
        //  bolusTypeBitmask, extendedBolusDuration, requestedVolume]
        let packets = try OracleRunner.encode(
            txId: 9, messageName: "LastBolusStatusV2Response",
            json: "[1, 10650, 461510714, 1000, 3, 8, 8, 0, 1000]").packets
        let msg = try #require(try parse(packets).message as? LastBolusStatusV2Response)
        #expect(msg.bolusId == 10650)
        #expect(msg.deliveredVolume == 1000)
        #expect(msg.deliveredUnits == 1.0)
    }

    /// A corrupted CRC must be rejected.
    @Test func crcMismatchRejected() throws {
        let packets = try OracleRunner.encode(
            txId: 6, messageName: "InsulinStatusResponse", json: "[142, 0, 0]").packets
        var f = try frame(packets)
        f[f.count - 1] ^= 0xFF   // corrupt CRC
        #expect(throws: ResponseParser.ParseError.self) {
            try ResponseParser.parse(frame: f, characteristic: .currentStatus)
        }
    }
}
