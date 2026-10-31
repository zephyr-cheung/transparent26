import Darwin
import Foundation

// MARK: - output helpers

func printJSON(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )) ?? Data("{}".utf8)
    out(String(decoding: data, as: UTF8.self))
}

func isoTime(_ epoch: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

// MARK: - privileges

func execSudo(_ argv: [String]) -> Never {
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execv("/usr/bin/sudo", &cargs)
    die("cannot re-exec through sudo: \(String(cString: strerror(errno)))", .blocked)
}

/// Commands that touch WindowServer need root. Rather than telling the user to
/// type `sudo` themselves, re-exec through it — except when a test target was
/// named with --pid, which needs no privileges.
func ensureRoot(_ options: Options) {
    if Host.isRoot { return }
    if options.pid != nil { return }
    if options.noSudo {
        die("this command needs root: run it with sudo", .blocked)
    }

    let exe = Host.executablePath()
    let passthrough = ["T26_LIBEXEC", "T26_ENGINE", "T26_HOOK", "T26_AGENT",
                       "T26_LOG", "T26_PID", "T26_PATTERN"]
        .compactMap { key -> String? in
            guard let value = ProcessInfo.processInfo.environment[key] else { return nil }
            return "\(key)=\(value)"
        }
    let original = Array(CommandLine.arguments.dropFirst())
    var argv = ["sudo"]
    if passthrough.isEmpty {
        argv += ["--", exe] + original
    } else {
        argv += ["/usr/bin/env"] + passthrough + [exe] + original
    }
    execSudo(argv)
}

func preflight(_ options: Options, layout: Layout) {
    guard FileManager.default.isExecutableFile(atPath: layout.engine) else {
        die(Layout.missingMessage(), .blocked)
    }
    guard FileManager.default.isExecutableFile(atPath: Host.lldb) else {
        die("lldb not found at /usr/bin/lldb — install the Command Line Tools: xcode-select --install", .blocked)
    }
    if options.pid != nil { return }

    if !options.ignoreSIP {
        let sip = Host.sipStatus()
        if sip != "disabled" {
            die("""
            SIP is \(sip). Debugging WindowServer needs it disabled.
                 Disable it in recoveryOS (csrutil disable), or try --ignore-sip.
            """, .blocked)
        }
    }
    guard Host.windowServerPid != nil else {
        die("WindowServer is not running", .noWindowServer)
    }
}

// MARK: - settle / fix / diagnostics

func runEngineCommand(_ options: Options, layout: Layout) -> Never {
    ensureRoot(options)
    preflight(options, layout: layout)

    let mode = options.command.rawValue
    let seconds = options.seconds ?? options.command.defaultSeconds
    let pid = options.pid ?? Host.windowServerPid ?? 0
    let displays = Host.activeDisplays
    let target = options.pid == nil
        ? "WindowServer (pid \(pid), \(displays.count) display\(displays.count == 1 ? "" : "s"))"
        : "pid \(pid)"

    if !options.json {
        out(Style.bold("t26 \(t26Version)") + Style.dim(" · \(mode)"))
        out(row("target", target))
        if options.command.modifiesWindowServer {
            out(row("pattern", options.pattern ?? "MenuBarBackdrop"))
            var budget: String
            if options.fast {
                budget = "\(seconds)s · one-shot: detach as soon as every display is repaired"
            } else if mode == "settle" {
                budget = "\(seconds)s · detach from ≥\(options.settleMin ?? 4)s to ≤\(options.settleMax ?? 60)s"
            } else {
                budget = "\(seconds)s · the debugger stays attached"
            }
            if mode == "settle", let guardSeconds = options.guardSeconds {
                budget += " · guard \(guardSeconds)s of quiet"
            }
            out(row("budget", budget))
        }
        out(row("log", options.log))
        out()
    }

    let request = EngineRequest(
        mode: mode,
        seconds: seconds,
        pattern: options.pattern,
        deep: options.deep,
        settleMin: options.settleMin,
        settleMax: options.settleMax,
        guardSeconds: options.guardSeconds,
        fast: options.fast,
        displays: Host.activeDisplays.count,
        log: options.log,
        pid: options.pid
    )
    let outcome = Engine.run(request, layout: layout, json: options.json)
    finish(options, outcome, layout: layout)
}

/// Turns the engine outcome into the final report and the exit code.
func finish(_ options: Options, _ outcome: EngineOutcome, layout: Layout) -> Never {
    let summary = outcome.summary

    if outcome.status == 5 {
        err(bad("the debugger could not be detached — WindowServer may still be stopped"))
        err(Style.dim("  run: sudo t26 abort"))
        exit(ExitCode.engine.rawValue)
    }

    var code = ExitCode.ok
    var headline = ""
    var rows: [(String, String)] = []
    var notes: [String] = []

    switch options.command {
    case .settle:
        let hidden = summary?.layersNeutralised ?? 0
        let passes = summary?.passes ?? 0
        let confirmed = summary?.confirmedDisplays
        let total = summary?.displaysTotal
        let breakpoints = summary?.breakpointsDisabled ?? 0
        let timedOut = summary?.doneReason?.hasPrefix("timed out") ?? false

        if hidden > 0 {
            headline = ok("menu bar backdrop removed — \(elapsed(outcome.seconds))")
            let span = (confirmed != nil && total != nil) ? " across \(confirmed!)/\(total!) display(s)" : ""
            rows.append(("hidden", "\(hidden) layer(s)\(span), \(passes) repair pass(es)"))
            rows.append(("debugger", breakpoints > 0
                ? "detached, \(breakpoints) breakpoint(s) disabled — WindowServer runs at full speed"
                : "detached — WindowServer runs at full speed"))
            rows.append(("untouched", "text, icons, status items, pills, shadow"))
            rows.append(("undo", "log out or reboot (nothing is persisted)"))
            if timedOut || (confirmed != nil && total != nil && confirmed! < total!) {
                let confirmedText = confirmed.map { "\($0)" } ?? "1"
                notes.append(warn("\(confirmedText)/\(total ?? 1) display(s) confirmed — that screen may stay frosted"))
                notes.append(Style.dim("  give it more time: sudo t26 settle -s 90 --settle-max 90"))
                if options.strict { code = .blocked }
            }
        } else {
            code = .failed
            headline = bad("no matching backdrop layer was neutralised (\(elapsed(outcome.seconds)))")
            notes.append(Style.dim("  force a rebuild by clicking the Apple menu, then retry"))
            notes.append(Style.dim("  inspect the tree: sudo t26 tree"))
        }

    case .fix:
        let hidden = summary?.layersNeutralised ?? 0
        if hidden > 0 {
            headline = ok("\(hidden) layer(s) neutralised over \(elapsed(outcome.seconds))")
            rows.append(("passes", "\(summary?.passes ?? 0) rebuild(s) repaired"))
            rows.append(("debugger", "still attached — WindowServer stutters on every rebuild"))
            rows.append(("next", "sudo t26 settle leaves it transparent with no debugger"))
        } else {
            code = .failed
            headline = bad("nothing matched in \(elapsed(outcome.seconds))")
            notes.append(Style.dim("  click the Apple menu once to force a rebuild, then retry"))
        }

    case .tree:
        let trees = summary?.trees ?? 0
        if trees > 0 {
            headline = ok("dumped \(trees) menu bar CALayer tree(s) — nothing was modified")
            rows.append(("read it", "the backdrop is a sibling of text / icons / pills"))
            rows.append(("log", options.log))
        } else {
            code = .failed
            headline = bad("no layer tree was dumped (\(elapsed(outcome.seconds)))")
            notes.append(Style.dim("  force a rebuild by clicking the Apple menu, then retry"))
        }

    case .probe:
        let matched = summary?.matched ?? 0
        if matched > 0 {
            headline = ok("\(matched) layer name(s) logged — nothing was modified")
            rows.append(("pattern", options.pattern ?? "MenuBarBackdrop"))
            rows.append(("log", options.log))
        } else {
            code = .failed
            headline = bad("no layer name matched '\(options.pattern ?? "MenuBarBackdrop")' — nothing was modified")
            notes.append(Style.dim("  check what names exist: sudo t26 tree"))
        }

    case .hunt:
        let hunted = summary?.hunted ?? 0
        headline = hunted > 0
            ? ok("\(hunted) setter call(s) from the menu bar code — nothing was modified")
            : bad("no menu bar setter call was seen — nothing was modified")
        if hunted == 0 { code = .failed }
        rows.append(("log", options.log))

    case .theme:
        let themed = summary?.themed ?? 0
        headline = themed > 0
            ? ok("\(themed) CoreUI-rendered layer(s) logged — nothing was modified")
            : bad("no CoreUI layer was painted — nothing was modified")
        if themed == 0 { code = .failed }
        rows.append(("log", options.log))

    default:
        headline = ok("done")
    }

    if let warnings = summary?.warnings, !warnings.isEmpty, options.verbose {
        for warning in warnings.prefix(5) {
            notes.append(Style.yellow("  " + warning))
        }
    }

    if options.json {
        var object: [String: Any] = [
            "command": options.command.rawValue,
            "ok": code == .ok,
            "milliseconds": Int((outcome.seconds * 1000).rounded()),
            "exitCode": Int(code.rawValue),
            "log": options.log,
            "engineStatus": Int(outcome.status),
        ]
        if let summary {
            object["summary"] = [
                "mode": summary.mode,
                "pid": summary.pid,
                "epoch": summary.epoch,
                "layersHidden": summary.layersNeutralised,
                "layersHiddenAuthoritative": summary.hidden,
                "passes": summary.passes,
                "hits": summary.hits,
                "matched": summary.matched,
                "trees": summary.trees,
                "hunted": summary.hunted,
                "themed": summary.themed,
                "breakpointsDisabled": summary.breakpointsDisabled,
                "displaysConfirmed": summary.confirmedDisplays as Any,
                "displaysTotal": summary.displaysTotal as Any,
                "settled": summary.settled,
                "done": summary.doneReason ?? "",
                "warnings": summary.warnings,
            ]
        }
        printJSON(object)
        exit(code.rawValue)
    }

    out(headline)
    for (name, value) in rows {
        out(row(name, value))
    }
    if !notes.isEmpty {
        out()
        for note in notes { out(note) }
    }
    if code == .ok, options.command.modifiesWindowServer {
        out()
        out(Style.dim("  switch between displays and apps to check your work; if the glass ever"))
        out(Style.dim("  returns, run: sudo t26 settle"))
    }
    exit(code.rawValue)
}

// MARK: - status

func commandStatus(_ options: Options, layout: Layout?) -> Never {
    let sip = Host.sipStatus()
    let displays = Host.activeDisplays
    let windowServer = Host.windowServerPid
    let lastRun = RunSummary.lastRun(path: options.log, mode: nil)
    let age = lastRun.map { Int(Date().timeIntervalSince1970) - $0.epoch } ?? 0

    if options.json {
        var object: [String: Any] = [
            "version": t26Version,
            "macos": Host.macosVersion,
            "sip": sip,
            "root": Host.isRoot,
            "windowServerPid": windowServer as Any,
            "displays": displays.map { Int($0) },
            "engine": layout?.engine ?? "",
            "hook": layout?.hook ?? "",
            "log": options.log,
            "lldb": FileManager.default.isExecutableFile(atPath: Host.lldb),
        ]
        if let lastRun {
            object["lastRun"] = [
                "epoch": lastRun.epoch,
                "when": isoTime(lastRun.epoch),
                "ageSeconds": age,
                "mode": lastRun.mode,
                "pid": lastRun.pid,
                "layersHidden": lastRun.layersNeutralised,
                "passes": lastRun.passes,
                "settled": lastRun.settled,
                "displaysConfirmed": lastRun.confirmedDisplays as Any,
                "displaysTotal": lastRun.displaysTotal as Any,
                "done": lastRun.doneReason ?? "",
            ]
        }
        printJSON(object)
        exit(ExitCode.ok.rawValue)
    }

    out(Style.bold("t26 \(t26Version)") + Style.dim(" · macOS \(Host.macosVersion) · \(Host.consoleUser)"))
    out(row("SIP", sip == "disabled" ? ok("disabled") : bad(sip)))
    out(row("privileges", Host.isRoot ? "root" : "user (t26 re-execs through sudo)"))
    out(row("WindowServer", windowServer.map { "pid \($0)" } ?? bad("not running")))
    let displayList = displays.prefix(4).map { "0x" + String($0, radix: 16) }.joined(separator: ", ")
    out(row("displays", displays.isEmpty ? bad("none") : "\(displays.count) (\(displayList))"))
    out(row("lldb", FileManager.default.isExecutableFile(atPath: Host.lldb) ? Host.lldb : bad("missing")))
    if let layout {
        out(row("engine", FileManager.default.fileExists(atPath: layout.engine) ? layout.engine : bad(layout.engine)))
        out(row("hook", FileManager.default.fileExists(atPath: layout.hook) ? layout.hook : bad(layout.hook)))
    } else {
        out(row("engine", bad("not found — run: sudo make install")))
    }
    if let lastRun {
        let confirmed = lastRun.confirmedDisplays
        let displaysText = confirmed != nil ? ", \(confirmed!)/\(lastRun.displaysTotal) display(s)" : ""
        let what: String
        if lastRun.settled {
            what = "\(lastRun.layersNeutralised) layer(s) hidden\(displaysText)"
        } else if lastRun.layersNeutralised > 0 {
            what = "\(lastRun.layersNeutralised) layer(s) repaired\(displaysText) — no verdict"
        } else {
            what = lastRun.doneReason ?? "no verdict"
        }
        out(row("last run", "\(lastRun.mode) · \(ago(age)) · \(what)"))
    } else {
        out(row("last run", Style.dim("none — sudo t26 settle")))
    }
    out(row("log", options.log))
    exit(ExitCode.ok.rawValue)
}

// MARK: - doctor

private enum CheckState { case pass, warn, fail }

private struct Check {
    let name: String
    let state: CheckState
    let detail: String
    let remedy: String?
}

func commandDoctor(_ options: Options, layout: Layout?) -> Never {
    var checks: [Check] = []
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let sip = Host.sipStatus()
    let windowServer = Host.windowServerPid
    let displays = Host.activeDisplays

    checks.append(Check(
        name: "macOS",
        state: version.majorVersion >= 14 ? .pass : .warn,
        detail: "\(Host.macosVersion) — menu bar uses SkyLight backdrop layers",
        remedy: version.majorVersion >= 14 ? nil : "layer names below macOS 14 are untested: sudo t26 tree"
    ))
    checks.append(Check(
        name: "SIP",
        state: sip == "disabled" ? .pass : (sip == "enabled" ? .fail : .warn),
        detail: sip,
        remedy: sip == "enabled"
            ? "disable it in recoveryOS: csrutil disable, then reboot"
            : (sip == "unknown" ? "could not read csrutil status" : nil)
    ))
    checks.append(Check(
        name: "WindowServer",
        state: windowServer == nil ? .fail : .pass,
        detail: windowServer.map { "pid \($0), \(displays.count) display(s)" } ?? "not running",
        remedy: windowServer == nil ? "log out and back in" : nil
    ))
    let lldb = FileManager.default.isExecutableFile(atPath: Host.lldb)
    checks.append(Check(
        name: "lldb",
        state: lldb ? .pass : .fail,
        detail: lldb ? Host.lldb : "missing",
        remedy: lldb ? nil : "xcode-select --install"
    ))
    if let layout {
        let engine = FileManager.default.isExecutableFile(atPath: layout.engine)
        checks.append(Check(
            name: "engine",
            state: engine ? .pass : .fail,
            detail: engine ? layout.engine : "not executable: \(layout.engine)",
            remedy: engine ? nil : "sudo make install"
        ))
        let hook = FileManager.default.fileExists(atPath: layout.hook)
        checks.append(Check(
            name: "hook",
            state: hook ? .pass : .fail,
            detail: hook ? layout.hook : "missing: \(layout.hook)",
            remedy: hook ? nil : "sudo make install"
        ))
        let fifo = FileManager.default.fileExists(atPath: layout.control)
        checks.append(Check(
            name: "session",
            state: fifo ? .warn : .pass,
            detail: fifo ? "a run looks active (\(layout.control) exists)" : "no run in progress",
            remedy: fifo ? "wait for it, or hand WindowServer back: sudo t26 abort" : nil
        ))
    } else {
        checks.append(Check(
            name: "engine",
            state: .fail,
            detail: "not found",
            remedy: "sudo make install"
        ))
    }
    let logDir = (options.log as NSString).deletingLastPathComponent
    let logWritable = FileManager.default.isWritableFile(atPath: logDir)
    checks.append(Check(
        name: "log dir",
        state: logWritable ? .pass : .fail,
        detail: logDir,
        remedy: logWritable ? nil : "use --log with a writable path"
    ))
    checks.append(Check(
        name: "privileges",
        state: .pass,
        detail: Host.isRoot ? "root" : "user — t26 re-execs through sudo when needed",
        remedy: nil
    ))

    let failures = checks.filter { $0.state == .fail }

    if options.json {
        printJSON([
            "ok": failures.isEmpty,
            "checks": checks.map { check in
                [
                    "name": check.name,
                    "state": check.state == .pass ? "pass" : (check.state == .warn ? "warn" : "fail"),
                    "detail": check.detail,
                    "remedy": check.remedy ?? "",
                ] as [String: Any]
            },
        ])
        exit(failures.isEmpty ? ExitCode.ok.rawValue : ExitCode.blocked.rawValue)
    }

    out(Style.bold("t26 \(t26Version)") + Style.dim(" · doctor"))
    for check in checks {
        let mark: String
        switch check.state {
        case .pass: mark = ok(check.detail)
        case .warn: mark = warn(check.detail)
        case .fail: mark = bad(check.detail)
        }
        out(row(check.name, mark))
    }
    if !failures.isEmpty {
        out()
        for check in failures where check.remedy != nil {
            out(Style.yellow("  \(check.name): ") + check.remedy!)
        }
        exit(ExitCode.blocked.rawValue)
    }
    out()
    out(Style.dim("  ready — sudo t26 settle"))
    exit(ExitCode.ok.rawValue)
}

// MARK: - logs

func commandLogs(_ options: Options, layout: Layout?) -> Never {
    let path = options.log
    guard FileManager.default.fileExists(atPath: path) else {
        die("no log at \(path) — nothing has run yet", .failed)
    }

    if options.follow {
        // Replace the process: tail then owns the terminal and Ctrl-C stops it.
        let parts: [String] = ["/usr/bin/tail", "-n", "\(options.lines ?? 20)", "-f", path]
        var cargs: [UnsafeMutablePointer<CChar>?] = parts.map { strdup($0) }
        cargs.append(nil)
        execv("/usr/bin/tail", &cargs)
        die("cannot run tail", .failed)
    }

    let runs = RunSummary.allRuns(path: path)
    guard !runs.isEmpty else {
        die("\(path) has no runs in it", .failed)
    }
    let selected = options.all ? runs : Array(runs.suffix(1))
    for (index, run) in selected.enumerated() {
        if index > 0 { out() }
        out(Style.bold("\(run.mode)") + Style.dim(" · \(isoTime(run.epoch)) · pid \(run.pid)"))
        let lines = options.lines.map { Array(run.lines.suffix($0)) } ?? run.lines
        for line in lines {
            var text = line
            if text.hasPrefix("t26: ") { text.removeFirst(5) }
            out(Style.dim("  ") + text)
        }
    }
    exit(ExitCode.ok.rawValue)
}

// MARK: - abort

func commandAbort(_ options: Options, layout: Layout?) -> Never {
    ensureRoot(options)
    let fifo = layout?.control ?? "/tmp/t26-ctl"
    guard FileManager.default.fileExists(atPath: fifo) else {
        out(Style.dim("no run in progress (no \(fifo))"))
        exit(ExitCode.ok.rawValue)
    }
    guard let handle = FileHandle(forWritingAtPath: fifo) else {
        die("cannot open \(fifo) — run this with sudo", .blocked)
    }
    handle.write("process detach\n".data(using: .utf8)!)
    try? handle.close()
    out(ok("detach requested — the running session will hand WindowServer back"))
    exit(ExitCode.ok.rawValue)
}

func commandVersion() -> Never {
    out("t26 \(t26Version)")
    exit(ExitCode.ok.rawValue)
}

// --- agent ---------------------------------------------------------------

let agentLabel = "local.t26.agent"
let agentPlist = "/Library/LaunchDaemons/\(agentLabel).plist"

func agentPlistBody(agent: String, t26: String, guardSeconds: Int, full: Bool = false) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(agentLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(agent)</string>
            <string>--t26</string><string>\(t26)</string>
            <string>--guard</string><string>\(guardSeconds)</string>\(full ? "\n            <string>--full</string>" : "")
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ProcessType</key><string>Background</string>
        <key>StandardOutPath</key><string>/tmp/t26-agent.log</string>
        <key>StandardErrorPath</key><string>/tmp/t26-agent.log</string>
    </dict>
    </plist>

    """
}

func commandAgent(_ options: Options, layout: Layout) -> Never {
    let action = options.agentAction
    let guardSeconds = options.guardSeconds ?? 8

    switch action {
    case "status":
        let installed = FileManager.default.fileExists(atPath: agentPlist)
        let print = Shell.run(["/bin/launchctl", "print", "system/\(agentLabel)"])
        let running = print.output.contains("state = running")
        let pidLine = print.output.split(separator: "\n")
            .first { $0.contains("pid = ") }?
            .trimmingCharacters(in: .whitespaces) ?? ""

        if options.json {
            printJSON([
                "installed": installed,
                "running": running,
                "pid": pidLine.replacingOccurrences(of: "pid = ", with: ""),
                "plist": agentPlist,
                "agent": layout.agent ?? "",
                "log": "/tmp/t26-agent.log",
            ])
            exit(ExitCode.ok.rawValue)
        }
        out(Style.bold("t26 \(t26Version)") + Style.dim(" · agent"))
        out(row("installed", installed ? ok(agentPlist) : warn("no — sudo t26 agent install")))
        out(row("running", running ? ok(pidLine) : warn("no")))
        out(row("binary", layout.agent.map(ok) ?? warn("missing — sudo make install")))
        out(row("log", "/tmp/t26-agent.log"))
        out()
        if installed && running {
            out(Style.dim("  repairs again after an unlock, a display change or a wallpaper change."))
        }
        exit(ExitCode.ok.rawValue)

    case "install":
        ensureRoot(options)
        guard let agent = layout.agent, FileManager.default.isExecutableFile(atPath: agent) else {
            die("the agent binary is missing: install first with `sudo make install`", .blocked)
        }
        let t26 = Host.executablePath()
        do {
            try agentPlistBody(agent: agent, t26: t26, guardSeconds: guardSeconds,
                               full: options.fullAgent)
                .write(toFile: agentPlist, atomically: true, encoding: .utf8)
        } catch {
            die("cannot write \(agentPlist): \(error.localizedDescription)", .failed)
        }
        _ = Shell.run(["/bin/launchctl", "bootout", "system/\(agentLabel)"])
        let boot = Shell.run(["/bin/launchctl", "bootstrap", "system", agentPlist])
        if boot.status != 0 {
            die("launchctl bootstrap failed: \(boot.output.trimmingCharacters(in: .whitespacesAndNewlines))", .failed)
        }
        out(ok("agent installed — repairs again after unlock / display change / wallpaper change"))
        out(row("watch", "unlock · display configuration · wallpaper store"))
        out(row("mode", options.fullAgent
                ? "\(t26) settle --guard \(guardSeconds) (guarded)"
                : "\(t26) settle --fast (one-shot)"))
        out(row("log", "/tmp/t26-agent.log"))
        out(row("remove", "sudo t26 agent uninstall"))
        exit(ExitCode.ok.rawValue)

    case "uninstall":
        ensureRoot(options)
        _ = Shell.run(["/bin/launchctl", "bootout", "system/\(agentLabel)"])
        try? FileManager.default.removeItem(atPath: agentPlist)
        try? FileManager.default.removeItem(atPath: "/tmp/t26-agent.lock")
        out(ok("agent removed — nothing runs in the background any more"))
        exit(ExitCode.ok.rawValue)

    case "run":
        guard let agent = layout.agent else {
            die("the agent binary is missing: install first with `sudo make install`", .blocked)
        }
        var argv = [agent, "--t26", Host.executablePath(), "--guard", "\(guardSeconds)"]
        if Host.isRoot == false { argv.insert("sudo", at: 0) }
        let status = Spawn.wait(argv, env: ProcessInfo.processInfo.environment)
        exit(status == 0 ? ExitCode.ok.rawValue : ExitCode.failed.rawValue)

    default:
        die("unknown agent action '\(action)' — install, uninstall, status or run", .usage)
    }
}
