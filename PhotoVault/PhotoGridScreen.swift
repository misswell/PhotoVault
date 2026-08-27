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
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var shareTemporaryURLs: [URL] = []
    @State private var isShowingDeleteConfirmation = false
    @State private var singleAssetToDelete: PHAsset?
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
                        onDelete: requestDelete(asset:)
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
                    .disabled(selectedAssets.isEmpty)

                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
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
                onCreate: { name in
                    store.createAlbum(named: name, containing: Array(selectedAssets.values)) { result in
                        handle(result)
                    }
                    exitSelectionMode()
                },
                onSelect: { album in
                    store.addAssets(Array(selectedAssets.values), to: album) { result in
                        handle(result)
                    }
                    exitSelectionMode()
                }
            )
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: shareItems)
                .onDisappear(perform: cleanupShareItems)
        }
        .confirmationDialog(
            singleAssetToDelete == nil ? "删除所选照片？" : "删除照片？",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除照片", role: .destructive) {
                let assetsToDelete = singleAssetToDelete.map { [$0] } ?? Array(selectedAssets.values)
                store.deleteAssets(assetsToDelete) { result in
                    handle(result)
                }
                singleAssetToDelete = nil
                exitSelectionMode()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("照片会从系统照片库中删除，并可能从其他设备移除。")
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

    private func share(asset: PHAsset) {
        store.requestShareItems(for: [asset]) { items, temporaryURLs in
            guard !items.isEmpty else {
                alert = PhotoVaultAlert(
                    title: "无法分享",
                    message: "这张照片暂时无法读取，请稍后重试。"
                )
                return
            }
            shareItems = items
            shareTemporaryURLs = temporaryURLs
            isShowingShareSheet = true
        }
    }

    private func requestDelete(asset: PHAsset) {
        singleAssetToDelete = asset
        isShowingDeleteConfirmation = true
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedAssets.removeAll()
    }

    private func beginShare() {
        let assetsToShare = Array(selectedAssets.values)
        guard assetsToShare.count <= 12 else {
            alert = PhotoVaultAlert(
                title: "选择太多",
                message: "为了保持流畅，一次最多分享 12 张照片。"
            )
            return
        }

        store.requestShareItems(for: assetsToShare) { items, temporaryURLs in
            guard !items.isEmpty else {
                alert = PhotoVaultAlert(
                    title: "无法分享",
                    message: "所选照片暂时无法读取，请稍后重试。"
                )
                return
            }
            shareItems = items
            shareTemporaryURLs = temporaryURLs
            isShowingShareSheet = true
        }
    }

    private func cleanupShareItems() {
        for url in shareTemporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        shareTemporaryURLs.removeAll()
        shareItems.removeAll()
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
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var shareTemporaryURLs: [URL] = []
    @State private var isShowingDeleteConfirmation = false
    @State private var singleAssetToDelete: PHAsset?
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
                    .disabled(selectedAssets.isEmpty)

                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
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
                onCreate: { name in
                    store.createAlbum(named: name, containing: Array(selectedAssets.values)) { result in
                        handle(result)
                    }
                    exitSelectionMode()
                },
                onSelect: { album in
                    store.addAssets(Array(selectedAssets.values), to: album) { result in
                        handle(result)
                    }
                    exitSelectionMode()
                }
            )
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: shareItems)
                .onDisappear(perform: cleanupShareItems)
        }
        .confirmationDialog(
            singleAssetToDelete == nil ? "删除所选照片？" : "删除照片？",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除照片", role: .destructive) {
                let assetsToDelete = singleAssetToDelete.map { [$0] } ?? Array(selectedAssets.values)
                store.deleteAssets(assetsToDelete) { result in
                    handle(result)
                }
                singleAssetToDelete = nil
                exitSelectionMode()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("照片会从系统照片库中删除，并可能从其他设备移除。")
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .overlay(alignment: .top) {
            if store.isIndexingUnsorted {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView(value: store.indexProgress?.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                        Text(indexProgressTitle)
                            .font(.subheadline)
                    }

                    if let progress = store.indexProgress,
                       progress.total > 0 {
                        Text("已扫描 \(progress.completed.formatted()) / \(progress.total.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 8)
            }
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
                onDelete: requestDelete(asset:)
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

    private func share(asset: PHAsset) {
        store.requestShareItems(for: [asset]) { items, temporaryURLs in
            guard !items.isEmpty else {
                alert = PhotoVaultAlert(title: "无法分享", message: "这张照片暂时无法读取，请稍后重试。")
                return
            }
            shareItems = items
            shareTemporaryURLs = temporaryURLs
            isShowingShareSheet = true
        }
    }

    private func requestDelete(asset: PHAsset) {
        singleAssetToDelete = asset
        isShowingDeleteConfirmation = true
    }

    private func beginShare() {
        let assetsToShare = Array(selectedAssets.values)
        guard assetsToShare.count <= 12 else {
            alert = PhotoVaultAlert(title: "选择太多", message: "为了保持流畅，一次最多分享 12 张照片。")
            return
        }
        store.requestShareItems(for: assetsToShare) { items, temporaryURLs in
            guard !items.isEmpty else {
                alert = PhotoVaultAlert(title: "无法分享", message: "所选照片暂时无法读取，请稍后重试。")
                return
            }
            shareItems = items
            shareTemporaryURLs = temporaryURLs
            isShowingShareSheet = true
        }
    }

    private func cleanupShareItems() {
        for url in shareTemporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        shareTemporaryURLs.removeAll()
        shareItems.removeAll()
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedAssets.removeAll()
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
    let onCreate: (String) -> Void
    let onSelect: (PhotoAlbum) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingCreateAlert = false
    @State private var newAlbumName = ""

    private var userAlbums: [PhotoAlbum] {
        albums.filter { $0.kind == .user }
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
                    List(userAlbums) { album in
                        Button {
                            onSelect(album)
                            dismiss()
                        } label: {
                            AlbumListRow(album: album)
                        }
                        .buttonStyle(.plain)
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
}

private struct AlbumListRow: View {
    let album: PhotoAlbum

    var body: some View {
        HStack(spacing: 12) {
            if let previewAsset = album.previewAsset {
                AssetImageView(
                    asset: previewAsset,
                    targetSize: CGSize(width: 160, height: 160)
                )
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: album.symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .foregroundStyle(.primary)
                Text("\(album.assetCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
