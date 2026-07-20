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
| Pairing type | **6-digit JPAKE** (firmware ≫ v7.7, so legacy 16-char does not apply) |

**Implication:** pairing uses the modern EC-JPAKE handshake (`PumpX2Auth.JpakeAuth`, mbedTLS
secp256r1/SHA-256). The legacy 16-char path is retained only for older pumps.

## Validation log

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
- **Pending niceties:** mass/accuracy check at a larger dose; cancel *mid*-
  delivery (extended/large bolus) for partial-delivery reporting.

## Toolchain notes

- Oracle build (cliparser) requires **JDK 17+** — the pinned Gradle 9.x refuses JDK 11.
  This environment uses Homebrew `openjdk@21`; select it via
  `JAVA_HOME=$(/usr/libexec/java_home -v 21)`.
- `swift test` requires the swift-testing framework, which ships with the CLT but needs
  extra search/rpath flags there — use `scripts/test.sh` until full Xcode is installed.
