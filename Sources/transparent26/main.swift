import AppKit
import Foundation

private let usage = """
transparent26 — menu bar transparency for macOS (SkyLight system override alpha)

USAGE
  transparent26                       run the menu bar app
  transparent26 --alpha <0.0-1.0>     one-shot: set alpha and exit
  transparent26 --alpha 0.3 --display 0
  transparent26 --alpha 0 --hold 5    keep the connection open for 5 s (the override
                                      is connection-scoped and dies with the process)
  transparent26 --restore             one-shot: put the menu bar back to normal
  transparent26 --rebuild             one-shot: force a menu bar rebuild (app switch)
  transparent26 --status              print the current display ids / API availability
  transparent26 --help

NOTES
  display 0 == every display. alpha 0 == fully transparent, 1 == normal.
  The override belongs to the WindowServer connection, so it disappears when the
  process exits. --restore only matters if a process is left running.
"""

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
    return arguments[index + 1]
}

if arguments.isEmpty {
    guard WindowServer.isAvailable else {
        fail("SkyLight private API unavailable — this tool needs macOS with WindowServer.")
    }
    MenuBarApp().run()
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

if arguments.contains("--status") {
    print("SkyLight API: \(WindowServer.isAvailable ? "available" : "unavailable")")
    print("displays: \(WindowServer.activeDisplays().map(String.init).joined(separator: ", "))")
    print("note: display 0 is the wildcard used for \"all displays\"")
    exit(0)
}

if arguments.contains("--restore") {
    WindowServer.restore()
    print("menu bar restored (alpha = 1.0)")
    exit(0)
}

if arguments.contains("--rebuild") {
    WindowServer.rebuildMenuBar()
    print("requested a menu bar rebuild")
    exit(0)
}

if arguments.contains("--alpha") {
    guard let raw = value(after: "--alpha"), let alpha = Float(raw), (0...1).contains(alpha) else {
        fail("--alpha expects a value between 0.0 and 1.0")
    }
    let display = UInt32(value(after: "--display") ?? "0") ?? 0
    guard WindowServer.setMenuBarAlpha(alpha, display: display) else {
        fail("SLSSetMenuBarSystemOverrideAlpha failed")
    }
    print(String(format: "menu bar alpha = %.2f (display %u)", alpha, display))
    if let hold = UInt32(value(after: "--hold") ?? "0"), hold > 0 {
        sleep(hold)
    }
    exit(0)
}

fail("unknown arguments: \(arguments.joined(separator: " "))\n\n\(usage)")
