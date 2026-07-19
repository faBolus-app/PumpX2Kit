# Pinned upstream

The Swift port tracks a specific, known-good commit of the upstream protocol library. This
is deliberate: for an insulin-delivery path, upstream changes must be reviewed and
bench-revalidated before adoption (see the upstream-sync workflow in the plan / README).

| What | Value |
| --- | --- |
| Upstream repo | [`jwoglom/pumpx2`](https://github.com/jwoglom/pumpx2) |
| Submodule path | `vendor/pumpx2-oracle` |
| Pinned commit | `dad3eea2a3f6ae1bb1a6fdc6b3eac37f3ac7132b` |
| Ported by | Swift port in `Sources/` (hand-ported, not generated) |

## Pump firmware

Recorded from the bench pump's Pump Info screen (2026-07-18). The protocol can break on a
future firmware update; this port is pinned to this firmware and treated as disposable against
vendor changes.

| Field | Value |
| --- | --- |
| Bench pump model | Tandem **t:slim X2** |
| t:slim Software | **Control-IQ+ 7.10.2** |
| ARM S/W Version | `da8923cc9d010d07` |
| MSP S/W Version | `da8923cc9d010d07` |
| S/W Part Number | `1017490 000` |
| Pairing type | **6-digit JPAKE** (firmware ≫ v7.7, so legacy 16-char does not apply) |

**Implication:** pairing uses the modern EC-JPAKE handshake (`PumpX2Auth.JpakeAuth`, mbedTLS
secp256r1/SHA-256). The legacy 16-char path is retained only for older pumps.

## Bench validation log

- **2026-07-18 — read-only monitor PASSED on hardware.** `swift run PumpX2BenchHarness monitor`
  against this pump: BLE scan → connect → discover, **6-digit JPAKE pairing succeeded**
  (signing key derived), and status reads parsed correctly. Insulin-remaining (70 u) and
  battery (35%) matched the pump exactly; all state-changing writes stayed blocked (read-only
  interlock). This validates the full stack — CoreBluetooth transport, EC-JPAKE pairing, and
  response parsing — end to end on the real pump.
  - **Finding:** the pump's displayed IOB matches **`swan6hrIOB`**, not `mudaliarIOB` — so
    `ControlIQIOBResponse.iobUnits` now uses `swan6hrIOB` (4.32 u observed = pump display).
- **Pending:** gravimetric saline bolus + cancel (writes enabled, out of read-only mode).

## Toolchain notes

- Oracle build (cliparser) requires **JDK 17+** — the pinned Gradle 9.x refuses JDK 11.
  This environment uses Homebrew `openjdk@21`; select it via
  `JAVA_HOME=$(/usr/libexec/java_home -v 21)`.
- `swift test` requires the swift-testing framework, which ships with the CLT but needs
  extra search/rpath flags there — use `scripts/test.sh` until full Xcode is installed.
