import Foundation

/// One `t26` run, parsed out of the hook log.
///
/// The engine writes everything it learns to `/tmp/t26hook.log`; the CLI tails
/// that file for progress and parses the last run block for the summary, so the
/// engine never has to emit machine-readable output.
struct RunSummary {
    var epoch: Int = 0
    var mode: String = ""
    var pid: Int = 0
    var lines: [String] = []

    var hidden = 0
    var passes = 0
    var hits = 0
    var matched = 0
    var confirmedDisplays: Int?
    var totalDisplays: Int?
    var breakpointsDisabled = 0
    var trees = 0
    var hunted = 0
    var themed = 0
    var doneReason: String?
    var warnings: [String] = []
    var roots = Set<String>()
    var displaysSeen = 0

    var settled: Bool { doneReason?.hasPrefix("settled") ?? false }
    var sawEveryDisplay: Bool {
        guard let confirmed = confirmedDisplays, let total = totalDisplays else { return false }
        return total > 0 && confirmed >= total
    }

    static func parse(_ text: String) -> [RunSummary] {
        var runs: [RunSummary] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if let groups = firstMatch("^t26: == run (\\d+) (\\S+) pid (\\d+)", raw) {
                runs.append(RunSummary(
                    epoch: Int(groups[1]) ?? 0,
                    mode: groups[2],
                    pid: Int(groups[3]) ?? 0
                ))
                continue
            }
            guard !runs.isEmpty else { continue }
            runs[runs.count - 1].lines.append(raw)
            runs[runs.count - 1].absorb(raw)
        }
        return runs
    }

    private mutating func absorb(_ raw: String) {
        if raw.contains("MATCH") { matched += 1 }
        if raw.contains("HUNT ") { hunted += 1 }
        if raw.contains("THEME ") { themed += 1 }
        if raw.contains("MENUBAR layer:") { trees += 1 }
        if raw.contains("WARNING") { warnings.append(raw.replacingOccurrences(of: "t26: ", with: "")) }

        if let g = firstMatch("fix pass (\\d+): neutralised", raw) {
            passes = max(passes, Int(g[1]) ?? passes)
        }
        if let g = firstMatch("neutralised \\d+ layer\\(s\\) under (0x[0-9a-f]+)", raw) {
            roots.insert(g[1])
        }
        if let g = firstMatch("(\\d+)/(\\d+) display\\(s\\) seen", raw) {
            displaysSeen = max(displaysSeen, Int(g[2]) ?? 0)
        }
        if let g = firstMatch("settle: (\\d+) layer\\(s\\) hidden over (\\d+) pass\\(es\\), (\\d+)/(\\d+) display", raw) {
            hidden = max(hidden, Int(g[1]) ?? 0)
            passes = max(passes, Int(g[2]) ?? 0)
            confirmedDisplays = Int(g[3])
            totalDisplays = Int(g[4])
        }
        if let g = firstMatch("settle: (\\d+) breakpoint\\(s\\) disabled", raw) {
            breakpointsDisabled = max(breakpointsDisabled, Int(g[1]) ?? 0)
        }
        if let g = firstMatch("^t26: done: (.*)$", raw) {
            doneReason = g[1]
        }
        if let g = firstMatch("^t26: done: .*? — (\\d+) hits, (\\d+) fix pass\\(es\\)", raw) {
            hits = Int(g[1]) ?? hits
            passes = max(passes, Int(g[2]) ?? 0)
        }
        if let g = firstMatch("done: .*?(\\d+) layer\\(s\\) matched", raw) {
            matched = max(matched, Int(g[1]) ?? 0)
        }
        if let g = firstMatch("done: .*matched '[^']*', (\\d+) hidden", raw) {
            hidden = max(hidden, Int(g[1]) ?? 0)
        }
    }

    /// Last run of `mode` (any mode when nil) that started at or after `since`.
    /// Layers this run can prove it neutralised: the authored total when the
    /// hook finished, otherwise the distinct menu bar roots it repaired.
    var layersNeutralised: Int { hidden > 0 ? hidden : roots.count }

    /// Displays that answered: confirmed by the settle line, else merely seen.
    var displaysTotal: Int { totalDisplays ?? displaysSeen }

    static func lastRun(path: String, mode: String?, since: Int? = nil) -> RunSummary? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let all = parse(text)
        return all.last { run in
            (mode == nil || run.mode == mode) && (since == nil || run.epoch >= since!)
        }
    }

    static func allRuns(path: String) -> [RunSummary] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text)
    }
}

/// Incremental reader for the hook log: prints what the engine appends while
/// the debugger is attached, without ever re-reading old runs.
struct LogTail {
    let path: String
    private var offset: UInt64
    private var buffer = ""

    init(path: String) {
        self.path = path
        self.offset = LogTail.size(of: path)
    }

    private static func size(of path: String) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.size] as? NSNumber else { return 0 }
        return number.uint64Value
    }

    mutating func pump(_ emit: (String) -> Void) {
        let end = LogTail.size(of: path)
        guard end > offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = end
        buffer += String(decoding: data, as: UTF8.self)

        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            var text = line
            if text.hasPrefix("t26: == run ") {
                text = "attaching: " + text.replacingOccurrences(of: "t26: == run ", with: "")
                    .replacingOccurrences(of: " ===", with: "")
            } else if text.hasPrefix("t26: ") {
                text.removeFirst(5)
            }
            if !text.isEmpty { emit(text) }
        }
    }
}

func firstMatch(_ pattern: String, _ subject: String) -> [String]? {
    let regex: NSRegularExpression
    do {
        regex = try NSRegularExpression(pattern: pattern)
    } catch {
        // A malformed pattern used to fail silently, which showed up as "the run
        // produced no summary". Say so instead.
        FileHandle.standardError.write(
            ("t26: internal pattern is invalid: " + pattern + "\n").data(using: .utf8)!)
        return nil
    }
    let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
    guard let match = regex.firstMatch(in: subject, range: range) else { return nil }
    var groups: [String] = []
    for index in 0..<match.numberOfRanges {
        guard let r = Range(match.range(at: index), in: subject) else {
            groups.append("")
            continue
        }
        groups.append(String(subject[r]))
    }
    return groups
}
