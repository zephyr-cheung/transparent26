import Foundation

enum Command: String {
    case settle, fix, now, tree, probe, hunt, theme, space
    case status, doctor, logs, abort, agent
    case version, help

    var needsWindowServer: Bool {
        switch self {
        case .settle, .fix, .now, .tree, .probe, .hunt, .theme, .space, .abort: return true
        default: return false
        }
    }

    var modifiesWindowServer: Bool {
        self == .settle || self == .fix || self == .now
    }

    var defaultSeconds: Int {
        switch self {
        case .settle: return 40
        case .now: return 20
        case .fix: return 900
        case .tree, .space: return 25
        case .probe: return 25
        case .theme: return 25
        case .hunt: return 60
        default: return 30
        }
    }
}

struct Options {
    var command: Command = .help
    var helpTopic: Command?
    var seconds: Int?
    var pattern: String?
    var deep = true
    var settleMin: Int?
    var settleMax: Int?
    var guardSeconds: Int?
    var fast = false
    var fullAgent = false
    var pid: Int?
    var log = ProcessInfo.processInfo.environment["T26_LOG"] ?? "/tmp/t26hook.log"
    var json = false
    var strict = false
    var ignoreSIP = false
    var noSudo = false
    var verbose = false
    var agentAction = "status"
    var lines: Int?
    var follow = false
    var all = false
}

struct UsageError: Error {
    let message: String
}

func parseArguments(_ arguments: [String]) throws -> Options {
    var options = Options()
    var rest = arguments[...]

    if let first = rest.first, let command = Command(rawValue: first) {
        options.command = command
        rest = rest.dropFirst()
        if command == .help, let topic = rest.first, let parsed = Command(rawValue: topic) {
            options.helpTopic = parsed
            rest = rest.dropFirst()
        }
    } else if let first = rest.first, !first.hasPrefix("-") {
        throw UsageError(message: "unknown command '\(first)' — run `t26 help`")
    }

    if options.command == .agent, let action = rest.first, !action.hasPrefix("-") {
        options.agentAction = action
        rest = rest.dropFirst()
    }

    var index = 0
    let args = Array(rest)

    func value(_ flag: String) throws -> String {
        guard index + 1 < args.count else {
            throw UsageError(message: "\(flag) needs a value")
        }
        index += 1
        return args[index]
    }

    func number(_ flag: String) throws -> Int {
        let raw = try value(flag)
        guard let parsed = Int(raw), parsed >= 0 else {
            throw UsageError(message: "\(flag) expects a non-negative integer, not '\(raw)'")
        }
        return parsed
    }

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-h", "--help":
            options.command = .help
            if options.helpTopic == nil, let first = arguments.first, let parsed = Command(rawValue: first) {
                options.helpTopic = parsed
            }
        case "--version":
            options.command = .version
        case "-s", "--seconds":
            options.seconds = try number(arg)
        case "-p", "--pattern":
            options.pattern = try value(arg)
        case "--shallow":
            options.deep = false
        case "--deep":
            options.deep = true
        case "--settle-min":
            options.settleMin = try number(arg)
        case "--settle-max":
            options.settleMax = try number(arg)
        case "--guard":
            options.guardSeconds = try number(arg)
        case "--fast":
            options.fast = true
        case "--full":
            options.fullAgent = true
        case "--pid":
            options.pid = try number(arg)
        case "--log":
            options.log = try value(arg)
        case "--json":
            options.json = true
        case "--strict":
            options.strict = true
        case "--ignore-sip":
            options.ignoreSIP = true
        case "--no-sudo":
            options.noSudo = true
        case "-v", "--verbose":
            options.verbose = true
        case "-n", "--lines":
            options.lines = try number(arg)
        case "-f", "--follow":
            options.follow = true
        case "--all":
            options.all = true
        default:
            if arg.hasPrefix("-") {
                throw UsageError(message: "unknown option '\(arg)'")
            }
            throw UsageError(message: "unexpected argument '\(arg)'")
        }
        index += 1
    }

    if let min = options.settleMin, let max = options.settleMax, min > max {
        throw UsageError(message: "--settle-min cannot be larger than --settle-max")
    }
    if let seconds = options.seconds, seconds < 3, options.command.needsWindowServer, options.command != .abort {
        throw UsageError(message: "--seconds must be at least 3")
    }
    if options.lines != nil || options.follow || options.all {
        if options.command == .help || options.command == .logs { options.command = .logs }
    }
    return options
}

