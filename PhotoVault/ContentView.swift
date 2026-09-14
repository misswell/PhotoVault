import Photos
import SwiftUI
import UIKit

/// A one-entry memo for a derived value read repeatedly during a single
/// `body` evaluation. It is a reference type stored in `@State` so updating it
/// does not trigger a SwiftUI update — it only avoids recomputing the same
/// projection several times per render.
@MainActor
private final class SidebarDerivationMemo<Value> {
    private var key: String?
    private var stored: Value?

    func value(for newKey: String, build: () -> Value) -> Value {
        if key == newKey, let stored {
            return stored
        }
        let built = build()
        key = newKey
        stored = built
        return built
    }
}

struct ContentView: View {
    private enum RootTab: Hashable {
        case library
        case organizer
    }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = PhotoLibraryStore()
    @State private var selectedRootTab = RootTab.library
    @State private var selection: PhotoSection? = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var searchText = ""
    @State private var isShowingLimitedPicker = false
    @State private var isShowingSettings = false
    @AppStorage(PhotoVaultStartupDestination.storageKey)
    private var startupDestinationRawValue = PhotoVaultStartupDestination.libraryRawValue
    @AppStorage("PhotoVault.home.regularAlbumsExpanded") private var regularAlbumsExpanded = true
    @AppStorage("PhotoVault.home.sharedAlbumsExpanded") private var sharedAlbumsExpanded = true
    @AppStorage("PhotoVault.home.folderPresentation") private var folderPresentationRawValue = FolderPresentation.list.rawValue
    @AppStorage("PhotoVault.home.folderGridMinimumWidth") private var folderGridMinimumWidthStorage = 132.0
    @AppStorage(AlbumTileColumnCount.storageKey) private var albumTileColumnCountRawValue = AlbumTileColumnCount.automatic.rawValue
    @GestureState private var albumMagnification: CGFloat = 1
    @State private var expandedFolderIDs: Set<String> = []
    /// Derivations of the store's album tree that the sidebar reads several
    /// times per body evaluation. Pinching a tile grid re-evaluates the whole
    /// body on every frame, and rebuilding these arrays each time was pure
    /// churn, so each projection is memoized against a cheap change key.
    @State private var folderListMemo = SidebarDerivationMemo<[FolderListItem]>()
    @State private var albumMatchesMemo = SidebarDerivationMemo<[PhotoAlbum]>()
#if DEBUG
    @State private var isShowingPerformance = false
#endif

    init() {
        let rawValue = UserDefaults.standard.string(
            forKey: PhotoVaultStartupDestination.storageKey
        ) ?? PhotoVaultStartupDestination.libraryRawValue

        switch rawValue {
        case PhotoVaultStartupDestination.homeRawValue:
            _selectedRootTab = State(initialValue: .library)
            _selection = State(initialValue: .home)
        case PhotoVaultStartupDestination.unsortedRawValue:
            _selectedRootTab = State(initialValue: .library)
            _selection = State(initialValue: .unsorted)
        case PhotoVaultStartupDestination.lanRawValue:
            _selectedRootTab = State(initialValue: .library)
            _selection = State(initialValue: .lan)
        case PhotoVaultStartupDestination.organizerRawValue:
            _selectedRootTab = State(initialValue: .organizer)
            _selection = State(initialValue: .home)
        case PhotoVaultStartupDestination.libraryRawValue:
            _selectedRootTab = State(initialValue: .library)
            _selection = State(initialValue: .library)
        default:
            _selectedRootTab = State(initialValue: .library)
            _selection = State(
                initialValue: PhotoVaultStartupDestination
                    .albumID(from: rawValue)
                    .map(PhotoSection.album) ?? .home
            )
        }
    }

    private enum FolderListItem: Identifiable {
        case folder(PhotoAlbumFolder, depth: Int)
        case album(PhotoAlbum, depth: Int)
        case albumGrid(PhotoAlbumFolder)

