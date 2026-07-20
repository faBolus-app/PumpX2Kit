import Testing
import PumpX2Messages
@testable import PumpX2BLE

@Suite struct WritePolicyInterlockTests {
    /// Default policy is read-only: CONTROL / signed / insulin-affecting messages are refused
    /// before anything is written — first sessions physically cannot command a bolus.
    @MainActor @Test func readOnlyBlocksAllWrites() {
        let client = PumpBLEClient()
        #expect(client.writePolicy == .readOnly)   // safe by default
        for msg: Message in [InitiateBolusRequest(totalVolume: 1000, bolusID: 1, bolusTypeBitmask: 1),
                             CancelBolusRequest(bolusId: 1), BolusPermissionRequest()] {
            #expect(throws: PumpBLEClient.ClientError.self) { try client.send(msg) }
        }
    }

    /// Status reads pass the interlock (fail only with notReady, not writeBlocked).
    @MainActor @Test func readOnlyAllowsStatusReads() {
        let client = PumpBLEClient()
        do { try client.send(ControlIQIOBRequest()); Issue.record("expected notReady") }
        catch PumpBLEClient.ClientError.notReady {}
        catch PumpBLEClient.ClientError.writeBlocked { Issue.record("read must not be blocked") }
        catch { Issue.record("unexpected: \(error)") }
    }

    /// allowNonDelivery permits signed non-dispensing writes (BolusPermission) but STILL
    /// hard-blocks insulin delivery (InitiateBolus). This is the mode for the signature test.
    @MainActor @Test func allowNonDeliveryBlocksOnlyDelivery() {
        let client = PumpBLEClient()
        client.writePolicy = .allowNonDelivery

        // InitiateBolus modifies insulin delivery → still blocked.
        #expect(throws: PumpBLEClient.ClientError.self) {
            try client.send(InitiateBolusRequest(totalVolume: 1000, bolusID: 1, bolusTypeBitmask: 1))
        }
        // BolusPermission is signed CONTROL but non-dispensing → passes interlock (notReady).
        do { try client.send(BolusPermissionRequest()); Issue.record("expected notReady") }
        catch PumpBLEClient.ClientError.notReady {}
        catch PumpBLEClient.ClientError.writeBlocked { Issue.record("permission must be allowed in allowNonDelivery") }
        catch { Issue.record("unexpected: \(error)") }
    }
}
