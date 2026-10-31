import Foundation

/// Where the privileged engine and its lldb Python hook live.
///
/// The CLI is one self-contained binary; the engine is a shell script that
/// drives lldb and the hook is imported *into* lldb, so both must exist on disk.
/// Installed layout:
///
///     /usr/local/bin/t26
///     /usr/local/libexec/t26/t26-engine.sh
///     /usr/local/libexec/t26/ws_hook.py
///
/// A checkout is found too (`bin/t26` → `../libexec/t26`), so `make` +
/// `./bin/t26 settle` works without installing.
struct Layout {
    var engine: String
    var hook: String

    var root: String { (engine as NSString).deletingLastPathComponent }
    var log: String { "/tmp/t26hook.log" }
    var control: String { "/tmp/t26-ctl" }
    var lldbLog: String { "/tmp/t26-layer-lldb.log" }

    static func resolve(executable: String) -> Layout? {
        let env = ProcessInfo.processInfo.environment

        if let engine = env["T26_ENGINE"], let hook = env["T26_HOOK"],
           exists(engine), exists(hook) {
            return Layout(engine: engine, hook: hook)
        }

        var dirs: [String] = []
        if let dir = env["T26_LIBEXEC"] { dirs.append(dir) }

        let exeDir = (executable as NSString).deletingLastPathComponent
        dirs.append(exeDir + "/libexec/t26")
        dirs.append(exeDir + "/../libexec/t26")
        dirs.append(exeDir + "/libexec")

        var walk = exeDir
        for _ in 0..<6 {
            walk = (walk as NSString).deletingLastPathComponent
            if walk.isEmpty || walk == "/" { break }
            dirs.append(walk + "/libexec/t26")
        }
        dirs.append("/usr/local/libexec/t26")
        dirs.append("/opt/homebrew/libexec/t26")
        dirs.append("/opt/homebrew/opt/t26/libexec/t26")

        var seen = Set<String>()
        for dir in dirs {
            let path = URL(fileURLWithPath: dir).standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            let engine = path + "/t26-engine.sh"
            let hook = path + "/ws_hook.py"
            if exists(engine), exists(hook) { return Layout(engine: engine, hook: hook) }
        }
        return nil
    }

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func missingMessage() -> String {
        [
            "cannot find the engine (libexec/t26/t26-engine.sh + ws_hook.py).",
            "Installed builds look in ../libexec/t26 next to the binary; a checkout",
            "looks in <repo>/libexec/t26. Fix with one of:",
            "",
            "  sudo make install                 # installs to /usr/local",
            "  ./bin/t26 settle                  # run from the checkout",
            "  export T26_LIBEXEC=/path/to/libexec/t26",
        ].joined(separator: "\n")
    }
}
