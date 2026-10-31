import Foundation

struct EngineRequest {
    var mode: String
    var seconds: Int
    var pattern: String?
    var deep: Bool
    var settleMin: Int?
    var settleMax: Int?
    var guardSeconds: Int?
    var fast: Bool
    var displays: Int
    var log: String
    var pid: Int?
}

struct EngineOutcome {
    var status: Int32
    var seconds: Double
    var summary: RunSummary?
}

enum Engine {
    /// Spawns the privileged engine and mirrors its log into the terminal.
    ///
    /// The engine is run in its own process group (see `Spawn.wait`), with its
    /// stdout thrown away: everything interesting already goes to the log, and
    /// this way the CLI can format it. Only the engine's stderr (a real failure,
    /// e.g. "must run as root") reaches the user untouched.
    static func run(_ request: EngineRequest, layout: Layout, json: Bool) -> EngineOutcome {
        var env = ProcessInfo.processInfo.environment
        env["T26_MODE"] = request.mode
        env["T26_LOG"] = request.log
        env["T26_QUIET"] = "1"
        env["T26_SECS"] = "\(request.seconds)"
        env["T26_DEEP"] = request.deep ? "1" : "0"
        if let pattern = request.pattern { env["T26_PATTERN"] = pattern }
        if let value = request.settleMin { env["T26_SETTLE_MIN"] = "\(value)" }
        if let value = request.settleMax { env["T26_SETTLE_MAX"] = "\(value)" }
        if let value = request.guardSeconds { env["T26_GUARD"] = "\(value)" }
        if request.displays > 0 { env["T26_DISPLAYS"] = "\(request.displays)" }
        if request.fast {
            env["T26_ONCE"] = "1"
            if env["T26_GUARD"] == nil { env["T26_GUARD"] = "2" }
            if env["T26_SETTLE_MIN"] == nil { env["T26_SETTLE_MIN"] = "1" }
            // A one-shot run has no reason to sit attached for long: the hook
            // gives up on its own after a few seconds, this is only the backstop.
            if request.seconds > 15 { env["T26_SECS"] = "15" }
        }
        if let pid = request.pid { env["T26_PID"] = "\(pid)" }

        var tail = LogTail(path: request.log)
        let startedAt = Date()
        let since = Int(startedAt.timeIntervalSince1970) - 1
        var warned = false

        func drain() {
            tail.pump { line in
                if !json { out(Style.dim("  · ") + line) }
            }
        }

        let status = Spawn.wait(
            [layout.engine, request.mode, "-s", "\(request.seconds)"],
            env: env,
            silenceStdout: true
        ) {
            drain()
            if t26Interrupted != 0 && !warned {
                warned = true
                err(warn("Ctrl-C ignored — SIGINT would make lldb kill WindowServer"))
                err(Style.dim("  the run finishes and detaches by itself; to force it: sudo t26 abort"))
            }
        }
        drain()

        return EngineOutcome(
            status: status,
            seconds: Date().timeIntervalSince(startedAt),
            summary: RunSummary.lastRun(path: request.log, mode: request.mode, since: since)
        )
    }
}
