import SwiftUI
import AppKit

@main
struct SpyglassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @AppStorage("theme") private var theme = "playful"

    var body: some Scene {
        Window("Spyglass", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 540)
                .background(OpenWindowBridge())
        }
        .defaultSize(width: 1180, height: 760)
        .commands { SpyglassCommands(model: model) }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

private struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { WindowOpener.action = { openWindow(id: "main") } }
    }
}

struct SpyglassCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { model.addTab() }.keyboardShortcut("t")
            Button("New Folder") { model.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Tab") { model.closeTab() }.keyboardShortcut("w")
            Divider()
            Button("Quick Search…") { QuickSearchPanel.shared.toggle() }.keyboardShortcut("k")
            Button("Find…") { QuickSearchPanel.shared.toggle() }.keyboardShortcut("f")
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") { if !forwardToTextField(#selector(NSText.copy(_:))) { model.copySelection() } }.keyboardShortcut("c")
            Button("Paste") { if !forwardToTextField(#selector(NSText.paste(_:))) { model.paste(move: false) } }.keyboardShortcut("v")
            Button("Move Items Here") { model.paste(move: true) }.keyboardShortcut("v", modifiers: [.command, .option])
            Button("Cut") { _ = forwardToTextField(#selector(NSText.cut(_:))) }.keyboardShortcut("x")
            Button("Select All") { if !forwardToTextField(#selector(NSText.selectAll(_:))) { model.tab.selection = Set(model.tab.items.map(\.url)) } }.keyboardShortcut("a")
            Divider()
            Button("Duplicate") { model.duplicateSelection() }.keyboardShortcut("d")
            Button("Move to Trash") { if !forwardToTextField(#selector(NSResponder.deleteToBeginningOfLine(_:))) { model.trashSelection() } }.keyboardShortcut(.delete)
            Button("Rename…") { if let u = model.selectedURLs.first, model.selectedURLs.count == 1 { model.renameTarget = u } else if model.selectedURLs.count > 1 { model.bulkRename = model.selectedURLs } }
                .disabled(model.page != .folder)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if !forwardToTextField(Selector(("undo:"))) { ActivityLog.shared.undoLast() } }.keyboardShortcut("z")
            Button("Redo") { _ = forwardToTextField(Selector(("redo:"))) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("View ") {
            Button("as Icons") { model.tab.mode = .grid }.keyboardShortcut("1")
            Button("as List") { model.tab.mode = .list }.keyboardShortcut("2")
            Button("as Columns") { model.tab.mode = .columns }.keyboardShortcut("3")
            Divider()
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }.keyboardShortcut("i")
            Button("Show/Hide Hidden Files") { model.toggleHidden() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Switch Playful / Minimal") { model.toggleTheme() }.keyboardShortcut("t", modifiers: [.command, .control])
            Divider()
            Button("Look") { model.room = .look; model.show(.home) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Sweep") { model.room = .sweep; model.show(.cleanup) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Tools") { model.room = .tools; model.show(.tools(nil)) }.keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            Button("Next Tab") { model.nextTab() }.keyboardShortcut(.tab, modifiers: [.control])
            Button(model.splitTab == nil ? "Split View" : "Close Split View") { model.toggleSplit() }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("Switch Pane") { if model.splitTab != nil { model.rightFocused.toggle() } }.keyboardShortcut(.tab, modifiers: [.option])
            Button("Copy to Other Pane") { model.sendToOtherPane(copy: true) }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Button("Move to Other Pane") { model.sendToOtherPane(copy: false) }.keyboardShortcut("m", modifiers: [.command, .option, .shift])
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }.keyboardShortcut("[")
            Button("Forward") { model.tab.goForward() }.keyboardShortcut("]")
            Button("Enclosing Folder") { if !forwardToTextField(#selector(NSResponder.moveToBeginningOfDocument(_:))) { model.tab.goUp(); model.show(.folder) } }.keyboardShortcut(.upArrow)
            Button("Open") { if !forwardToTextField(#selector(NSResponder.moveToEndOfDocument(_:))), let u = model.selectedURLs.first { model.openItem(u) } }.keyboardShortcut(.downArrow)
            Divider()
            Button("Home Dashboard") { model.show(.home) }.keyboardShortcut("h", modifiers: [.command, .option, .shift])
            Button("Recents") { model.show(.recents) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Downloaded From") { model.show(.downloadedFrom) }.keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Home") { model.open(folder: Places.home) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { model.open(folder: Places.desktop) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Documents") { model.open(folder: Places.documents) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Downloads") { model.open(folder: Places.downloads) }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Applications") { model.open(folder: Places.applications) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Go to Folder…") { model.goToFolder = true }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu("Tidy") {
            Button("Clean Up") { model.show(.cleanup) }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Duplicates") { model.show(.duplicates) }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Space Map") { model.show(.spaceMap) }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Disk Usage") { model.show(.diskUsage) }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Mac Health") { model.show(.health) }.keyboardShortcut("h", modifiers: [.command, .option, .control])
            Button("Memory") { model.show(.memory) }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Organize Folder…") { model.show(.organize) }
            Button("Assistant") { model.show(.assistant) }.keyboardShortcut("a", modifiers: [.command, .option, .shift])
            Divider()
            Button("Activity") { model.show(.activity) }.keyboardShortcut("y", modifiers: [.command, .shift])
            Button("Put Back Last Cleanup") { ActivityLog.shared.undoLast(of: [.cleanup, .trash, .uninstall]) }.keyboardShortcut("z", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Getting Started") { UserDefaults.standard.set(false, forKey: "hideGettingStarted"); model.show(.home) }
            Button("Keyboard Shortcuts") { model.show(.tool("shortcuts")) }
        }
    }

    /// When a text field is being edited, route standard edit commands to it instead of the file browser.
    private func forwardToTextField(_ sel: Selector) -> Bool {
        if let r = NSApp.keyWindow?.firstResponder, r is NSText || r is NSTextView {
            return NSApp.sendAction(sel, to: nil, from: nil)
        }
        return false
    }
}
