# AGENTS.md — PumpX2Kit

Working notes for AI coding agents (and humans). Companion to [`llms.txt`](llms.txt) (the map). This is
a Swift port of the Tandem t:slim X2 / Mobi Bluetooth protocol (from jwoglom's pumpX2), consumed by the
faBolus app. **Safety-critical: a wrong byte can misdose insulin.** Read the doc-comment of anything
you touch first.

## The golden rule
Every request's bytes and every response's parse are verified **byte-exact** against the vendored Java
oracle (`vendor/pumpx2-oracle/`). **Never change message bytes without adding/keeping a matching
oracle-parity test.** Doing otherwise can silently misdose.

## Commands
- **Full suite incl. oracle parity:** `./scripts/test.sh` (needs **JDK 21** for the oracle).
- **Swift-only / single test:** `swift test` · `swift test --filter <Name>`
- Golden regeneration + tooling live under `scripts/` / `tools/` where present.

## Layout (SPM products)
- `Sources/PumpX2Messages/` — messages + framing. `Requests/…`, `Responses/Responses.swift`,
  `Core/MessageProps.swift` (per-message `opCode`, `size`, `signed`, `characteristic`,
  `modifiesInsulinDelivery`, `responseOpCode`). `ResponseParser` dispatches on **(characteristic,
  opCode)** — opcodes are NOT globally unique.
- `Sources/PumpX2Auth/` — `PairingCoordinator` (client JPAKE state machine), `JpakeAuth`/
  `EcJpakeContext` (EC-JPAKE via vendored mbedTLS), `Crypto` (HMAC/HKDF).
- `Sources/PumpX2BLE/` — `PumpBLEClient` (CoreBluetooth central; state restoration; the `WritePolicy`
  interlock `.readOnly`/`.allowNonDelivery`/`.allowDelivery`).
- `Tests/PumpX2MessagesTests/` — parity tests (`OracleParityTests`, `ResponseParityTests`, …).

## How to add a message
1. Add the request/response under `Sources/PumpX2Messages/…` with correct `MessageProps` (opcode, size,
   `signed`, `characteristic`, `modifiesInsulinDelivery`, `responseOpCode`).
2. Register the response type in `ResponseParser`.
3. Add a **byte-exact test from an oracle vector** (encode → compare cargo; parse → compare fields).
4. Signed / insulin-affecting messages must set `modifiesInsulinDelivery: true` so the client's
   `WritePolicy` gate applies.

## Conventions
- Match the oracle exactly; each type's doc-comment cites its Java origin. If a field's meaning is
  unverified on-device, say so in the doc-comment — don't guess.
- Swift 6 concurrency: keep CoreBluetooth delegate isolation correct.

## Consumed by
`../faBolus` (the app, via SwiftPM). App-level safety layering + UI live there; the wire format lives
here. Keep them in step.
