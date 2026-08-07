# Pinned upstream

The Swift port tracks a specific, known-good commit of the upstream protocol library. This
is deliberate: for an insulin-delivery path, upstream changes must be reviewed and
re-validated before adoption (see the upstream-sync workflow in the plan / README).

| What | Value |
| --- | --- |
| Upstream repo | [`jwoglom/pumpx2`](https://github.com/jwoglom/pumpx2) |
| Submodule path | `vendor/pumpx2-oracle` |
| Pinned commit | `dad3eea2a3f6ae1bb1a6fdc6b3eac37f3ac7132b` |
| Ported by | Swift port in `Sources/` (hand-ported, not generated) |

## Pump firmware

Recorded from the pump's Pump Info screen (2026-07-18). The protocol can break on a
future firmware update; this port is pinned to this firmware and treated as disposable against
vendor changes.

| Field | Value |
| --- | --- |
| Pump model | Tandem **t:slim X2** |
| t:slim Software | **Control-IQ+ 7.10.2** |
| ARM S/W Version | `da8923cc9d010d07` |
| MSP S/W Version | `da8923cc9d010d07` |
| S/W Part Number | `1017490 000` |
| Pairing type | **6-digit JPAKE** (firmware ≫ v7.7) |

**Implication:** pairing uses the modern EC-JPAKE handshake (`PumpX2Auth.JpakeAuth`, mbedTLS
secp256r1/SHA-256).

## Spare bench pump — legacy V1 (pre-v7.7), 16-char pairing (added 2026-08-07)

There is now a **SECOND, distinct** pump on the bench: a spare **t:slim X2** running **older
firmware (< v7.7)** that pairs with a **16-character alphanumeric pairing code** via the **legacy V1
CentralChallenge → PumpChallenge** handshake — NOT the 6-digit EC-JPAKE scheme the primary pump
above uses. Discovered while bringing the spare up on the hardware harness; the V1 library support
this needed now exists (`PairingAuth.createV1`, `LegacyPairingCoordinator`, op-17/19 parsers,
`PairingAuth.detectType`), and `LiveSession.beginPairing()` auto-selects V1 vs JPAKE from the code.

> **The two pumps are DIFFERENT FIRMWARE FAMILIES and must be validated separately.** A behavior
> observed on one (capability bitmask contents, "Mobi-only" write acceptance, remote time-set,
> txId-match, API-version-gated message variants) does **not** transfer to the other. The harness
> captures a `PumpFirmwareProfile` (API version + pump SW version + auth scheme) and prints it at the
> top of each run — **every validation-log entry below must record which pump/firmware it was
> observed on** (see the log's tagging rule).

## Validation log

> **Tagging rule (required):** every entry must state the **pump + firmware + pairing scheme** it was
> observed on — e.g. `[t:slim X2 · CIQ+ 7.10.2 · JPAKE]` or `[t:slim X2 · <fw> · V1/16-char]`. Results
> are firmware-scoped; an untagged entry is ambiguous now that two firmware families are on the bench.
> The 2026-07-18 entries below all refer to the **primary** pump `[t:slim X2 · CIQ+ 7.10.2 · JPAKE]`.

- **2026-07-18 — read-only monitor PASSED on hardware.** `swift run PumpX2BenchHarness monitor`
  against this pump: BLE scan → connect → discover, **6-digit JPAKE pairing succeeded**
  (signing key derived), and status reads parsed correctly. Insulin-remaining (70 u) and
  battery (35%) matched the pump exactly; all state-changing writes stayed blocked (read-only
  interlock). This validates the full stack — CoreBluetooth transport, EC-JPAKE pairing, and
  response parsing — end to end on the real pump.
  - **Finding:** the pump's displayed IOB matches **`swan6hrIOB`**, not `mudaliarIOB` — so
    `ControlIQIOBResponse.iobUnits` now uses `swan6hrIOB` (4.32 u observed = pump display).
- **2026-07-18 — additional reads confirmed on hardware:** glucose (CGM EGV V2), basal, last
  bolus, and the bolus-calculator snapshot (carb ratio, ISF, target BG) all matched the pump
  screens. Signing timestamp = `TimeSinceResetResponse.currentTime`.
- **2026-07-18 — SIGNED WRITE validated on hardware (permission test):** a signed
  BolusPermissionRequest was ACCEPTED (granted=true) and released — no insulin delivered.
- **2026-07-18 — 🎯 MILESTONE 1 DoD MET: signed bolus delivered.** `bolus 100` delivered
  **0.10 u**: permission → signed InitiateBolus (FOOD2) accepted → LastBolusStatus
  reported 0.10 u (id 1774); the **pump screen agreed**. Signed CancelBolus round-trips.
  Full delivery path (BLE + JPAKE + signed permission + signed initiate + status + cancel) is
  proven on the real pump, with every outgoing message byte-exact vs the cliparser oracle.
- **Pending niceties — BOOKED as one saline session, see [`docs/BENCH-SESSION-PLAN.md`](docs/BENCH-SESSION-PLAN.md):**
  cancel *mid*-delivery (extended/large bolus) for partial-delivery reporting (group B indeterminate
  case, WIP item 5); whether the pump echoes the request txId in `frame[1]` (WIP item 12, gates
  retiring R3-D delivery-class serialization); and a mass/accuracy check at a larger dose. Bundled
  because all three need the same pump+saline+Mac setup — run in one sitting, not piecemeal.

## Toolchain notes

- Oracle build (cliparser) requires **JDK 17+** — the pinned Gradle 9.x refuses JDK 11.
  This environment uses Homebrew `openjdk@21`; select it via
  `JAVA_HOME=$(/usr/libexec/java_home -v 21)`.
- `swift test` requires the swift-testing framework, which ships with the CLT but needs
  extra search/rpath flags there — use `scripts/test.sh` until full Xcode is installed.
