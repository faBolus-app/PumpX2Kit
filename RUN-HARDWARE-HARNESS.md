# Bench runbook — running the Tier-1 hardware harness

This worktree (`PumpX2Kit-harness-bench`, a dedicated persistent git worktree pinned to the
`harness/pumpx2-hardware-tests` branch tip) is set up so the owner can run the gated
`PumpX2HardwareTests` suite against a real pump. It is already built and its submodules/mbedtls
symlinks are in place. This document is the run procedure for the owner's **current pump config:
NO cartridge, NO CGM.**

> This worktree is checked out **detached** at the harness branch tip (git shows "HEAD detached").
> That is expected — the same branch is checked out in the primary repo, so the bench copy is a
> detached, isolated build/run sandbox. Running tests does not care about the detached state.

---

## ⛔ HARD SAFETY — read every time

- **SALINE OR EMPTY ONLY. NEVER real insulin. NEVER on a body.** This is a bench harness. The pump
  sits on the desk in BLE range of this Mac and nothing else.
- **Both software delivery walls stay armed at all times.** The harness never disables them:
  1. `PumpBLEClient.WritePolicy` defaults to `.readOnly`; the harness elevates the policy only for
     the exact op that needs it, always via `withWritePolicy` (auto-restores `.readOnly`).
  2. `Packetize` `actionsAffectingInsulinDeliveryEnabled` gate — set only for a delivery-class
     message, never globally.
