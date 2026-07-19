import Testing
import PumpX2Messages
@testable import PumpX2Auth

@Suite struct JpakeTests {
    /// End-to-end in-process EC-JPAKE handshake: a client and server sharing the same 6-digit
    /// code must derive an identical pre-master secret. Proves the mbedTLS integration + shim
    /// + RNG work. (Interop with the pump's implementation is validated via the oracle
    /// jpake-server handshake / bench.)
    @Test func inProcessHandshakeDerivesEqualSecret() throws {
        let secret = JpakeAuth.pairingCodeToBytes("123456")
        let client = try EcJpakeContext(role: .client, secret: secret)
        let server = try EcJpakeContext(role: .server, secret: secret)

        let cR1 = try client.writeRoundOne()
        let sR1 = try server.writeRoundOne()
        #expect(cR1.count == 330)   // secp256r1 round one
        try client.readRoundOne(sR1)
        try server.readRoundOne(cR1)

        let cR2 = try client.writeRoundTwo()
        let sR2 = try server.writeRoundTwo()
        try client.readRoundTwo(sR2)
        try server.readRoundTwo(cR2)

        let cSecret = try client.deriveSecret()
        let sSecret = try server.deriveSecret()
        #expect(cSecret.count == 32)
        #expect(cSecret == sSecret)
    }

    /// A wrong pairing code derives a DIFFERENT secret (EC-JPAKE's security property — the
    /// rounds still succeed; the mismatch is caught by round-3/4 key confirmation).
    @Test func mismatchedCodeDerivesDifferentSecret() throws {
        let client = try EcJpakeContext(role: .client, secret: JpakeAuth.pairingCodeToBytes("123456"))
        let server = try EcJpakeContext(role: .server, secret: JpakeAuth.pairingCodeToBytes("654321"))
        let cR1 = try client.writeRoundOne(), sR1 = try server.writeRoundOne()
        try client.readRoundOne(sR1); try server.readRoundOne(cR1)
        let cR2 = try client.writeRoundTwo(), sR2 = try server.writeRoundTwo()
        try client.readRoundTwo(sR2); try server.readRoundTwo(cR2)
        let a = try client.deriveSecret(), b = try server.deriveSecret()
        #expect(a != b)   // different passwords → different keys
    }

    /// JpakeAuth produces the 1a/1b split and round-2 request shapes.
    @Test func jpakeAuthProducesRoundMessages() throws {
        let auth = try JpakeAuth(pairingCode: "123456")
        let (r1a, r1b) = try auth.makeRound1Requests()
        #expect(r1a.centralChallenge.count == 165)
        #expect(r1b.centralChallenge.count == 165)
        #expect(r1a.cargo.count == 167 && r1b.cargo.count == 167)
    }

    /// Rounds 3–4: authKey = HKDF(serverNonce, derivedSecret); round-4 HMAC + server verify.
    @Test func round4KeyConfirmation() throws {
        let auth = try JpakeAuth(pairingCode: "123456")
        // Simulate a completed rounds 1–2 by running an in-process handshake through JpakeAuth.
        let server = try EcJpakeContext(role: .server, secret: JpakeAuth.pairingCodeToBytes("123456"))
        let (r1a, r1b) = try auth.makeRound1Requests()
        let sR1 = try server.writeRoundOne()
        try server.readRoundOne(r1a.centralChallenge + r1b.centralChallenge)
        let mid = sR1.count / 2
        try auth.readServerRound1(challenge1a: Array(sR1[0..<mid]), challenge1b: Array(sR1[mid...]))
        let r2 = try auth.makeRound2Request()
        let sR2 = try server.writeRoundTwo()
        try server.readRoundTwo(r2.centralChallenge)
        try auth.readServerRound2(challenge: sR2)
        let clientSecret = try auth.derive()
        let serverSecret = try server.deriveSecret()
        #expect(clientSecret == serverSecret)

        // Round 3/4: server picks a nonce; client computes confirmation; server verifies +
        // responds; client verifies server.
        let serverNonce3 = JpakeAuth.randomBytes(8)
        let req4 = auth.makeRound4Request(serverNonce3: serverNonce3)
        let expectedClientHash = Crypto.hmacSha256(
            data: req4.nonce, key: Crypto.hkdf(nonce: serverNonce3, keyMaterial: serverSecret))
        #expect(req4.hashDigest == expectedClientHash)          // server-side check would pass

        let serverNonce4 = JpakeAuth.randomBytes(8)
        let serverHash = Crypto.hmacSha256(
            data: serverNonce4, key: Crypto.hkdf(nonce: serverNonce3, keyMaterial: serverSecret))
        #expect(throws: Never.self) {
            try auth.verifyServerRound4(serverNonce4: serverNonce4, serverHashDigest: serverHash)
        }
        #expect(auth.authKey == Crypto.hkdf(nonce: serverNonce3, keyMaterial: serverSecret))
    }
}
