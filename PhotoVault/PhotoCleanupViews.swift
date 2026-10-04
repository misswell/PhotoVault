import AVFoundation
import CryptoKit
import ImageIO
import Photos
import SwiftUI
import Charts

struct ScannedMedia: Codable, Identifiable, Sendable {
    let id: String
    let date: Date?
    let modified: Date?
    let bytes: Int64?
    let kind: Int
    let live: Bool
    let screenshot: Bool
    let width: Int
    let height: Int
    let hash: UInt64?
    let digest: String?
}

struct CleanupSnapshot: Codable, Sendable {
    let date: Date
    let libraryCount: Int
    let items: [ScannedMedia]
    let similarGroups: [[String]]
}

struct CleanupDay: Sendable { let date: Date; let bytes: Int64; let unknownCount: Int }
struct CleanupBucket: Sendable { let name: String; let count: Int }
struct CleanupProjection: Sendable {
    let bytes: Int64
    let measuredCount: Int
    let duplicates: [[String]]
    let categories: [String: [ScannedMedia]]
    let days: [CleanupDay]
    let buckets: [CleanupBucket]
}

actor CleanupProjectionWorker {
    static let shared = CleanupProjectionWorker()
    func sort(_ items: [ScannedMedia], ascending: Bool) -> [ScannedMedia] {
        items.sorted { ascending ? ($0.bytes ?? -1) < ($1.bytes ?? -1) : ($0.bytes ?? -1) > ($1.bytes ?? -1) }
    }
    func project(_ snapshot: CleanupSnapshot) -> CleanupProjection {
        let items = snapshot.items
        let duplicates = Dictionary(grouping: items.filter { $0.digest != nil }, by: { $0.digest! }).values.filter { $0.count > 1 }.map { $0.map(\.id) }
        let categories = [
            "screenshots": items.filter { $0.screenshot && ($0.bytes ?? 0) > 1_000_000 },
            "photos": items.filter { $0.kind == PHAssetMediaType.image.rawValue && !$0.live && ($0.bytes ?? 0) >= 5_000_000 },
            "videos": items.filter { $0.kind == PHAssetMediaType.video.rawValue && ($0.bytes ?? 0) >= 50_000_000 },
            "live": items.filter { $0.live && ($0.bytes ?? 0) >= 3_000_000 }
        ]
        let days = Dictionary(grouping: items.filter { $0.date != nil }, by: { Calendar.current.startOfDay(for: $0.date!) })
            .map { CleanupDay(date: $0.key, bytes: $0.value.reduce(0) { $0 + ($1.bytes ?? 0) }, unknownCount: $0.value.filter { $0.bytes == nil }.count) }.sorted { $0.date > $1.date }
        let ranges: [(String, Range<Int64>)] = [("< 1 MB", 0..<1_000_000), ("1–5 MB", 1_000_000..<5_000_000), ("5–20 MB", 5_000_000..<20_000_000), ("20–100 MB", 20_000_000..<100_000_000), ("≥ 100 MB", 100_000_000..<Int64.max)]
        let buckets = ranges.map { name, range in CleanupBucket(name: name, count: items.filter { $0.bytes.map { range.contains($0) } ?? false }.count) }
        return CleanupProjection(bytes: items.reduce(0) { $0 + ($1.bytes ?? 0) }, measuredCount: items.filter { $0.bytes != nil }.count,
                                 duplicates: duplicates, categories: categories, days: days, buckets: buckets)
    }
}

/// Six disjoint hash bands guarantee that a pair within five differing bits
/// shares a band. Candidate lookup spans the library without an all-pairs scan.
struct CleanupSimilarityIndex {
    private struct Candidate { let id: String; let hash: UInt64; let ratio: Double }
    private struct Band: Hashable { let index: Int; let value: UInt64 }
    private var buckets: [Band: [Candidate]] = [:]
    private var exact: [UInt64: [Candidate]] = [:]
    private var groupByID: [String: Int] = [:]
    private(set) var groups: [[String]] = []

