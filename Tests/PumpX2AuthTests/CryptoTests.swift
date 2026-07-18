import Testing
import PumpX2Messages
@testable import PumpX2Auth

@Suite struct CryptoTests {
    // Known-answer vectors captured from the cliparser oracle (`hmac-sha256`, `hkdf`).
    @Test func hmacSha256KnownAnswer() throws {
        let out = Crypto.hmacSha256(data: try Hex.decode("01020304"), key: try Hex.decode("0a0b0c0d"))
        #expect(Hex.encode(out) == "a0ab311e66ff4ca8d5fa7b60597d93637b3fb86f3ce9a01ceee118a4bf143af2")
    }

    @Test func hkdfKnownAnswer() throws {
        let out = Crypto.hkdf(nonce: try Hex.decode("0011223344556677"),
                              keyMaterial: try Hex.decode("aabbccddeeff"))
        #expect(Hex.encode(out) == "23babb413e58519c975ff4c28f980d11a2051341ca3a67a7ea4394e5c88c1250")
    }

    // Standard RFC/well-known HMAC-SHA1 vector.
    @Test func hmacSha1KnownAnswer() {
        let key = Array("key".utf8)
        let data = Array("The quick brown fox jumps over the lazy dog".utf8)
        #expect(Hex.encode(Crypto.hmacSha1(data: data, key: key))
            == "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9")
    }
}

@Suite struct PairingAuthTests {
    @Test func validLongCodes() throws {
        for code in ["abcdefghijklmnop", "abcd-efgh-ijkl-mnop", "abcd-1234-ijkl-5678",
                     "abcd1234ijkl5678", "abcd-1234-ijkl 5678"] {
            #expect(throws: Never.self) { try PairingAuth.processPairingCode(code) }
        }
    }

    @Test func invalidLongCodes() {
        #expect(throws: PairingAuth.PairingError.self) {
            try PairingAuth.processPairingCode("abcd-!fgh-ijkl-mnop")
        }
        #expect(throws: PairingAuth.PairingError.self) {
            try PairingAuth.processPairingCode("abcd!fghijklmnop")
        }
        #expect(throws: PairingAuth.PairingError.invalidLongPairingCode) {
            try PairingAuth.processPairingCode("123456", type: .long16Char)
        }
    }

    @Test func validShortCodes() throws {
        for code in ["123456", "123 456", "123-456", "123-789"] {
            #expect(throws: Never.self) { try PairingAuth.processPairingCode(code) }
        }
    }

    @Test func invalidShortCodes() {
        #expect(throws: PairingAuth.PairingError.invalidShortPairingCode) {
            try PairingAuth.processPairingCode("123", type: .short6Char)
        }
        #expect(throws: PairingAuth.PairingError.invalidShortPairingCode) {
            try PairingAuth.processPairingCode("1234567", type: .short6Char)
        }
        #expect(throws: PairingAuth.PairingError.invalidShortPairingCode) {
            try PairingAuth.processPairingCode("abcd-efgh-ijkl-mnop", type: .short6Char)
        }
    }

    /// V1 pairing hash: `PumpChallengeRequest.pumpChallengeHash` = HMAC-SHA1(hmacKey, pairingCode).
    @Test func createV1ComputesHash() throws {
        let hmacKey = try Hex.decode("00112233445566778899aabbccddeeff")
        let code = "abcd1234ijkl5678"
        let req = try PairingAuth.createV1(appInstanceId: 0, hmacKey: hmacKey, pairingCode: code)
        #expect(req.appInstanceId == 0)
        #expect(req.pumpChallengeHash == Crypto.hmacSha1(data: hmacKey, key: Array(code.utf8)))
        #expect(req.pumpChallengeHash.count == 20)
        #expect(req.cargo.count == 22)
    }
}
