# Open questions & blockers

Running list of things that need a human decision, hardware, or external input. Raised
during the autonomous build so they can be resolved when you're available.

## Blockers needing hardware (deferred to a final bench-test phase)
These are written but **cannot be validated without a physical pump/phone/watch**:

1. **BLE transport end-to-end** (`PumpX2BLE/PumpBLEClient`). Structure follows upstream
   `TandemBluetoothHandler` (service `0000fdfb…`, MTU 185, write-with-response, notify
   reassembly), but scan/connect/bond/discover/notify have never run against a pump. Needs:
   pairing, characteristic discovery on real firmware, MTU behavior, and the exclusive-
   connection handoff with the official app.
2. **Gravimetric bolus accuracy / cancel / interruption** — the Milestone 1 DoD. Requires the
   saline test pump + scale.
3. **Pump firmware version + pairing type** to pin (`PINNED.md` TODO). Determines whether we
   use legacy 16-char pairing (implemented) or JPAKE (not implemented — see below).

## JPAKE (6-digit) pairing — IMPLEMENTED (crypto validated in-process)
4. **Resolved approach:** vendored **mbedTLS `ecjpake`** (v3.6.7 submodule, secp256r1/SHA-256)
   as a C-interop target (`CMbedTLSJPAKE`), wrapped by `PumpX2Auth.JpakeAuth`. Both pairing
   paths now exist: legacy 16-char (`PairingAuth.createV1`) and modern 6-digit JPAKE.
   - JPAKE wire messages `Jpake1a…4` ported (framing byte-exact vs oracle).
   - Crypto validated by an **in-process client↔server handshake deriving equal secrets** +
     rounds-3/4 HMAC key confirmation (`JpakeTests`).
   - **Remaining validation (not blocking further build):**
     (a) **Oracle interop** — drive the oracle's `jpake-server` (stdin/stdout ping-pong) with
         our Swift client and confirm the derived secret matches the server's. This proves
         compatibility with the pump's exact implementation (upstream uses mbedTLS via
         Particle, so interop is expected). Deferred; good CI/bench step.
     (b) **Bench** — real pairing against the test pump.
   - **Question:** the app should auto-select pairing type; confirm the bench pump's exact
     firmware so we pin it (`PINNED.md`).

## Decisions to confirm
5. **Repo visibility** — both repos were created **private** on GitHub (sensible default for a
   medical-device reverse-engineering PoC). Change if you want them public.
6. **Response parsing scope.** Outgoing (request) messages are byte-exact vs the oracle. Full
   *response* parsing (`PacketArrayList`/`BTResponseParser` + response models) is only
   partially needed for the harness/app and is being ported on demand. Which pump reads does
   the app UI actually need to display first (IOB, battery, insulin remaining, last bolus)?
7. **Courtesy heads-up to jwoglom** about this independent reimplementation (mentioned in the
   handoff) — do you want to do that, and when?

## Environment notes (resolved)
- Full Xcode 26.6 installed; `xcode-select` still points at CLT (needs
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`) — using `DEVELOPER_DIR`
  meanwhile. **License acceptance needs sudo** (`sudo xcodebuild -license accept`) before app
  builds — pending.
- Simulator runtimes were still downloading at last check.