        var id: String {
            switch self {
            case .folder(let folder, _):
                return "folder:\(folder.id)"
            case .album(let album, _):
                return "album:\(album.id)"
            case .albumGrid(let folder):
                return "album-grid:\(folder.id)"
            }
        }
    }

    var body: some View {
        Group {
            if store.canReadPhotos {
                rootTabView
            } else {
                PhotoPermissionView(store: store)
            }
        }
        .task {
            photoVaultTraceLaunch("content task begin")
            store.start()
            photoVaultTraceLaunch("content task returned")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                store.suspendForBackground()
            case .active:
                store.resumeAfterBackground()
            default:
                break
            }
        }
        .onChange(of: store.isLoadingAlbums) { _, isLoading in
            guard !isLoading else { return }
            guard case .album(let id) = selection,
                  PhotoVaultStartupDestination.albumID(
                      from: startupDestinationRawValue
                  ) == id,
                  store.album(withID: id) == nil
            else {
                return
            }
            selection = .home
        }
    }

    private var rootTabView: some View {
        TabView(selection: $selectedRootTab) {
            photoLibraryView
                .tabItem {
                    Label("图库", systemImage: "photo.on.rectangle.angled")
                }
                .tag(RootTab.library)

            RandomPhotoOrganizerView(store: store)
                .tabItem {
                    Label("整理", systemImage: "rectangle.stack.badge.play")
                }
                .tag(RootTab.organizer)
        }
        .tint(.blue)
    }

    private var photoLibraryView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section {
                    Label("首页", systemImage: "house")
                        .tag(PhotoSection.home)

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

                    Label("智能搜索", systemImage: "sparkle.magnifyingglass")
                        .tag(PhotoSection.smartSearch)

                    Label("文件夹相册", systemImage: "folder")
                        .tag(PhotoSection.lan)
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
                placement: .navigationBarDrawer(displayMode: .always),
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
            PhotoVaultSettingsView(store: store)
        }
    }

    private var visibleAlbums: [PhotoAlbum] {
        // One filtered pass per (structure revision, query) pair. The sidebar
        // asks for the matched, regular and shared lists in the same body, and
        // each access used to re-run the locale-aware scan over every album.
        albumMatchesMemo.value(for: "\(store.albumStructureRevision)|\(searchQuery)") {
            let query = searchQuery
            guard !query.isEmpty else { return [] }
            return store.albums.filter { album in
                album.title.localizedCaseInsensitiveContains(query)
            }
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
        // Keyed on the store's album-structure revision, the list/grid
        // presentation and the expanded set — the only inputs that change the
        // flattened result.
        let expandedKey = expandedFolderIDs.sorted().joined(separator: ",")
        return folderListMemo.value(
            for: "\(store.albumStructureRevision)|\(folderPresentationRawValue)|\(expandedKey)"
        ) {
            store.albumFolders.flatMap {
                folderListItems(for: $0, albumPresentation: folderPresentation)
            }
        }
    }

    private func folderListItems(
        for folder: PhotoAlbumFolder,
        depth: Int = 0,
        albumPresentation: FolderPresentation
    ) -> [FolderListItem] {
        var items: [FolderListItem] = [.folder(folder, depth: depth)]
        guard expandedFolderIDs.contains(folder.id) else { return items }

        for subfolder in folder.subfolders {
            items.append(contentsOf: folderListItems(
                for: subfolder,
                depth: depth + 1,
                albumPresentation: albumPresentation
            ))
        }

        if albumPresentation == .grid {
            if !folder.albums.isEmpty {
                // Keep the grid as a peer List row instead of nesting it in
                // the folder row. Nested lazy grids make List recalculate a
                // large, changing row while scrolling, which can leave the
                // row with the right height but no painted tiles.
                items.append(.albumGrid(folder))
            }
        } else {
            items.append(contentsOf: folder.albums.map {
                .album($0, depth: depth + 1)
            })
        }
        return items
    }

    private func folderListIndent(for depth: Int) -> CGFloat {
        CGFloat(max(0, depth)) * 20
    }

    private func toggleFolder(_ folder: PhotoAlbumFolder) {
        // The folder header is its own List row. Animating the parent List's
        // insert/delete transaction makes the list preserve its scroll anchor
        // by moving the visible header up and down. Update the structure
        // without that transaction; the chevron below still animates locally.
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
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

    private var albumTileColumnCount: Int? {
        let preset = AlbumTileColumnCount(rawValue: albumTileColumnCountRawValue) ?? .automatic
        return preset == .automatic ? nil : preset.rawValue
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
                // The magnification gesture already provides the interactive
                // transition. Animating the stored width again here makes
                // List remeasure every tile a second time and can leave a
                // nested grid with a blank but oversized row.
                folderGridMinimumWidthStorage = Double(
                    min(max(updatedWidth, 88), 220)
                )
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
                        columnCount: albumTileColumnCount,
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
                AlbumSectionHeaderLabel(
                    title: "普通相册",
                    systemImage: "rectangle.stack"
                )
                Spacer(minLength: 8)
                Text(store.topLevelAlbums.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    withAnimation(AppMotion.state) {
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
            ForEach(visibleFolderListItems) { item in
                folderListItemView(item)
            }
        } header: {
            AlbumSectionHeaderLabel(title: "文件夹", systemImage: "folder")
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
        case .albumGrid(let folder):
            AlbumGrid(
                albums: folder.albums,
                minimumWidth: folderGridMinimumWidth,
                columnCount: albumTileColumnCount,
                usesListRowInsets: true,
                onSelectAlbum: { album in
                    selection = .album(album.id)
                },
                magnificationGesture: albumGridMagnificationGesture
            )
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var sharedAlbumsSection: some View {
        Section {
            if sharedAlbumsExpanded {
                if folderPresentation == .list {
                    ForEach(store.topLevelSharedAlbums) { album in
                        AlbumSidebarRow(album: album)
                            .tag(PhotoSection.album(album.id))
                    }
                } else {
                    AlbumGrid(
                        albums: store.topLevelSharedAlbums,
                        minimumWidth: folderGridMinimumWidth,
                        columnCount: albumTileColumnCount,
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
                AlbumSectionHeaderLabel(
                    title: "共享相册",
                    systemImage: "person.2.fill"
                )
                Spacer(minLength: 8)
                Text(store.topLevelSharedAlbums.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    withAnimation(AppMotion.state) {
                        sharedAlbumsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: sharedAlbumsExpanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(sharedAlbumsExpanded ? "折叠共享相册" : "展开共享相册")
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .library {
        case .home:
            PhotoVaultHomeScreen(
                store: store,
                onSelectSection: { destination in
                    selection = destination
                },
                onSelectOrganizer: {
                    selectedRootTab = .organizer
                }
            )
            .id("home-detail")
        case .library:
            PhotoGridScreen(
                title: "图库",
                assets: store.allPhotos,
                store: store
            )
            .id("library-detail")
        case .unsorted:
            UnsortedPhotosScreen(store: store)
                .id("unsorted-detail")
        case .smartSearch:
            SmartSearchScreen(store: store)
                .id("smart-search-detail")
        case .lan:
            // The LAN home is the only detail screen that pushes a second
            // level (NavigationLink into a folder grid). On compact width
            // that push lands on the split view's own internal navigation
            // stack; popping it corrupts the split view's detail-presentation
            // state and every sidebar row silently stops navigating. Give the
            // branch a dedicated NavigationStack so the folder push stays
            // inside it.
            NavigationStack {
                LANAlbumHomeScreen()
            }
            .id("lan-detail")
        case .album(let id):
            if let album = store.album(withID: id) {
                PhotoGridScreen(
                    title: album.title,
                    assets: store.assets(in: album),
                    store: store,
                    album: album
                )
                .id("album-detail-\(id)")
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

private struct PhotoVaultHomeScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    let onSelectSection: (PhotoSection) -> Void
    let onSelectOrganizer: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("照片")
                        .font(.largeTitle.weight(.bold))
                    Text("从这里开始浏览和整理你的照片。")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    PhotoVaultHomeActionCard(
                        title: "图库",
                        detail: store.allPhotos?.count.formatted() ?? "读取中",
                        systemImage: "photo.on.rectangle.angled"
                    ) {
                        onSelectSection(.library)
                    }

                    PhotoVaultHomeActionCard(
                        title: "未整理",
                        detail: store.unsortedCount.formatted() + " 张",
                        systemImage: "tray.full"
                    ) {
                        onSelectSection(.unsorted)
                    }

                    PhotoVaultHomeActionCard(
                        title: "文件夹相册",
                        detail: "SMB、本机或 U 盘",
                        systemImage: "folder"
                    ) {
                        onSelectSection(.lan)
                    }

                    PhotoVaultHomeActionCard(
                        title: "整理",
                        detail: "随机整理照片",
                        systemImage: "rectangle.stack.badge.play"
                    ) {
                        onSelectOrganizer()
                    }
                }

                if !store.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("相册")
                            .font(.headline)

                        ForEach(store.albums.prefix(6)) { album in
                            Button {
                                onSelectSection(.album(album.id))
                            } label: {
                                AlbumSidebarRow(album: album)
                                    .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PhotoVaultHomeActionCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
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

private struct AlbumSectionHeaderLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 20, height: 20, alignment: .center)
            Text(title)
        }
    }
}

private struct AlbumGrid<GestureType: Gesture>: View {
    let albums: [PhotoAlbum]
    let minimumWidth: CGFloat
    let columnCount: Int?
    let usesListRowInsets: Bool
    let onSelectAlbum: (PhotoAlbum) -> Void
    let magnificationGesture: GestureType

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        Group {
            if usesListRowInsets {
                gridContent
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } else {
                gridContent
            }
        }
        .onPreferenceChange(AlbumGridWidthPreferenceKey.self) { width in
            guard width > 0, abs(width - availableWidth) > 0.5 else { return }
            availableWidth = width
        }
    }

    private var gridContent: some View {
        LazyVGrid(
            columns: gridColumns,
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(albums) { album in
                AlbumGridCell(album: album) {
                    onSelectAlbum(album)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Album grids live inside a List row. Asking the grid for its full
        // intrinsic height prevents List from keeping the previous row
        // measurement after a 2-column -> 1-column transition.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, usesListRowInsets ? 0 : 12)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AlbumGridWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        }
        // LazyVGrid's adaptive layout can keep its old column arrangement
        // when it is embedded in List and the minimum width changes during a
        // pinch. Rebuild only when the effective column count changes; the
        // tiles themselves keep stable album IDs, so this is cheap for the
        // small album list and deterministic at the transition boundary.
        .id("album-grid-columns-\(resolvedColumnCount)")
        // Pinch-to-zoom must win over the buttons inside the grid. With a
        // simultaneous gesture, ending a pinch can also be interpreted as a
        // card tap and open an album unexpectedly.
        .highPriorityGesture(magnificationGesture, including: .all)
    }

    private var resolvedColumnCount: Int {
        if let columnCount, columnCount > 0 {
            return columnCount
        }

        guard availableWidth > 0 else { return 1 }
        let spacing: CGFloat = 12
        return max(
            1,
            Int((availableWidth + spacing) / (minimumWidth + spacing))
        )
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(minimum: 0),
                spacing: 12,
                alignment: .top
            ),
            count: resolvedColumnCount
        )
    }
}

private struct AlbumGridWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
                        targetSize: CGSize(width: 256, height: 256),
                        cacheResult: true,
                        cacheScope: .albumThumbnail,
                        usesPhotoKitCaching: false
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

            Text(folder.title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(folderSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(isExpanded ? .degrees(90) : .zero)
                .animation(AppMotion.micro, value: isExpanded)
        }
        .contentShape(Rectangle())
    }

    private var folderSummary: String {
        let albumCount = folder.albumCount
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
    let columnCount: Int?
    let magnificationGesture: GestureType
    let onSelectAlbum: (PhotoAlbum) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppMotion.state) {
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
                            columnCount: columnCount,
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
                            columnCount: columnCount,
                            usesListRowInsets: false,
                            onSelectAlbum: onSelectAlbum,
                            magnificationGesture: magnificationGesture
                        )
                    }
                }
                // Keep the expanded content in place while the row grows.
                // Moving it from the top can make the first tile paint over
                // the folder title during List's own row measurement pass.
                .transition(.opacity)
            }
        }
        .animation(AppMotion.state, value: isExpanded)
    }

    private var folderSummary: String {
        let albumCount = folder.albumCount
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
                withAnimation(AppMotion.state) {
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
        .animation(AppMotion.state, value: isExpanded)
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
        let albumCount = folder.albumCount
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
                withAnimation(AppMotion.state) {
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
                    // The row is only 28 points wide. Request a small,
                    // retina-friendly preview so scrolling the sidebar does
                    // not decode a much larger image than it can display.
                    targetSize: CGSize(width: 60, height: 60),
                    cacheResult: true,
                    cacheScope: .albumThumbnail,
                    usesPhotoKitCaching: false
                )
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: album.symbolName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            Text(album.title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(album.assetCount) 张")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
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
    @ObservedObject private var indexProgressReporter: PhotoIndexProgressReporter
    @Environment(\.dismiss) private var dismiss
    @State private var activeRequests = 0

    init(store: PhotoLibraryStore) {
        self.store = store
        self._indexProgressReporter = ObservedObject(
            wrappedValue: store.indexProgressReporter
        )
    }

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
                    if let progress = indexProgressReporter.progress {
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
    @ObservedObject var store: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PhotoVaultStartupDestination.storageKey)
    private var startupDestinationRawValue = PhotoVaultStartupDestination.libraryRawValue
    @AppStorage(AlbumTileColumnCount.storageKey)
    private var albumTileColumnCountRawValue = AlbumTileColumnCount.automatic.rawValue
    @AppStorage(PhotoSwipeStyle.storageKey)
    private var swipeStyleRawValue = PhotoSwipeStyle.system.rawValue
    @AppStorage(SlideshowTransitionStyle.storageKey)
    private var slideshowTransitionRawValue = SlideshowTransitionStyle.fade.rawValue
    @AppStorage(AppIconPreference.storageKey)
    private var appIconPreferenceRawValue = AppIconPreference.system.rawValue
    @State private var isDeletingRecycleBin = false
    @State private var alert: PhotoVaultAlert?

    private var selectedAlbumTileColumnCount: AlbumTileColumnCount {
        AlbumTileColumnCount(rawValue: albumTileColumnCountRawValue) ?? .automatic
    }

    private var selectedSwipeStyle: PhotoSwipeStyle {
        PhotoSwipeStyle(rawValue: swipeStyleRawValue) ?? .system
    }

    private var selectedSlideshowTransition: SlideshowTransitionStyle {
        SlideshowTransitionStyle(rawValue: slideshowTransitionRawValue) ?? .fade
    }

    private var selectedAppIconPreference: AppIconPreference {
        AppIconPreference(rawValue: appIconPreferenceRawValue) ?? .system
    }

    private var savedStartupAlbumID: String? {
        PhotoVaultStartupDestination.albumID(from: startupDestinationRawValue)
    }

    private var selectedStartupDestinationDetail: String {
        switch startupDestinationRawValue {
        case PhotoVaultStartupDestination.homeRawValue:
            return "下次启动时打开首页。"
        case PhotoVaultStartupDestination.libraryRawValue:
            return "下次启动时打开图库。"
        case PhotoVaultStartupDestination.unsortedRawValue:
            return "下次启动时打开未整理。"
        case PhotoVaultStartupDestination.lanRawValue:
            return "下次启动时打开文件夹相册。"
        case PhotoVaultStartupDestination.organizerRawValue:
            return "下次启动时打开整理。"
        default:
            guard let albumID = savedStartupAlbumID else {
                return "下次启动时打开首页。"
            }
            if let album = store.album(withID: albumID) {
                return "下次启动时直接打开「\(album.title)」。"
            }
            return store.isLoadingAlbums
                ? "正在读取相册列表。"
                : "已保存的相册不可用，下次启动时将打开首页。"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("启动时打开") {
                    Picker("启动页面", selection: $startupDestinationRawValue) {
                        Text("首页")
                            .tag(PhotoVaultStartupDestination.homeRawValue)
                        Text("图库")
                            .tag(PhotoVaultStartupDestination.libraryRawValue)
                        Text("未整理")
                            .tag(PhotoVaultStartupDestination.unsortedRawValue)
                        Text("文件夹相册")
                            .tag(PhotoVaultStartupDestination.lanRawValue)
                        Text("整理")
                            .tag(PhotoVaultStartupDestination.organizerRawValue)

                        Section("相册") {
                            ForEach(store.albums) { album in
                                Text(album.title)
                                    .tag(
                                        PhotoVaultStartupDestination
                                            .albumRawValue(for: album.id)
                                    )
                            }

                            if let savedStartupAlbumID,
                               store.album(withID: savedStartupAlbumID) == nil {
                                Text(
                                    store.isLoadingAlbums
                                        ? "正在读取相册…"
                                        : "已保存的相册不可用"
                                )
                                .tag(startupDestinationRawValue)
                            }
                        }
                    }

                    Text(selectedStartupDestinationDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("修改后会在下次启动时生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("相册平铺") {
                    Picker("每行列数", selection: $albumTileColumnCountRawValue) {
                        ForEach(AlbumTileColumnCount.allCases) { columnCount in
                            Text(columnCount.title).tag(columnCount.rawValue)
                        }
                    }

                    Text(selectedAlbumTileColumnCount.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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

                Section("应用图标") {
                    Picker("图标", selection: $appIconPreferenceRawValue) {
                        ForEach(AppIconPreference.allCases) { preference in
                            Text(preference.title).tag(preference.rawValue)
                        }
                    }
                    .onChange(of: appIconPreferenceRawValue) { _, _ in
                        applyAppIconPreference(selectedAppIconPreference)
                    }

                    Text(selectedAppIconPreference.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("切换时系统会弹出确认提示。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("回收站") {
                    LabeledContent("待删除照片", value: store.recycleBinCount.formatted())

                    Text("加入回收站的照片仍保留在照片库。删除回收站内容时，会弹出系统确认并将其移入系统“最近删除”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        guard !isDeletingRecycleBin else { return }
                        guard store.recycleBinCount > 0 else {
                            alert = PhotoVaultAlert(
                                title: "回收站为空",
                                message: "请先在照片详情中点击垃圾桶按钮，将照片加入回收站。"
                            )
                            return
                        }
                        isDeletingRecycleBin = true
                        store.deleteRecycleBinContents { result in
                            isDeletingRecycleBin = false
                            if case .failure(let error) = result {
                                alert = PhotoVaultAlert(
                                    title: "无法删除回收站内容",
                                    message: error.localizedDescription
                                )
                            }
                        }
                    } label: {
                        if isDeletingRecycleBin {
                            Label("正在删除…", systemImage: "hourglass")
                        } else {
                            Label("删除回收站内容", systemImage: "trash")
                        }
                    }
                    .disabled(isDeletingRecycleBin)
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
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .presentationDetents([.medium, .large])
    }

    /// UIApplication persists the alternate icon itself; "跟随系统" maps to
    /// nil, restoring the primary set whose light/dark variants follow the
    /// system appearance.
    private func applyAppIconPreference(_ preference: AppIconPreference) {
        let application = UIApplication.shared
        guard application.alternateIconName != preference.alternateIconName else { return }
        application.setAlternateIconName(preference.alternateIconName)
    }
}
