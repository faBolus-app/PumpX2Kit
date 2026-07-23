import Testing
@testable import PumpX2Messages

/// Byte-locks for the carb/BG-metadata and IDP field VALUES that faBolus sends (audit C-07). The
/// encoders themselves are already parity-locked in OracleParityTests; these pin the specific argument
/// values that were previously best guesses to the reference's ground truth, so a regression that
/// reverts them fails here.
@Suite struct RemoteEntryAndIdpOracleTests {

    /// Ground truth from a captured real-app BLE payload (oracle `RemoteBgEntryRequestTest.ID10652`):
    /// a bolus-window BG is sent as entryType = MANUAL (byte 3 = 0) and source = REMOTE (byte 4 = 1) —
    /// "entered remotely via BLE". faBolus now sends exactly this (was source = PUMP/0). bg 142,
    /// pumpTime 1079274, bolusId 10652.
    @Test func remoteBgEntryManualRemoteMatchesCapture() {
        let req = RemoteBgEntryRequest(bg: 142, useForCgmCalibration: false, entryTypeId: 0, sourceId: 1,
                                       pumpTimeSecondsSinceBoot: 1_079_274, bolusId: 10652)
        // [bg LE][useForCgmCal][entryType][source][pumpTime uint32 LE][bolusId LE]
        let expected: [UInt8] = [142, 0, 0, 0, 1, 234, 119, 16, 0, 156, 41]
        #expect(req.cargo == expected)
        #expect(req.cargo[3] == 0)   // entryType MANUAL
        #expect(req.cargo[4] == 1)   // source REMOTE  ← the corrected value (was 0/PUMP)
    }

    /// The `isAutopopBg: false` convenience faBolus USED to call encodes source = PUMP(0) — i.e. NOT
    /// what any captured vector sends. This guards against regressing back to it.
    @Test func legacyIsAutopopFalseEncodesPumpSource() {
        let legacy = RemoteBgEntryRequest(bg: 142, useForCgmCalibration: false, isAutopopBg: false,
                                          pumpTimeSecondsSinceBoot: 1_079_274, bolusId: 10652)
        #expect(legacy.cargo[4] == 0)   // PUMP — contradicts the captures; must not be used for a remote entry
    }

    /// IDP segment write: `idpStatusId` is a changed-fields bitmask (IDPSegmentStatus BASAL_RATE 1 |
    /// CARB_RATIO 2 | TARGET_BG 4 | CORRECTION_FACTOR 8 | START_TIME 16 = 31 for all). faBolus now sends
    /// 31 (all fields) for create/modify; it previously sent 0 ("nothing changed"). Byte 16 is idpStatusId.
    @Test func setIdpSegmentStatusBitmaskAllFields() {
        let req = SetIDPSegmentRequest(idpId: 1, profileIndex: 0, segmentIndex: 0, operationId: 1,
                                       profileStartTime: 0, profileBasalRate: 1000, profileCarbRatio: 3000,
                                       profileTargetBG: 100, profileISF: 2, idpStatusId: 31)
        #expect(req.cargo.count == 17)
        #expect(req.cargo[16] == 31)   // all-fields bitmask (was 0)
    }

    /// IDP profile create: reference new-profile values (CreateIDPRequestTest.new1 + field doc-comments):
    /// timeSegmentBitmask 31 (all), bolusSettingsBitmask 5 (insulinDuration|carbEntry), idpSourceId 255
    /// (0xFF = brand-new, not a duplicate), carbEntry 1. faBolus now sends these (was 1 / 0 / 0 / 1).
    @Test func createIdpNewProfileFieldBytes() {
        let req = CreateIDPRequest(name: "testprofile", firstSegmentProfileCarbRatio: 3000,
                                   firstSegmentProfileBasalRate: 1000, firstSegmentProfileTargetBG: 100,
                                   firstSegmentProfileISF: 2, profileInsulinDuration: 300,
                                   timeSegmentBitmask: 31, bolusSettingsBitmask: 5, carbEntry: 1, idpSourceId: 255)
        #expect(req.cargo.count == 35)
        #expect(req.cargo[31] == 31)    // timeSegmentBitmask = all
        #expect(req.cargo[32] == 5)     // bolusSettingsBitmask = insulinDuration|carbEntry
        #expect(req.cargo[33] == 255)   // idpSourceId 0xFF = new profile (was 0 = "duplicate profile 0")
        #expect(req.cargo[34] == 1)     // carbEntry
    }
}
