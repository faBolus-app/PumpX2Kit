import Testing
@testable import PumpX2Messages

/// Byte-exact lock for the **extended (combo) bolus** cargo, which faBolus relies on for delivery.
/// Vector from the oracle test `testInitiateBolusRequest_Mobi_Extended8h`: a pure-extended bolus of
/// 2000 mU (2.0 U) over 28800 s (8 h), bolusID 248, bolusTypeBitmask 12 (FOOD2|EXTENDED).
@Suite struct InitiateBolusExtendedTests {
    @Test func extendedComboCargoMatchesOracle() {
        let req = InitiateBolusRequest(
            totalVolume: 0, bolusID: 248, bolusTypeBitmask: 12,
            foodVolume: 0, correctionVolume: 0, bolusCarbs: 0, bolusBG: 0, bolusIOB: 0,
            extendedVolume: 2000, extendedSeconds: 28800, extended3: 0)

        // Oracle cargo (signed Java bytes) reinterpreted as UInt8.
        let expected: [UInt8] = [0,0,0,0, 248,0, 0,0, 12, 0,0,0,0, 0,0,0,0, 0,0, 0,0,
                                 0,0,0,0, 208,7,0,0, 128,112,0,0, 0,0,0,0]
        #expect(req.cargo == expected)
        #expect(req.bolusTypeBitmask == 12)
        #expect(req.extendedVolume == 2000)
        #expect(req.extendedSeconds == 28800)
    }

    /// Guards the min-extended precondition boundary (0.40 U total across now + later).
    @Test func minExtendedIs400Milliunits() {
        #expect(InitiateBolusRequest.minExtendedBolusMilliunits == 400)
    }

    /// Locks the carb/BG metadata byte positions for a standard bolus (faBolus now populates these so
    /// the pump graph / t:connect / Control-IQ record the carbs). 1.0 U (1000 mU), bolusID 10,
    /// FOOD2 bitmask 1, carbs 45 g @ bytes 17-18, BG 120 mg/dL @ bytes 19-20.
    @Test func standardBolusCarbsBgCargo() {
        let req = InitiateBolusRequest(totalVolume: 1000, bolusID: 10, bolusTypeBitmask: 1,
                                       bolusCarbs: 45, bolusBG: 120)
        let expected: [UInt8] = [232,3,0,0, 10,0, 0,0, 1, 0,0,0,0, 0,0,0,0, 45,0, 120,0,
                                 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0]
        #expect(req.cargo == expected)
        #expect(req.bolusCarbs == 45)
        #expect(req.bolusBG == 120)
    }
}