    mutating func add(id: String, hash: UInt64, ratio: Double) {
        let candidate = Candidate(id: id, hash: hash, ratio: ratio)
        let identical = exact[hash]?.first { abs($0.ratio - ratio) < 0.05 }
        let bands = (0..<6).map { index in
            let shift = index * 11
            let bits = min(11, 64 - shift)
            return Band(index: index, value: (hash >> shift) & ((1 << bits) - 1))
        }
        var match = identical
        if match == nil {
            for band in bands {
                if let found = buckets[band]?.last(where: { abs($0.ratio - ratio) < 0.05 && ($0.hash ^ hash).nonzeroBitCount <= 5 }) {
                    match = found; break
                }
            }
        }
        if let match {
            if let group = groupByID[match.id] { groups[group].append(id); groupByID[id] = group }
            else { groupByID[match.id] = groups.count; groupByID[id] = groups.count; groups.append([match.id, id]) }
        }
        // Identical hashes with a matching aspect ratio already have a lookup
        // representative; avoid huge candidate buckets for repeated images.
        if identical == nil {
            exact[hash, default: []].append(candidate)
            for band in bands { buckets[band, default: []].append(candidate) }
        }
    }
}

actor PhotoCleanupWorker {
    static let shared = PhotoCleanupWorker()
    private var cacheURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cleanup-v2.json")
    }
    func load() -> CleanupSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CleanupSnapshot.self, from: data)
    }
    func scan(_ assets: PhotoFetchSnapshot, progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> CleanupSnapshot {
        let old = load()
        let cached = Dictionary((old?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var items: [ScannedMedia] = []
        var similarity = CleanupSimilarityIndex()
        var lastProgress = Date.distantPast
        for index in 0..<assets.result.count {
            try Task.checkCancellation()
            let asset = assets.result.object(at: index)
            let item: ScannedMedia
            if let previous = cached[asset.localIdentifier], previous.modified == asset.modificationDate, previous.bytes != nil {
                item = previous
            } else {
                let input = await localInput(asset)
                var url: URL? = input?.fullSizeImageURL
                if asset.mediaType == .video { url = (input?.audiovisualAsset as? AVURLAsset)?.url }
                let bytes = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init)
                let hash = asset.mediaType == .image ? url.flatMap(Self.perceptualHash) : nil
                // Exact duplicate detection streams local files. Never asks
                // PhotoKit to download an iCloud original during a scan.
                let digest = !asset.mediaSubtypes.contains(.photoLive) ? url.flatMap(Self.digest) : nil
                item = ScannedMedia(id: asset.localIdentifier, date: asset.creationDate, modified: asset.modificationDate,
                                    bytes: bytes, kind: asset.mediaType.rawValue, live: asset.mediaSubtypes.contains(.photoLive), screenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                                    width: asset.pixelWidth, height: asset.pixelHeight, hash: hash, digest: digest)
            }
            items.append(item)
            if let hash = item.hash, item.height > 0 {
                similarity.add(id: item.id, hash: hash, ratio: Double(item.width) / Double(item.height))
            }
            if Date().timeIntervalSince(lastProgress) > 0.3 {
                await progress(index + 1, assets.result.count); lastProgress = .now
            }
        }
        try Task.checkCancellation()
        let snapshot = CleanupSnapshot(date: .now, libraryCount: assets.result.count, items: items, similarGroups: similarity.groups)
        if let data = try? JSONEncoder().encode(snapshot) {
            try Task.checkCancellation()
            try? data.write(to: cacheURL, options: .atomic)
        }
        await progress(items.count, assets.result.count)
        return snapshot
    }

    private func localInput(_ asset: PHAsset) async -> PHContentEditingInput? {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        options.canHandleAdjustmentData = { @Sendable _ in false }
        let box = WorkspaceContinuation<WorkspaceEditingInput>()
        let source = WorkspacePhotoAsset(value: asset)
        let result = try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.attach(continuation)
                let id = asset.requestContentEditingInput(with: options) { @Sendable input, _ in
                    if let input { box.resume(.success(WorkspaceEditingInput(value: input))) }
                    else { box.resume(.failure(MediaWorkspaceError.unavailable)) }
                }
                box.installCancellation { source.value.cancelContentEditingInputRequest(id) }
            }
        } onCancel: { box.cancel() }
        return result?.value
    }

    nonisolated private static func digest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
                if Task.isCancelled { return nil }
                hash.update(data: block)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }

    nonisolated private static func perceptualHash(_ url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        var result: UInt64 = 0
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8)); return true
        }
        guard success else { return nil }
        for y in 0..<8 { for x in 0..<8 { if pixels[y * 9 + x] > pixels[y * 9 + x + 1] { result |= UInt64(1) << UInt64(y * 8 + x) } } }
        return result
    }
}

