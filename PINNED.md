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

**TODO (Milestone 1):** record the exact t:slim X2 / Mobi firmware version of the bench
pump the port is validated against. The protocol can break on a future firmware update;
this port is pinned to the tested firmware and treated as disposable against vendor changes.

| Bench pump model | _TBD_ |
| Firmware version | _TBD_ |
| Pairing type | _TBD (legacy 16-char CentralChallenge vs. modern 6-digit JPAKE)_ |

## Toolchain notes

- Oracle build (cliparser) requires **JDK 17+** — the pinned Gradle 9.x refuses JDK 11.
  This environment uses Homebrew `openjdk@21`; select it via
  `JAVA_HOME=$(/usr/libexec/java_home -v 21)`.
- `swift test` requires the swift-testing framework, which ships with the CLT but needs
  extra search/rpath flags there — use `scripts/test.sh` until full Xcode is installed.
