import Photos
import SwiftUI

struct PhotoDiscoveryScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    @ObservedObject private var workspace = PhotoWorkspaceStore.shared
    @State private var query = ""
    @State private var showSettings = false
    @State private var noteIDs: [String] = []
    @State private var noteAssets: [String: PHAsset] = [:]
    @State private var noteLimit = 200
    @State private var anniversary: PhotoAnniversary?
    @State private var showNewAnniversary = false
    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section("备注") {
                        ForEach(Array(noteIDs.prefix(noteLimit)), id: \.self) { id in
                            if let asset = noteAssets[id] {
                                NavigationLink {
                                    WorkspaceIdentifierGrid(title: "备注搜索", ids: [id], store: store)
                                } label: { HStack { WorkspaceThumbnail(asset: asset).frame(width: 44, height: 44); Text(workspace.notes[id] ?? "").lineLimit(3) } }
                            }
                        }
                    }
                    if noteIDs.count > noteLimit { Button("显示更多备注") { noteLimit += 200 } }
                    Section("日记") {
                        ForEach(workspace.journal.filter { $0.text.localizedStandardContains(query) }) { entry in
                            NavigationLink { JournalEditorSheet(entry: entry) } label: { Text(entry.text).lineLimit(3) }
                        }
                    }
                    Section("相册") {
                        ForEach(store.albums.filter { $0.title.localizedStandardContains(query) }) { album in
                            NavigationLink(album.title) { WorkspaceAlbumGrid(album: album, store: store) }
                        }
                    }
                } else {
                    Section("快捷访问") {
                        NavigationLink { LongScreenshotScreen() } label: { Label("长截图", systemImage: "rectangle.portrait.on.rectangle.portrait") }
                        NavigationLink { SmartSearchScreen(store: store) } label: { Label("智能搜图", systemImage: "sparkle.magnifyingglass") }
                        NavigationLink { RandomPhotoOrganizerView(store: store) } label: { Label("随机漫游", systemImage: "shuffle") }
                        NavigationLink { OnThisDayScreen(store: store) } label: { Label("往年今日", systemImage: "clock.arrow.circlepath") }
                        NavigationLink { FavoriteWorkspaceScreen(store: store) } label: { Label("我的收藏", systemImage: "heart") }
                        NavigationLink { JournalListScreen() } label: { Label("我的日记", systemImage: "book.closed") }
                        NavigationLink { CompressionHistoryScreen(store: store) } label: { Label("压缩前后对比", systemImage: "rectangle.split.2x1") }
                    }
                    Section("生日与纪念日") {
                        ForEach(workspace.anniversaries.sorted { $0.daysUntilNext() < $1.daysUntilNext() }) { item in
                            Button { anniversary = item } label: {
                                HStack {
                                    Label(item.name, systemImage: item.isBirthday ? "birthday.cake" : "heart.circle")
                                    Spacer()
                                    Text(item.daysUntilNext() == 0 ? "就是今天" : "\(item.daysUntilNext()) 天").foregroundStyle(.secondary)
                                }.foregroundStyle(.primary)
                            }
                            .swipeActions { Button("删除", role: .destructive) { workspace.deleteAnniversary(item.id) } }
                        }
                        Button("添加生日或纪念日", systemImage: "plus") { showNewAnniversary = true }
                    }
                    Section("导出与帮助") {
                        ShareLink(item: workspace.journalExport(), preview: SharePreview("PhotoVault 日记与备注")) { Label("导出日记和备注", systemImage: "square.and.arrow.up") }
                        NavigationLink { PhotoFeatureGuide() } label: { Label("功能介绍", systemImage: "questionmark.circle") }
                        Link(destination: URL(string: "https://github.com/misswell/PhotoVault/issues")!) { Label("功能建议与问题反馈", systemImage: "bubble.left.and.bubble.right") }
                        Link(destination: URL(string: "https://github.com/misswell/PhotoVault/releases")!) { Label("检查新版本", systemImage: "arrow.down.circle") }
                        ShareLink(item: URL(string: "https://github.com/misswell/PhotoVault")!) { Label("分享 PhotoVault", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("发现")
            .searchable(text: $query, prompt: "搜索日记、备注、相册")
            .onChange(of: query) { _, _ in noteLimit = 200; noteIDs = []; noteAssets = [:] }
            .task(id: NoteSearchRequest(query: query, notes: workspace.notes, limit: noteLimit, revision: store.libraryRevision)) {
                guard !query.isEmpty else { noteIDs = []; noteAssets = [:]; return }
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                let matches = await WorkspaceAssetQuery.shared.matchingNotes(workspace.notes, query: query)
                let resolved = await WorkspaceAssetQuery.shared.batch(Array(matches.prefix(noteLimit)))
                guard !Task.isCancelled else { return }
                noteIDs = matches; noteAssets = resolved.assets
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("设置", systemImage: "gearshape") { showSettings = true } } }
        }
        .sheet(isPresented: $showSettings) { PhotoVaultSettingsView(store: store) }
        .sheet(item: $anniversary) { AnniversaryEditor(item: $0) }
        .sheet(isPresented: $showNewAnniversary) { AnniversaryEditor() }
    }
}

