import CoreGraphics
import AppKit
import Darwin
import Foundation

/// Thin wrapper around the SkyLight (WindowServer client) private API that owns the
/// menu bar's system override alpha.
///
/// Verified on macOS 14.6.1:
///   int SLSSetMenuBarSystemOverrideAlpha(CGSConnectionID cid,
///                                        uint32_t display,   // 0 == every display
///                                        float alpha,        // 0 == invisible, 1 == normal
///                                        uint32_t flags,     // 0 observed
///                                        uint32_t animate)   // 1 observed
/// `display` must be 0 (or the real display id); passing CGMainDisplayID() is not a
/// wildcard and silently does nothing on multi-display setups.
enum WindowServer {
    struct API {
        let connection: UInt32
        let setOverrideAlpha: @convention(c) (UInt32, UInt32, Float, UInt32, UInt32) -> Int32
    }

    static let allDisplays: UInt32 = 0

    static let shared: API? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let connSymbol = dlsym(handle, "CGSMainConnectionID"),
              let alphaSymbol = dlsym(handle, "SLSSetMenuBarSystemOverrideAlpha")
        else { return nil }

        let connection = unsafeBitCast(connSymbol, to: (@convention(c) () -> UInt32).self)()
        let setAlpha = unsafeBitCast(
            alphaSymbol,
            to: (@convention(c) (UInt32, UInt32, Float, UInt32, UInt32) -> Int32).self
        )
        return API(connection: connection, setOverrideAlpha: setAlpha)
    }()

    static var isAvailable: Bool { shared != nil }

    @discardableResult
    static func setMenuBarAlpha(_ alpha: Float, display: UInt32 = allDisplays) -> Bool {
        guard let api = shared else { return false }
        return api.setOverrideAlpha(api.connection, display, alpha, 0, 1) == 0
    }

    static func activeDisplays() -> [CGDirectDisplayID] {        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// NOTE: SLSTransactionSpaceRebuildMenuBar() is *not* a convenience call —
    /// it is a transaction encoder whose first argument is an opaque
    /// SLSTransaction object (it writes opcodes into a byte buffer), not a
    /// connection id. Calling it with a CGSConnectionID crashes.
    /// Use `forceMenuBarRebuild()` in main.swift instead, which simply changes
    /// the frontmost application and lets WindowServer rebuild the bar itself.
    ///
    /// Asks the WindowServer to rebuild the menu bar layers, which re-runs the
    /// layer construction path (useful after a runtime hook is installed).
    /// Implemented by handing focus to Finder: WindowServer rebuilds the menu
    /// bar on every front-application change.
    static func rebuildMenuBar() {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) else { return }
        finder.activate()
    }

    /// Belt and braces: the wildcard display plus every concrete display.
    static func restore() {
        _ = setMenuBarAlpha(1.0, display: allDisplays)
        for display in activeDisplays() {
            _ = setMenuBarAlpha(1.0, display: display)
        }
    }
}
