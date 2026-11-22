import SwiftUI
import Photos

/// Read-only view of the Photos library, including shared albums.
@MainActor final class PhotoLibrary: ObservableObject {
    static let shared = PhotoLibrary()
    enum Filter: String, CaseIterable { case all = "All", favorites = "Favorites", videos = "Videos", screenshots = "Screenshots", selfies = "Selfies", live = "Live" }
    @Published var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var assets: PHFetchResult<PHAsset>?
    @Published var albums: [PHAssetCollection] = []
    @Published var album: PHAssetCollection?
    @Published var filter = Filter.all
    let images = PHCachingImageManager()

    func request() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in DispatchQueue.main.async { self.status = s; self.load() } }
    }

    func load() {
        guard status == .authorized || status == .limited else { return }
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var preds: [NSPredicate] = []
        switch filter {
        case .favorites: preds.append(NSPredicate(format: "favorite == YES"))
        case .videos: preds.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        case .screenshots: preds.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
        case .live: preds.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue))
        default: break
        }
        if !preds.isEmpty { o.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds) }
        if filter == .selfies, album == nil,
           let selfies = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil).firstObject {
            assets = PHAsset.fetchAssets(in: selfies, options: o)
        } else if let album { assets = PHAsset.fetchAssets(in: album, options: o) }
        else { assets = PHAsset.fetchAssets(with: o) }
        var list: [PHAssetCollection] = []
        for type in [PHAssetCollectionType.album] {
            for sub in [PHAssetCollectionSubtype.albumRegular, .albumCloudShared, .albumSyncedAlbum] {
                PHAssetCollection.fetchAssetCollections(with: type, subtype: sub, options: nil).enumerateObjects { c, _, _ in list.append(c) }
            }
        }
        albums = list
    }

    /// Exports originals to ~/Downloads/Spyglass/Photos.
    func export(_ assets: [PHAsset]) {
        let dir = FileOps.outputFolder("Photos")
        var out: [URL] = []
        let group = DispatchGroup()
        for a in assets {
            guard let r = PHAssetResource.assetResources(for: a).first(where: { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto }) ?? PHAssetResource.assetResources(for: a).first else { continue }
            let dest = FileOps.uniqueURL(dir.appendingPathComponent(r.originalFilename))
            let opts = PHAssetResourceRequestOptions(); opts.isNetworkAccessAllowed = true
            group.enter()
            PHAssetResourceManager.default().writeData(for: r, toFile: dest, options: opts) { err in
                DispatchQueue.main.async { if err == nil { out.append(dest) }; group.leave() }
            }
        }
        group.notify(queue: .main) {
            FileOps.created(out, title: "Exported \(out.count) photo\(out.count == 1 ? "" : "s")")
            FileOps.reveal(out)
        }
    }
}

struct PhotosView: View {
    @StateObject private var lib = PhotoLibrary.shared
    @State private var size = 130.0
    @State private var selected = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: lib.album?.localizedTitle ?? "Photos", subtitle: subtitle, symbol: "photo.stack", tint: .orange) {
                HStack {
                    if lib.status == .authorized || lib.status == .limited {
                        Menu(lib.album?.localizedTitle ?? "All Photos") {
                            Button("All Photos") { lib.album = nil; lib.load() }
                            Divider()
                            ForEach(lib.albums, id: \.localIdentifier) { a in
                                Button((a.assetCollectionSubtype == .albumCloudShared ? "Shared · " : "") + (a.localizedTitle ?? "Album")) { lib.album = a; lib.load() }
                            }
                        }.frame(width: 170)
                        Button { export() } label: { Label("Export", systemImage: "square.and.arrow.down") }.disabled(selected.isEmpty)
                        Slider(value: $size, in: 70...260).frame(width: 100)
                    }
                }
            }.padding(20)
            if lib.status == .authorized || lib.status == .limited {
                Picker("", selection: $lib.filter) { ForEach(PhotoLibrary.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 10)
                    .onChange(of: lib.filter) { _, _ in lib.load() }
                Divider()
                if let a = lib.assets, a.count > 0 {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: size), spacing: 4)], spacing: 4) {
                            ForEach(0..<a.count, id: \.self) { i in
                                let asset = a.object(at: i)
                                AssetThumb(asset: asset, side: size, selected: selected.contains(asset.localIdentifier))
                                    .onTapGesture {
                                        if NSApp.currentEvent?.clickCount == 2 { lib.export([asset]) }
                                        else if NSEvent.modifierFlags.contains(.command) { if selected.contains(asset.localIdentifier) { selected.remove(asset.localIdentifier) } else { selected.insert(asset.localIdentifier) } }
                                        else { selected = [asset.localIdentifier] }
                                    }
                                    .contextMenu { Button("Export Original") { lib.export([asset]) }; Button("Open Photos") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app")) } }
                            }
                        }.padding(8)
                    }
                } else { EmptyState(symbol: "photo", title: "No photos here") }
            } else {
                VStack(spacing: 12) {
                    EmptyState(symbol: "photo.stack", title: "See your Photos library", message: "Spyglass shows your photos and shared albums read-only. Nothing is changed or uploaded. Double-click a photo to export the original.")
                    if lib.status == .notDetermined { Button("Allow Access to Photos") { lib.request() }.buttonStyle(.borderedProminent) }
                    else { Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!) } }
                }.frame(maxHeight: .infinity)
            }
        }
        .task { lib.status = PHPhotoLibrary.authorizationStatus(for: .readWrite); if lib.assets == nil { lib.load() } }
    }

    var subtitle: String {
        guard let a = lib.assets else { return "Read-only · nothing is changed" }
        return "\(Fmt.count(a.count)) items" + (selected.isEmpty ? "" : " · \(selected.count) selected")
    }
    func export() {
        guard let a = lib.assets else { return }
        var list: [PHAsset] = []
        a.enumerateObjects { x, _, _ in if selected.contains(x.localIdentifier) { list.append(x) } }
        lib.export(list)
    }
}

struct AssetThumb: View {
    let asset: PHAsset
    let side: Double
    let selected: Bool
    @State private var image: NSImage?
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Color.primary.opacity(0.06))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity) }
            if asset.mediaType == .video { Text(String(format: "%d:%02d", Int(asset.duration) / 60, Int(asset.duration) % 60)).font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(4).shadow(radius: 2) }
            if asset.isFavorite { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.white).padding(4).shadow(radius: 2).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
        }
        .frame(width: side, height: side).clipped()
        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0))
        .task(id: asset.localIdentifier) {
            let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true; o.resizeMode = .fast
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            PhotoLibrary.shared.images.requestImage(for: asset, targetSize: CGSize(width: side * scale, height: side * scale), contentMode: .aspectFill, options: o) { img, _ in
                withAnimation(.easeOut(duration: 0.15)) { image = img }
            }
        }
    }
}

// MARK: - Blurry photo detection (variance of the Laplacian on a small greyscale copy)

enum Blur {
    /// Lower = blurrier. Returns nil for images with depth data (portraits with a soft background are intentional).
    static func sharpness(_ u: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDisparity) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDepth) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypePortraitEffectsMatte) != nil { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = img.width, h = img.height
        guard w > 16, h > 16 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            let r = y * w
            for x in 1..<(w - 1) {
                let l = Double(px[r + x - 1]) + Double(px[r + x + 1]) + Double(px[r - w + x]) + Double(px[r + w + x]) - 4 * Double(px[r + x])
                sum += l; sq += l * l; n += 1
            }
        }
        let mean = sum / n
        return sq / n - mean * mean
    }
}
