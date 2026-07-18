// swift-tools-version: 6.0
// PumpX2Kit — Swift port of the jwoglom/pumpx2 Tandem pump protocol.
// Independent reimplementation. Bench proof-of-concept only. Not affiliated with
// Tandem Diabetes Care or the upstream pumpX2 / controlX2 projects.
import PackageDescription

let package = Package(
    name: "PumpX2Kit",
    platforms: [
        .iOS(.v16),
        .watchOS(.v9),
        .macOS(.v13), // for command-line tests + bench harness
    ],
    products: [
        .library(name: "PumpX2Messages", targets: ["PumpX2Messages"]),
        .library(name: "PumpX2Auth", targets: ["PumpX2Auth"]),
        .library(name: "PumpX2BLE", targets: ["PumpX2BLE"]),
        .executable(name: "PumpX2BenchHarness", targets: ["PumpX2BenchHarness"]),
    ],
    targets: [
        // Portable protocol: framing, opcodes, message models, packetization.
        // No platform dependencies — compiles everywhere.
        .target(name: "PumpX2Messages"),

        // Pairing handshake (legacy CentralChallenge + modern JPAKE) and per-command
        // HMAC signing. Depends on Messages for message shapes and byte helpers.
        .target(name: "PumpX2Auth", dependencies: ["PumpX2Messages"]),

        // Core Bluetooth central transport. Platform-agnostic (iOS + watchOS): imports
        // CoreBluetooth only, never UIKit.
        .target(name: "PumpX2BLE", dependencies: ["PumpX2Messages", "PumpX2Auth"]),

        // Bench/oracle CLI: connect → status → saline bolus → cancel.
        .executableTarget(
            name: "PumpX2BenchHarness",
            dependencies: ["PumpX2Messages", "PumpX2Auth", "PumpX2BLE"]
        ),

        // Tests. The oracle (cliparser) tests live in PumpX2MessagesTests.
        .testTarget(name: "PumpX2MessagesTests", dependencies: ["PumpX2Messages"]),
        .testTarget(name: "PumpX2AuthTests", dependencies: ["PumpX2Auth"]),
        .testTarget(name: "PumpX2BLETests", dependencies: ["PumpX2BLE"]),
    ]
)