let usageText = """
t26 \(t26Version) — a transparent menu bar for macOS

Removes the menu bar's backdrop layer inside WindowServer. Text,
icons, status items, pills and the shadow are left exactly where they were: only
the backdrop layer is emptied out. Nothing is loaded into WindowServer and
nothing is written outside /tmp, so logging out or rebooting undoes everything.

USAGE
  sudo t26 settle [options]        make the menu bar transparent (recommended)
  sudo t26 fix [options]           stay attached, repair every rebuild
  sudo t26 now                     repair right away, no rebuild needed
  sudo t26 tree                    dump the live menu bar CALayer tree
  sudo t26 probe                   log the layer names WindowServer assigns
  sudo t26 hunt                    log the setters the menu bar code calls
  sudo t26 theme                   log what the CoreUI renderer paints
  sudo t26 space                   dump the long-lived menu bar space structs
       t26 status [--json]         what this machine looks like right now
       t26 doctor                  check the prerequisites
       t26 logs [-n N] [-f|--all]  read the hook log
  sudo t26 abort                   emergency: hand WindowServer back
  sudo t26 agent install           keep it repaired across unlocks / display changes
       t26 agent status | uninstall
       t26 version | help [cmd]

OPTIONS
  -s, --seconds N     time budget (settle 40, fix 900, tree/probe/theme 25, hunt 60)
  -p, --pattern S     layer-name substring to neutralise (default MenuBarBackdrop)
      --shallow       only hide the backdrop (no opacity/contents/filters)
      --settle-min N  earliest detach, seconds (default 4)
      --settle-max N  stop waiting for every display to report (default 60)
      --guard N       stay attached until the bar is quiet for N seconds, so a
                      repair survives the rebuild burst after an unlock/wake
      --fast          one-shot: repair, detach, never steal focus (for the agent)
      --full          agent: use the guarded settle instead of the one-shot repair
      --pid N         operate on another process (for testing; no sudo needed)
      --strict        exit 3 unless every attached display was confirmed
      --json          machine-readable output (settle, fix, status, doctor)
      --ignore-sip    try even when SIP is enabled
      --no-sudo       never re-exec through sudo
      --log PATH      hook log (default /tmp/t26hook.log)
  -v, --verbose
  -h, --help
      --version

EXIT CODES
  0 fixed   1 not fixed   2 usage   3 blocked (SIP/root/strict)
  4 no WindowServer       5 engine failure   130 interrupted

HOW IT WORKS
  lldb attaches to WindowServer, breaks on SkyLight`resize_one_pill, climbs to the
  menu bar's root layer and empties every child named *MenuBarBackdrop*. `settle`
  then disables the breakpoints and detaches, so WindowServer runs at full speed.

SAFETY
  Ctrl-C is ignored on purpose: SIGINT makes lldb kill its target, and the target
  is the desktop. A run always hands WindowServer back by itself; if one ever
  hangs, open another terminal and run: sudo t26 abort

DOCS
  docs/01-how-it-works.md · 02-reverse-engineering · 03-dead-ends · 04-performance
"""

let commandNotes: [Command: String] = [
    .space: """
    space — dump the long-lived menu bar objects, change nothing.

    update_menu_bar_layers(PKGManagedMenuSpace *space, display, AppMenuBarInfo_t
    *info, CGXWindow *bar) is where SkyLight decides what material the bar gets.
    The space outlives every layer rebuild, so anything there survives an unlock
    or a wallpaper change - which is what a "one write, no debugger afterwards"
    fix would have to change. The struct layouts are unknown, so the words are
    dumped and diffed:

      sudo t26 space                    # unlocked
      ssh macbook-air sudo t26 space    # while the screen is locked
      diff <(sudo t26 space) <(...)

    Read-only; nothing is written.
    """,
    .settle: """
    settle — neutralise the backdrop, then let go of the debugger.

    The engine repairs the bar landscape on every pill resize for a few seconds.
    As soon as every display WindowServer reported has been repaired at least
    twice, it disables its breakpoints and detaches, leaving no debugger behind:
    zero overhead from then on. If a display never shows up before --settle-max,
    the run ends with a warning and that screen may stay frosted; raise -s and
    --settle-max, or press the Apple menu once to force a rebuild.

    sudo t26 settle                       # usually enough
    sudo t26 settle -s 90 --settle-max 90 # stubborn multi-display setups
    sudo t26 settle --strict              # fail unless every display was fixed
    """,
    .fix: """
    fix — keep the debugger attached and repair every menu bar rebuild.

    Use this only for debugging. WindowServer is stopped at every breakpoint hit,
    which costs frames; `settle` is what you want for normal use.
    """,
    .tree: """
    tree — dump the live menu bar CALayer tree and change nothing.

    Shows the root layer, its children (text, icons, pills, shadow, backdrop and
    the backdrop's own children) with their names, classes and filters. This is
    how the sibling relationship behind the whole trick was found.
    """,
    .probe: """
    probe — log every layer name WindowServer assigns, change nothing.

    Read-only. Useful to check that your build of macOS still calls the backdrop
    layer *MenuBarBackdrop*; pass --pattern to look for something else.
    """,
    .hunt: """
    hunt — log the render-layer setters called from the menu bar code.

    Read-only and noisy: it watches filters, background filters, compositing
    filters and backdrop groups. This is how the CoreUI theme renderer was ruled
    out as the place to intervene.
    """,
    .theme: """
    theme — log the layers CoreUI's theme renderer paints.

    space — dump the long-lived menu bar objects (PKGManagedMenuSpace and the
    AppMenuBarInfo_t it is rebuilt from) instead of the layers. Everything that
    decides whether the bar gets a material lives on that side, and it survives
    a layer rebuild, so this is what a "one write, no debugger afterwards" fix
    would have to change. Read-only.

    Read-only. That renderer is what produces the glass pixels, but it is shared
    with every other material on screen, so this is diagnostic only.
    """,
    .status: """
    status — report SIP, WindowServer, displays, engine paths and the last run.

    Add --json for a machine-readable object (handy in scripts and status bars).
    """,
    .doctor: """
    doctor — check everything the fix needs and say how to repair what is missing.

    Verifies: macOS version, SIP, WindowServer, lldb, engine/hook paths, log
    directory. Exits 3 when a hard requirement is not met.
    """,
    .logs: """
    logs — read the hook log.

    t26 logs              last run, formatted
    t26 logs -n 40        last 40 lines of the last run
    t26 logs --all        every run in the log
    t26 logs -f           follow the log live (useful next to `t26 fix`)
    """,
    .abort: """
    abort — hand WindowServer back if a run looks stuck.

    Writes "process detach" into the engine's control pipe. Never kill lldb or
    send the run a SIGINT: both take WindowServer down with them.
    """,
]

func usage(for command: Command?) -> String {
    guard let command, let note = commandNotes[command] else { return usageText }
    return note + "\n" + usageText
}
