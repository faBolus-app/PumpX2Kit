# PumpX2Kit

A Swift port of the reverse-engineered [`jwoglom/pumpx2`](https://github.com/jwoglom/pumpx2)
protocol for the Tandem **t:slim X2 / Mobi** insulin pump. It provides the shared
protocol / auth / BLE core that the [`faBolus`](../faBolus) app and its watch /
Garmin remotes build on.

> [!WARNING]
> **This is an independent, unofficial reimplementation and a bench proof-of-concept.**
> It is **not** affiliated with, endorsed by, or a fork of Tandem Diabetes Care, the
> `pumpX2` project, or the `controlX2` project. The insulin-dosing path here is our own
> reimplementation and is treated as **unproven**. All testing is done on a **dedicated
> test pump dispensing saline into a container on a scale — never on a body.** On-body
> use is explicitly out of scope.

## Modules

| Target | Purpose |
| --- | --- |
| `PumpX2Messages` | Message framing, opcodes, request/response models, packetization. Portable, no platform deps. |
| `PumpX2Auth` | Pairing handshake (legacy CentralChallenge + modern JPAKE) and per-command HMAC signing. **Safety-critical.** |
| `PumpX2BLE` | Core Bluetooth central: scan / connect / bond / discover / notify. Platform-agnostic (iOS + watchOS). |
| `PumpX2BenchHarness` | Executable bench/oracle CLI: connect → status → saline bolus → cancel. |

## Use it in your project

PumpX2Kit is a reusable SwiftPM package (iOS 16+, watchOS 9+, macOS 13+). Add it as a dependency and
import the products you need:

```swift
// Package.swift
.package(url: "https://github.com/faBolus-app/PumpX2Kit.git", from: "0.1.0")
// then, per target:
.product(name: "PumpX2Messages", package: "PumpX2Kit"),  // message framing + models
.product(name: "PumpX2Auth", package: "PumpX2Kit"),      // pairing (JPAKE/legacy) + HMAC signing
.product(name: "PumpX2BLE", package: "PumpX2Kit"),       // Core Bluetooth transport
```

Typical entry points: `PumpBLEClient` (scan/connect/subscribe/write), `PairingCoordinator`
(JPAKE / legacy pairing), and the request/response types in `PumpX2Messages`. For a worked example
of driving a full connect → status → bolus → cancel flow, see `PumpX2BenchHarness` and the faBolus
app's `TandemBackend` (which adapts this library to faBolus's `PumpBackend` interface). To build a
non-faBolus app on it, depend on these products directly — you don't need faBolus. Contributions go
through PR, not fork; see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## The cliparser oracle

Every outgoing message must **byte-match** the upstream `cliparser` output ("byte-exact or
fail"). The upstream `pumpx2` repo is pinned as a git submodule at `vendor/pumpx2-oracle`
(see [`PINNED.md`](PINNED.md)); its `cliparser` shadow JAR is the byte-level oracle.

Build the oracle (requires **JDK 17+** — the pinned Gradle 9.x will not run on JDK 11):

```sh
cd vendor/pumpx2-oracle
JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :cliparser:shadowJar
# → cliparser/build/libs/cliparser.jar  (shadow/fat jar)
```

Generate reference bytes for a message:

```sh
java -jar cliparser.jar encode <txId> <MessageName> '<jsonParams>'
# prints JSON incl. a "packets" array of hex — the bytes Swift output is compared against
# e.g. encode 0 ApiVersionRequest '{}' → packets ["00002000005a4a"]
```

## Build & test

```sh
swift build
swift test
```

## Status

**Milestone 1 bench definition-of-done met** — read-only monitor, 6-digit JPAKE pairing, and a
signed saline bolus have been validated on real hardware (see [`PINNED.md`](PINNED.md) for the
bench log). Every outgoing message is byte-exact against the `cliparser` oracle in CI.

## The app built on this

[`faBolus`](https://github.com/faBolus-app/faBolus) is the iPhone / Apple Watch app that
consumes PumpX2Kit (the Garmin remote lives in
[`faBolusGarmin`](https://github.com/faBolus-app/faBolusGarmin)). Its documentation — a
no-experience-required build guide, usage, and customization — is the best starting point:

### 👉 https://fabolus.org/
