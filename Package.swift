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

        // Vendored mbedTLS EC-JPAKE (secp256r1/SHA-256), pinned submodule at
        // vendor/mbedtls (v3.6.7, Apache-2.0). The needed mbedTLS .c files are symlinked into
        // mbedtls_lib/ (see scripts/link-mbedtls.sh) and compiled as separate TUs alongside
        // our shim. Only cmbedtls_jpake.h is exposed to Swift — mbedTLS headers are reached
        // via header search paths, so the full (unparseable-under-min-config) header tree is
        // never turned into a module. Custom minimal config drops PSA/SSL/entropy.
        .target(
            name: "CMbedTLSJPAKE",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../../vendor/mbedtls/include"),
                .headerSearchPath("../../vendor/mbedtls/library"),
                .unsafeFlags(["-DMBEDTLS_CONFIG_FILE=\"mbedtls_config_min.h\""]),
            ]
        ),

        // Pairing handshake (legacy CentralChallenge + modern JPAKE) and per-command
        // HMAC signing. Depends on Messages for message shapes and byte helpers.
        .target(name: "PumpX2Auth", dependencies: ["PumpX2Messages", "CMbedTLSJPAKE"]),
        // (CMbedTLSJPAKE compiles the vendored mbedTLS EC-JPAKE sources; see above.)

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
