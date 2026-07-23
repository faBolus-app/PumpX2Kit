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

    /// allowBenignControl (audit P-01) permits benign signed ops (dismiss alert, find-my-pump) but
    /// still blocks therapy-significant config, destructive commands, and delivery.
    @MainActor @Test func allowBenignControlSeparatesBenignFromSettings() {
        let client = PumpBLEClient()
        client.writePolicy = .allowBenignControl
        // Benign signed control → passes the interlock (fails later only with notReady).
        for msg: Message in [DismissNotificationRequest(kind: .alert, notificationId: 1), PlaySoundRequest()] {
            do { try client.send(msg); Issue.record("expected notReady") }
            catch PumpBLEClient.ClientError.notReady {}
            catch PumpBLEClient.ClientError.writeBlocked { Issue.record("benign op must be allowed under allowBenignControl") }
            catch { Issue.record("unexpected: \(error)") }
        }
        // Therapy-significant config (.settings) and delivery are still blocked.
        #expect(throws: PumpBLEClient.ClientError.self) { try client.send(BolusPermissionRequest()) }
        #expect(throws: PumpBLEClient.ClientError.self) {
            try client.send(InitiateBolusRequest(totalVolume: 1000, bolusID: 1, bolusTypeBitmask: 1))
        }
    }

    /// The operation-risk taxonomy classifies representative messages as expected (audit P-01).
    @Test func operationRiskClassification() {
        #expect(InitiateBolusRequest(totalVolume: 1000, bolusID: 1, bolusTypeBitmask: 1).operationRisk == .delivery)
        #expect(SuspendPumpingRequest().operationRisk == .delivery)   // modifiesInsulinDelivery
        #expect(DismissNotificationRequest(kind: .alert, notificationId: 1).operationRisk == .benign)
        #expect(PlaySoundRequest().operationRisk == .benign)
        #expect(FactoryResetRequest().operationRisk == .destructive)
        #expect(BolusPermissionRequest().operationRisk == .settings)   // signed control, non-dispensing default
    }
}
