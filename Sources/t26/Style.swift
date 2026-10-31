import Darwin
import Foundation

let t26Version = "0.1.0"

/// Exit codes are part of the CLI contract: scripts branch on them.
enum ExitCode: Int32 {
    case ok = 0
    case failed = 1          // ran, but the menu bar was not fixed
    case usage = 2           // bad arguments
    case blocked = 3         // preflight refused: SIP, root, missing tools, strict mode
    case noWindowServer = 4  // WindowServer is not running
    case engine = 5          // the lldb engine could not hand WindowServer back
    case interrupted = 130   // never attempted: SIGINT is ignored on purpose
}

enum Style {
    static let color = isatty(STDOUT_FILENO) == 1
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        && ProcessInfo.processInfo.environment["TERM"] != "dumb"

    private static func wrap(_ text: String, _ code: String) -> String {
        color ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    static func bold(_ text: String) -> String { wrap(text, "1") }
    static func dim(_ text: String) -> String { wrap(text, "2") }
    static func green(_ text: String) -> String { wrap(text, "32") }
    static func red(_ text: String) -> String { wrap(text, "31") }
    static func yellow(_ text: String) -> String { wrap(text, "33") }
    static func cyan(_ text: String) -> String { wrap(text, "36") }
}

func out(_ text: String = "") {
    FileHandle.standardOutput.write((text + "\n").data(using: .utf8)!)
}

func err(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

func die(_ message: String, _ code: ExitCode = .failed) -> Never {
    err(Style.red("t26: ") + message)
    exit(code.rawValue)
}

/// `  name        value` — the layout every command uses for its report.
func row(_ name: String, _ value: String, width: Int = 13) -> String {
    let pad = String(repeating: " ", count: max(1, width - name.count))
    return "  " + Style.dim(name + pad) + "  " + value
}

func ok(_ text: String) -> String { Style.green("✓") + " " + text }
func warn(_ text: String) -> String { Style.yellow("!") + " " + text }
func bad(_ text: String) -> String { Style.red("✗") + " " + text }

func elapsed(_ seconds: Double) -> String {
    seconds < 10 ? String(format: "%.1f s", seconds) : String(format: "%.0f s", seconds)
}

/// Human "3 minutes ago", used by `t26 status`.
func ago(_ seconds: Int) -> String {
    switch seconds {
    case ..<5: return "just now"
    case ..<90: return "\(seconds)s ago"
    case ..<5400: return "\(seconds / 60)m ago"
    case ..<172_800: return "\(seconds / 3600)h ago"
    default: return "\(seconds / 86_400)d ago"
    }
}