struct JournalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry: PhotoJournalEntry
    init(date: Date = .now, entry: PhotoJournalEntry? = nil) {
        _entry = State(initialValue: entry ?? PhotoJournalEntry(date: date, text: "", assetID: nil))
    }
    var body: some View {
        Form {
            DatePicker("日期", selection: $entry.date, displayedComponents: .date)
            TextEditor(text: $entry.text).frame(minHeight: 250)
        }
        .navigationTitle("日记").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { PhotoWorkspaceStore.shared.saveEntry(entry); dismiss() }.disabled(entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct JournalListScreen: View {
    @ObservedObject private var workspace = PhotoWorkspaceStore.shared
    @State private var create = false
    var body: some View {
        List {
            ForEach(workspace.journal) { entry in
                NavigationLink { JournalEditorSheet(entry: entry) } label: {
                    VStack(alignment: .leading, spacing: 6) { Text(entry.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary); Text(entry.text).lineLimit(4) }
                }.swipeActions { Button("删除", role: .destructive) { workspace.deleteEntry(entry.id) } }
            }
        }
        .overlay { if workspace.journal.isEmpty { ContentUnavailableView("写下第一篇日记", systemImage: "book.closed", description: Text("也可以从照片详情的“备注 / 日记”保存。")) } }
        .navigationTitle("我的日记")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("写日记", systemImage: "square.and.pencil") { create = true } } }
        .sheet(isPresented: $create) { NavigationStack { JournalEditorSheet() } }
    }
}

private struct AnniversaryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotoAnniversary
    init(item: PhotoAnniversary? = nil) { _item = State(initialValue: item ?? PhotoAnniversary(name: "", date: .now, isBirthday: true)) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("姓名或纪念日名称", text: $item.name)
                DatePicker("日期", selection: $item.date, displayedComponents: .date)
                Toggle("生日", isOn: $item.isBirthday)
                LabeledContent("距下一次", value: "\(item.daysUntilNext()) 天")
            }.navigationTitle("生日 / 纪念日").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { PhotoWorkspaceStore.shared.saveAnniversary(item); dismiss() }.disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

private struct OnThisDayScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    @State private var assets: PHFetchResult<PHAsset>?
    var body: some View {
        PhotoGridScreen(title: "往年今日", assets: assets, store: store)
            .task(id: store.libraryRevision) {
                guard let all = store.allPhotos else { assets = PHFetchResult<PHAsset>(); return }
                let result = await OnThisDayWorker.shared.fetch(PhotoFetchSnapshot(result: all))
                if !Task.isCancelled { assets = result.result }
            }
    }
}