@MainActor
final class PhotoCleanupModel: ObservableObject {
    @Published var snapshot: CleanupSnapshot?
    @Published var projection: CleanupProjection?
    @Published var running = false
    @Published var processed = 0
    @Published var total = 0
    private var task: Task<Void, Never>?
    func load() async {
        if snapshot == nil, let result = await PhotoCleanupWorker.shared.load() {
            projection = await CleanupProjectionWorker.shared.project(result)
            snapshot = result
        }
    }
    func start(_ assets: PHFetchResult<PHAsset>) {
        guard !running else { return }
        running = true; processed = 0; total = assets.count
        let result = PhotoFetchSnapshot(result: assets)
        task = Task {
            defer { running = false; task = nil }
            do {
                let snapshot = try await PhotoCleanupWorker.shared.scan(result) { [weak self] count, total in
                    guard !Task.isCancelled else { return }
                    await MainActor.run { guard self?.running == true else { return }; self?.processed = count; self?.total = total }
                }
                let projection = await CleanupProjectionWorker.shared.project(snapshot)
                try Task.checkCancellation()
                self.projection = projection; self.snapshot = snapshot
            } catch is CancellationError {
                // Preserve the last complete snapshot when paused or hidden.
            } catch {
                PagerDiagnostics.log("cleanup_scan_failed \(error.localizedDescription)")
            }
        }
    }
    func stop() { task?.cancel() }
}

struct PhotoCleanupScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    @StateObject private var model = PhotoCleanupModel()
    @ObservedObject private var scene = AppSceneState.shared
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let snapshot = model.snapshot, let projection = model.projection {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(ByteCountFormatter.string(fromByteCount: projection.bytes, countStyle: .file)).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                            Text("已读取本机媒体 · \(projection.measuredCount.formatted()) / \(snapshot.libraryCount.formatted()) 项").font(.caption).foregroundStyle(.secondary)
                            Text("云端原片及未读取的 Live Photo 配对视频不计入大小。统计时间：\(snapshot.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                            if snapshot.libraryCount != store.allPhotos?.count { Text("图库已变化，请更新扫描。").font(.caption).foregroundStyle(.orange) }
                        }
                    } else { Text("扫描本机媒体，查看占用与清理建议。").foregroundStyle(.secondary) }
                    if model.running {
                        ProgressView(value: Double(model.processed), total: Double(max(1, model.total)))
                        HStack { Text("\(model.processed) / \(model.total)").font(.caption).monospacedDigit(); Spacer(); Button("暂停") { model.stop() } }
                    } else {
                        Button(model.snapshot == nil ? "开始扫描" : "更新扫描", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") { if let assets = store.allPhotos { model.start(assets) } }.disabled(store.allPhotos == nil)
                    }
                }
                if let snapshot = model.snapshot, let projection = model.projection {
                    Section("清理建议") {
                        NavigationLink { CleanupGroupList(title: "相似照片", groups: snapshot.similarGroups, store: store) } label: { Label("相似照片 · \(snapshot.similarGroups.count) 组", systemImage: "square.on.square") }

                        NavigationLink { CleanupGroupList(title: "重复文件", groups: projection.duplicates, store: store) } label: { Label("重复文件 · \(projection.duplicates.count) 组", systemImage: "doc.on.doc") }
                        category("大截图", symbol: "viewfinder", items: projection.categories["screenshots"] ?? [])
                        category("大照片", symbol: "photo", items: projection.categories["photos"] ?? [])
                        category("大视频", symbol: "video", items: projection.categories["videos"] ?? [])
                        category("大 Live Photo", symbol: "livephoto", items: projection.categories["live"] ?? [])
                        NavigationLink { CleanupAssetList(title: "全部文件排序", items: snapshot.items, store: store) } label: { Label("全部文件排序", systemImage: "arrow.up.arrow.down") }
                    }
                    Section("更多工具") {
                        NavigationLink { CleanupStatisticsScreen(projection: projection) } label: { Label("每日空间统计 / 文件大小分布", systemImage: "chart.bar") }
                        NavigationLink { WorkspaceAlbumBrowser(store: store) } label: { Label("按相册清理", systemImage: "rectangle.stack") }
                        NavigationLink { RandomDayWorkspace(store: store) } label: { Label("随机整理某天", systemImage: "dice") }
                        NavigationLink { EmptyAlbumScreen(store: store) } label: { Label("空相册和文件夹", systemImage: "folder.badge.minus") }
                    }
                }
                Section { NavigationLink { CompressionHistoryScreen(store: store) } label: { Label("压缩记录与对比", systemImage: "rectangle.split.2x1") } }
            }
            .labelStyle(.titleAndIcon)
            .navigationTitle("清理相册")
            .task { await model.load() }
            .onChange(of: scene.phase) { _, value in if value == .background { model.stop() } }
            .onDisappear { model.stop() }
        }
    }
    private func category(_ title: String, symbol: String, items: [ScannedMedia]) -> some View {
        NavigationLink { CleanupAssetList(title: title, items: items, store: store) } label: { Label("\(title) · \(items.count)", systemImage: symbol) }
    }
}

