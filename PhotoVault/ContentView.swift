import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = PhotoLibraryStore()
    @State private var selection: PhotoSection? = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var searchText = ""
    @State private var isShowingLimitedPicker = false
    @State private var isShowingSettings = false
    @AppStorage("PhotoVault.home.regularAlbumsExpanded") private var regularAlbumsExpanded = true
    @AppStorage("PhotoVault.home.folderPresentation") private var folderPresentationRawValue = FolderPresentation.list.rawValue
    @AppStorage("PhotoVault.home.folderGridMinimumWidth") private var folderGridMinimumWidthStorage = 132.0
    @GestureState private var albumMagnification: CGFloat = 1
    @State private var albumGridLayoutGeneration = 0
    @State private var expandedFolderIDs: Set<String> = []
#if DEBUG
    @State private var isShowingPerformance = false
#endif

    private enum FolderListItem: Identifiable {
        case folder(PhotoAlbumFolder, depth: Int)
        case album(PhotoAlbum, depth: Int)

        var id: String {
            switch self {
            case .folder(let folder, _):
                return "folder:\(folder.id)"
            case .album(let album, _):
                return "album:\(album.id)"
            }
        }
    }

    var body: some View {
        Group {
            if store.canReadPhotos {
                photoLibraryView
            } else {
                PhotoPermissionView(store: store)
            }
        }
        .task {
            store.start()
        }
    }

    private var photoLibraryView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section {
                    Label("图库", systemImage: "photo.on.rectangle.angled")
                        .tag(PhotoSection.library)

                    HStack {
                        Label("未整理", systemImage: "tray.full")
                        Spacer(minLength: 8)
                        if store.unsortedCount > 0 {
                            Text(store.unsortedCount.formatted())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .tag(PhotoSection.unsorted)
                }

                if searchQuery.isEmpty {
                    if store.isLoadingAlbums && !hasCachedAlbumContent {
                        Section("相册") {
                            AlbumRefreshStatusRow(isInitialLoad: true)
                        }
                    } else {
                        if !store.albumFolders.isEmpty {
                            foldersSection
                        }

                        if !store.topLevelAlbums.isEmpty {
                            regularAlbumsSection
                        }

                        if !store.topLevelSharedAlbums.isEmpty {
                            sharedAlbumsSection
                        }
                    }
                } else {
                    if !visibleRegularAlbums.isEmpty {
                        Section("普通相册") {
                            ForEach(visibleRegularAlbums) { album in
                                AlbumSidebarRow(album: album)
                                    .tag(PhotoSection.album(album.id))
                            }
                        }
                    }

                    if !visibleSharedAlbums.isEmpty {
                        Section("共享相册") {
                            ForEach(visibleSharedAlbums) { album in
                                AlbumSidebarRow(album: album)
                                    .tag(PhotoSection.album(album.id))
                            }
                        }
                    }

                    if visibleAlbums.isEmpty {
                        ContentUnavailableView(
                            "没有找到相册",
                            systemImage: "magnifyingglass",
                            description: Text("请尝试搜索其他相册名称。")
                        )
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("照片")
            .searchable(
                text: $searchText,
                placement: .sidebar,
                prompt: "搜索相册或照片"
            )
            .onSubmit(of: .search) {
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return }
                selection = .search(query)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        folderPresentationRawValue = folderPresentation == .list
                            ? FolderPresentation.grid.rawValue
                            : FolderPresentation.list.rawValue
                    } label: {
                        Image(systemName: folderPresentation == .list ? "square.grid.2x2" : "list.bullet")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel(folderPresentation == .list ? "切换为平铺相册" : "切换为列表相册")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoadingAlbums && hasCachedAlbumContent {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在更新相册")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("设置")
                }
            }
        } detail: {
            detailView
        }
        .tint(.blue)
        .background {
            LimitedLibraryPickerTrigger(isPresented: $isShowingLimitedPicker)
                .frame(width: 0, height: 0)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.authorizationStatus == .limited {
                    Button {
                        isShowingLimitedPicker = true
                    } label: {
                        Label("管理照片访问权限", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
#if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingPerformance = true
                } label: {
                    Label("性能", systemImage: "gauge.with.dots.needle.67percent")
                }
                .accessibilityLabel("打开性能面板")
            }
#endif
        }
#if DEBUG
        .sheet(isPresented: $isShowingPerformance) {
            DebugPerformanceView(store: store)
        }
#endif
        .sheet(isPresented: $isShowingSettings) {
            PhotoVaultSettingsView()
        }
    }

    private var visibleAlbums: [PhotoAlbum] {
        let query = searchQuery
        return store.albums.filter { album in
            album.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleRegularAlbums: [PhotoAlbum] {
        visibleAlbums.filter { $0.kind != .shared }
    }

    private var visibleSharedAlbums: [PhotoAlbum] {
        visibleAlbums.filter { $0.kind == .shared }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCachedAlbumContent: Bool {
        !store.albums.isEmpty || !store.albumFolders.isEmpty
    }

    private var visibleFolderListItems: [FolderListItem] {
        store.albumFolders.flatMap { folderListItems(for: $0) }
    }

    private func folderListItems(
        for folder: PhotoAlbumFolder,
        depth: Int = 0
    ) -> [FolderListItem] {
        var items: [FolderListItem] = [.folder(folder, depth: depth)]
        guard expandedFolderIDs.contains(folder.id) else { return items }

        for subfolder in folder.subfolders {
            items.append(contentsOf: folderListItems(for: subfolder, depth: depth + 1))
        }
        items.append(contentsOf: folder.albums.map { .album($0, depth: depth + 1) })
        return items
    }

    private func folderListIndent(for depth: Int) -> CGFloat {
        CGFloat(max(0, depth)) * 20
    }

    private func toggleFolder(_ folder: PhotoAlbumFolder) {
        withAnimation(.snappy(duration: 0.22)) {
            if expandedFolderIDs.contains(folder.id) {
                expandedFolderIDs.remove(folder.id)
            } else {
                expandedFolderIDs.insert(folder.id)
            }
        }
    }

    private var folderPresentation: FolderPresentation {
        FolderPresentation(rawValue: folderPresentationRawValue) ?? .list
    }

    private var folderGridMinimumWidth: CGFloat {
        let storedWidth = CGFloat(folderGridMinimumWidthStorage)
        let liveWidth = storedWidth * min(max(albumMagnification, 0.75), 1.6)
        return min(max(liveWidth, 88), 220)
    }

    private var albumGridMagnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($albumMagnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                guard value.isFinite else { return }
                let clampedValue = min(max(value, 0.75), 1.6)
                let updatedWidth = CGFloat(folderGridMinimumWidthStorage) * clampedValue
                withAnimation(.snappy(duration: 0.22)) {
                    folderGridMinimumWidthStorage = Double(
                        min(max(updatedWidth, 88), 220)
                    )
                    albumGridLayoutGeneration &+= 1
                }
            }
    }

    @ViewBuilder
    private var regularAlbumsSection: some View {
        Section {
            if regularAlbumsExpanded {
                if folderPresentation == .list {
                    ForEach(store.topLevelAlbums) { album in
                        AlbumSidebarRow(album: album)
                            .tag(PhotoSection.album(album.id))
                    }
                } else {
                    AlbumGrid(
                        albums: store.topLevelAlbums,
                        minimumWidth: folderGridMinimumWidth,
                        layoutGeneration: albumGridLayoutGeneration,
                        usesListRowInsets: true,
                        onSelectAlbum: { album in
                            selection = .album(album.id)
                        },
                        magnificationGesture: albumGridMagnificationGesture
                    )
                }
            }
        } header: {
            HStack(spacing: 8) {
                Label("普通相册", systemImage: "rectangle.stack")
                Spacer(minLength: 8)
                Text(store.topLevelAlbums.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        regularAlbumsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: regularAlbumsExpanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(regularAlbumsExpanded ? "折叠普通相册" : "展开普通相册")
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        Section {
            if folderPresentation == .list {
                ForEach(visibleFolderListItems) { item in
                    folderListItemView(item)
                }
            } else {
                ForEach(store.albumFolders) { folder in
                    AlbumFolderSidebarRow(
                        folder: folder,
                        albumPresentation: folderPresentation,
                        minimumWidth: folderGridMinimumWidth,
                        layoutGeneration: albumGridLayoutGeneration,
                        magnificationGesture: albumGridMagnificationGesture,
                        onSelectAlbum: { album in
                            selection = .album(album.id)
                        }
                    )
                }
            }
        } header: {
            Text("文件夹")
        }
    }

    @ViewBuilder
    private func folderListItemView(_ item: FolderListItem) -> some View {
        switch item {
        case .folder(let folder, let depth):
            AlbumFolderSidebarListRow(
                folder: folder,
                isExpanded: expandedFolderIDs.contains(folder.id),
                onToggle: { toggleFolder(folder) }
            )
            .padding(.leading, folderListIndent(for: depth))
        case .album(let album, let depth):
            AlbumSidebarRow(album: album)
                .padding(.leading, folderListIndent(for: depth))
                .tag(PhotoSection.album(album.id))
        }
    }

    @ViewBuilder
    private var sharedAlbumsSection: some View {
        Section {
            if folderPresentation == .list {
                ForEach(store.topLevelSharedAlbums) { album in
                    AlbumSidebarRow(album: album)
                        .tag(PhotoSection.album(album.id))
                }
            } else {
                AlbumGrid(
                    albums: store.topLevelSharedAlbums,
                    minimumWidth: folderGridMinimumWidth,
                    layoutGeneration: albumGridLayoutGeneration,
                    usesListRowInsets: true,
                    onSelectAlbum: { album in
                        selection = .album(album.id)
                    },
                    magnificationGesture: albumGridMagnificationGesture
                )
            }
        } header: {
            HStack(spacing: 8) {
                Label("共享相册", systemImage: "person.2.fill")
                Spacer(minLength: 8)
                Text(store.topLevelSharedAlbums.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .library {
        case .library:
            PhotoGridScreen(
                title: "图库",
                assets: store.allPhotos,
                store: store
            )
        case .unsorted:
            UnsortedPhotosScreen(store: store)
        case .album(let id):
            if let album = store.album(withID: id) {
                PhotoGridScreen(
                    title: album.title,
                    assets: store.assets(in: album),
                    store: store,
                    album: album
                )
            } else {
                ContentUnavailableView(
                    "相册已不可用",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("照片库正在更新，请重新选择相册。")
                )
            }
        case .search(let query):
            PhotoSearchResultsScreen(
                query: query,
                store: store,
                onSelectAlbum: { album in
                    selection = .album(album.id)
                    searchText = album.title
                }
            )
        }
    }
}

private enum FolderPresentation: String {
    case list
    case grid
}

private struct AlbumRefreshStatusRow: View {
    let isInitialLoad: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(isInitialLoad ? "正在读取相册" : "正在更新相册")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AlbumGrid<GestureType: Gesture>: View {
    let albums: [PhotoAlbum]
    let minimumWidth: CGFloat
    let layoutGeneration: Int
    let usesListRowInsets: Bool
    let onSelectAlbum: (PhotoAlbum) -> Void
    let magnificationGesture: GestureType

    var body: some View {
        Group {
            if usesListRowInsets {
                gridContent
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } else {
                gridContent
            }
        }
    }

    private var gridContent: some View {
        AlbumGridLayout(minimumItemWidth: minimumWidth, spacing: 12) {
            ForEach(albums) { album in
                AlbumGridCell(album: album) {
                    onSelectAlbum(album)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(layoutGeneration)
        .padding(.vertical, usesListRowInsets ? 0 : 12)
        .padding(.horizontal, 0)
        .fixedSize(horizontal: false, vertical: true)
        // Pinch-to-zoom must win over the buttons inside the grid. With a
        // simultaneous gesture, ending a pinch can also be interpreted as a
        // card tap and open an album unexpectedly.
        .highPriorityGesture(magnificationGesture, including: .all)
    }
}

private struct AlbumGridLayout: Layout {
    let minimumItemWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = resolvedWidth(for: proposal, subviewCount: subviews.count)
        let columns = columnCount(for: width)
        let itemWidth = itemWidth(for: width, columns: columns)
        let rowHeights = rowHeights(
            for: subviews,
            columns: columns,
            itemWidth: itemWidth
        )
        let height = rowHeights.reduce(0, +)
            + spacing * CGFloat(max(0, rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let width = max(bounds.width, 1)
        let columns = columnCount(for: width)
        let itemWidth = itemWidth(for: width, columns: columns)
        let rowHeights = rowHeights(
            for: subviews,
            columns: columns,
            itemWidth: itemWidth
        )

        var rowOriginY = bounds.minY
        for row in 0..<rowHeights.count {
            let rowHeight = rowHeights[row]
            let startIndex = row * columns
            let endIndex = min(startIndex + columns, subviews.count)

            for index in startIndex..<endIndex {
                let column = index - startIndex
                let originX = bounds.minX + CGFloat(column) * (itemWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: originX, y: rowOriginY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: itemWidth, height: rowHeight)
                )
            }

            rowOriginY += rowHeight + spacing
        }
    }

    private func resolvedWidth(
        for proposal: ProposedViewSize,
        subviewCount: Int
    ) -> CGFloat {
        if let width = proposal.width, width.isFinite, width > 0 {
            return width
        }
        return max(
            minimumItemWidth,
            CGFloat(max(1, min(subviewCount, 3))) * minimumItemWidth
                + CGFloat(max(0, min(subviewCount, 3) - 1)) * spacing
        )
    }

    private func columnCount(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumItemWidth + spacing)))
    }

    private func itemWidth(for width: CGFloat, columns: Int) -> CGFloat {
        (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
    }

    private func rowHeights(
        for subviews: Subviews,
        columns: Int,
        itemWidth: CGFloat
    ) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { startIndex in
            let endIndex = min(startIndex + columns, subviews.count)
            return (startIndex..<endIndex).reduce(CGFloat.zero) { height, index in
                max(
                    height,
                    subviews[index].sizeThatFits(
                        ProposedViewSize(width: itemWidth, height: nil)
                    ).height
                )
            }
        }
    }
}

private struct AlbumFolderGrid<GestureType: Gesture>: View {
    let folders: [PhotoAlbumFolder]
    let minimumWidth: CGFloat
    let onSelectAlbum: (PhotoAlbum) -> Void
    let magnificationGesture: GestureType

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: minimumWidth),
                    spacing: 12,
                    alignment: .top
                )
            ],
            spacing: 16
        ) {
            ForEach(folders) { folder in
                AlbumFolderGridCard(folder: folder, onSelectAlbum: onSelectAlbum)
            }
        }
        .padding(.all, 12)
        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        .highPriorityGesture(magnificationGesture, including: .all)
    }
}

private struct AlbumGridCell: View {
    let album: PhotoAlbum
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                AlbumGridThumbnail(
                    asset: album.previewAsset,
                    symbolName: album.symbolName
                )

                Text(album.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(album.assetCount.formatted() + " 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AlbumGridThumbnail: View {
    let asset: PHAsset?
    let symbolName: String

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let asset {
                    AssetImageView(
                        asset: asset,
                        targetSize: CGSize(width: 360, height: 360)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: symbolName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

private struct PhotoSearchResultsScreen: View {
    let query: String
    @ObservedObject var store: PhotoLibraryStore
    let onSelectAlbum: (PhotoAlbum) -> Void

    @State private var assets: PHFetchResult<PHAsset>?
    @State private var matchingAlbums: [PhotoAlbum] = []
    @State private var isLoaded = false

    var body: some View {
        Group {
            if let assets {
                PhotoGridScreen(
                    title: "搜索：\(query)",
                    assets: assets,
                    store: store
                )
            } else if !isLoaded {
                ProgressView("正在搜索")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !matchingAlbums.isEmpty {
                List(matchingAlbums) { album in
                    Button {
                        onSelectAlbum(album)
                    } label: {
                        AlbumSidebarRow(album: album)
                    }
                    .buttonStyle(.plain)
                }
                .navigationTitle("搜索结果")
            } else {
                ContentUnavailableView(
                    "没有匹配的照片",
                    systemImage: "magnifyingglass",
                    description: Text("可以搜索相册名称、年份、照片、视频或收藏。")
                )
            }
        }
        .task(id: query) {
            await search()
        }
    }

    private func search() async {
        assets = nil
        matchingAlbums = store.albums.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
        isLoaded = false

        guard let kind = PhotoSearchKind(query: query) else {
            isLoaded = true
            return
        }

        let result = await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: false)
            ]
            options.predicate = kind.predicate
            return PHAsset.fetchAssets(with: options)
        }.value

        guard !Task.isCancelled else { return }
        assets = result
        isLoaded = true
    }
}

private enum PhotoSearchKind: Sendable {
    case image
    case video
    case favorite
    case year(Int)

    init?(query: String) {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "照片", "图片", "photo", "photos", "image", "images":
            self = .image
        case "视频", "影片", "video", "videos", "movie", "movies":
            self = .video
        case "收藏", "收藏夹", "favorite", "favorites":
            self = .favorite
        default:
            guard normalized.count == 4,
                  let year = Int(normalized),
                  (1900...2100).contains(year)
            else { return nil }
            self = .year(year)
        }
    }

    var predicate: NSPredicate {
        switch self {
        case .image:
            return NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.image.rawValue
            )
        case .video:
            return NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.video.rawValue
            )
        case .favorite:
            return NSPredicate(format: "isFavorite == YES")
        case .year(let year):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let start = calendar.date(from: DateComponents(year: year)) ?? .distantPast
            let end = calendar.date(from: DateComponents(year: year + 1)) ?? .distantFuture
            return NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                start as NSDate,
                end as NSDate
            )
        }
    }
}

private struct AlbumFolderSidebarListRow: View {
    let folder: PhotoAlbumFolder
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            AlbumFolderSidebarRowLabel(folder: folder, isExpanded: isExpanded)
        }
        .buttonStyle(.plain)
    }
}

private struct AlbumFolderSidebarRowLabel: View {
    let folder: PhotoAlbumFolder
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(
                    Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.title)
                    .lineLimit(1)
                Text(folderSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var folderSummary: String {
        let albumCount = folder.allAlbums.count
        if albumCount == 0 {
            return "空文件夹"
        }
        return "\(albumCount) 个相册 · \(folder.assetCount) 张"
    }
}

private struct AlbumFolderSidebarRow<GestureType: Gesture>: View {
    let folder: PhotoAlbumFolder
    let albumPresentation: FolderPresentation
    let minimumWidth: CGFloat
    let layoutGeneration: Int
    let magnificationGesture: GestureType
    let onSelectAlbum: (PhotoAlbum) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                AlbumFolderSidebarRowLabel(folder: folder, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(folder.subfolders) { childFolder in
                        AlbumFolderSidebarRow(
                            folder: childFolder,
                            albumPresentation: albumPresentation,
                            minimumWidth: minimumWidth,
                            layoutGeneration: layoutGeneration,
                            magnificationGesture: magnificationGesture,
                            onSelectAlbum: onSelectAlbum
                        )
                    }

                    if albumPresentation == .list {
                        ForEach(folder.albums) { album in
                            Button {
                                onSelectAlbum(album)
                            } label: {
                                AlbumSidebarRow(album: album)
                            }
                            .buttonStyle(.plain)
                            .tag(PhotoSection.album(album.id))
                        }
                    } else {
                        AlbumGrid(
                            albums: folder.albums,
                            minimumWidth: minimumWidth,
                            layoutGeneration: layoutGeneration,
                            usesListRowInsets: false,
                            onSelectAlbum: onSelectAlbum,
                            magnificationGesture: magnificationGesture
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.22), value: isExpanded)
    }

    private var folderSummary: String {
        let albumCount = folder.allAlbums.count
        if albumCount == 0 {
            return "空文件夹"
        }
        return "\(albumCount) 个相册 · \(folder.assetCount) 张"
    }
}

private struct AlbumFolderGridCard: View {
    let folder: PhotoAlbumFolder
    let onSelectAlbum: (PhotoAlbum) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    folderPreview

                    HStack(spacing: 6) {
                        Text(folder.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(folderSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(folder.subfolders) { childFolder in
                        AlbumFolderGridChildRow(
                            folder: childFolder,
                            onSelectAlbum: onSelectAlbum
                        )
                    }

                    ForEach(folder.albums) { album in
                        Button {
                            onSelectAlbum(album)
                        } label: {
                            AlbumSidebarRow(album: album)
                        }
                        .buttonStyle(.plain)
                    }

                    if folder.subfolders.isEmpty && folder.albums.isEmpty {
                        Text("空文件夹")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.snappy(duration: 0.22), value: isExpanded)
    }

    private var folderPreview: some View {
        ZStack(alignment: .bottomLeading) {
            AlbumGridThumbnail(
                asset: folder.previewAsset,
                symbolName: "folder.fill"
            )

            Image(systemName: "folder.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(8)
        }
    }

    private var folderSummary: String {
        let albumCount = folder.allAlbums.count
        if albumCount == 0 {
            return "空文件夹"
        }
        return albumCount.formatted() + " 个相册 · " + folder.assetCount.formatted() + " 张"
    }
}

private struct AlbumFolderGridChildRow: View {
    let folder: PhotoAlbumFolder
    let onSelectAlbum: (PhotoAlbum) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .foregroundStyle(.blue)
                    Text(folder.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(folder.subfolders) { childFolder in
                    AlbumFolderGridChildRow(
                        folder: childFolder,
                        onSelectAlbum: onSelectAlbum
                    )
                    .padding(.leading, 12)
                }

                ForEach(folder.albums) { album in
                    Button {
                        onSelectAlbum(album)
                    } label: {
                        AlbumSidebarRow(album: album)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AlbumSidebarRow: View {
    let album: PhotoAlbum

    var body: some View {
        HStack(spacing: 10) {
            if let previewAsset = album.previewAsset {
                AssetImageView(
                    asset: previewAsset,
                    targetSize: CGSize(width: 88, height: 88)
                )
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: album.symbolName)
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .lineLimit(1)
                Text("\(album.assetCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct PhotoPermissionView: View {
    @ObservedObject var store: PhotoLibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("需要访问照片", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("PhotoVault 使用系统照片库展示图库、相册和未整理照片。")
        } actions: {
            if store.authorizationStatus == .notDetermined {
                Button("允许访问照片") {
                    store.requestAccess()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("打开设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

/// Presents Apple's Limited Photos picker from a real UIKit controller while
/// keeping the rest of the app in SwiftUI. The picker is never recreated as a
/// custom permission UI.
private struct LimitedLibraryPickerTrigger: UIViewControllerRepresentable {
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard isPresented else { return }
        isPresented = false
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }
}

#if DEBUG
/// A small developer-only panel for validating the large-library invariants
/// without adding diagnostics to the release Photos experience.
private struct DebugPerformanceView: View {
    @ObservedObject var store: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var activeRequests = 0

    var body: some View {
        NavigationStack {
            List {
                Section("照片库") {
                    LabeledContent("图库资源", value: countText(store.allPhotos?.count))
                    LabeledContent("未整理", value: store.unsortedCount.formatted())
                    LabeledContent("相册", value: store.albums.count.formatted())
                }

                Section("索引") {
                    LabeledContent("状态", value: indexState)
                    if let progress = store.indexProgress {
                        LabeledContent(
                            "进度",
                            value: "\(progress.completed.formatted()) / \(progress.total.formatted())"
                        )
                    }
                    if let stats = store.indexStats {
                        LabeledContent("资产索引", value: stats.assetCount.formatted())
                        LabeledContent("关系索引", value: stats.albumCount.formatted())
                    }
                }

                Section("媒体请求") {
                    LabeledContent("活动请求", value: activeRequests.formatted())
                    Text("网格只请求可见缩略图；查看器和幻灯片优先级更高。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("性能面板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                activeRequests = PhotoImageManager.shared.activeRequestCount
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private var indexState: String {
        if store.isIndexingUnsorted { return "建立中" }
        if store.indexErrorMessage != nil { return "失败" }
        if store.indexStats != nil { return "已完成" }
        return "未建立"
    }

    private func countText(_ count: Int?) -> String {
        count.map { $0.formatted() } ?? "读取中"
    }
}
#endif

struct PhotoVaultSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PhotoSwipeStyle.storageKey)
    private var swipeStyleRawValue = PhotoSwipeStyle.system.rawValue
    @AppStorage(SlideshowTransitionStyle.storageKey)
    private var slideshowTransitionRawValue = SlideshowTransitionStyle.fade.rawValue

    private var selectedSwipeStyle: PhotoSwipeStyle {
        PhotoSwipeStyle(rawValue: swipeStyleRawValue) ?? .system
    }

    private var selectedSlideshowTransition: SlideshowTransitionStyle {
        SlideshowTransitionStyle(rawValue: slideshowTransitionRawValue) ?? .fade
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("图片左右滑动") {
                    Picker("切换样式", selection: $swipeStyleRawValue) {
                        ForEach(PhotoSwipeStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }

                    Text(selectedSwipeStyle.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("幻灯片切换") {
                    Picker("过渡样式", selection: $slideshowTransitionRawValue) {
                        ForEach(SlideshowTransitionStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }

                    Text(selectedSlideshowTransition.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("图片会预读相邻照片的高质量版本，尽量避免从 iCloud 切换时出现黑屏或闪烁。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
