import Foundation

/// Small JSON state file. A plain (unbundled) executable has no reliable
/// `UserDefaults` domain, so we keep the state next to the user's other app data.
struct State: Codable {
    var enabled: Bool = false
    var alpha: Float = 0
    var display: UInt32 = 0

    static let storeURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("transparent26", isDirectory: true)
            .appendingPathComponent("state.json")
    }()

    static func load() -> State {
        guard let data = try? Data(contentsOf: storeURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: State.storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(self).write(to: State.storeURL)
        } catch {
            FileHandle.standardError.write("state save failed: \(error)\n".data(using: .utf8)!)
        }
    }
}
