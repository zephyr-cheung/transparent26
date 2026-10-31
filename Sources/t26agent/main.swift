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
    var bootRepair = true
    var cooldown = 90
    var events: Set<String> = ["unlock", "wallpaper"]
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
        case "--no-boot": options.bootRepair = false
        case "--cooldown": index += 1; if index < arguments.count { options.cooldown = Int(arguments[index]) ?? 90 }
        case "--events":
            index += 1
            if index < arguments.count {
                options.events = Set(arguments[index].split(separator: ",").map(String.init))
            }
        case "--dry-run": options.dryRun = true
        case "-v", "--verbose": options.verbose = true
        case "-h", "--help":
            print("""
            usage: t26-agent [--t26 PATH] [--grace N] [--full [--guard N]] [--dry-run] [-v]

              watches for screen unlock and wallpaper changes, then runs
              `t26 settle --fast` (one-shot: repair, detach, no focus stealing).
              Display-configuration changes are off by default because a display
              going to sleep looks like one, and repairing on every wake is more
              stutter than it is worth.

              --dry-run   print what would happen, run nothing
              --full      use the guarded settle instead of the one-shot repair
                          (stays attached longer: more reliable, more stutter)
              --no-boot   do not repair when the agent starts or a user logs in
              --events a,b  which events repair: unlock, wallpaper, display
                            (default: unlock,wallpaper)
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

/// The user whose session is on the console, or "" before anyone logs in.
func consoleUser() -> String {
    let user = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String? ?? ""
    return user == "loginwindow" ? "" : user
}

/// Hash of the wallpaper *contents*, not of their timestamps: macOS rewrites the
/// store (and touches its mtime) for reasons that have nothing to do with the
/// user picking a new picture, and treating those as wallpaper changes made the
/// agent repair in a loop.
func fnv(_ data: Data) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data {
        hash = (hash ^ UInt64(byte)) &* 0x100000001b3
    }
    return hash
}

func wallpaperFingerprint() -> UInt64 {
    let user = consoleUser()
    guard !user.isEmpty else { return 0 }
    let home = "/Users/" + user
    let paths = [
        home + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist",
        home + "/Library/Application Support/Dock/desktoppicture.db",
    ]
    var hash: UInt64 = 0xcbf29ce484222325
    for path in paths {
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        hash = (hash ^ fnv(data)) &* 0x100000001b3
    }
    return hash == 0xcbf29ce484222325 ? 0 : hash
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
log("t26-agent started (t26 \(options.t26), mode \(arguments(options).joined(separator: " ")), "
    + "events \(options.events.sorted().joined(separator: ",")), grace \(options.grace)s)")

var lastLocked = isLocked()
var lastDisplays = displayFingerprint()
var lastWallpaper = wallpaperFingerprint()
var lastConsole = consoleUser()
var pendingWallpaper: UInt64 = 0
var lastRunAt: TimeInterval = 0
if options.verbose {
    log("user='\(lastConsole)' locked=\(lastLocked) displays=[\(lastDisplays)] wallpaper=\(String(lastWallpaper, radix: 16))")
}

// Started at boot with a session already on screen (launchd starts this before
// login, but it can also be restarted or started by hand): the bar has just been
// built by a new WindowServer, so repair it without waiting for an event.
if options.bootRepair, !lastConsole.isEmpty, !lastDisplays.isEmpty {
    Thread.sleep(forTimeInterval: Double(options.grace))
    lastRunAt = Date().timeIntervalSince1970
    settle(options, reason: "agent started")
}

while true {
    Thread.sleep(forTimeInterval: 1.0)
    let locked = isLocked()
    let displays = displayFingerprint()
    let wallpaper = wallpaperFingerprint()
    let user = consoleUser()

    var reason: String?
    if options.bootRepair, lastConsole.isEmpty, !user.isEmpty {
        // Logging in: WindowServer has a brand new bar, and the repair from the
        // previous session died with the old process.
        reason = "session started (\(user))"
    } else if lastLocked && !locked, options.events.contains("unlock") {
        reason = "screen unlocked"
    } else if options.events.contains("display"), !displays.isEmpty,
              displays != lastDisplays {
        reason = "display configuration changed"
    } else if options.events.contains("wallpaper"), wallpaper != 0, wallpaper != lastWallpaper,
              wallpaper == pendingWallpaper, pendingWallpaper != 0 {
        // Two polls in a row: a wallpaper write in progress is not a change yet.
        reason = "wallpaper changed"
    }

    if options.verbose && (displays != lastDisplays || wallpaper != lastWallpaper
                           || locked != lastLocked || user != lastConsole) {
        log("state user='\(user)' locked=\(locked) displays=[\(displays)] wallpaper=\(String(wallpaper, radix: 16))")
    }
    if wallpaper != lastWallpaper { pendingWallpaper = wallpaper }
    lastLocked = locked
    lastDisplays = displays
    lastWallpaper = wallpaper
    lastConsole = user

    if let reason {
        // Never repair twice in a row for the same reason: a repair can itself
        // cause the wallpaper store to be rewritten, which would start a loop.
        if Date().timeIntervalSince1970 - lastRunAt < Double(options.cooldown) {
            if options.verbose { log("\(reason): within the \(options.cooldown)s cooldown, skipped") }
            continue
        }
        lastRunAt = Date().timeIntervalSince1970
        // The bar is rebuilt a moment after the event, not instantly: settle
        // repairs on every rebuild, and --guard keeps it attached until the
        // burst is over.
        Thread.sleep(forTimeInterval: Double(options.grace))
        lastLocked = isLocked()
        lastDisplays = displayFingerprint()
        lastWallpaper = wallpaperFingerprint()
        lastConsole = consoleUser()
        settle(options, reason: reason)
    }
}
