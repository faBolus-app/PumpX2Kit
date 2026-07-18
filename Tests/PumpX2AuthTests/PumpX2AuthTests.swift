import Testing
@testable import PumpX2Auth

@Suite struct PumpX2AuthScaffoldTests {
    // Placeholder until the auth layer is ported (Milestone 1c). Real tests will validate
    // JPAKE / CentralChallenge and per-command HMAC signing byte-exact against captured
    // traces and pumpX2 test vectors.
    @Test func scaffoldCompiles() {
        #expect(PumpX2Auth.notYetImplemented)
    }
}
