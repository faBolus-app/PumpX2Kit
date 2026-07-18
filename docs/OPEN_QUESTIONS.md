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

## Blocker needing a crypto decision
4. **JPAKE (6-digit) pairing is NOT implemented.** Modern t:slim X2 firmware (v7.7+, API 3.2+)
   and Mobi use an elliptic-curve J-PAKE handshake. Upstream relies on the native
   `io.particle.crypto.EcJpake` library; there's no drop-in Swift equivalent.
   **Question:** which pairing does the bench pump use? If JPAKE, we need to either (a) port
   an EC J-PAKE implementation to Swift (significant, safety-critical crypto — likely over
   secp256r1; would validate against the oracle's `jpake`/`jpake-server` commands), or
   (b) confirm the bench pump can use legacy 16-char pairing. The legacy path
   (`PairingAuth.createV1`) is done and unit-tested.
   - The JPAKE *wire* message classes (`Jpake1a…4`) are not yet ported either; only the
     legacy `CentralChallenge`/`PumpChallenge` messages are.

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
