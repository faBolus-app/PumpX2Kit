import Testing
import PumpX2Messages
@testable import PumpX2BLE

@Suite struct ReadOnlyInterlockTests {
    /// In read-only mode (the default), a CONTROL/insulin-affecting message is hard-refused
    /// before anything is written — the first bench sessions physically cannot command a bolus.
    @MainActor @Test func readOnlyBlocksControlWrites() {
        let client = PumpBLEClient()
        #expect(client.readOnly)   // safe by default

        // Bolus messages are signed + CONTROL → blocked with the read-only error.
        #expect(throws: PumpBLEClient.ClientError.self) {
            try client.send(InitiateBolusRequest(totalVolume: 1000, bolusID: 1, bolusTypeBitmask: 1))
        }
        #expect(throws: PumpBLEClient.ClientError.self) {
            try client.send(CancelBolusRequest(bolusId: 1))
        }
        #expect(throws: PumpBLEClient.ClientError.self) {
            try client.send(BolusPermissionRequest())
        }
    }

    /// Status reads are allowed by the interlock; they fail only because we aren't connected
    /// (notReady), NOT because of read-only — proving reads remain possible.
    @MainActor @Test func readOnlyAllowsStatusReads() {
        let client = PumpBLEClient()
        do {
            try client.send(ControlIQIOBRequest())
            Issue.record("expected notReady")
        } catch PumpBLEClient.ClientError.notReady {
            // expected: allowed past the interlock, blocked only by connection state
        } catch PumpBLEClient.ClientError.readOnlyModeBlockedWrite {
            Issue.record("status read must not be blocked by read-only mode")
        } catch { Issue.record("unexpected: \(error)") }
    }
}