private struct CleanupGroupList: View {
    let title: String
    let groups: [[String]]
    @ObservedObject var store: PhotoLibraryStore
    var body: some View {
        List {
            Text("相似度仅用于发现候选；打开每组查看并选择要删除的照片。系统不会自动选择或删除原片。").font(.footnote).foregroundStyle(.secondary)
            ForEach(Array(groups.enumerated()), id: \.offset) { index, ids in
                NavigationLink {
                    WorkspaceIdentifierGrid(title: "\(title) · 第 \(index + 1) 组", ids: ids, store: store)
                } label: {
                    HStack { ForEach(Array(ids.prefix(4)), id: \.self) { id in WorkspaceIdentifierThumbnail(id: id, revision: store.libraryRevision).frame(width: 55, height: 55).clipShape(RoundedRectangle(cornerRadius: 7)) }; Spacer(); Text("\(ids.count) 项") }
                }
            }
        }.navigationTitle(title)
        .overlay { if groups.isEmpty { ContentUnavailableView("没有发现候选", systemImage: "checkmark.circle") } }
    }
}

private struct CleanupAssetList: View {
    let title: String
    let items: [ScannedMedia]
    @ObservedObject var store: PhotoLibraryStore
    @State private var ascending = false
    @State private var page = 0
    private let pageSize = 200
    @State private var sorted: [ScannedMedia] = []
    @State private var pageAssets: [String: PHAsset] = [:]
    private var current: [ScannedMedia] { Array(sorted.dropFirst(page * pageSize).prefix(pageSize)) }
    var body: some View {
        List {
            NavigationLink("选择 / 压缩 / 删除这一页") { WorkspaceIdentifierGrid(title: title, ids: current.map(\.id), store: store) }
            ForEach(current) { item in
                if let asset = pageAssets[item.id] {
                    NavigationLink { WorkspaceIdentifierGrid(title: title, ids: [item.id], store: store) } label: {
                        HStack { WorkspaceThumbnail(asset: asset).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 8)); VStack(alignment: .leading) { Text(item.date?.formatted(date: .abbreviated, time: .shortened) ?? "未知日期"); Text(item.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "云端 / 大小未知").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            }
            HStack { Button("上一页") { page -= 1 }.disabled(page == 0); Spacer(); Text("\(page + 1) / \(max(1, (items.count + pageSize - 1) / pageSize))"); Spacer(); Button("下一页") { page += 1 }.disabled((page + 1) * pageSize >= items.count) }
        }.navigationTitle(title)
        .task(id: "\(ascending)-\(items.count)") {
            let result = await CleanupProjectionWorker.shared.sort(items, ascending: ascending)
            guard !Task.isCancelled else { return }; sorted = result
        }
        .task(id: WorkspaceIdentifierRequest(ids: current.map(\.id), revision: store.libraryRevision)) {
            let result = await WorkspaceAssetQuery.shared.batch(current.map(\.id))
            guard !Task.isCancelled else { return }; pageAssets = result.assets
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("大小排序", systemImage: "arrow.up.arrow.down") { ascending.toggle(); page = 0 } } }
    }
}

private struct CleanupStatisticsScreen: View {
    let projection: CleanupProjection
    private var daily: [CleanupDay] { projection.days }
    private var buckets: [CleanupBucket] { projection.buckets }
    var body: some View {
        List {
            Section("文件大小分布 · 已读取本机媒体") {
                Chart(buckets, id: \.name) { item in BarMark(x: .value("文件数", item.count), y: .value("大小", item.name)).foregroundStyle(.blue) }.frame(height: 180)
            }
            Section("每日空间统计") {
                ForEach(daily, id: \.date) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(day.date.formatted(date: .abbreviated, time: .omitted), value: day.unknownCount > 0 && day.bytes == 0 ? "大小未知" : ByteCountFormatter.string(fromByteCount: day.bytes, countStyle: .file))
                        if day.unknownCount > 0 { Text("\(day.unknownCount) 项大小未知，未计入已读取大小").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.navigationTitle("空间统计")
    }
}

private struct EmptyAlbumScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    @State private var error: String?
    var body: some View {
        List {
            Text("只列出空的普通相册。删除相册不会删除照片，文件夹保留原层级。").font(.footnote).foregroundStyle(.secondary)
            ForEach(store.albums.filter { $0.kind == .user && $0.assetCount == 0 }) { album in
                HStack { Label(album.title, systemImage: "rectangle.stack"); Spacer(); Button("删除", role: .destructive) { delete(album) } }
            }
            ForEach(emptyFolders) { folder in
                HStack { Label(folder.title, systemImage: "folder"); Spacer(); Button("删除", role: .destructive) { deleteFolder(folder) } }
            }
        }.navigationTitle("空相册和文件夹")
            .alert("无法删除", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func delete(_ album: PhotoAlbum) {
        Task {
            do { try await PHPhotoLibrary.shared().performChanges { @Sendable in PHAssetCollectionChangeRequest.deleteAssetCollections([album.collection] as NSArray) } }
            catch { if !isUserCancelledPhotoChange(error) { self.error = error.localizedDescription } }
        }
    }
    private var emptyFolders: [PhotoAlbumFolder] {
        func collect(_ folders: [PhotoAlbumFolder]) -> [PhotoAlbumFolder] {
            folders.flatMap { $0.albumCount == 0 ? [$0] : collect($0.subfolders) }
        }
        return collect(store.albumFolders)
    }
    private func deleteFolder(_ folder: PhotoAlbumFolder) {
        let collection = folder.collection
        Task {
            do { try await PHPhotoLibrary.shared().performChanges { @Sendable in PHCollectionListChangeRequest.deleteCollectionLists([collection] as NSArray) } }
            catch { if !isUserCancelledPhotoChange(error) { self.error = error.localizedDescription } }
        }
    }
}

private struct RandomDayWorkspace: View {
    @ObservedObject var store: PhotoLibraryStore
    @State private var days: [LibraryPeriod] = []
    @State private var period: LibraryPeriod?
    @State private var loading = true
    var body: some View {
        Group {
            if let period { LibraryPeriodScreen(period: period, store: store).id(period.id) }
            else if loading { ProgressView("正在挑选一天…") }
            else { ContentUnavailableView("没有可整理的日期", systemImage: "calendar") }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("换一天", systemImage: "dice") { period = days.randomElement() }.disabled(days.isEmpty) } }
        .task(id: store.libraryRevision) {
            guard let assets = store.allPhotos else { return }
            loading = true
            if let result = try? await LibraryTimelineWorker.shared.periods(PhotoFetchSnapshot(result: assets), mode: .days), !Task.isCancelled {
                days = result
                period = result.first { $0.id == period?.id } ?? result.randomElement()
                loading = false
            }
        }
    }
}
