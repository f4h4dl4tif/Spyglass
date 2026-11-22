import SwiftUI
import AppKit

@MainActor final class StatusItemController: NSObject {
    static let shared = StatusItemController()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var readingsTimer: Timer?

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = Self.icon()
        it.button?.imagePosition = .imageLeading
        it.button?.target = self
        it.button?.action = #selector(toggle)
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if let b = it.button {
            let drop = StatusDropView(frame: b.bounds)
            drop.autoresizingMask = [.width, .height]
            b.addSubview(drop)
        }
        item = it
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 460)
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        applyReadings()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let on = UserDefaults.standard.bool(forKey: "menuBarEnabled")
                if !on { StatusItemController.shared.remove() } else if StatusItemController.shared.item == nil { StatusItemController.shared.install() }
                StatusItemController.shared.applyReadings()
            }
        }
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil; readingsTimer?.invalidate(); readingsTimer = nil
    }

    func applyReadings() {
        let on = UserDefaults.standard.bool(forKey: "menuBarReadings")
        if on && readingsTimer == nil {
            _ = SystemStats.cpu(); _ = SystemStats.network()
            readingsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                DispatchQueue.global(qos: .utility).async {
                    let c = SystemStats.cpu(), m = SystemStats.memory(), n = SystemStats.network()
                    let title = String(format: " %d%%  %@  ↓%@", Int(c * 100), ["", "●", "◐", "", "○"][min(m.pressure, 4)], Fmt.size(Int64(n.0)).replacingOccurrences(of: " ", with: ""))
                    DispatchQueue.main.async { StatusItemController.shared.item?.button?.title = title }
                }
            }
            readingsTimer?.tolerance = 1
        } else if !on {
            readingsTimer?.invalidate(); readingsTimer = nil
            item?.button?.title = ""
        }
    }

    func setRecording(_ on: Bool) {
        guard let b = item?.button else { return }
        if on {
            b.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording — click to stop")
            b.contentTintColor = .systemRed
            b.toolTip = "Recording — click to stop"
        } else { b.image = Self.icon(); b.contentTintColor = nil; b.toolTip = nil }
    }

    @objc func toggle() {
        guard let b = item?.button else { return }
        if ScreenRecorder.shared.recording { ScreenRecorder.shared.stop(); return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NotificationCenter.default.post(name: .menuBarWillOpen, object: nil)
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func close() { popover.performClose(nil) }

    /// Template icon: a folder with a spyglass lens.
    static func icon() -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { r in
            NSColor.black.set()
            let folder = NSBezierPath()
            folder.move(to: NSPoint(x: 1.5, y: 2))
            folder.line(to: NSPoint(x: 1.5, y: 13))
            folder.line(to: NSPoint(x: 6.5, y: 13))
            folder.line(to: NSPoint(x: 8, y: 11.5))
            folder.line(to: NSPoint(x: 16.5, y: 11.5))
            folder.line(to: NSPoint(x: 16.5, y: 8))
            folder.move(to: NSPoint(x: 1.5, y: 2))
            folder.line(to: NSPoint(x: 9, y: 2))
            folder.lineWidth = 1.5; folder.lineJoinStyle = .round; folder.lineCapStyle = .round
            folder.stroke()
            let lens = NSBezierPath(ovalIn: NSRect(x: 10, y: 2.5, width: 6.5, height: 6.5))
            lens.lineWidth = 1.6; lens.stroke()
            let handle = NSBezierPath(); handle.move(to: NSPoint(x: 15.6, y: 3.3)); handle.line(to: NSPoint(x: 18.6, y: 0.6))
            handle.lineWidth = 2; handle.lineCapStyle = .round; handle.stroke()
            NSBezierPath(ovalIn: NSRect(x: 11.8, y: 5.6, width: 1.6, height: 1.6)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

extension Notification.Name { static let menuBarWillOpen = Notification.Name("SpyglassMenuBarWillOpen") }

/// Lets files be dropped on the menu bar icon: files open in Spyglass, folders open in Disk Usage.
final class StatusDropView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the button
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let first = urls.first else { return false }
        MainActor.assumeIsolated {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            if isDir.boolValue && urls.count == 1 { DiskScan.shared.scan(first); AppModel.shared.show(.diskUsage) }
            else { AppModel.shared.reveal(first) }
        }
        return true
    }
}

struct MenuBarView: View {
    @State private var downloads: [Spotlight.Hit] = []
    @ObservedObject var mon = SystemMonitor.shared
    @AppStorage("menuBarReadings") private var readings = false
    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(nsImage: StatusItemController.icon()).renderingMode(.template)
                Text("Spyglass").font(.headline)
                Spacer()
                Button { StatusItemController.shared.close(); QuickSearchPanel.shared.show() } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Quick Search")
                Button { StatusItemController.shared.close(); AppModel.shared.show(.home) } label: { Image(systemName: "macwindow") }.buttonStyle(.borderless).help("Open Spyglass")
            }.padding(12)
            HStack(spacing: 8) {
                mini("cpu", "\(Int(mon.r.cpu * 100))%", "CPU")
                mini("memorychip", ["", "Normal", "Elevated", "", "Critical"][min(mon.r.pressure, 4)], "Memory")
                mini("internaldrive", Fmt.size(mon.r.diskFree), "Free")
                mini("arrow.down", SystemStats.rate(mon.r.netIn), "Network")
            }.padding(.horizontal, 12)
            Divider().padding(.top, 10)
            HStack { Text("Recent Downloads").font(.subheadline.weight(.semibold)); Spacer()
                Button("Open Folder") { StatusItemController.shared.close(); AppModel.shared.open(folder: Places.downloads) }.buttonStyle(.borderless).font(.caption) }
                .padding(.horizontal, 12).padding(.vertical, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(downloads) { h in
                        HStack(spacing: 10) {
                            Thumb(url: h.url, side: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.name).lineLimit(1)
                                Text("\(Fmt.size(h.size)) · \(Fmt.ago(h.date))" + (Meta.sourceName(for: Meta.whereFroms(h.url)).map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { FileOps.open(h.url); StatusItemController.shared.close() }
                        .onDrag { NSItemProvider(object: h.url as NSURL) }
                        .contextMenu { Button("Show in Spyglass") { AppModel.shared.reveal(h.url) }; Button("Show in Finder") { FileOps.reveal([h.url]) }; Button("Move to Trash") { FileOps.trash([h.url]); load() } }
                        .help("Drag into any app")
                    }
                    if downloads.isEmpty { Text("No downloads yet").foregroundStyle(.secondary).padding() }
                }.padding(.horizontal, 4)
            }
            Divider()
            HStack {
                Button("Clean Up") { StatusItemController.shared.close(); AppModel.shared.show(.cleanup) }
                Button("Mac Health") { StatusItemController.shared.close(); AppModel.shared.show(.health) }
                Spacer()
                Menu {
                    Toggle("Show readings in menu bar", isOn: $readings)
                    Button("Settings…") { StatusItemController.shared.close(); NSApp.activate(ignoringOtherApps: true); NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                    Divider()
                    Button("Quit Spyglass") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 34)
            }.padding(10)
        }
        .frame(width: 340, height: 460)
        .onReceive(NotificationCenter.default.publisher(for: .menuBarWillOpen)) { _ in load(); mon.start() }
        .onDisappear { mon.stop() }
        .onAppear { load(); mon.start() }
    }

    func mini(_ s: String, _ v: String, _ t: String) -> some View {
        VStack(spacing: 2) { Image(systemName: s).font(.caption).foregroundStyle(.secondary); Text(v).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7); Text(t).font(.caption2).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity).padding(.vertical, 6).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    func load() {
        Task { downloads = await Spotlight.run("kMDItemPath == \"\(Places.downloads.path)/*\"", scopes: [Places.downloads.path], sort: "kMDItemDateAdded", limit: 10).hits }
    }
}
