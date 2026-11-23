#if DEBUG
import AppKit
import SwiftUI

/// Developer aid (debug builds only): `Spyglass --glass-snapshot <dir>` captures the main pages, Quick Search,
/// a toast and Settings with the Liquid Glass theme off and on, in light and dark, using the app's own window
/// capture (renders real glass), then restores the saved setting and quits.
@MainActor
enum GlassSnapshot {
    static var requestedDir: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--glass-snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func run(_ dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: GlassTheme.key)
        let model = AppModel.shared
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Spyglass" }) else { NSApp.terminate(nil); return }

        let pages: [(String, () -> Void)] = [
            ("home", { model.show(.home) }),
            ("folder", { model.open(folder: Places.home) }),
            ("health", { model.show(.health) }),
            ("cleanup", { model.show(.cleanup) }),
            ("tools", { model.show(.tools(nil)) }),
        ]
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for glass in [false, true] {
                defaults.set(glass, forKey: GlassTheme.key)
                let suffix = "\(glass ? "glass" : "plain")-\(dark ? "dark" : "light")"
                for (name, go) in pages {
                    go()
                    try? await Task.sleep(for: .seconds(name == "home" || name == "cleanup" ? 2.5 : 1.3))
                    await capture(window, to: dir.appendingPathComponent("\(name)-\(suffix).png"))
                }
                model.show(.health)
                ActivityLog.shared.show("Moved 3 items to the Trash")
                try? await Task.sleep(for: .seconds(1.2))
                await capture(window, to: dir.appendingPathComponent("toast-\(suffix).png"))
                ActivityLog.shared.toast = nil

                QuickSearchPanel.shared.show()
                QuickSearchPanel.shared.state.text = "inv"
                QuickSearchPanel.shared.state.update()
                try? await Task.sleep(for: .seconds(1.5))
                if let panel = NSApp.windows.first(where: { $0 is KeyPanel && $0.isVisible }) {
                    await capture(panel, to: dir.appendingPathComponent("quicksearch-\(suffix).png"), activate: false)
                    await capture(panel, to: dir.appendingPathComponent("quicksearch-over-desktop-\(suffix).png"), activate: false, withBackground: true)
                }
                QuickSearchPanel.shared.hide()

                NSApp.activate(ignoringOtherApps: true)
                if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                   let i = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                    appMenu.performActionForItem(at: i)
                } else {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                try? await Task.sleep(for: .seconds(1.2))
                if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && !($0 is KeyPanel) && $0.frame.width > 400 }) {
                    await capture(settings, to: dir.appendingPathComponent("settings-\(suffix).png"))
                    settings.close()
                }
            }
        }
        if let original { defaults.set(original, forKey: GlassTheme.key) } else { defaults.removeObject(forKey: GlassTheme.key) }
        model.show(.home)
        NSApp.terminate(nil)
    }

    private typealias CapFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static func capture(_ window: NSWindow, to url: URL, activate: Bool = true, withBackground: Bool = false) async {
        if activate {
            for _ in 0..<30 where !(NSApp.isActive && window.isKeyWindow) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
        let f = unsafeBitCast(sym, to: CapFn.self)
        var rect = CGRect.null
        var list: UInt32 = 8
        if withBackground, let screen = NSScreen.screens.first {
            // Include whatever is below the panel (desktop/other windows) to judge the glass in context.
            let f = window.frame
            rect = CGRect(x: f.minX - 40, y: screen.frame.maxY - f.maxY - 40, width: f.width + 80, height: f.height + 80)
            list = 4 | 8
        }
        guard let img = f(rect, list, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
