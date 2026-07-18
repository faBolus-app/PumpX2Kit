import Foundation
import PumpX2Messages

/// PumpX2Auth — pairing handshake (legacy CentralChallenge/PumpChallenge and modern JPAKE)
/// plus per-command HMAC signing.
///
/// SAFETY-CRITICAL: the per-command signature authorizes insulin delivery. Nothing here
/// drives a pump until it is validated byte-exact against a captured session trace / the
/// pumpX2 test vectors. See Milestone 1c in the plan.
public enum PumpX2Auth {
    /// Placeholder marker until the auth layer is ported. Kept so the target compiles
    /// during scaffolding.
    public static let notYetImplemented = true
}
