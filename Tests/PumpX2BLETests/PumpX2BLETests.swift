import Testing
@testable import PumpX2BLE

@Suite struct PumpX2BLEScaffoldTests {
    // Placeholder until the BLE transport is ported (Milestone 1d). Transport tests that
    // need real hardware run via the bench harness, not here.
    @Test func scaffoldCompiles() {
        #expect(PumpX2BLE.notYetImplemented)
    }
}
