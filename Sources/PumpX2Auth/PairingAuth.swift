import Foundation
import PumpX2Messages

/// The two legacy pairing code formats. Port of `models/PairingCodeType`.
/// - LONG_16CHAR: t:slim X2 before firmware v7.7 (alphanumeric).
/// - SHORT_6CHAR: t:slim X2 v7.7+ (6 digits, used with JPAKE).
public enum PairingCodeType: String, Sendable {
    case long16Char = "LONG_16CHAR"
    case short6Char = "SHORT_6CHAR"

    /// Strips separators/invalid characters. LONG keeps [A-Za-z0-9]; SHORT keeps [0-9].
    public func filterCharacters(_ pairingCode: String) -> String {
        pairingCode.filter { c in
            switch self {
            case .long16Char: return c.isLetter && c.isASCII || (c.isNumber && c.isASCII)
            case .short6Char: return c.isNumber && c.isASCII
            }
        }
    }
}

/// Legacy (V1 / 16-char) pairing handshake helper. Port of the V1 path of
/// `builders/PumpChallengeRequestBuilder`.
///
/// The V2 (JPAKE / 6-digit) path is NOT implemented here — it requires an elliptic-curve
/// J-PAKE implementation (upstream uses `io.particle.crypto.EcJpake`). See `JpakeAuth` and
/// the plan's open question about the crypto library.
public enum PairingAuth {
    public enum PairingError: Error, Equatable {
        case invalidLongPairingCode
        case invalidShortPairingCode
        case invalidType
    }

    /// Validates + normalizes a pairing code to the given type's canonical form.
    public static func processPairingCode(_ pairingCode: String, type: PairingCodeType) throws -> String {
        switch type {
        case .long16Char:
            let p = type.filterCharacters(pairingCode)
            guard p.count == 16 else { throw PairingError.invalidLongPairingCode }
            return p
        case .short6Char:
            let p = type.filterCharacters(pairingCode)
            guard p.count == 6 else { throw PairingError.invalidShortPairingCode }
            return p
        }
    }

    /// Auto-detects the type (6-digit → SHORT, else LONG) and normalizes.
    public static func processPairingCode(_ pairingCode: String) throws -> String {
        if pairingCode.count == 6 || PairingCodeType.short6Char.filterCharacters(pairingCode).count == 6 {
            return try processPairingCode(pairingCode, type: .short6Char)
        }
        return try processPairingCode(pairingCode, type: .long16Char)
    }

    /// V1 pairing: given the pump's `hmacKey` (from CentralChallengeResponse), the
    /// `appInstanceId`, and the 16-char pairing code, produces the `PumpChallengeRequest`.
    ///
    /// The hash is `HMAC-SHA1(data = hmacKey, key = pairingCode UTF-8 bytes)` (note the
    /// argument order — the pairing code is the HMAC key), matching `createV1`.
    public static func createV1(
        appInstanceId: Int,
        hmacKey: [UInt8],
        pairingCode: String
    ) throws -> PumpChallengeRequest {
        let pairingChars = try processPairingCode(pairingCode, type: .long16Char)
        let challengeHash = Crypto.hmacSha1(data: hmacKey, key: Array(pairingChars.utf8))
        return PumpChallengeRequest(appInstanceId: appInstanceId, pumpChallengeHash: challengeHash)
    }
}
