import Photos
import SwiftUI
import UIKit

struct PhotoGridScreen: View {
    let title: String
    let assets: PHFetchResult<PHAsset>?
    @ObservedObject var store: PhotoLibraryStore
    let album: PhotoAlbum?

    @State private var selectionMode = false
    @State private var selectedAssets: [String: PHAsset] = [:]
    @State private var viewerRequest: PhotoViewerRequest?
    @State private var isViewerTransitioning = false
    @State private var isShowingSlideshow = false
    @State private var isShowingAlbumPicker = false
    // Assets the album picker will operate on: the selection-mode batch or a
    // single asset chosen through the grid's context menu.
    @State private var pickerAssets: [PHAsset] = []
    @State private var isPreparingShare = false
    @State private var alert: PhotoVaultAlert?

    init(
        title: String,
        assets: PHFetchResult<PHAsset>?,
        store: PhotoLibraryStore,
        album: PhotoAlbum? = nil
    ) {
        self.title = title
        self.assets = assets
        self.store = store
        self.album = album
    }

    var body: some View {
        Group {
            if let assets {
                if assets.count == 0 {
                    ContentUnavailableView(
                        "还没有照片",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("照片出现在系统照片库后，会自动显示在这里。")
                    )
                } else {
                    PhotoGridView(
                        assets: assets,
                        isActive: !isViewerTransitioning
                            && !isShowingSlideshow,
                        selectionMode: selectionMode,
                        selectedIDs: Set(selectedAssets.keys),
                        onOpen: { index in
                            presentViewer(at: index)
                        },
                        onToggleSelection: toggleSelection(for:),
                        onFavorite: toggleFavorite(for:),
                        onShare: share(asset:),
                        onDelete: delete(asset:),
                        onAddToAlbum: requestAddToAlbum(asset:),
                        onRemoveFromAlbum: removeFromAlbum(asset:album:),
                        containingUserAlbums: { asset in
                            store.userAlbums(containing: asset)
                        },
                        onAddToQuickAlbum: addToQuickAlbum(asset:album:),
                        quickAlbums: { store.quickAlbums() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView("正在读取照片")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .onAppear {
            photoVaultTrace("grid screen appear title=\(title)")
        }
        .onDisappear {
            photoVaultTrace("grid screen disappear title=\(title)")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectionMode {
                    Button("取消") {
                        exitSelectionMode()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                // Home-style lightweight refresh indicator: shown only while
                // a background library scan runs over already-visible
                // content, so it never blocks interaction or layout.
                if store.isLoadingAlbums, assets != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在更新照片")
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if selectionMode,
                   let assets,
                   assets.count <= 2_000,
                   selectedAssets.count < assets.count {
                    Button("全选") {
                        selectAll(from: assets)
                    }
                }

                if !selectionMode, let assets, assets.count > 0 {
                    Button {
                        isShowingSlideshow = true
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                }

                Button(selectionMode ? "完成" : "选择") {
                    if selectionMode {
                        exitSelectionMode()
                    } else {
                        selectionMode = true
                    }
                }
            }

            if selectionMode {
                ToolbarItemGroup(placement: .bottomBar) {
                    Text("已选 \(selectedAssets.count) 张")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        pickerAssets = Array(selectedAssets.values)
                        isShowingAlbumPicker = true
                    } label: {
                        Label("添加到相册", systemImage: "folder.badge.plus")
                    }
                    .disabled(selectedAssets.isEmpty || store.albums.filter { $0.kind == .user }.isEmpty)

                    if let album, album.kind == .user {
                        Button {
                            store.removeAssets(Array(selectedAssets.values), from: album) { result in
                                handle(result)
                            }
                            exitSelectionMode()
                        } label: {
                            Label("移出相册", systemImage: "folder.badge.minus")
                        }
                        .disabled(selectedAssets.isEmpty)
                    }

                    Button {
                        beginShare()
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedAssets.isEmpty || isPreparingShare)

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(selectedAssets.isEmpty)
                }
            }
        }
        .fullScreenCover(item: $viewerRequest, onDismiss: {
            photoVaultTrace("photo viewer dismissed title=\(title)")
            viewerRequest = nil
            isViewerTransitioning = false
        }) { request in
            if let assets {
                PhotoViewerView(
                    assets: assets,
                    initialIndex: request.index,
                    store: store,
                    album: album,
                    onDismissRequested: dismissViewer
                )
            }
        }
        .fullScreenCover(isPresented: $isShowingSlideshow) {
            if let assets {
                SlideshowView(title: title, assets: assets)
            }
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            AlbumPickerSheet(
                albums: store.albums,
                folders: store.albumFolders,
                quickAlbumIDs: store.quickAlbumIDs,
                onToggleQuickAlbum: { store.toggleQuickAlbum($0) },
                onCreate: { name in
                    store.createAlbum(named: name, containing: pickerAssets) { result in
                        handle(result)
                    }
                    exitSelectionMode()
                },
                onSelect: { album in
                    store.addAssets(pickerAssets, to: album) { result in
                        handle(result)
                    }
                    exitSelectionMode()
                }
            )
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func toggleSelection(for asset: PHAsset) {
        if selectedAssets.removeValue(forKey: asset.localIdentifier) == nil {
            selectedAssets[asset.localIdentifier] = asset
        }
    }

    private func selectAll(from assets: PHFetchResult<PHAsset>) {
        guard assets.count <= 2_000 else { return }
        selectedAssets.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            selectedAssets[asset.localIdentifier] = asset
        }
    }

    private func toggleFavorite(for asset: PHAsset) {
        store.toggleFavorite(asset) { result in
            handle(result)
        }
    }

    private func requestAddToAlbum(asset: PHAsset) {
        pickerAssets = [asset]
        isShowingAlbumPicker = true
    }

    private func removeFromAlbum(asset: PHAsset, album: PhotoAlbum) {
        store.removeAssets([asset], from: album) { result in
            handle(result)
        }
    }

    private func addToQuickAlbum(asset: PHAsset, album: PhotoAlbum) {
        store.addAssets([asset], to: album) { result in
            handle(result)
        }
    }

    private func share(asset: PHAsset) {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        store.requestShareItems(for: [asset]) { items, temporaryURLs in
            isPreparingShare = false
            guard !items.isEmpty else {
                alert = PhotoVaultAlert(
                    title: "无法分享",
                    message: "这张照片暂时无法读取，请稍后重试。"
                )
                return
            }
            ActivityPresenter.present(items: items) {
                removeTemporaryURLs(temporaryURLs)
            }
        }
    }

    private func delete(asset: PHAsset) {
        // The system delete alert is the confirmation; no second dialog.
        store.deleteAssets([asset]) { result in
            handle(result)
        }
    }

    private func deleteSelected() {
        let assetsToDelete = Array(selectedAssets.values)
        guard !assetsToDelete.isEmpty else { return }
        store.deleteAssets(assetsToDelete) { result in
            handle(result)
        }
        exitSelectionMode()
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedAssets.removeAll()
        pickerAssets = []
    }

    private func beginShare() {
        guard !isPreparingShare else { return }
        let assetsToShare = Array(selectedAssets.values)
        guard assetsToShare.count <= 12 else {
            alert = PhotoVaultAlert(
                title: "选择太多",
                message: "为了保持流畅，一次最多分享 12 张照片。"
            )
            return
        }

        isPreparingShare = true
        store.requestShareItems(for: assetsToShare) { items, temporaryURLs in
            isPreparingShare = false
            guard !items.isEmpty else {
                alert = PhotoVaultAlert(
                    title: "无法分享",
                    message: "所选照片暂时无法读取，请稍后重试。"
                )
                return
            }
            ActivityPresenter.present(items: items) {
                removeTemporaryURLs(temporaryURLs)
            }
        }
    }

    private func removeTemporaryURLs(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func handle(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            alert = PhotoVaultAlert(
                title: "操作失败",
                message: error.localizedDescription
            )
        }
    }

    private func presentViewer(at index: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isViewerTransitioning = true
            viewerRequest = PhotoViewerRequest(index: index)
        }
    }

    private func dismissViewer() {
        photoVaultTrace("photo viewer dismiss committed title=\(title)")
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewerRequest = nil
            isViewerTransitioning = false
        }
    }
}

struct UnsortedPhotosScreen: View {
    @ObservedObject var store: PhotoLibraryStore

    @State private var selectionMode = false
    @State private var selectedAssets: [String: PHAsset] = [:]
    @State private var viewerIndex: Int?
    @State private var isViewerTransitioning = false
    @State private var isShowingSlideshow = false
    @State private var isShowingAlbumPicker = false
    // Assets the album picker will operate on: the selection-mode batch or a
    // single asset chosen through the grid's context menu.
    @State private var pickerAssets: [PHAsset] = []
    @State private var isPreparingShare = false
    @State private var alert: PhotoVaultAlert?

    var body: some View {
        contentView
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("未整理")
        .onAppear {
            photoVaultTrace(
                "unsorted screen appear count=\(store.unsortedCount) "
                    + "indexing=\(store.isIndexingUnsorted)"
            )
        }
        .onDisappear {
            photoVaultTrace("unsorted screen disappear")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectionMode {
                    Button("取消") { exitSelectionMode() }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                // Home-style lightweight indicator: indexing never blocks
                // layout or interaction, it just spins in the toolbar corner
                // while the background scan runs.
                if store.isIndexingUnsorted {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(indexProgressTitle)
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if !selectionMode, store.unsortedCount > 0 {
                    Button {
                        isShowingSlideshow = true
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                }

                Button(selectionMode ? "完成" : "选择") {
                    if selectionMode {
                        exitSelectionMode()
                    } else {
                        selectionMode = true
                    }
                }
            }

            if selectionMode {
                ToolbarItemGroup(placement: .bottomBar) {
                    Text("已选 \(selectedAssets.count) 张")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        pickerAssets = Array(selectedAssets.values)
                        isShowingAlbumPicker = true
                    } label: {
                        Label("添加到相册", systemImage: "folder.badge.plus")
                    }
                    .disabled(selectedAssets.isEmpty || store.albums.filter { $0.kind == .user }.isEmpty)

                    Button {
                        beginShare()
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedAssets.isEmpty || isPreparingShare)

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(selectedAssets.isEmpty)
                }
            }
        }
        .fullScreenCover(
            isPresented: viewerPresentationBinding,
            onDismiss: {
                photoVaultTrace("indexed photo viewer dismissed")
                viewerIndex = nil
                isViewerTransitioning = false
            }
        ) { viewerView }
        .fullScreenCover(isPresented: $isShowingSlideshow) {
            IndexedSlideshowView(
                title: "未整理",
                totalCount: store.unsortedCount,
                store: store
            )
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            AlbumPickerSheet(
                albums: store.albums,
                folders: store.albumFolders,
                quickAlbumIDs: store.quickAlbumIDs,
                onToggleQuickAlbum: { store.toggleQuickAlbum($0) },
                onCreate: { name in
                    store.createAlbum(named: name, containing: pickerAssets) { result in
                        handle(result)
                    }
                    exitSelectionMode()
                },
                onSelect: { album in
                    store.addAssets(pickerAssets, to: album) { result in
                        handle(result)
                    }
                    exitSelectionMode()
                }
            )
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .task(id: store.isLoadingAlbums) {
            store.ensureUnsortedIndex()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let indexErrorMessage = store.indexErrorMessage {
            ContentUnavailableView {
                Label("未整理索引失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(indexErrorMessage)
            } actions: {
                Button("重试") {
                    store.retryUnsortedIndex()
                }
                .buttonStyle(.borderedProminent)
            }
        } else if store.unsortedCount == 0, !store.isIndexingUnsorted {
            ContentUnavailableView(
                "没有未整理照片",
                systemImage: "tray.full",
                description: Text("加入用户相册的照片会自动从这里移除。")
            )
        } else {
            IndexedPhotoGridView(
                totalCount: store.unsortedCount,
                store: store,
                isActive: !isViewerTransitioning
                    && !isShowingSlideshow,
                selectionMode: selectionMode,
                selectedIDs: Set(selectedAssets.keys),
                onOpen: openViewer(asset:index:),
                onToggleSelection: toggleSelection(for:),
                onFavorite: toggleFavorite(for:),
                onShare: share(asset:),
                onDelete: delete(asset:),
                onAddToAlbum: requestAddToAlbum(asset:),
                onRemoveFromAlbum: removeFromAlbum(asset:album:),
                containingUserAlbums: { asset in
                    store.userAlbums(containing: asset)
                },
                onAddToQuickAlbum: addToQuickAlbum(asset:album:),
                quickAlbums: { store.quickAlbums() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var viewerView: some View {
        if let viewerIndex {
            IndexedPhotoViewerView(
                title: "未整理",
                totalCount: store.unsortedCount,
                initialIndex: viewerIndex,
                store: store,
                onDismissRequested: dismissViewer
            )
        }
    }

    private var viewerPresentationBinding: Binding<Bool> {
        Binding(
            get: { viewerIndex != nil },
            set: { if !$0 { viewerIndex = nil } }
        )
    }

    private func openViewer(asset: PHAsset, index: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isViewerTransitioning = true
            viewerIndex = index
        }
    }

    private func dismissViewer() {
        photoVaultTrace("indexed photo viewer dismiss committed")
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewerIndex = nil
            isViewerTransitioning = false
        }
    }

    private func toggleSelection(for asset: PHAsset) {
        if selectedAssets.removeValue(forKey: asset.localIdentifier) == nil {
            selectedAssets[asset.localIdentifier] = asset
        }
    }

    private func toggleFavorite(for asset: PHAsset) {
        store.toggleFavorite(asset) { result in handle(result) }
    }

    private func requestAddToAlbum(asset: PHAsset) {
        pickerAssets = [asset]
        isShowingAlbumPicker = true
    }

    private func removeFromAlbum(asset: PHAsset, album: PhotoAlbum) {
        store.removeAssets([asset], from: album) { result in handle(result) }
    }

    private func addToQuickAlbum(asset: PHAsset, album: PhotoAlbum) {
        store.addAssets([asset], to: album) { result in handle(result) }
    }

    private func share(asset: PHAsset) {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        store.requestShareItems(for: [asset]) { items, temporaryURLs in
            isPreparingShare = false
            guard !items.isEmpty else {
                alert = PhotoVaultAlert(title: "无法分享", message: "这张照片暂时无法读取，请稍后重试。")
                return
            }
            ActivityPresenter.present(items: items) {
                removeTemporaryURLs(temporaryURLs)
            }
        }
    }

    private func delete(asset: PHAsset) {
        // The system delete alert is the confirmation; no second dialog.
        store.deleteAssets([asset]) { result in
            handle(result)
        }
    }

    private func deleteSelected() {
        let assetsToDelete = Array(selectedAssets.values)
        guard !assetsToDelete.isEmpty else { return }
        store.deleteAssets(assetsToDelete) { result in
            handle(result)
        }
        exitSelectionMode()
    }

    private func beginShare() {
        guard !isPreparingShare else { return }
        let assetsToShare = Array(selectedAssets.values)
        guard assetsToShare.count <= 12 else {
            alert = PhotoVaultAlert(title: "选择太多", message: "为了保持流畅，一次最多分享 12 张照片。")
            return
        }
        isPreparingShare = true
        store.requestShareItems(for: assetsToShare) { items, temporaryURLs in
            isPreparingShare = false
            guard !items.isEmpty else {
                alert = PhotoVaultAlert(title: "无法分享", message: "所选照片暂时无法读取，请稍后重试。")
                return
            }
            ActivityPresenter.present(items: items) {
                removeTemporaryURLs(temporaryURLs)
            }
        }
    }

    private func removeTemporaryURLs(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedAssets.removeAll()
        pickerAssets = []
    }

    private func handle(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            alert = PhotoVaultAlert(title: "操作失败", message: error.localizedDescription)
        }
    }

    private var indexProgressTitle: String {
        switch store.indexProgress?.phase {
        case .scanningAlbums:
            return "正在分析相册归属…"
        case .finalizing:
            return "正在完成索引…"
        case .finished:
            return "索引已完成"
        default:
            return "正在整理照片…"
        }
    }
}

struct AlbumPickerSheet: View {
    let albums: [PhotoAlbum]
    var folders: [PhotoAlbumFolder] = []
    // Identifiers of albums pinned for the grid's quick-add menu. Toggling a
    // row's star persists through onToggleQuickAlbum without dismissing.
    var quickAlbumIDs: [String] = []
    var onToggleQuickAlbum: (String) -> Void = { _ in }
    let onCreate: (String) -> Void
    let onSelect: (PhotoAlbum) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingCreateAlert = false
    @State private var newAlbumName = ""
    @State private var expandedFolderIDs: Set<String> = []

    /// One indent step per folder nesting level, shared by folder headers and
    /// their albums so the hierarchy lines up.
    fileprivate static let indentStep: CGFloat = 20

    private var userAlbums: [PhotoAlbum] {
        albums.filter { $0.kind == .user }
    }

    /// Albums that live inside any folder; the remaining ones are top-level.
    private var folderAlbumIDs: Set<String> {
        Set(folders.flatMap { $0.allAlbums.map(\.id) })
    }

    private var topLevelAlbums: [PhotoAlbum] {
        userAlbums.filter { !folderAlbumIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if userAlbums.isEmpty {
                    ContentUnavailableView(
                        "还没有自定义相册",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("请先在系统照片中创建一个相册。")
                    )
                } else {
                    List {
                        ForEach(pickerRows) { row in
                            switch row {
                            case .album(let album, let depth):
                                albumRow(album, indent: CGFloat(depth) * Self.indentStep)
                            case .folder(let folder, let depth):
                                folderRow(folder, depth: depth)
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加到相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingCreateAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建相册")
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("新建相册", isPresented: $isShowingCreateAlert) {
            TextField("相册名称", text: $newAlbumName)
            Button("创建") {
                let name = newAlbumName
                newAlbumName = ""
                onCreate(name)
                dismiss()
            }
            Button("取消", role: .cancel) {
                newAlbumName = ""
            }
        } message: {
            Text("新相册会保存到系统照片库。")
        }
    }

    /// Every visible item is its own List row so all rows get identical
    /// insets, separators and spacing. Children of a folder are only part of
    /// the list while that folder is expanded.
    private enum PickerRow: Identifiable {
        case album(PhotoAlbum, depth: Int)
        case folder(PhotoAlbumFolder, depth: Int)

        var id: String {
            switch self {
            case .album(let album, _):
                return "album:\(album.id)"
            case .folder(let folder, _):
                return "folder:\(folder.id)"
            }
        }
    }

    private var pickerRows: [PickerRow] {
        var rows: [PickerRow] = topLevelAlbums.map { .album($0, depth: 0) }

        func append(_ folder: PhotoAlbumFolder, depth: Int) {
            rows.append(.folder(folder, depth: depth))
            guard expandedFolderIDs.contains(folder.id) else { return }
            for subfolder in folder.subfolders {
                append(subfolder, depth: depth + 1)
            }
            for album in folder.albums {
                rows.append(.album(album, depth: depth + 1))
            }
        }

        for folder in folders {
            append(folder, depth: 0)
        }
        return rows
    }

    private func albumRow(_ album: PhotoAlbum, indent: CGFloat) -> some View {
        Button {
            onSelect(album)
            dismiss()
        } label: {
            AlbumListRow(
                album: album,
                isPinned: quickAlbumIDs.contains(album.id),
                onTogglePin: { onToggleQuickAlbum(album.id) }
            )
            .padding(.leading, indent)
        }
        .buttonStyle(.plain)
    }

    private func folderRow(_ folder: PhotoAlbumFolder, depth: Int) -> some View {
        let isExpanded = expandedFolderIDs.contains(folder.id)
        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                if isExpanded {
                    expandedFolderIDs.remove(folder.id)
                } else {
                    expandedFolderIDs.insert(folder.id)
                }
            }
        } label: {
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
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(folderSummary(folder))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
                    .animation(.easeInOut(duration: 0.16), value: isExpanded)
            }
            .padding(.leading, CGFloat(depth) * Self.indentStep)
        }
        .buttonStyle(.plain)
    }

    private func folderSummary(_ folder: PhotoAlbumFolder) -> String {
        let albumCount = folder.albumCount
        if albumCount == 0 {
            return "空文件夹"
        }
        return "\(albumCount) 个相册 · \(folder.assetCount) 张"
    }
}

private struct AlbumListRow: View {
    let album: PhotoAlbum
    var isPinned = false
    var onTogglePin: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let previewAsset = album.previewAsset {
                AssetImageView(
                    asset: previewAsset,
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
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text("\(album.assetCount) 张")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let onTogglePin {
                Button {
                    onTogglePin()
                } label: {
                    Image(systemName: isPinned ? "star.fill" : "star")
                        .font(.body)
                        .foregroundStyle(isPinned ? Color.yellow : Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPinned ? "取消快速收藏" : "标记为快速收藏")
            }
        }
    }
}

/// Presents the system share sheet straight through UIKit. Hosting
/// UIActivityViewController inside a SwiftUI sheet lays its content out for
/// the wrong size first and then jumps into place; presenting from the top
/// view controller keeps the sheet anchored from the first frame and gives
/// iPad the popover anchor it requires.
@MainActor
enum ActivityPresenter {
    static func present(items: [Any], onDismiss cleanup: @escaping () -> Void = {}) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.keyWindow?.rootViewController
        else {
            cleanup()
            return
        }
        var top: UIViewController = root
        while let presented = top.presentedViewController {
            top = presented
        }

        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
            cleanup()
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(
                x: top.view.bounds.midX,
                y: top.view.bounds.maxY - 60,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        top.present(activity, animated: true)
    }
}
