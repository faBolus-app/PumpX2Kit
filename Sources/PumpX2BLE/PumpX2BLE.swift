import Foundation

/// PumpX2BLE — Core Bluetooth central transport for the Tandem pump.
///
/// Platform-agnostic: imports CoreBluetooth only, never UIKit, so the same code runs on iOS
/// and watchOS. Entry point is `PumpBLEClient`; `PacketReassembler` handles inbound
/// multi-packet reassembly. NOT yet hardware-tested (no pump/phone available) — the
/// connection flow follows upstream `TandemBluetoothHandler` and must be bench-validated
/// before driving a pump.
public enum PumpX2BLE {}
