import CoreGraphics
import Darwin
import Foundation

/// Set from the SIGINT handler. Wall-clock truth for "the user pressed Ctrl-C".
var t26Interrupted: Int32 = 0

enum Shell {
    struct Result {
        var status: Int32
        var output: String
    }

    /// Runs a short-lived helper and captures its combined output.
    static func run(_ command: [String]) -> Result {
        guard let exe = command.first else { return Result(status: -1, output: "") }
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            return Result(status: -1, output: "")
        }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = Array(command.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return Result(status: -1, output: "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

enum Spawn {
    /// Runs `argv` in **its own process group** and waits for it.
    ///
    /// The separate group is the whole point: Ctrl-C in the terminal then only
    /// reaches this CLI, never the batch lldb that owns WindowServer — SIGINT
    /// makes lldb kill its target, which would take the desktop down with it.
    static func wait(
        _ argv: [String],
        env: [String: String],
        silenceStdout: Bool = false,
        tick: (() -> Void)? = nil
    ) -> Int32 {
        guard let path = argv.first else { return -1 }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return -1 }
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return -1 }
        defer { posix_spawn_file_actions_destroy(&actions) }
        if silenceStdout {
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        }

        var argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        argvC.append(nil)
        var envC: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envC.append(nil)
        defer {
            for p in argvC where p != nil { free(p) }
            for p in envC where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let rc = path.withCString { cpath in
            posix_spawn(&pid, cpath, &actions, &attr, &argvC, &envC)
        }
        guard rc == 0 else {
            err(Style.red("t26: ") + "cannot start \(path): \(String(cString: strerror(rc)))")
            return -1
        }

        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0 {
                if errno == EINTR { continue }
                break
            }
            usleep(150_000)
            tick?()
        }
        // WIFEXITED & friends are unavailable as Swift functions, so decode by
        // hand: low 7 bits are the signal (0 = exited, 0x7F = stopped).
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal == 0x7f { return (status >> 8) & 0xff }
        return 128 + signal
    }
}

enum Host {
    static var isRoot: Bool { geteuid() == 0 }

    static var macosVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var lldb: String { "/usr/bin/lldb" }

    static func pids(named name: String) -> [Int] {
        let result = Shell.run(["/usr/bin/pgrep", "-x", name])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int($0) }
    }

    static var windowServerPid: Int? { pids(named: "WindowServer").first }

    /// "disabled" / "enabled" / "unknown"
    static func sipStatus() -> String {
        let result = Shell.run(["/usr/bin/csrutil", "status"])
        let text = result.output.lowercased()
        if text.contains("status: disabled") { return "disabled" }
        if text.contains("status: enabled") { return "enabled" }
        return "unknown"
    }

    static var activeDisplays: [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static var consoleUser: String {
        let result = Shell.run(["/usr/bin/stat", "-f", "%Su", "/dev/console"])
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? NSUserName() : name
    }

    /// Absolute path of this executable, with symlinks resolved (needed before
    /// re-exec through sudo and when looking for `libexec` next to it).
    static func executablePath() -> String {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return CommandLine.arguments.first ?? "t26"
        }
        let raw = String(cString: buffer)
        guard let resolved = realpath(raw, nil) else { return raw }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
