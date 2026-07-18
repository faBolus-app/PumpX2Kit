import Foundation
import PumpX2Messages
import PumpX2Auth

/// PumpX2BLE — Core Bluetooth central transport for the Tandem pump.
///
/// Platform-agnostic: imports CoreBluetooth only, never UIKit, so the same code runs on
/// iOS and watchOS. Responsibilities (Milestone 1d): scan → connect → bond/encrypt →
/// discover services/characteristics → subscribe notifications → request/response with
/// timeouts + retries, under a single-control-connection model.
public enum PumpX2BLE {
    /// Placeholder marker until the transport is ported. Kept so the target compiles
    /// during scaffolding.
    public static let notYetImplemented = true
}