private struct FavoriteWorkspaceScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    @State private var assets: PHFetchResult<PHAsset>?
    var body: some View {
        PhotoGridScreen(title: "我的收藏", assets: assets, store: store)
            .task(id: store.libraryRevision) {
                let result = await WorkspaceLibraryQuery.shared.fetch(scope: .favorites, oldestFirst: false)
                if !Task.isCancelled { assets = result.result }
            }
    }
}

actor OnThisDayWorker {
    static let shared = OnThisDayWorker()
    func fetch(_ snapshot: PhotoFetchSnapshot) -> PhotoFetchSnapshot {
        let calendar = Calendar.current, today = calendar.dateComponents([.month, .day], from: .now)
        var ids: [String] = []
        for index in 0..<snapshot.result.count {
            if Task.isCancelled { break }
            let asset = snapshot.result.object(at: index)
            if let date = asset.creationDate {
                let parts = calendar.dateComponents([.month, .day], from: date)
                if parts == today && calendar.component(.year, from: date) < calendar.component(.year, from: .now) { ids.append(asset.localIdentifier) }
            }
        }
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PhotoFetchSnapshot(result: PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options))
    }
}

private struct PhotoFeatureGuide: View {
    var body: some View {
        List {
            Section("浏览") { Text("按年、月、日浏览，在日记模式记录每一天。双指缩放网格，点照片进入详情，左右翻页或拖动胶片条，下拉返回当前照片。") }
            Section("编辑与压缩") { Text("详情页点调节按钮，可裁剪、旋转、镜像、应用滤镜和调色。支持撤销重做，按住“原图对比”查看原片。保存前显示实际文件大小；另存结果保留拍摄日期、位置、收藏和相册。") }
            Section("整理") { Text("详情页点文件夹，在底部面板切换已加入、最近、全部或星标相册。点未加入相册会添加，再点已加入的相册会移除。长按相册可设为快速收藏。") }
            Section("清理") { Text("显式扫描本机媒体，查看文件大小、相似照片、按日期与相册清理。云端原片不会因扫描被下载。删除始终通过系统照片确认。") }
            Section("回忆") { Text("在照片详情添加备注并保存成日记，发现页可全文搜索、记录生日与纪念日、导出日记及备注。地图按拍摄地点展示有位置的照片。") }
        }.navigationTitle("功能介绍")
    }
}

struct WorkspaceAlbumBrowser: View {
    @ObservedObject var store: PhotoLibraryStore
    @ObservedObject private var workspace = PhotoWorkspaceStore.shared
    @State private var scope = "全部"
    @State private var query = ""
    @AppStorage("PhotoVault.albums.tiles") private var tiles = true
    @State private var ascending = true
    @State private var create = false
    @State private var name = ""
    @State private var error: String?
    private var albums: [PhotoAlbum] {
        let result: [PhotoAlbum]
        switch scope {
        case "星标": result = store.quickAlbums()
        case "历史": result = workspace.recentAlbumIDs.compactMap { store.album(withID: $0) }
        case "共享": result = store.topLevelSharedAlbums
        default: result = query.isEmpty ? store.topLevelAlbums : store.albums.filter { $0.kind != .shared }
        }
        let filtered = result.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        if scope == "历史" || scope == "星标" { return filtered }
        return filtered.sorted { ascending ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.title.localizedStandardCompare($1.title) == .orderedDescending }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("相册范围", selection: $scope) { ForEach(["全部", "星标", "历史", "共享"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    if scope == "全部" && query.isEmpty {
                        ForEach(store.albumFolders) { folder in WorkspaceFolderBrowserRow(folder: folder, store: store, tiles: tiles) }
                    }
                    WorkspaceAlbumRows(albums: albums, store: store, tiles: tiles)
                }.padding()
            }
            .navigationTitle(scope == "历史" ? "相册浏览历史" : "全部相册")
            .searchable(text: $query, prompt: "搜索相册")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("创建", systemImage: "plus") { create = true }
                    Button(tiles ? "列表" : "平铺", systemImage: tiles ? "list.bullet" : "square.grid.2x2") { tiles.toggle() }
                    Button("排序", systemImage: "arrow.up.arrow.down") { ascending.toggle() }
                }
            }
        }
        .alert("新建相册", isPresented: $create) {
            TextField("相册名称", text: $name)
            Button("创建") { store.createAlbum(named: name, containing: []) { if case .failure(let error) = $0 { self.error = error.localizedDescription } }; name = "" }
            Button("取消", role: .cancel) {}
        }
        .alert("无法创建相册", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
}

