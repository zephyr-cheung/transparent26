import Darwin
import Foundation

// Ctrl-C must never reach the debugger. SIGINT makes a batch lldb *kill* the
// process it is attached to, and that process is WindowServer — the desktop.
// Two things keep it safe: the engine runs in its own process group (so the
// terminal only signals this CLI) and this handler swallows the signal.
signal(SIGINT) { _ in t26Interrupted = 1 }

let rawArguments = Array(CommandLine.arguments.dropFirst())

let options: Options
do {
    options = try parseArguments(rawArguments)
} catch let error as UsageError {
    err(Style.red("t26: ") + error.message)
    err("")
    err(usageText)
    exit(ExitCode.usage.rawValue)
} catch {
    err("t26: \(error)")
    exit(ExitCode.usage.rawValue)
}

let layout = Layout.resolve(executable: Host.executablePath())

switch options.command {
case .version:
    commandVersion()

case .help:
    out(usage(for: options.helpTopic))
    exit(ExitCode.ok.rawValue)

case .status:
    commandStatus(options, layout: layout)

case .doctor:
    commandDoctor(options, layout: layout)

case .logs:
    commandLogs(options, layout: layout)

case .agent:
    guard let layout else { die(Layout.missingMessage(), .blocked) }
    commandAgent(options, layout: layout)

case .abort:
    guard let layout else { die(Layout.missingMessage(), .blocked) }
    commandAbort(options, layout: layout)

case .settle, .fix, .tree, .probe, .hunt, .theme, .space:
    guard let layout else { die(Layout.missingMessage(), .blocked) }
    runEngineCommand(options, layout: layout)
}
