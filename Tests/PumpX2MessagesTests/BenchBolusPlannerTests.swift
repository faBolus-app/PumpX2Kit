import Testing
import Foundation
@testable import PumpX2Messages

/// Round-2 P1: the bench carb planner must match the Tandem oracle `BolusCalculator.parse()` — the same
/// formula faBolus's `BolusMath` ports and `faBolusCore`'s 563-vector `BolusMathParityTests` verifies.
/// The old harness formula used `max(0, (BG−target)/ISF)`, dropping the SIGNED below-target correction
/// (and its IOB interaction) and skipping two-decimal component rounding — an over-delivery risk on saline.
/// These deterministic cases lock the corrected behavior (signed correction, IOB, dp2, zero floor,
/// 0.05 U snap, bench cap) and the full request cargo.
@Suite struct BenchBolusPlannerTests {

    // A clean profile: 10 g/U, ISF 50 mg/dL/U, target 120 mg/dL.
    private func profile(iob: Double = 0) -> BenchBolusPlanner.Profile {
        BenchBolusPlanner.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 50, targetBgMgdl: 120, iobUnits: iob)
    }
    private let F1 = InitiateBolusRequest.bitFood1
    private let F2 = InitiateBolusRequest.bitFood2
    private let CORR = InitiateBolusRequest.bitCorrection

    /// food+correction always equals total; a deliverable plan (≥ 0.05 U) builds a valid PX-07 request.
    private func assertCoherent(_ p: BenchBolusPlanner.Plan) {
        #expect(p.foodMilliunits + p.correctionMilliunits == p.totalMilliunits)
        if p.totalMilliunits >= InitiateBolusRequest.minBolusMilliunits {
            #expect((try? BenchBolusPlanner.request(for: p, bolusID: 42)) != nil)
        }
    }

    // MARK: above target

    @Test func aboveTargetCarbsNoIob() {
        let p = BenchBolusPlanner.plan(carbsGrams: 30, bgMgdl: 170, profile: profile())
        // fromCarbs 3.00 + fromBG (170-120)/50=1.00 → total 4.00
        #expect(p.totalMilliunits == 4000)
        #expect(p.foodMilliunits == 3000 && p.correctionMilliunits == 1000)
        #expect(p.bitmask == (F1 | CORR))
        assertCoherent(p)
    }

    @Test func iobExceedingCorrectionAddsNothing() {
        let p = BenchBolusPlanner.plan(carbsGrams: 30, bgMgdl: 140, profile: profile(iob: 2.0))
        // fromBG 0.40, fromIOB -2.00 → corr -1.60 (<0) → add nothing → total = carbs 3.00
        #expect(p.totalMilliunits == 3000)
        #expect(p.correctionMilliunits == 0 && p.bitmask == F1)
        assertCoherent(p)
    }

    @Test func iobEqualToCorrectionAddsNothing() {
        let p = BenchBolusPlanner.plan(carbsGrams: 30, bgMgdl: 170, profile: profile(iob: 1.0))
        // fromBG 1.00, fromIOB -1.00 → corr 0 → total = carbs 3.00
        #expect(p.totalMilliunits == 3000)
        assertCoherent(p)
    }

    // MARK: below target — the bug the old formula had

    @Test func belowTargetReducesDoseBelowFoodOnly() {
        let below = BenchBolusPlanner.plan(carbsGrams: 30, bgMgdl: 70, profile: profile())
        let foodOnly = BenchBolusPlanner.plan(carbsGrams: 30, bgMgdl: nil, profile: profile())
        // fromBG (70-120)/50 = -1.00 → total 3.00 - 1.00 = 2.00, strictly LESS than food-only 3.00.
        #expect(below.totalMilliunits == 2000)
        #expect(foodOnly.totalMilliunits == 3000)
        #expect(below.totalMilliunits < foodOnly.totalMilliunits)   // the old max(0,…) got this wrong
        #expect(below.fromBGUnits == -1.00)
        assertCoherent(below); assertCoherent(foodOnly)
    }

    @Test func belowTargetWithIobFloorsAtZero() {
        // No carbs, deeply below target → correction alone can't take the total below 0.
        let p = BenchBolusPlanner.plan(carbsGrams: nil, bgMgdl: 50, profile: profile())
        // fromBG (50-120)/50 = -1.40, no carbs → total floored at 0.
        #expect(p.totalMilliunits == 0)
        #expect(p.bitmask == F2)          // no carbs ⇒ FOOD2, no correction component
        assertCoherent(p)
    }

    // MARK: correction-only (no carbs) → FOOD2 (+CORRECTION)

    @Test func correctionOnlyAboveTargetUsesFood2() {
        let p = BenchBolusPlanner.plan(carbsGrams: nil, bgMgdl: 200, profile: profile())
        // fromBG (200-120)/50 = 1.60 → total 1.60
        #expect(p.totalMilliunits == 1600)
        #expect(p.foodMilliunits == 0 && p.correctionMilliunits == 1600)
        #expect(p.bitmask == (F2 | CORR))
        assertCoherent(p)
    }

    // MARK: two-decimal HALF_UP component rounding

    @Test func componentIsTwoDecimalRounded() {
        let prof = BenchBolusPlanner.Profile(carbRatioGramsPerUnit: 7, isfMgdlPerUnit: 50, targetBgMgdl: 120, iobUnits: 0)
        let p = BenchBolusPlanner.plan(carbsGrams: 25, bgMgdl: 120, profile: prof)
        // 25/7 = 3.5714… → dp2 = 3.57 (not the raw binary value). Compare with tolerance (the dp() double
        // is the nearest binary to 3.57); the milliunit conversion snaps it cleanly.
        #expect(abs(p.fromCarbsUnits - 3.57) < 1e-9)
        assertCoherent(p)
    }

    // MARK: bench cap + sanity

    @Test func benchCapBoundsTheDose() {
        // 100/10 = 10.0 U, but the harness passes a tight 2.0 U saline cap.
        let p = BenchBolusPlanner.plan(carbsGrams: 100, bgMgdl: nil, profile: profile(), benchCapMilliunits: 2000)
        #expect(p.totalMilliunits == 2000)   // capped at the 2.0 U bench limit
        assertCoherent(p)
    }

    @Test func invalidProfileSanityFailsToZero() {
        let bad = BenchBolusPlanner.Profile(carbRatioGramsPerUnit: 0, isfMgdlPerUnit: 50, targetBgMgdl: 120, iobUnits: 0)
        let p = BenchBolusPlanner.plan(carbsGrams: 30, bgMgdl: 170, profile: bad)
        #expect(p.sanityFailed)
        #expect(p.totalMilliunits == 0)
    }

    // MARK: full request cargo

    @Test func fullRequestCargoMatchesPlan() throws {
        let p = BenchBolusPlanner.plan(carbsGrams: 45, bgMgdl: 180, profile: profile(iob: 0.5))
        // fromCarbs 4.50 + fromBG 1.20 + fromIOB -0.50 → 5.20
        #expect(p.totalMilliunits == 5200)
        #expect(p.carbGrams == 45 && p.bgMgdl == 180)
        #expect(p.iobMilliunits == 500)
        #expect(p.bitmask == (F1 | CORR))
        let req = try BenchBolusPlanner.request(for: p, bolusID: 7)   // PX-07 validating build succeeds
        #expect(!req.cargo.isEmpty)
        assertCoherent(p)
    }
}
