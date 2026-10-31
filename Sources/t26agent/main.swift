import CoreGraphics
import Foundation
import SystemConfiguration

// t26-agent
//
// WindowServer owns the menu bar's layer tree and throws it away whenever a
// display sleeps, wakes, is reconfigured or the theme changes. A repair written
// into those layer objects dies with them, so something has to notice the event
// and repair again. That is this process: it watches the cheap, external signs
// (screen unlock, display configuration, wallpaper store) and runs
// `t26 settle --guard N` after each one — repair, then stay attached until the
// rebuild burst is over, then detach.
//
// It never holds the debugger while idle, and it never runs two settles at once.

struct Options {
    var t26 = "/usr/local/bin/t26"
    var guardSeconds = 2
    var full = false
    var grace = 2
    var dryRun = false
    var verbose = false
}

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    print("\(formatter.string(from: Date())) \(message)")
    fflush(stdout)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--t26": index += 1; if index < arguments.count { options.t26 = arguments[index] }
        case "--guard": index += 1; if index < arguments.count { options.guardSeconds = Int(arguments[index]) ?? 8 }
        case "--grace": index += 1; if index < arguments.count { options.grace = Int(arguments[index]) ?? 2 }
        case "--full": options.full = true
        case "--dry-run": options.dryRun = true
        case "-v", "--verbose": options.verbose = true
        case "-h", "--help":
            print("""
            usage: t26-agent [--t26 PATH] [--grace N] [--full [--guard N]] [--dry-run] [-v]

              watches for screen unlock, display configuration changes and
              wallpaper changes, then runs `t26 settle --fast` (one-shot: repair,
              detach, no focus stealing).

              --dry-run   print what would happen, run nothing
              --full      use the guarded settle instead of the one-shot repair
                          (stays attached longer: more reliable, more stutter)
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("t26-agent: unknown argument \(arg)\n".utf8))
            exit(2)
        }
        index += 1
    }
    return options
}

func isLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
}

func displayFingerprint() -> String {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return "" }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return "" }
    return ids.prefix(Int(count)).sorted().map { id in
        let bounds = CGDisplayBounds(id)
        return "\(id):\(Int(bounds.width))x\(Int(bounds.height))@\(Int(bounds.origin.x)),\(Int(bounds.origin.y))"
    }.joined(separator: " ")
}

/// Newest modification time in a file or directory tree. Wallpaper changes only
/// touch these paths, and their mtime moves even when the file content is
/// replaced through a new inode.
func newestMtime(_ path: String) -> Double {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
    let attributes = try? fm.attributesOfItem(atPath: path)
    var newest = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    guard isDirectory.boolValue else { return newest }
    guard let enumerator = fm.enumerator(atPath: path) else { return newest }
    for case let item as String in enumerator {
        if let attributes = try? fm.attributesOfItem(atPath: path + "/" + item),
           let date = attributes[.modificationDate] as? Date {
            newest = max(newest, date.timeIntervalSince1970)
        }
    }
    return newest
}

func wallpaperFingerprint() -> Double {
    let consoleUser = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String? ?? ""
    guard !consoleUser.isEmpty, consoleUser != "loginwindow" else { return 0 }
    let home = "/Users/" + consoleUser
    return [
        home + "/Library/Application Support/com.apple.wallpaper",
        home + "/Library/Application Support/Dock/desktoppicture.db",
    ].map(newestMtime).max() ?? 0
}

let lockPath = "/tmp/t26-agent.lock"

func acquireLock() -> Bool {
    let fd = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    if fd >= 0 {
        close(fd)
        return true
    }
    // A stale lock from a crashed run must not wedge the agent forever.
    if let attributes = try? FileManager.default.attributesOfItem(atPath: lockPath),
       let date = attributes[.modificationDate] as? Date,
       Date().timeIntervalSince(date) > 180 {
        try? FileManager.default.removeItem(atPath: lockPath)
        return open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o600) >= 0
    }
    return false
}

func releaseLock() {
    try? FileManager.default.removeItem(atPath: lockPath)
}

func settle(_ options: Options, reason: String) {
    if options.dryRun {
        log("dry-run: would run \(options.t26) settle \(arguments(options).joined(separator: " "))  (\(reason))")
        return
    }
    guard acquireLock() else {
        log("\(reason): a settle is already running, skipped")
        return
    }
    defer { releaseLock() }
    log("\(reason): repairing (t26 settle \(arguments(options).joined(separator: " ")))")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: options.t26)
    process.arguments = ["settle"] + arguments(options)
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["T26_QUIET": "1"], uniquingKeysWith: { _, new in new })
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        log("\(reason): cannot run \(options.t26): \(error.localizedDescription)")
        return
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    if options.verbose || process.terminationStatus != 0 {
        for line in text.split(separator: "\n") { log("  " + line) }
    }
    log("\(reason): t26 exited with \(process.terminationStatus)")
}

// --- main loop ------------------------------------------------------------

/// One-shot by default: repair, detach, no focus stealing. `--full` falls back to
/// the guarded settle, which stays attached for a while after the repair.
func arguments(_ options: Options) -> [String] {
    options.full ? ["--guard", "\(options.guardSeconds)"] : ["--fast"]
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
log("t26-agent started (t26 \(options.t26), mode \(arguments(options).joined(separator: " ")), grace \(options.grace)s)")

var lastLocked = isLocked()
var lastDisplays = displayFingerprint()
var lastWallpaper = wallpaperFingerprint()
if options.verbose {
    log("locked=\(lastLocked) displays=[\(lastDisplays)] wallpaper=\(Int(lastWallpaper))")
}

while true {
    Thread.sleep(forTimeInterval: 1.0)
    let locked = isLocked()
    let displays = displayFingerprint()
    let wallpaper = wallpaperFingerprint()

    var reason: String?
    if lastLocked && !locked {
        reason = "screen unlocked"
    } else if !displays.isEmpty, displays != lastDisplays {
        reason = "display configuration changed"
    } else if wallpaper != 0, wallpaper != lastWallpaper {
        reason = "wallpaper changed"
    }

    if options.verbose && (displays != lastDisplays || wallpaper != lastWallpaper || locked != lastLocked) {
        log("state locked=\(locked) displays=[\(displays)] wallpaper=\(Int(wallpaper))")
    }
    lastLocked = locked
    lastDisplays = displays
    lastWallpaper = wallpaper

    if let reason {
        // The bar is rebuilt a moment after the event, not instantly: settle
        // repairs on every rebuild, and --guard keeps it attached until the
        // burst is over.
        Thread.sleep(forTimeInterval: Double(options.grace))
        lastLocked = isLocked()
        lastDisplays = displayFingerprint()
        lastWallpaper = wallpaperFingerprint()
        settle(options, reason: reason)
    }
}