private struct WorkspaceFolderBrowserRow: View {
    let folder: PhotoAlbumFolder
    @ObservedObject var store: PhotoLibraryStore
    let tiles: Bool
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) { Image(systemName: expanded ? "chevron.down" : "chevron.right"); Image(systemName: "folder").frame(width: 28, height: 28); Text(folder.title); Spacer(); Text("\(folder.albumCount)").foregroundStyle(.secondary) }.frame(minHeight: 44).foregroundStyle(.primary)
            }
            if expanded {
                ForEach(folder.subfolders) { child in WorkspaceFolderBrowserRow(folder: child, store: store, tiles: tiles) }
                WorkspaceAlbumRows(albums: folder.albums, store: store, tiles: tiles)
            }
        }
    }
}

private struct WorkspaceAlbumRows: View {
    let albums: [PhotoAlbum]
    @ObservedObject var store: PhotoLibraryStore
    let tiles: Bool
    @AppStorage(AlbumTileColumnCount.storageKey) private var count = 0
    var body: some View {
        if tiles {
            LazyVGrid(columns: count == 0 ? [GridItem(.adaptive(minimum: 110), spacing: 12)] : Array(repeating: GridItem(.flexible(), spacing: 12), count: count), spacing: 18) {
                ForEach(albums) { album in link(album, tile: true) }
            }.id(count)
        } else {
            LazyVStack(spacing: 0) { ForEach(albums) { album in link(album, tile: false); Divider() } }
        }
    }
    private func link(_ album: PhotoAlbum, tile: Bool) -> some View {
        NavigationLink {
            WorkspaceAlbumGrid(album: album, store: store)
        } label: {
            if tile {
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear.overlay { if let asset = album.previewAsset { WorkspaceThumbnail(asset: asset) } else { Image(systemName: album.symbolName).font(.largeTitle).foregroundStyle(.secondary) } }
                        .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                    Text(album.title).lineLimit(1).font(.subheadline)
                    Text(album.assetCount.formatted()).font(.caption).foregroundStyle(.secondary)
                }.foregroundStyle(.primary)
            } else {
                HStack(spacing: 10) {
                    if let asset = album.previewAsset { WorkspaceThumbnail(asset: asset).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5)) }
                    else { Image(systemName: album.symbolName).frame(width: 28, height: 28) }
                    Text(album.title); Spacer(); Text(album.assetCount.formatted()).foregroundStyle(.secondary)
                }.frame(minHeight: 44).foregroundStyle(.primary)
            }
        }
        .contextMenu { Button(store.quickAlbumIDs.contains(album.id) ? "取消星标" : "设为快速收藏") { store.toggleQuickAlbum(album.id) } }
    }
}

private struct NoteSearchRequest: Equatable { let query: String; let notes: [String: String]; let limit: Int; let revision: Int }

private struct WorkspaceAlbumGrid: View {
    let album: PhotoAlbum
    @ObservedObject var store: PhotoLibraryStore
    @State private var assets: PHFetchResult<PHAsset>?
    var body: some View {
        PhotoGridScreen(title: album.title, assets: assets, store: store, album: album)
            .task(id: "\(album.id):\(store.libraryRevision)") {
                let result = await store.assetsAsync(in: album)
                guard !Task.isCancelled else { return }; assets = result
            }
    }
}
