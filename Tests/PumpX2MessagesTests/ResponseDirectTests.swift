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

    /// TempRateStatusResponse: active/id/duration (offsets mirror upstream parse; oracle has no
    /// field constructor so this is a direct test). active@0, tempRateId short@1, start u32@4,
    /// secondsSincePumpReset u32@8, duration u32@12.
    @Test func tempRateStatusOffsets() {
        var cargo = [UInt8](repeating: 0, count: 16)
        cargo[0] = 1  // active
        let id = Bytes.firstTwoBytesLittleEndian(7); cargo[1] = id[0]; cargo[2] = id[1]
        let dur = Bytes.toUint32(1800); for i in 0..<4 { cargo[12 + i] = dur[i] }
        let m = TempRateStatusResponse(cargo: cargo)
        #expect(m.active)
        #expect(m.tempRateId == 7)
        #expect(m.durationSeconds == 1800)
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

    /// HistoryLogStreamResponse: pull completed boluses out of a stream frame. Uses the upstream
    /// `BolusCompletedHistoryLogTest` wire vector (pumpTimeSec 446158750, delivered 1.7869551,
    /// iob 3.652852) to verify the record offsets byte-for-byte.
    @Test func historyLogStreamBolusParsing() {
        func hex(_ s: String) -> [UInt8] {
            var out: [UInt8] = []; var i = s.startIndex
            while i < s.endIndex { let j = s.index(i, offsetBy: 2)
                out.append(UInt8(s[i..<j], radix: 16)!); i = j }
            return out
        }
        let rec = hex("14009ed7971a70d802000300210454c86940f2bae43ff2bae43f")
        #expect(rec.count == 26)
        let cargo: [UInt8] = [1, 3] + rec   // numberOfHistoryLogs=1, streamId=3
        let m = HistoryLogStreamResponse(cargo: cargo)
        let boluses = m.bolusRecords
        #expect(boluses.count == 1)
        #expect(boluses.first?.pumpTimeSec == 446_158_750)
        #expect(boluses.first?.sequenceNum == 186_480)
        #expect(boluses.first?.completionStatusId == 3)
        #expect(abs((boluses.first?.deliveredUnits ?? 0) - 1.7869551) < 0.0001)
        #expect(abs((boluses.first?.iobUnits ?? 0) - 3.652852) < 0.0001)
        #expect(m.cgmReadings.isEmpty)   // a bolus record is not a CGM reading
    }

    /// Alert/alarm bitmaps decode to the right notifications. Bit 0 (Low insulin) + bit 11
    /// (Incomplete bolus) → uint64 with those bits set.
    @Test func alertBitmapDecodes() {
        let bits: UInt64 = (1 << 0) | (1 << 11)
        let m = AlertStatusResponse(cargo: Bytes.toUint64(bits))
        let ns = m.notifications
        #expect(ns.count == 2)
        #expect(ns.contains { $0.id == 0 && $0.kind == .alert && $0.title == "Low insulin" })
        #expect(ns.contains { $0.id == 11 && $0.title == "Incomplete bolus" })
    }

    @Test func alarmBitmapDecodesOcclusion() {
        let m = AlarmStatusResponse(cargo: Bytes.toUint64(1 << 2))
        #expect(m.notifications.count == 1)
        #expect(m.notifications.first?.id == 2)
        #expect(m.notifications.first?.kind == .alarm)
        #expect(m.notifications.first?.title == "Occlusion")
    }

    /// DismissNotificationRequest cargo: notificationId (uint32) + typeId + executeExtraAction.
    @Test func dismissNotificationCargo() {
        let m = DismissNotificationRequest(kind: .alert, notificationId: 21)
        #expect(m.cargo == [21, 0, 0, 0, 1, 0])   // id=21, type=alert(1), flag=0
        #expect(DismissNotificationRequest.props.signed)
        #expect(DismissNotificationRequest.props.characteristic == .control)
        let alarm = DismissNotificationRequest(kind: .alarm, notificationId: 2, executeExtraAction: true)
        #expect(alarm.cargo == [2, 0, 0, 0, 2, 1])
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