- **No delivery is possible in your current config.** With no cartridge loaded, `HardwareGate.delivery`
  is false, so every delivery case **SKIPS**. There is nothing to dispense and no code path that
  attempts a dose. Delivery is unlocked only by an explicit, three-flag opt-in (see "Enable more
  later"), and even then it is saline-only.
- **A SKIP is a correct, green result** for a config that is not present — it is not a failure.

---

## The one command you run first

```sh
cd /Users/zgranowitz/Code/zgranowitz/PumpX2Kit-harness-bench && \
  PUMPX2_HARDWARE=1 PUMP_PAIRING_CODE=<6 digits from the pump> swift test --filter PumpX2HardwareTests
```

- Replace `<6 digits from the pump>` with the pairing code the pump shows on its screen.
- `PUMPX2_HARDWARE=1` **plus** a non-empty `PUMP_PAIRING_CODE` is what flips `HardwareGate.connected`
  to true and makes the suite actually run. Omit either and the whole suite SKIPS (green) — that is
  the same gate the oracle parity suite uses, so a no-hardware checkout stays green.
- The harness target has **no oracle dependency**, so this filtered run does **not** need Java / the
  cliparser jar. (Only the full `swift test` — see the appendix — needs JDK 21.)
- `swift test` works directly on this Mac (the toolchain bundles the Testing framework). On an older
  Command Line Tools setup where it can't find `Testing.framework`, use `scripts/test.sh --filter
  PumpX2HardwareTests` with the same env — it's a drop-in wrapper that adds the CLT rpath flags.

To keep a durable log of the run (recommended — the console is the primary record; see "Where results
land"):

```sh
mkdir -p bench-runs
cd /Users/zgranowitz/Code/zgranowitz/PumpX2Kit-harness-bench && \
  PUMPX2_HARDWARE=1 PUMP_PAIRING_CODE=<6 digits> swift test --filter PumpX2HardwareTests \
  2>&1 | tee "bench-runs/$(date +%Y-%m-%d-%H%M)-readonly.log"
```

---

## The one human step

1. Put the pump in BLE range of this Mac (on the desk) and wake its screen.
2. Start the command above. It scans, connects, and begins the **EC-JPAKE 6-digit pairing**.
3. When the pump displays the 6-digit code, that is the value you already passed as
   `PUMP_PAIRING_CODE`; **confirm the pairing on the pump screen.** This is required only on the
   **first pair**. The suite pairs once and shares the session across all cases; the reconnect case
   drops the link and re-establishes it via **JPAKE resume (quick-pair)** — no new 6-digit code and
   no second on-screen confirm.

If the pump is out of range / asleep, the connect times out and the suite **skips cleanly** rather
than reporting a false pass.

---

## What runs now vs what skips (NO cartridge, NO CGM)

The suite is `@Suite(.enabled(if: HardwareGate.connected), .serialized)`. See
[`docs/BENCH-SESSION-PLAN.md`](docs/BENCH-SESSION-PLAN.md) for the design-level case list; the source
of truth for the cases is `Tests/PumpX2HardwareTests/BenchCases.swift`.

**RUNS NOW** — the "runnable now" read-only subset (`readOnly(_:)`, gated only by `connected`):

| Case | What it proves |
| --- | --- |
| `pairing-reconnect-state-restoration` | Full 6-digit pair once, then a forced link drop → reconnect → **JPAKE resume**; signing key still derived, reads parse before/after, write policy stayed `.readOnly`. **No delivery.** |
| `read-only-state-and-capability-discovery` | All the status/settings reads parse (API version, time, insulin, battery, basal, IOB, Control-IQ info, profile, IDP, home-screen mirror), the **capability/feature bitmask dump** (derived `controlIQSupported` == bit 1024), and signing timestamp == currentTime. EGV read is parse-only here (tolerant of no-CGM). |
| `txid-match-probe (read-only)` | Whether the pump echoes the request txId in `frame[1]` — echo, distinct-id preservation, and the decisive pipelined same-opcode bijection. **READ-ONLY status reads only**; never pipelines a delivery command. Informs WIP item 12 / BENCH-SESSION-PLAN Obj 2. |

**SKIPS NOW** (correct — the config isn't present):

| Case / suite | Gate that skips it |
| --- | --- |
| `delivery(_:)` → `saline-bolus-1.0u-history-verify`, `temp-basal-80pct-30min-set-read` | `HardwareGate.delivery` — needs cartridge + saline attest + deliver flag |
| `cgm(_:)` → `cgm-live-egv-read`, `cgm-history-records` | `HardwareGate.cgmPresent` — needs a connected sensor |
| `NoCartridgeBolusProbeTests` → `bolusWithoutCartridgeIsRejected()` | opt-in flag `PUMPX2_NO_CARTRIDGE_BOLUS_PROBE` (off) |

### Reading the swift-testing output

- `✔ Test … passed` — the case ran and its assertions held.
- `➜ Test … skipped` / `➜ Suite … skipped` — gated off. **This is the correct, green result for a
  config you don't have** (no cartridge → delivery skips; no CGM → CGM skips). It is **not** a failure.
- `✘ Test … failed` — a real assertion or precondition failure. Investigate (see the message; a
  precondition like "need ≥ 2.0u remaining" or "Control-IQ must be OFF" points at pump state, not a bug).
- The final line summarizes, e.g. `✔ Test run with N tests in M suites passed`.

With no hardware at all, the gate self-check looks like this (verified in this worktree, exit 0):

```
➜ Suite PumpX2HardwareTests skipped.
➜ Suite NoCartridgeBolusProbeTests skipped.
➜ Test readOnly(_:) skipped.
➜ Test cgm(_:) skipped.
➜ Test delivery(_:) skipped.
✔ Test run with 4 tests in 2 suites passed after 0.001 seconds.
```

---

## Enable more later (still saline-only, still on the bench)

Add env flags to the command. Each axis is independent and fail-closed.

**Saline delivery suite** — unlocks `delivery(_:)` (`saline-bolus-1.0u-history-verify` verifies the
dose from the pump's own history log; `temp-basal-…` is Mobi-only and self-SKIPs on a t:slim X2):

```sh
PUMPX2_HARDWARE=1 PUMP_PAIRING_CODE=<6 digits> \
  PUMP_CARTRIDGE_LOADED=1 PUMP_SALINE_ATTESTED=1 PUMPX2_DELIVER_SALINE=1 \
  swift test --filter PumpX2HardwareTests
```

All three flags are required (`HardwareGate.delivery` = connected ∧ cartridge ∧ saline-attested ∧
deliver). `PUMP_SALINE_ATTESTED=1` is **your on-the-pump attestation that the loaded cartridge is
saline** — a read cannot tell saline from insulin, so this is a human safety gate. Confirm saline on
the pump's own screens / t:connect before setting it.

**CGM reads** — unlocks `cgm(_:)` (`cgm-live-egv-read`, `cgm-history-records`) when a sensor is
connected to the pump:

```sh
PUMPX2_HARDWARE=1 PUMP_PAIRING_CODE=<6 digits> PUMP_CGM_PRESENT=1 \
  swift test --filter PumpX2HardwareTests
```

**Opt-in no-cartridge bolus-rejection probe** — its own flag so it never runs by accident. Drives a
bolus command through BOTH walls with **NO cartridge** loaded and records that the pump rejects it;
because a cartridge is guaranteed absent it can never dispense. Requires `PUMPX2_HARDWARE=1`,
`PUMPX2_NO_CARTRIDGE_BOLUS_PROBE=1`, **and** that `PUMP_CARTRIDGE_LOADED` is **unset** (its gate is
`connected ∧ flag ∧ !cartridgeLoaded`):

```sh
PUMPX2_HARDWARE=1 PUMP_PAIRING_CODE=<6 digits> PUMPX2_NO_CARTRIDGE_BOLUS_PROBE=1 \
  swift test --filter PumpX2HardwareTests
```

---

## Where results / traces land, and logging the outcome

- **Primary record: the swift-testing console output.** `passed` / `skipped` / `failed` per case plus
  the run summary. Redirect it to a file with the `tee` form above (`bench-runs/DATE-*.log`) so the
  run is reproducible in the validation log. Full build/test artifacts live under `.build/` (not
  committed).
- **BLE hex trace:** each `LiveSession` captures every outbound/inbound frame in memory
  (`LiveSession.trace`), surfaced in a failing case's message for post-hoc inspection. It is not
  written to a separate file; the `tee`'d console log is your durable copy.
- **Append a dated line to the validation log in [`PINNED.md`](PINNED.md).** Add a bullet under
  `## Validation log`, in the same style as the `2026-07-18` entries. Template:

  ```md
  - **YYYY-MM-DD — Tier-1 read-only harness on hardware.** `swift test --filter PumpX2HardwareTests`
    (PUMPX2_HARDWARE=1, no cartridge, no CGM) against the pinned-firmware pump: pairing + JPAKE-resume
    reconnect PASSED, all read-only/capability cases PASSED, delivery + CGM cases SKIPPED (correct for
    this config). txId-match probe result: <echoed reliably / not echoed>. Log: bench-runs/<file>.
  ```

  If you run the saline delivery objectives, also update WIP register item 5/12 and follow the
  "After the session" checklist in `docs/BENCH-SESSION-PLAN.md`.

---

## Companion plans (context, in `faBolus-internal`)

These live in the sibling repo `faBolus-internal` and give the wider test/edge-case context. They are
reference only — do not edit them from here:

- `/Users/zgranowitz/Code/zgranowitz/faBolus-internal/pump-hardware-test-plan-2026-08-06.md`
- `/Users/zgranowitz/Code/zgranowitz/faBolus-internal/pump-open-questions-2026-08-06.md`
- `/Users/zgranowitz/Code/zgranowitz/faBolus-internal/pump-edge-case-discovery-plan-2026-08-06.md`

In this repo: [`docs/BENCH-SESSION-PLAN.md`](docs/BENCH-SESSION-PLAN.md) is the booked saline-session
plan (the three delivery/txId objectives); `WIP-REGISTER.md` items 5 and 12 track their disposition.

---

## Appendix — full-suite oracle parity (optional, no pump needed)

Running the **entire** `swift test` (not just the harness filter) exercises the byte-exact cliparser
oracle, which needs **JDK 21**. On this Mac JDK 21 is a Homebrew install that `java_home -v 21` does
not see (it falls back to JDK 11), so point `JAVA_HOME` at it directly and build the jar once:

```sh
# one-time: build the oracle jar
cd vendor/pumpx2-oracle && \
  JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :cliparser:shadowJar
# → vendor/pumpx2-oracle/cliparser/build/libs/cliparser.jar

# run the full suite serially (avoids CPU-contention flakes in the wall-clock deadline tests)
cd /Users/zgranowitz/Code/zgranowitz/PumpX2Kit-harness-bench && \
  JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home swift test --no-parallel
```

Run `--no-parallel`: with the oracle spawning many parallel Java subprocesses, the timing-sensitive
`PumpTransactionCoordinatorTests` can miss their wall-clock deadlines and flake; serially the full
suite is green (verified here: 230 tests / 25 suites passed). **Never** set
`PUMPX2_ALLOW_ORACLE_SKIP=1` — that would silently disable byte-parity coverage (the
`OracleAvailabilityGateTests` PX-09 gate exists to prevent exactly that false green).
