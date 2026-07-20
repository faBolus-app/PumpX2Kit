import Testing
@testable import PumpX2Messages

/// Builds a 26-byte history-log record with the given header + a tail starting at offset 10.
private func record(typeId: Int, pumpTimeSec: UInt32, seq: UInt32, tail: [UInt8] = []) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 26)
    let t = Bytes.firstTwoBytesLittleEndian(typeId); r[0] = t[0]; r[1] = t[1]
    let pt = Bytes.toUint32(pumpTimeSec); for i in 0..<4 { r[2 + i] = pt[i] }
    let sq = Bytes.toUint32(seq); for i in 0..<4 { r[6 + i] = sq[i] }
    for (i, b) in tail.enumerated() where 10 + i < 26 { r[10 + i] = b }
    return r
}

/// Byte-exact **decode** parity for history-log events: for each ported typeId, build a record,
/// feed the same bytes to the upstream oracle (`cliparser historylog`) and to Swift
/// `HistoryLogParser`, and assert both agree on typeId + concrete class. History logs are
/// decode-only, so matching the upstream decode is the correctness property.
@Suite(.enabled(if: OracleRunner.isAvailable)) struct HistoryLogOracleParityTests {
    static let cases: [(Int, String)] = [
        (280, "BolusDeliveryHistoryLog"), (20, "BolusCompletedHistoryLog"),
        (55, "BolusActivatedHistoryLog"), (59, "BolexActivatedHistoryLog"),
        (21, "BolexCompletedHistoryLog"), (64, "BolusRequestedMsg1HistoryLog"),
        (65, "BolusRequestedMsg2HistoryLog"), (66, "BolusRequestedMsg3HistoryLog"),
        (3, "BasalRateChangeHistoryLog"), (81, "DailyBasalHistoryLog"),
        (2, "TempRateActivatedHistoryLog"), (15, "TempRateCompletedHistoryLog"),
        (48, "CarbEnteredHistoryLog"), (16, "BGHistoryLog"),
        (256, "DexcomG6CGMHistoryLog"), (5, "AlarmActivatedHistoryLog"),
        (4, "AlertActivatedHistoryLog"), (28, "AlarmClearedHistoryLog"),
        (12, "PumpingResumedHistoryLog"), (11, "PumpingSuspendedHistoryLog"),
        (33, "CartridgeFilledHistoryLog"), (61, "CannulaFilledHistoryLog"),
        (63, "TubingFilledHistoryLog"),
    ]

    @Test(arguments: cases)
    func decodeParity(typeId: Int, name: String) throws {
        let rec = record(typeId: typeId, pumpTimeSec: 461_500_000, seq: 42)
        let oracle = try OracleRunner.parseHistoryLog(hex: Hex.encode(rec))
        #expect(oracle.typeId == typeId, "oracle typeId \(oracle.typeId) != \(typeId)")
        #expect(oracle.className == name, "oracle class \(oracle.className) != \(name)")
        let event = HistoryLogParser.parse(record: rec)
        #expect(String(describing: type(of: event)) == name)
        #expect(event.typeId == typeId)
        #expect(event.pumpTimeSec == 461_500_000)
        #expect(event.sequenceNum == 42)
    }
}

/// Direct field-offset tests that don't need the oracle.
@Suite struct HistoryLogEventsTests {
    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    /// Real BolusCompleted wire vector (from upstream BolusCompletedHistoryLogTest): typeId 20,
    /// delivered 1.7869551 u, iob 3.652852 u.
    @Test func bolusCompletedRealVector() {
        let rec = hex("14009ed7971a70d802000300210454c86940f2bae43ff2bae43f")
        #expect(rec.count == 26)
        let event = HistoryLogParser.parse(record: rec)
        let m = try? #require(event as? BolusCompletedHistoryLog)
        #expect(m?.completionStatusId == 3)
        #expect(m?.bolusId == 1057)
        #expect(abs((m?.insulinDelivered ?? 0) - 1.7869551) < 0.0001)
        #expect(abs((m?.iob ?? 0) - 3.652852) < 0.0001)
        #expect(m?.pumpTimeSec == 446_158_750)
        #expect(m?.sequenceNum == 186_480)
    }

    /// An unknown typeId decodes to UnknownHistoryLog while preserving the header.
    @Test func unknownTypeIdFallsBack() {
        let rec = record(typeId: 4095, pumpTimeSec: 123, seq: 9)
        let event = HistoryLogParser.parse(record: rec)
        #expect(event is UnknownHistoryLog)
        #expect(event.pumpTimeSec == 123)
        #expect(event.sequenceNum == 9)
    }

    /// TempRateActivated: percent float@10, tempRateId short@20.
    @Test func tempRateActivatedFields() {
        var tail = [UInt8](repeating: 0, count: 16)
        let pct = Bytes.toFloat(150.0); for i in 0..<4 { tail[i] = pct[i] }         // offset 10
        let id = Bytes.firstTwoBytesLittleEndian(7); tail[10] = id[0]; tail[11] = id[1] // offset 20
        let rec = record(typeId: 2, pumpTimeSec: 500, seq: 1, tail: tail)
        let m = try? #require(HistoryLogParser.parse(record: rec) as? TempRateActivatedHistoryLog)
        #expect(m?.percent == 150.0)
        #expect(m?.tempRateId == 7)
    }
}
