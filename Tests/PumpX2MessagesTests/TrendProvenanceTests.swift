import Testing
@testable import PumpX2Messages

/// C8 / defect E8: faBolus must never *calculate* a trend arrow, and "no trend available" has to render
/// as no arrow rather than an inferred one.
///
/// The authoritative source is `HomeScreenMirrorResponse.cgmTrendIconId` — the icon the pump is showing
/// on its own home screen, which includes an explicit `noArrow` state. The client-side derivation from
/// `CurrentEgvGuiDataV2Response.trendRate` is a fallback and must return `nil` rather than guess.
@Suite struct TrendProvenanceTests {

    // MARK: The pump's own icon (authoritative)

    /// Ids match upstream `HomeScreenMirrorResponse.CGMTrendIcon`.
    @Test func pumpTrendIconMapsEveryDeclaredId() {
        let expected: [(Int, String)] = [
            (0, ""),    // NO_ARROW — the state a derived arrow cannot express
            (1, "⇈"),   // DOUBLE_UP
            (2, "↑"),   // UP
            (3, "↗"),   // UP_RIGHT
            (4, "→"),   // FLAT
            (5, "↘"),   // DOWN_RIGHT
            (6, "↓"),   // DOWN
            (7, "⇊"),   // DOUBLE_DOWN
        ]
        for (id, arrow) in expected {
            var cargo = [UInt8](repeating: 0, count: 9)
            cargo[0] = UInt8(id)
            let m = HomeScreenMirrorResponse(cargo: cargo)
            #expect(m.cgmTrendIconId == id)
            #expect(m.cgmTrendArrow == arrow, "icon id \(id) should render \(arrow.isEmpty ? "no arrow" : arrow)")
        }
    }

    /// An id the pump firmware might add later must degrade to "no arrow", never to a guessed direction.
    @Test func unknownPumpTrendIconRendersNoArrow() {
        for id: UInt8 in [8, 9, 200, 255] {
            var cargo = [UInt8](repeating: 0, count: 9)
            cargo[0] = id
            let m = HomeScreenMirrorResponse(cargo: cargo)
            #expect(m.cgmTrendIcon == nil)
            #expect(m.cgmTrendArrow == "")
        }
    }

    // MARK: The derived fallback

    /// Builds an 8-byte EGV V2 cargo: reading @4 (short), status @6, signed trend rate @7.
    private func egv(reading: Int, status: UInt8, rate: Int8) -> CurrentEgvGuiDataV2Response {
        var cargo = [UInt8](repeating: 0, count: 8)
        let r = Bytes.firstTwoBytesLittleEndian(reading); cargo[4] = r[0]; cargo[5] = r[1]
        cargo[6] = status
        cargo[7] = UInt8(bitPattern: rate)
        return CurrentEgvGuiDataV2Response(cargo: cargo)
    }

    /// The E8 mechanism: `0x7f` is the Dexcom-family "rate unavailable" sentinel, and decoding it as a
    /// rate yields +12.7 mg/dL/min — a double-up arrow while the pump shows none.
    @Test func sentinelRateYieldsNoArrow() {
        let up = egv(reading: 120, status: 1, rate: Int8.max)      // 0x7f
        #expect(up.trendRateIsUnavailable)
        #expect(up.trendRateIfKnown == nil)
        #expect(up.trendArrow == nil, "0x7f must not read as a rapid rise")

        let down = egv(reading: 120, status: 1, rate: Int8.min)    // 0x80
        #expect(down.trendRateIsUnavailable)
        #expect(down.trendArrow == nil)
    }

    /// An INVALID (0) or UNAVAILABLE (4) frame has no usable rate, so it has no arrow — the assignment
    /// used to happen outside the validity check, so garbage still produced an arrow.
    @Test func invalidOrUnavailableFrameYieldsNoArrow() {
        for status: UInt8 in [0, 4] {
            let m = egv(reading: 120, status: status, rate: 20)
            #expect(!m.hasValidReading)
            #expect(m.trendRateIfKnown == nil)
            #expect(m.trendArrow == nil, "status \(status) must not produce an arrow")
        }
    }

    /// Equal magnitudes must produce equal severity. `-3.0` used to map to a single arrow while `+3.0`
    /// fell through the catch-all `default` to double-up.
    @Test func bandsAreSymmetric() {
        // rate is in 0.1 mg/dL/min units, so ±30 == ±3.0 mg/dL/min.
        #expect(egv(reading: 120, status: 1, rate: -30).trendArrow == "⇊")
        #expect(egv(reading: 120, status: 1, rate: 30).trendArrow == "⇈")
        #expect(egv(reading: 120, status: 1, rate: -25).trendArrow == "↓")
        #expect(egv(reading: 120, status: 1, rate: 25).trendArrow == "↑")
        #expect(egv(reading: 120, status: 1, rate: -15).trendArrow == "↘")
        #expect(egv(reading: 120, status: 1, rate: 15).trendArrow == "↗")
        #expect(egv(reading: 120, status: 1, rate: 0).trendArrow == "→")
        #expect(egv(reading: 120, status: 1, rate: -10).trendArrow == "→")
        #expect(egv(reading: 120, status: 1, rate: 10).trendArrow == "→")
    }

    /// A real frame still works: the previously-verified 9-byte Control-IQ+ cargo.
    @Test func realFrameStillDerivesAnArrow() {
        let cargo: [UInt8] = [0xc5, 0x67, 0xe2, 0x22, 0x9e, 0x00, 0x01, 0x04, 0x00]
        let m = CurrentEgvGuiDataV2Response(cargo: cargo)
        #expect(m.trendRate == 4)                    // +0.4 mg/dL/min
        #expect(m.trendRateIfKnown == 0.4)
        #expect(m.trendArrow == "→")                 // steady
    }
}
