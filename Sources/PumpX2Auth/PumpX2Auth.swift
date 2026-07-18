import Foundation

/// PumpX2Auth — pump authentication: crypto primitives (`Crypto`), the legacy 16-char
/// pairing handshake (`PairingAuth`), and per-command signing support.
///
/// SAFETY-CRITICAL. The per-command signature authorizes insulin delivery (see
/// `PumpX2Messages.Packetize` for the HMAC-SHA1 signing applied to signed messages). The
/// legacy V1 pairing path is implemented and unit-tested. The modern JPAKE (6-digit) path
/// requires an elliptic-curve J-PAKE implementation and is tracked separately — see the
/// plan's open question.
public enum PumpX2Auth {}
