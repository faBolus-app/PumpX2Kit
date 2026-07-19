import Testing
@testable import PumpX2Messages

/// Direct (non-oracle) parse tests for responses whose oracle encoding is awkward (many
/// constructor args) or whose real firmware cargo is longer than the base size. Offsets mirror
/// upstream `parse()`.
@Suite struct ResponseDirectTests {
    /// BolusCalcDataSnapshotResponse: verify carbRatio / isf / targetBg offsets.
    @Test func bolusCalcSnapshotOffsets() {
        var cargo = [UInt8](repeating: 0, count: 46)
        // targetBg (short @9) = 110
        let tb = Bytes.firstTwoBytesLittleEndian(110); cargo[9] = tb[0]; cargo[10] = tb[1]
        // isf (short @11) = 40
        let isf = Bytes.firstTwoBytesLittleEndian(40); cargo[11] = isf[0]; cargo[12] = isf[1]
        cargo[13] = 1  // carbEntryEnabled
        // carbRatio (uint32 @14) = 10000  (10 g/u ×1000)
        let cr = Bytes.toUint32(10000); for i in 0..<4 { cargo[14 + i] = cr[i] }
        // maxBolusAmount (short @18) = 25000 milliunits
        let mb = Bytes.firstTwoBytesLittleEndian(25000); cargo[18] = mb[0]; cargo[19] = mb[1]

        let m = BolusCalcDataSnapshotResponse(cargo: cargo)
        #expect(m.targetBg == 110)
        #expect(m.isf == 40)
        #expect(m.carbEntryEnabled)
        #expect(m.carbRatio == 10000)
        #expect(m.carbRatioGramsPerUnit == 10.0)
        #expect(m.maxBolusAmount == 25000)
    }

    /// HistoryLogStatusResponse: count + first/last sequence numbers (uint32 LE @0/4/8).
    @Test func historyLogStatusOffsets() {
        var cargo = [UInt8](repeating: 0, count: 12)
        let n = Bytes.toUint32(50_000);  for i in 0..<4 { cargo[0 + i] = n[i] }
        let f = Bytes.toUint32(1_000);   for i in 0..<4 { cargo[4 + i] = f[i] }
        let l = Bytes.toUint32(50_999);  for i in 0..<4 { cargo[8 + i] = l[i] }
        let m = HistoryLogStatusResponse(cargo: cargo)
        #expect(m.numEntries == 50_000)
        #expect(m.firstSequenceNum == 1_000)
        #expect(m.lastSequenceNum == 50_999)
    }

    /// HistoryLogStreamResponse: pull CGM readings out of a stream frame, skipping non-CGM
    /// records. Builds one Dexcom G6 CGM record (typeId 256) and one non-CGM record (typeId 1).
    @Test func historyLogStreamCgmParsing() {
        func record(typeId: Int, pumpTimeSec: UInt32, seq: UInt32, mgdl: Int) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 26)
            let t = Bytes.firstTwoBytesLittleEndian(typeId); r[0] = t[0]; r[1] = t[1]
            let pt = Bytes.toUint32(pumpTimeSec); for i in 0..<4 { r[2 + i] = pt[i] }
            let sq = Bytes.toUint32(seq);         for i in 0..<4 { r[6 + i] = sq[i] }
            let g = Bytes.firstTwoBytesLittleEndian(mgdl); r[16] = g[0]; r[17] = g[1]
            return r
        }
        let cgm = record(typeId: 256, pumpTimeSec: 555_000, seq: 42, mgdl: 142)
        let other = record(typeId: 1, pumpTimeSec: 555_060, seq: 43, mgdl: 0)
        let cargo: [UInt8] = [2, 7] + cgm + other   // numberOfHistoryLogs=2, streamId=7

        let m = HistoryLogStreamResponse(cargo: cargo)
        #expect(m.numberOfHistoryLogs == 2)
        #expect(m.streamId == 7)
        #expect(m.records.count == 2)
        let readings = m.cgmReadings
        #expect(readings.count == 1)
        #expect(readings.first?.glucoseMgdl == 142)
        #expect(readings.first?.pumpTimeSec == 555_000)
        #expect(readings.first?.sequenceNum == 42)
    }

    /// EGV V2 parses a 9-byte cargo (Control-IQ+ firmware appends a trailing byte); a VALID
    /// status (1) with an in-range reading is displayable.
    @Test func egvV2NineByteCargo() {
        // From a real pump frame c1 08 09 | c5 67 e2 22 9e 00 01 04 00 | crc
        let cargo: [UInt8] = [0xc5, 0x67, 0xe2, 0x22, 0x9e, 0x00, 0x01, 0x04, 0x00]
        let m = CurrentEgvGuiDataV2Response(cargo: cargo)
        #expect(m.cgmReading == 158)
        #expect(m.egvStatusId == 1)   // VALID
        #expect(m.trendRate == 4)
        #expect(m.hasValidReading)
    }
}
