import Foundation

/// Runs the upstream `cliparser` JAR — the byte-level oracle — and returns the packet hex it
/// produces for a given message. Swift-produced bytes are asserted equal to this ("byte-exact
/// or fail"). See `PumpX2Kit/README.md` and Milestone 1a.
///
/// Resolution order (all overridable by env so CI can point at its own build):
///   - JDK:  $PUMPX2_JAVA, else Homebrew openjdk@21, else `java` on PATH.
///   - JAR:  $PUMPX2_ORACLE_JAR, else vendor/pumpx2-oracle/cliparser/build/libs/cliparser.jar.
enum OracleRunner {
    struct EncodeResult: Decodable {
        let messageName: String
        let txId: String
        let packets: [String]
        let characteristicName: String
        let characteristic: String
    }

    enum OracleError: Error, CustomStringConvertible {
        case unavailable(String)
        case failed(String)
        var description: String {
            switch self {
            case .unavailable(let s): return "oracle unavailable: \(s)"
            case .failed(let s): return "oracle failed: \(s)"
            }
        }
    }

    /// Package root, derived from this file's path (…/Tests/PumpX2MessagesTests/OracleRunner.swift).
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PumpX2MessagesTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    static let jarPath: String = {
        if let env = ProcessInfo.processInfo.environment["PUMPX2_ORACLE_JAR"] { return env }
        return packageRoot
            .appendingPathComponent("vendor/pumpx2-oracle/cliparser/build/libs/cliparser.jar")
            .path
    }()

    static let javaPath: String = {
        if let env = ProcessInfo.processInfo.environment["PUMPX2_JAVA"] { return env }
        let brew = "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin/java"
        if FileManager.default.isExecutableFile(atPath: brew) { return brew }
        return "/usr/bin/java"
    }()

    /// True when both the JDK and the built oracle JAR are present. Used to gate oracle tests
    /// so a checkout without a built oracle still runs the rest of the suite.
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: jarPath)
            && FileManager.default.isExecutableFile(atPath: javaPath)
    }

    /// Serializes every cliparser invocation across the whole test run. swift-testing executes
    /// test cases in parallel, so without this the ~45 oracle calls would each spawn a fresh JVM
    /// simultaneously and contend for CPU/memory; on a loaded box that produced transient
    /// "oracle failed: exit 1" / "no JSON in output" failures. One JVM at a time is deterministic
    /// (a single spawn is ~0.25s, so the whole serialized run adds only a few seconds), and the
    /// cache below means identical encode requests never re-spawn.
    private static let processLock = NSLock()

    /// Memoized encode results, keyed on the full request. All access is serialized by
    /// `processLock`, so the concurrency checker's "unsafe" caveat is satisfied by hand.
    nonisolated(unsafe) private static var cache: [String: EncodeResult] = [:]

    /// A fixed legacy pairing code + pump-time used for signed-message parity tests. The HMAC
    /// key for a legacy pairing is the code's ASCII bytes (see PumpStateSupplier), so the same
    /// values fed to Swift Packetize and to the oracle env produce identical signed packets.
    static let testPairingCode = "6VeDeRAL5DCigGw2"   // 16 chars, from an upstream example
    static let testPumpTimeSinceReset: UInt32 = 461_589_180

    /// Runs `cliparser encode <txId> <messageName> <jsonParams>` and returns the parsed result.
    /// For signed messages, pass `pairingCode`/`pumpTimeSinceReset` so the oracle computes the
    /// HMAC with the same key/time as Swift.
    static func encode(
        txId: UInt8,
        messageName: String,
        json: String = "{}",
        pairingCode: String? = nil,
        pumpTimeSinceReset: UInt32? = nil
    ) throws -> EncodeResult {
        guard isAvailable else {
            throw OracleError.unavailable("jar=\(jarPath) java=\(javaPath)")
        }
        let cacheKey = "\(txId)|\(messageName)|\(json)|\(pairingCode ?? "")|\(pumpTimeSinceReset.map(String.init) ?? "")"

        // Serialize the JVM spawn (and guard the cache) so parallel test cases never contend.
        processLock.lock()
        defer { processLock.unlock() }

        if let cached = cache[cacheKey] { return cached }

        var env: [String: String] = [:]
        if let pairingCode { env["PUMP_PAIRING_CODE"] = pairingCode }
        if let pumpTimeSinceReset { env["PUMP_TIME_SINCE_RESET"] = String(pumpTimeSinceReset) }
        let (out, err, status) = try run([
            "-jar", jarPath, "encode", String(txId), messageName, json,
        ], extraEnv: env)
        guard status == 0 else {
            throw OracleError.failed("exit \(status): \(err)")
        }
        // The oracle prints the JSON result on stdout; diagnostics go to stderr.
        guard let line = out.split(separator: "\n").last(where: { $0.contains("\"packets\"") }),
              let data = line.data(using: .utf8) else {
            throw OracleError.failed("no JSON in output: \(out)\n\(err)")
        }
        let result = try JSONDecoder().decode(EncodeResult.self, from: data)
        cache[cacheKey] = result
        return result
    }

    /// Convenience: just the packet hex strings.
    static func encodePackets(txId: UInt8, messageName: String, json: String = "{}") throws -> [String] {
        try encode(txId: txId, messageName: messageName, json: json).packets
    }

    private static func run(_ args: [String], extraEnv: [String: String] = [:]) throws
        -> (out: String, err: String, status: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: javaPath)
        proc.arguments = args
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            proc.environment = env
        }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        // stdout carries the JSON result; stderr carries only short diagnostics for `encode`
        // (well under the 64KB pipe buffer), so a sequential drain is safe here. We deliberately
        // do NOT offload one pipe to a background dispatch queue: `run` executes while holding
        // `processLock`, and swift-testing's parallel cases block on that same lock — grabbing a
        // second dispatch worker under those conditions can starve the pool and deadlock.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self),
            proc.terminationStatus
        )
    }
}
