import Testing
import PumpX2Messages

/// PX-07: the typed/throwing `InitiateBolusRequest(validating:)` rejects out-of-range and incoherent
/// doses BEFORE any byte reaches the wire, instead of silently truncating a uint16 field or trapping.
@Suite struct InitiateBolusValidationTests {
    typealias E = InitiateBolusRequest.ValidationError

    /// A valid carb bolus validates and produces byte-identical cargo to the trapping initializer.
    @Test func validCarbBolusMatchesUnvalidatedBytes() throws {
        let validated = try InitiateBolusRequest(
            validating: 2500, bolusID: 42, bolusTypeBitmask: InitiateBolusRequest.bitFood1,
            foodVolume: 2500, correctionVolume: 0, bolusCarbs: 30, bolusBG: 120, bolusIOB: 130)
        let direct = InitiateBolusRequest(
            totalVolume: 2500, bolusID: 42, bolusTypeBitmask: InitiateBolusRequest.bitFood1,
            foodVolume: 2500, correctionVolume: 0, bolusCarbs: 30, bolusBG: 120, bolusIOB: 130)
        #expect(validated.cargo == direct.cargo)   // validation never changes the bytes
    }

    @Test func rejectsDoseBelowMinimum() {
        #expect(throws: E.doseTooSmall(totalMilliunits: 10, extendedMilliunits: 0)) {
            _ = try InitiateBolusRequest(validating: 10, bolusID: 1, bolusTypeBitmask: 1, foodVolume: 10)
        }
    }

    @Test func rejectsInvalidBolusID() {
        #expect(throws: E.invalidBolusID(0)) {
            _ = try InitiateBolusRequest(validating: 1000, bolusID: 0, bolusTypeBitmask: 1, foodVolume: 1000)
        }
        #expect(throws: E.invalidBolusID(70000)) {   // > uint16 → would silently truncate on the wire
            _ = try InitiateBolusRequest(validating: 1000, bolusID: 70000, bolusTypeBitmask: 1, foodVolume: 1000)
        }
    }

    @Test func rejectsCarbsAndBgOverWireWidth() {
        #expect(throws: E.carbsOutOfRange(70000)) {
            _ = try InitiateBolusRequest(validating: 1000, bolusID: 1, bolusTypeBitmask: 1,
                                         foodVolume: 1000, bolusCarbs: 70000)
        }
        #expect(throws: E.bgOutOfRange(-5)) {
            _ = try InitiateBolusRequest(validating: 1000, bolusID: 1, bolusTypeBitmask: 1,
                                         foodVolume: 1000, bolusBG: -5)
        }
    }

    @Test func rejectsBadTypeMask() {
        #expect(throws: E.invalidTypeBitmask(0)) {
            _ = try InitiateBolusRequest(validating: 1000, bolusID: 1, bolusTypeBitmask: 0, foodVolume: 1000)
        }
        #expect(throws: E.invalidTypeBitmask(0x10)) {   // unknown bit
            _ = try InitiateBolusRequest(validating: 1000, bolusID: 1, bolusTypeBitmask: 0x10, foodVolume: 1000)
        }
    }

    @Test func rejectsIncoherentExtended() {
        // EXTENDED bit but no duration.
        #expect(throws: E.self) {
            _ = try InitiateBolusRequest(
                validating: 1000, bolusID: 1,
                bolusTypeBitmask: InitiateBolusRequest.bitFood1 | InitiateBolusRequest.bitExtended,
                foodVolume: 1000, extendedVolume: 500, extendedSeconds: 0)
        }
        // Extended fields set without the EXTENDED bit.
        #expect(throws: E.self) {
            _ = try InitiateBolusRequest(validating: 1000, bolusID: 1, bolusTypeBitmask: 1,
                                         foodVolume: 1000, extendedVolume: 500, extendedSeconds: 3600)
        }
    }

    @Test func acceptsWellFormedExtended() throws {
        let r = try InitiateBolusRequest(
            validating: 1000, bolusID: 5,
            bolusTypeBitmask: InitiateBolusRequest.bitFood1 | InitiateBolusRequest.bitExtended,
            foodVolume: 1500, correctionVolume: 0, extendedVolume: 500, extendedSeconds: 7200)
        #expect(r.extendedSeconds == 7200)
        #expect(r.totalVolume == 1000)
    }

    @Test func rejectsComponentLargerThanTotal() {
        #expect(throws: E.self) {
            _ = try InitiateBolusRequest(validating: 1000, bolusID: 1, bolusTypeBitmask: 1, foodVolume: 5000)
        }
    }

    // MARK: - PX-06: the shared type-bitmask derivation (used by the bench harness AND production)

    /// A carb bolus is FOOD1 (1) — NOT FOOD1|FOOD2 (9). This is the exact bug the old bench harness had
    /// (it always OR-ed FOOD2 in). The value must match the oracle FOOD1 byte-lock in
    /// InitiateBolusExtendedTests.
    @Test func typeBitmaskDerivation() {
        typealias R = InitiateBolusRequest
        #expect(R.typeBitmask(hasCarbs: true,  hasCorrection: false, isExtended: false) == R.bitFood1)     // 1
        #expect(R.typeBitmask(hasCarbs: false, hasCorrection: false, isExtended: false) == R.bitFood2)     // 8
        #expect(R.typeBitmask(hasCarbs: true,  hasCorrection: true,  isExtended: false) == R.bitFood1 | R.bitCorrection)      // 3
        #expect(R.typeBitmask(hasCarbs: true,  hasCorrection: false, isExtended: true)  == R.bitFood1 | R.bitExtended)        // 5
        #expect(R.typeBitmask(hasCarbs: false, hasCorrection: true,  isExtended: false) == R.bitFood2 | R.bitCorrection)      // 10
        // FOOD2 is never OR-ed into a carb bolus.
        #expect(R.typeBitmask(hasCarbs: true, hasCorrection: false, isExtended: false) & R.bitFood2 == 0)
    }

    /// The derived carb mask, put on the wire, lands in the type byte (offset 8) as FOOD1 — the same byte
    /// the oracle capture locks.
    @Test func carbBolusTypeByteIsFood1() throws {
        let mask = InitiateBolusRequest.typeBitmask(hasCarbs: true, hasCorrection: false, isExtended: false)
        let req = try InitiateBolusRequest(validating: 2500, bolusID: 1, bolusTypeBitmask: mask, foodVolume: 2500)
        #expect(req.cargo[8] == 1)   // FOOD1
    }
}
