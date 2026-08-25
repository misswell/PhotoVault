import Photos
import SwiftUI
import UIKit
import AVKit
import PhotosUI

private func viewerPageTransition(
    style: PhotoSwipeStyle,
    direction: Int
) -> AnyTransition {
    let insertionEdge: Edge = direction >= 0 ? .trailing : .leading
    let removalEdge: Edge = direction >= 0 ? .leading : .trailing

    switch style {
    case .system:
        return .identity
    case .fade:
        return .opacity
    case .push:
        return .asymmetric(
            insertion: .move(edge: insertionEdge),
            removal: .move(edge: removalEdge)
        )
    case .zoom:
        return .asymmetric(
            insertion: .scale(scale: 0.88).combined(with: .opacity),
            removal: .scale(scale: 1.08).combined(with: .opacity)
        )
    }
}

private func slideshowPageTransition(
    style: SlideshowTransitionStyle,
    direction: Int
) -> AnyTransition {
    let insertionEdge: Edge = direction >= 0 ? .trailing : .leading
    let removalEdge: Edge = direction >= 0 ? .leading : .trailing

    switch style {
    case .fade:
        return .opacity
    case .slide:
        return .asymmetric(
            insertion: .move(edge: insertionEdge),
            removal: .move(edge: removalEdge)
        )
    case .zoom:
        return .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 1.06).combined(with: .opacity)
        )
    case .dissolve:
        return .opacity.combined(with: .scale(scale: 0.96))
    }
}

private struct ViewerMediaView: View {
    let asset: PHAsset
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let requestPriority: PhotoRequestPriority
    let onReady: (Bool) -> Void
    let onZoomingChanged: ((Bool) -> Void)?

    init(
        asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        requestPriority: PhotoRequestPriority = .viewer,
        onReady: @escaping (Bool) -> Void = { _ in },
        onZoomingChanged: ((Bool) -> Void)? = nil
    ) {
        self.asset = asset
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.requestPriority = requestPriority
        self.onReady = onReady
        self.onZoomingChanged = onZoomingChanged
    }

    @ViewBuilder
    var body: some View {
        switch asset.mediaType {
        case .video:
            VideoAssetViewer(
                asset: asset,
                requestPriority: requestPriority,
                onReady: onReady
            )
        case .image where asset.mediaSubtypes.contains(.photoLive):
            LivePhotoAssetViewer(
                asset: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                requestPriority: requestPriority,
                onReady: onReady
            )
        default:
            ZoomableAssetView(
                asset: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                requestPriority: requestPriority,
                onLoadStateChange: onReady,
                onZoomingChanged: onZoomingChanged
            )
        }
    }
}

private struct LivePhotoAssetViewer: View {
    let asset: PHAsset
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let requestPriority: PhotoRequestPriority
    let onReady: (Bool) -> Void

    @State private var livePhoto: PHLivePhoto?
    @State private var requestHandle: PhotoRequestHandle?
    @State private var errorMessage: String?
    @State private var loadAttempt = 0

    var body: some View {
        ZStack {
            Color.black

            if let livePhoto {
                LivePhotoUIKitView(livePhoto: livePhoto, contentMode: contentMode)
                    .transition(.opacity)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .font(.title2)
                    Text(errorMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        loadAttempt &+= 1
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding()
            } else {
                ProgressView("正在读取实况照片…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .task(id: "\(asset.localIdentifier)-\(loadAttempt)") {
            requestLivePhoto()
        }
        .onDisappear {
            PhotoImageManager.shared.cancel(requestHandle)
            requestHandle = nil
        }
    }

    private func requestLivePhoto() {
        PhotoImageManager.shared.cancel(requestHandle)
        livePhoto = nil
        errorMessage = nil
        onReady(false)
        requestHandle = PhotoImageManager.shared.requestLivePhoto(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            priority: requestPriority,
            isNetworkAccessAllowed: true
        ) { livePhoto, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? Error
            Task { @MainActor in
                guard !cancelled else { return }
                if let livePhoto {
                    self.livePhoto = livePhoto
                    self.onReady(true)
                } else if let error {
                    self.errorMessage = error.localizedDescription
                    self.onReady(false)
                } else {
                    self.errorMessage = "实况照片暂时无法读取"
                    self.onReady(false)
                }
            }
        }
    }
}

private struct LivePhotoUIKitView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let contentMode: PHImageContentMode

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = contentMode == .aspectFill ? .scaleAspectFill : .scaleAspectFit
        view.isMuted = false
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
        }
    }
}

private struct VideoAssetViewer: View {
    let asset: PHAsset
    let requestPriority: PhotoRequestPriority
    let onReady: (Bool) -> Void

    @State private var player: AVPlayer?
    @State private var requestHandle: PhotoRequestHandle?
    @State private var errorMessage: String?
    @State private var loadAttempt = 0

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.title2)
                    Text(errorMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        loadAttempt &+= 1
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding()
            } else {
                ProgressView("正在准备视频…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .task(id: "\(asset.localIdentifier)-\(loadAttempt)") {
            requestPlayerItem()
        }
        .onDisappear {
            PhotoImageManager.shared.cancel(requestHandle)
            requestHandle = nil
            player?.pause()
            player = nil
        }
    }

    private func requestPlayerItem() {
        PhotoImageManager.shared.cancel(requestHandle)
        player?.pause()
        player = nil
        errorMessage = nil
        onReady(false)
        requestHandle = PhotoImageManager.shared.requestPlayerItem(
            for: asset,
            priority: requestPriority,
            isNetworkAccessAllowed: true
        ) { item, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? Error
            Task { @MainActor in
                guard !cancelled else { return }
                if let item {
                    self.player = AVPlayer(playerItem: item)
                    self.onReady(true)
                } else {
                    self.errorMessage = error?.localizedDescription ?? "视频暂时无法播放"
                    self.onReady(false)
                }
            }
        }
    }
}

struct AssetPager: View {
    let assets: PHFetchResult<PHAsset>
    @Binding var currentIndex: Int
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let neighborPriority: PhotoRequestPriority
    let onMediaReady: ((Bool) -> Void)?

    @State private var pageSelection: Int
    @State private var isZooming = false
    @State private var customDirection = 1
    @AppStorage(PhotoSwipeStyle.storageKey)
    private var swipeStyleRawValue = PhotoSwipeStyle.system.rawValue

    init(
        assets: PHFetchResult<PHAsset>,
        currentIndex: Binding<Int>,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        neighborPriority: PhotoRequestPriority = .slideshow,
        onMediaReady: ((Bool) -> Void)? = nil
    ) {
        self.assets = assets
        _currentIndex = currentIndex
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.neighborPriority = neighborPriority
        self.onMediaReady = onMediaReady
        _pageSelection = State(initialValue: currentIndex.wrappedValue)
    }

    // Keep only the visible page and its two neighbors alive.  The tags use
    // absolute asset indexes instead of -1/0/1 offsets, so rebuilding the
    // window after a swipe does not replace the page the user is looking at.
    private var pageIndexes: [Int] {
        guard assets.count > 0 else { return [] }

        var indexes = [Int]()
        if currentIndex > 0 {
            indexes.append(currentIndex - 1)
        }
        indexes.append(currentIndex)
        if currentIndex < assets.count - 1 {
            indexes.append(currentIndex + 1)
        }
        return indexes
    }

    private var swipeStyle: PhotoSwipeStyle {
        PhotoSwipeStyle(rawValue: swipeStyleRawValue) ?? .system
    }

    var body: some View {
        Group {
            if assets.count == 0 {
                ContentUnavailableView(
                    "没有可显示的照片",
                    systemImage: "photo",
                    description: Text("这个相册暂时为空。")
                )
                .foregroundStyle(.white)
            } else {
                if swipeStyle == .system {
                    nativePager
                } else {
                    customPager
                }
            }
        }
        .background(Color.black)
        .onChange(of: currentIndex) { oldValue, newValue in
            customDirection = newValue >= oldValue ? 1 : -1
            synchronizePageSelection()
        }
    }

    private var nativePager: some View {
        TabView(selection: $pageSelection) {
            ForEach(pageIndexes, id: \.self) { index in
                ViewerMediaView(
                    asset: assets.object(at: index),
                    targetSize: targetSize,
                    contentMode: contentMode,
                    requestPriority: index == currentIndex
                        ? .viewer
                        : neighborPriority,
                    onReady: { ready in
                        guard index == currentIndex else { return }
                        onMediaReady?(ready)
                    },
                    onZoomingChanged: { zooming in
                        guard index == currentIndex else { return }
                        if zooming {
                            isZooming = true
                        } else {
                            DispatchQueue.main.async {
                                isZooming = false
                            }
                        }
                    }
                )
                .id("viewer-\(assets.object(at: index).localIdentifier)")
                .tag(index)
                .contentShape(Rectangle())
                .simultaneousGesture(pageSwipeGesture)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: pageSelection) { _, newValue in
            guard newValue >= 0, newValue < assets.count else { return }
            guard newValue != currentIndex else { return }
            currentIndex = newValue
        }
    }

    private var customPager: some View {
        ZStack {
            ViewerMediaView(
                asset: assets.object(at: currentIndex),
                targetSize: targetSize,
                contentMode: contentMode,
                requestPriority: .viewer,
                onReady: { ready in
                    onMediaReady?(ready)
                },
                onZoomingChanged: { zooming in
                    isZooming = zooming
                }
            )
            .id("custom-viewer-\(assets.object(at: currentIndex).localIdentifier)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(
                viewerPageTransition(style: swipeStyle, direction: customDirection)
            )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(customSwipeGesture)
        .animation(.easeInOut(duration: 0.32), value: currentIndex)
    }

    private func synchronizePageSelection() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageSelection = currentIndex
        }
    }

    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isZooming else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)
                guard horizontalDistance > 72,
                      horizontalDistance > verticalDistance * 1.15
                else { return }
                // If the native page controller already completed this
                // swipe, its selection and the public index will briefly be
                // out of sync. Let that native transition win instead of
                // advancing a second time.
                guard pageSelection == currentIndex else { return }

                let nextIndex = value.translation.width < 0
                    ? currentIndex + 1
                    : currentIndex - 1
                guard nextIndex >= 0, nextIndex < assets.count else { return }

                // Update the public index first so the counter and filmstrip
                // move even when TabView's internal page recognizer loses the
                // drag to the zoomable image. Updating the tag as well keeps
                // the page controller's native slide animation.
                withAnimation(.easeInOut(duration: 0.28)) {
                    currentIndex = nextIndex
                    pageSelection = nextIndex
                }
            }
    }

    private var customSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isZooming else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)
                guard horizontalDistance > 72,
                      horizontalDistance > verticalDistance * 1.15
                else { return }

                let nextIndex = value.translation.width < 0
                    ? currentIndex + 1
                    : currentIndex - 1
                guard nextIndex >= 0, nextIndex < assets.count else { return }

                customDirection = nextIndex > currentIndex ? 1 : -1
                withAnimation(.easeInOut(duration: 0.32)) {
                    currentIndex = nextIndex
                }
            }
    }
}

struct PhotoViewerView: View {
    let assets: PHFetchResult<PHAsset>
    let initialIndex: Int
    @ObservedObject var store: PhotoLibraryStore
    let album: PhotoAlbum?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var currentIndex: Int
    @State private var controlsVisible = true
    @State private var isShowingInfo = false
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var shareTemporaryURLs: [URL] = []
    @State private var isFavorite: Bool
    @State private var filmstripPosition: Int?
    @State private var dismissDragOffset: CGSize = .zero
    @State private var isFullScreen = false
    @State private var isShowingAlbumPicker = false
    @State private var alert: PhotoVaultAlert?

    init(
        assets: PHFetchResult<PHAsset>,
        initialIndex: Int,
        store: PhotoLibraryStore,
        album: PhotoAlbum? = nil
    ) {
        self.assets = assets
        self.initialIndex = min(max(0, initialIndex), max(0, assets.count - 1))
        self.store = store
        self.album = album
        _currentIndex = State(initialValue: self.initialIndex)
        _isFavorite = State(
            initialValue: assets.count > 0 ? assets.object(at: self.initialIndex).isFavorite : false
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(Double(1 - dismissProgress * 0.72))
                .ignoresSafeArea()

            GeometryReader { proxy in
                AssetPager(
                    assets: assets,
                    currentIndex: $currentIndex,
                    targetSize: mediaTargetSize(for: proxy.size),
                    contentMode: viewerContentMode
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .offset(dismissDragOffset)
                .scaleEffect(1 - dismissProgress * 0.08)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            controlsVisible.toggle()
                        }
                    }
                )
                // Keep the Photos-style pull-down-to-dismiss interaction
                // simultaneous with the page controller. The gesture only
                // changes state for a clearly vertical drag, so horizontal
                // swipes remain owned by the photo pager.
                .simultaneousGesture(dismissGesture)
            }
            // Only the media canvas is allowed to extend under the status bar
            // and home indicator. Keep the control layer in the cover's safe
            // area so its buttons remain tappable on iPhone and iPad.
            .ignoresSafeArea(.container, edges: .all)

            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if assets.count > 0 {
                        ViewerFilmstrip(
                            assets: assets,
                            currentIndex: $currentIndex,
                            position: $filmstripPosition
                        )
                        .frame(height: 64)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 10)
                    }
                    bottomBar
                }
                .opacity(Double(1 - dismissProgress))
                .offset(y: dismissDragOffset.height * 0.28)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .presentationBackground(.black)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.automatic)
        .sheet(isPresented: $isShowingInfo) {
            if assets.count > 0 {
                PhotoInfoView(asset: assets.object(at: currentIndex))
            }
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            if let currentAsset {
                AlbumPickerSheet(
                    albums: store.albums,
                    onCreate: { name in
                        store.createAlbum(named: name, containing: [currentAsset]) { result in
                            handle(result)
                        }
                    },
                    onSelect: { targetAlbum in
                        store.addAssets([currentAsset], to: targetAlbum) { result in
                            handle(result)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: shareItems)
                .onDisappear(perform: cleanupShareItems)
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onChange(of: currentIndex) { _, newIndex in
            guard assets.count > 0 else { return }
            isFavorite = assets.object(at: newIndex).isFavorite
        }
    }

    private var dismissProgress: CGFloat {
        min(max(dismissDragOffset.height / 420, 0), 1)
    }

    private var currentAsset: PHAsset? {
        guard assets.count > 0 else { return nil }
        return assets.object(at: currentIndex)
    }

    private var viewerContentMode: PHImageContentMode {
        isFullScreen ? .aspectFill : .aspectFit
    }

    private func toggleFullScreen() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullScreen.toggle()
            controlsVisible = !isFullScreen
        }
    }

    private func mediaTargetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let isVertical = value.translation.height > abs(value.translation.width) * 1.15
                guard isVertical else { return }

                dismissDragOffset = CGSize(
                    width: value.translation.width * 0.18,
                    height: max(0, value.translation.height)
                )
            }
            .onEnded { value in
                let isVertical = value.translation.height > abs(value.translation.width) * 1.15
                guard isVertical else {
                    resetDismissOffset()
                    return
                }

                let shouldDismiss = value.translation.height > 150
                    || value.predictedEndTranslation.height > 280
                if shouldDismiss {
                    dismiss()
                } else {
                    resetDismissOffset()
                }
            }
    }

    private func resetDismissOffset() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            dismissDragOffset = .zero
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Text("\(currentIndex + 1) / \(assets.count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()

            Button {
                isShowingInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button(action: toggleFullScreen) {
                Image(systemName: isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(isFullScreen ? "退出全屏" : "全屏显示")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                guard assets.count > 0 else { return }
                store.toggleFavorite(assets.object(at: currentIndex))
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
            }

            Spacer()

            Text("双指缩放 · 双击放大")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.76))

            Spacer()

            Menu {
                Button {
                    isShowingAlbumPicker = true
                } label: {
                    Label("移入相册", systemImage: "folder.badge.plus")
                }

                if let album, album.kind == .user {
                    Button(role: .destructive) {
                        removeCurrentFromAlbum()
                    } label: {
                        Label("移出当前相册", systemImage: "folder.badge.minus")
                    }
                }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.title3)
            }
            .disabled(currentAsset == nil)
            .accessibilityLabel("管理相册")

            Button {
                guard assets.count > 0 else { return }
                store.requestShareItems(for: [assets.object(at: currentIndex)]) { items, temporaryURLs in
                    guard !items.isEmpty else { return }
                    shareItems = items
                    shareTemporaryURLs = temporaryURLs
                    isShowingShareSheet = true
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
            }
            .disabled(assets.count == 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private func cleanupShareItems() {
        for url in shareTemporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        shareTemporaryURLs.removeAll()
        shareItems.removeAll()
    }

    private func removeCurrentFromAlbum() {
        guard let currentAsset,
              let album,
              album.kind == .user
        else { return }

        store.removeAssets([currentAsset], from: album) { result in
            switch result {
            case .success:
                dismiss()
            case .failure:
                handle(result)
            }
        }
    }

    private func handle(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            alert = PhotoVaultAlert(title: "操作失败", message: error.localizedDescription)
        }
    }
}

private struct ViewerFilmstrip: UIViewRepresentable {
    let assets: PHFetchResult<PHAsset>
    @Binding var currentIndex: Int
    @Binding var position: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            assets: assets,
            currentIndex: $currentIndex,
            position: $position
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 48, height: 48)
        layout.minimumLineSpacing = 3
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.decelerationRate = .fast
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(
            ViewerFilmstripCell.self,
            forCellWithReuseIdentifier: ViewerFilmstripCell.reuseIdentifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        context.coordinator.attach(collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(
            collectionView: collectionView,
            assets: assets,
            currentIndex: currentIndex
        )
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UIScrollViewDelegate {
        private let thumbnailSize = CGSize(width: 128, height: 128)
        private var assets: PHFetchResult<PHAsset>
        private var selectedIndex: Int
        private var collectionView: UICollectionView?
        private var isProgrammaticScroll = false
        private var needsInitialScroll = true
        private var currentIndexBinding: Binding<Int>
        private var positionBinding: Binding<Int?>

        init(
            assets: PHFetchResult<PHAsset>,
            currentIndex: Binding<Int>,
            position: Binding<Int?>
        ) {
            self.assets = assets
            selectedIndex = min(max(0, currentIndex.wrappedValue), max(0, assets.count - 1))
            currentIndexBinding = currentIndex
            positionBinding = position
        }

        func attach(_ collectionView: UICollectionView) {
            self.collectionView = collectionView
            collectionView.reloadData()
            // SwiftUI creates the representable before its final frame is
            // assigned. Defer the first scroll so opening a photo from the
            // middle of a large library also centers its filmstrip item.
            DispatchQueue.main.async { [weak self] in
                self?.scrollToSelected(animated: false)
            }
        }

        func update(
            collectionView: UICollectionView,
            assets: PHFetchResult<PHAsset>,
            currentIndex: Int
        ) {
            self.collectionView = collectionView

            if self.assets.count != assets.count {
                self.assets = assets
                collectionView.reloadData()
            } else {
                self.assets = assets
            }

            let clampedIndex = min(max(0, currentIndex), max(0, assets.count - 1))
            guard clampedIndex != selectedIndex else {
                updateVisibleSelection()
                if needsInitialScroll {
                    scrollToSelected(animated: false)
                }
                return
            }

            selectedIndex = clampedIndex
            updateVisibleSelection()
            scrollToSelected(animated: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            assets.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ViewerFilmstripCell.reuseIdentifier,
                for: indexPath
            ) as! ViewerFilmstripCell
            cell.configure(asset: assets.object(at: indexPath.item), targetSize: thumbnailSize)
            cell.setSelected(indexPath.item == selectedIndex)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            select(index: indexPath.item, animated: true, notify: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            let prefetchAssets = indexPaths.compactMap { indexPath -> PHAsset? in
                guard indexPath.item >= 0, indexPath.item < assets.count else { return nil }
                return assets.object(at: indexPath.item)
            }
            guard !prefetchAssets.isEmpty else { return }
            PhotoImageManager.shared.startCaching(
                assets: prefetchAssets,
                targetSize: thumbnailSize
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            let prefetchedAssets = indexPaths.compactMap { indexPath -> PHAsset? in
                guard indexPath.item >= 0, indexPath.item < assets.count else { return nil }
                return assets.object(at: indexPath.item)
            }
            guard !prefetchedAssets.isEmpty else { return }
            PhotoImageManager.shared.stopCaching(
                assets: prefetchedAssets,
                targetSize: thumbnailSize
            )
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportCenteredIndex(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                reportCenteredIndex(in: scrollView)
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        private func select(index: Int, animated: Bool, notify: Bool) {
            guard index >= 0, index < assets.count else { return }
            selectedIndex = index
            updateVisibleSelection()
            if notify {
                currentIndexBinding.wrappedValue = index
                positionBinding.wrappedValue = index
            }
            scrollToSelected(animated: animated)
        }

        private func updateVisibleSelection() {
            guard let collectionView else { return }
            for cell in collectionView.visibleCells {
                guard let filmstripCell = cell as? ViewerFilmstripCell,
                      let indexPath = collectionView.indexPath(for: cell)
                else { continue }
                filmstripCell.setSelected(indexPath.item == selectedIndex)
            }
        }

        private func scrollToSelected(animated: Bool) {
            guard let collectionView,
                  selectedIndex >= 0,
                  selectedIndex < assets.count,
                  collectionView.bounds.width > 0
            else { return }

            isProgrammaticScroll = true
            positionBinding.wrappedValue = selectedIndex
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(
                at: IndexPath(item: selectedIndex, section: 0),
                at: .centeredHorizontally,
                animated: animated
            )
            if !animated {
                isProgrammaticScroll = false
            }
            needsInitialScroll = false
        }

        private func reportCenteredIndex(in scrollView: UIScrollView) {
            guard !isProgrammaticScroll,
                  let collectionView = scrollView as? UICollectionView
            else { return }

            let center = CGPoint(
                x: scrollView.contentOffset.x + scrollView.bounds.midX,
                y: scrollView.contentOffset.y + scrollView.bounds.midY
            )
            let indexPath = collectionView.indexPathForItem(at: center)
                ?? collectionView.indexPathsForVisibleItems.min {
                    guard let lhs = collectionView.cellForItem(at: $0),
                          let rhs = collectionView.cellForItem(at: $1)
                    else { return false }
                    return abs(lhs.center.x - center.x) < abs(rhs.center.x - center.x)
                }

            guard let index = indexPath?.item,
                  index >= 0,
                  index < assets.count,
                  index != selectedIndex
            else { return }

            select(index: index, animated: false, notify: true)
        }
    }
}

private final class ViewerFilmstripCell: UICollectionViewCell {
    static let reuseIdentifier = "ViewerFilmstripCell"

    private let imageView = UIImageView()
    private var requestHandle: PhotoRequestHandle?
    private var representedIdentifier: String?
    private var representedAsset: PHAsset?
    private var representedTargetSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 8
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        layer.cornerRadius = 8
        layer.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        representedIdentifier = nil
        representedAsset = nil
        imageView.image = nil
        setSelected(false)
    }

    func configure(asset: PHAsset, targetSize: CGSize) {
        cancelRequest()
        representedIdentifier = asset.localIdentifier
        representedAsset = asset
        representedTargetSize = targetSize
        imageView.image = nil
        PhotoImageManager.shared.startCaching(asset: asset, targetSize: targetSize)
        requestHandle = PhotoImageManager.shared.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            deliveryMode: .opportunistic,
            resizeMode: .fast,
            priority: .nearGrid,
            isNetworkAccessAllowed: true
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            guard !cancelled else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.representedIdentifier == asset.localIdentifier
                else { return }
                self.imageView.image = image
            }
        }
    }

    func showPlaceholder() {
        cancelRequest()
        representedIdentifier = nil
        representedAsset = nil
        imageView.image = nil
    }

    func setSelected(_ selected: Bool) {
        layer.borderWidth = selected ? 2 : 0
        layer.borderColor = selected ? UIColor.white.cgColor : UIColor.clear.cgColor
    }

    private func cancelRequest() {
        PhotoImageManager.shared.cancel(requestHandle)
        if let representedAsset {
            PhotoImageManager.shared.stopCaching(
                asset: representedAsset,
                targetSize: representedTargetSize
            )
        }
        requestHandle = nil
    }
}

/// The Unsorted screen is backed by an SQLite index rather than a
/// PHFetchResult containing every matching asset.  This pager keeps the
/// current item and its two neighbors available, then asks PhotoKit for the
/// next three only after a swipe reaches a new index.
private struct IndexedAssetPager: View {
    let totalCount: Int
    let store: PhotoLibraryStore
    @Binding var currentIndex: Int
    @Binding var assetsByIndex: [Int: PHAsset]
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let neighborPriority: PhotoRequestPriority
    let onMediaReady: ((Bool) -> Void)?

    @State private var pageSelection: Int
    @State private var loadingOffsets = Set<Int>()
    @State private var loadedOffsets = Set<Int>()
    @State private var loadError: String?
    @State private var isZooming = false
    @State private var customDirection = 1
    @AppStorage(PhotoSwipeStyle.storageKey)
    private var swipeStyleRawValue = PhotoSwipeStyle.system.rawValue

    private let pageSize = 60

    init(
        totalCount: Int,
        store: PhotoLibraryStore,
        currentIndex: Binding<Int>,
        assetsByIndex: Binding<[Int: PHAsset]>,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        neighborPriority: PhotoRequestPriority = .slideshow,
        onMediaReady: ((Bool) -> Void)? = nil
    ) {
        self.totalCount = max(0, totalCount)
        self.store = store
        _currentIndex = currentIndex
        _assetsByIndex = assetsByIndex
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.neighborPriority = neighborPriority
        self.onMediaReady = onMediaReady
        _pageSelection = State(initialValue: min(max(0, currentIndex.wrappedValue), max(0, totalCount - 1)))
    }

    private var pageIndexes: [Int] {
        guard totalCount > 0 else { return [] }
        let index = min(max(0, currentIndex), totalCount - 1)
        var indexes = [Int]()
        if index > 0 { indexes.append(index - 1) }
        indexes.append(index)
        if index < totalCount - 1 { indexes.append(index + 1) }
        return indexes
    }

    private var swipeStyle: PhotoSwipeStyle {
        PhotoSwipeStyle(rawValue: swipeStyleRawValue) ?? .system
    }

    var body: some View {
        Group {
            if totalCount == 0 {
                ContentUnavailableView(
                    "没有可显示的照片",
                    systemImage: "photo",
                    description: Text("这个列表暂时为空。")
                )
                .foregroundStyle(.white)
            } else {
                if swipeStyle == .system {
                    nativePager
                } else {
                    customPager
                }
            }
        }
        .background(Color.black)
        .onChange(of: currentIndex) { oldValue, newValue in
            customDirection = newValue >= oldValue ? 1 : -1
            synchronizePageSelection(to: newValue)
            trimAssetCache(around: newValue)
            loadWindow(around: newValue)
        }
        .onChange(of: totalCount) { _, newValue in
            loadingOffsets.removeAll()
            loadedOffsets.removeAll()
            assetsByIndex.removeAll()
            synchronizePageSelection(to: min(currentIndex, max(0, newValue - 1)))
            loadWindow(around: currentIndex)
        }
        .overlay {
            if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .font(.title2)
                    Text(loadError)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        self.loadError = nil
                        loadWindow(around: currentIndex)
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .task(id: "\(totalCount)-\(currentIndex)") {
            loadWindow(around: currentIndex)
        }
    }

    private var nativePager: some View {
        TabView(selection: $pageSelection) {
            ForEach(pageIndexes, id: \.self) { index in
                Group {
                    if let asset = assetsByIndex[index] {
                        ViewerMediaView(
                            asset: asset,
                            targetSize: targetSize,
                            contentMode: contentMode,
                            requestPriority: index == currentIndex
                                ? .viewer
                                : neighborPriority,
                            onReady: { ready in
                                guard index == currentIndex else { return }
                                onMediaReady?(ready)
                            },
                            onZoomingChanged: { zooming in
                                guard index == currentIndex else { return }
                                if zooming {
                                    isZooming = true
                                } else {
                                    DispatchQueue.main.async {
                                        isZooming = false
                                    }
                                }
                            }
                        )
                        .id("indexed-viewer-\(asset.localIdentifier)")
                    } else {
                        ProgressView("正在读取照片…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(index)
                .contentShape(Rectangle())
                .simultaneousGesture(pageSwipeGesture)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: pageSelection) { _, newValue in
            guard newValue >= 0, newValue < totalCount else { return }
            guard newValue != currentIndex else { return }
            currentIndex = newValue
        }
    }

    @ViewBuilder
    private var customPager: some View {
        if let asset = assetsByIndex[currentIndex] {
            ZStack {
                ViewerMediaView(
                    asset: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    requestPriority: .viewer,
                    onReady: { ready in
                        onMediaReady?(ready)
                    },
                    onZoomingChanged: { zooming in
                        isZooming = zooming
                    }
                )
                .id("custom-indexed-viewer-\(asset.localIdentifier)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    viewerPageTransition(style: swipeStyle, direction: customDirection)
                )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(customSwipeGesture)
            .animation(.easeInOut(duration: 0.32), value: currentIndex)
        } else {
            ProgressView("正在读取照片…")
                .tint(.white)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .simultaneousGesture(customSwipeGesture)
        }
    }

    private func synchronizePageSelection(to index: Int) {
        let clampedIndex = min(max(0, index), max(0, totalCount - 1))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageSelection = clampedIndex
        }
    }

    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isZooming else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)
                guard horizontalDistance > 72,
                      horizontalDistance > verticalDistance * 1.15
                else { return }
                guard pageSelection == currentIndex else { return }

                let nextIndex = value.translation.width < 0
                    ? currentIndex + 1
                    : currentIndex - 1
                guard nextIndex >= 0, nextIndex < totalCount else { return }

                withAnimation(.easeInOut(duration: 0.28)) {
                    currentIndex = nextIndex
                    pageSelection = nextIndex
                }
            }
    }

    private var customSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isZooming else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)
                guard horizontalDistance > 72,
                      horizontalDistance > verticalDistance * 1.15
                else { return }

                let nextIndex = value.translation.width < 0
                    ? currentIndex + 1
                    : currentIndex - 1
                guard nextIndex >= 0, nextIndex < totalCount else { return }

                customDirection = nextIndex > currentIndex ? 1 : -1
                withAnimation(.easeInOut(duration: 0.32)) {
                    currentIndex = nextIndex
                }
            }
    }

    private func loadWindow(around index: Int) {
        guard totalCount > 0 else { return }
        let clampedIndex = min(max(0, index), totalCount - 1)
        let offset = (clampedIndex / pageSize) * pageSize
        var offsets = [offset]
        if offset > 0 {
            offsets.append(offset - pageSize)
        }
        if offset + pageSize < totalCount {
            offsets.append(offset + pageSize)
        }

        for pageOffset in offsets {
            loadPage(at: pageOffset)
        }
    }

    private func loadPage(at offset: Int) {
        guard offset >= 0, offset < totalCount,
              !loadedOffsets.contains(offset),
              loadingOffsets.insert(offset).inserted
        else { return }

        let limit = min(pageSize, totalCount - offset)
        store.fetchUnsortedAssets(offset: offset, limit: limit) { result in
            loadingOffsets.remove(offset)
            guard case .success(let pageAssets) = result else {
                if case .failure(let error) = result {
                    loadError = error.localizedDescription
                }
                return
            }

            loadError = nil
            loadedOffsets.insert(offset)
            var merged = assetsByIndex
            for (localIndex, asset) in pageAssets.enumerated() {
                merged[offset + localIndex] = asset
            }
            assetsByIndex = merged
            trimAssetCache(around: currentIndex)
        }
    }

    private func trimAssetCache(around index: Int) {
        guard totalCount > 0 else {
            assetsByIndex.removeAll()
            loadedOffsets.removeAll()
            return
        }

        let clampedIndex = min(max(0, index), totalCount - 1)
        let lowerBound = max(0, clampedIndex - pageSize)
        let upperBound = min(totalCount, clampedIndex + pageSize * 2)
        assetsByIndex = assetsByIndex.filter {
            $0.key >= lowerBound && $0.key < upperBound
        }
        loadedOffsets = loadedOffsets.filter {
            $0 < upperBound && $0 + pageSize > lowerBound
        }
    }
}

/// A horizontally scrolling, recycled filmstrip for the indexed viewer. It
/// reports the centered thumbnail after a drag and resolves only the page of
/// thumbnails currently visible, so a 100k-photo list does not become a
/// 100k-element in-memory array.
private struct IndexedViewerFilmstrip: UIViewRepresentable {
    let totalCount: Int
    let store: PhotoLibraryStore
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(
            totalCount: totalCount,
            store: store,
            currentIndex: $currentIndex
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 48, height: 48)
        layout.minimumLineSpacing = 3
        layout.sectionInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.decelerationRate = .fast
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(
            ViewerFilmstripCell.self,
            forCellWithReuseIdentifier: ViewerFilmstripCell.reuseIdentifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        context.coordinator.attach(collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(
            collectionView: collectionView,
            totalCount: totalCount,
            currentIndex: currentIndex
        )
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UIScrollViewDelegate {
        private let pageSize = 180
        private let maxCachedPages = 10
        private var totalCount: Int
        private let store: PhotoLibraryStore
        private var selectedIndex: Int
        private var pages: [Int: [PHAsset]] = [:]
        private var pageOrder: [Int] = []
        private var loadingPages = Set<Int>()
        private weak var collectionView: UICollectionView?
        private var isProgrammaticScroll = false
        private var needsInitialScroll = true
        private var currentIndexBinding: Binding<Int>

        init(
            totalCount: Int,
            store: PhotoLibraryStore,
            currentIndex: Binding<Int>
        ) {
            self.totalCount = max(0, totalCount)
            self.store = store
            selectedIndex = min(max(0, currentIndex.wrappedValue), max(0, totalCount - 1))
            currentIndexBinding = currentIndex
        }

        func attach(_ collectionView: UICollectionView) {
            self.collectionView = collectionView
            collectionView.reloadData()
            loadPage(containing: selectedIndex, in: collectionView)
            DispatchQueue.main.async { [weak self] in
                self?.scrollToSelected(animated: false)
            }
        }

        func update(
            collectionView: UICollectionView,
            totalCount: Int,
            currentIndex: Int
        ) {
            self.collectionView = collectionView
            let newCount = max(0, totalCount)
            if newCount != self.totalCount {
                self.totalCount = newCount
                pages.removeAll(keepingCapacity: true)
                pageOrder.removeAll(keepingCapacity: true)
                loadingPages.removeAll()
                needsInitialScroll = true
                collectionView.reloadData()
            }

            let clampedIndex = min(max(0, currentIndex), max(0, self.totalCount - 1))
            guard clampedIndex != selectedIndex else {
                updateVisibleSelection()
                if needsInitialScroll {
                    scrollToSelected(animated: false)
                }
                return
            }

            selectedIndex = clampedIndex
            updateVisibleSelection()
            loadPage(containing: selectedIndex, in: collectionView)
            scrollToSelected(animated: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            totalCount
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ViewerFilmstripCell.reuseIdentifier,
                for: indexPath
            ) as! ViewerFilmstripCell

            if let asset = asset(at: indexPath.item) {
                cell.configure(asset: asset, targetSize: CGSize(width: 128, height: 128))
            } else {
                cell.showPlaceholder()
                loadPage(containing: indexPath.item, in: collectionView)
            }
            cell.setSelected(indexPath.item == selectedIndex)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            guard indexPath.item < totalCount else { return }
            select(index: indexPath.item, animated: true, notify: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            for indexPath in indexPaths {
                loadPage(containing: indexPath.item, in: collectionView)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            // Requests are page-sized and inexpensive compared with the
            // image requests. Let a page already in flight finish so a fast
            // drag does not repeatedly fetch the same metadata.
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportCenteredIndex(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { reportCenteredIndex(in: scrollView) }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        private func select(index: Int, animated: Bool, notify: Bool) {
            guard index >= 0, index < totalCount else { return }
            selectedIndex = index
            updateVisibleSelection()
            if notify { currentIndexBinding.wrappedValue = index }
            loadPage(containing: index, in: collectionView)
            scrollToSelected(animated: animated)
        }

        private func updateVisibleSelection() {
            guard let collectionView else { return }
            for cell in collectionView.visibleCells {
                guard let filmstripCell = cell as? ViewerFilmstripCell,
                      let indexPath = collectionView.indexPath(for: cell)
                else { continue }
                filmstripCell.setSelected(indexPath.item == selectedIndex)
            }
        }

        private func scrollToSelected(animated: Bool) {
            guard let collectionView,
                  selectedIndex >= 0,
                  selectedIndex < totalCount,
                  collectionView.bounds.width > 0
            else { return }

            isProgrammaticScroll = true
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(
                at: IndexPath(item: selectedIndex, section: 0),
                at: .centeredHorizontally,
                animated: animated
            )
            if !animated { isProgrammaticScroll = false }
            needsInitialScroll = false
        }

        private func reportCenteredIndex(in scrollView: UIScrollView) {
            guard !isProgrammaticScroll,
                  let collectionView = scrollView as? UICollectionView
            else { return }

            let center = CGPoint(
                x: scrollView.contentOffset.x + scrollView.bounds.midX,
                y: scrollView.contentOffset.y + scrollView.bounds.midY
            )
            let indexPath = collectionView.indexPathForItem(at: center)
                ?? collectionView.indexPathsForVisibleItems.min {
                    guard let lhs = collectionView.cellForItem(at: $0),
                          let rhs = collectionView.cellForItem(at: $1)
                    else { return false }
                    return abs(lhs.center.x - center.x) < abs(rhs.center.x - center.x)
                }
            guard let index = indexPath?.item,
                  index >= 0,
                  index < totalCount,
                  index != selectedIndex
            else { return }
            select(index: index, animated: false, notify: true)
        }

        private func pageStart(for index: Int) -> Int {
            (max(0, index) / pageSize) * pageSize
        }

        private func asset(at index: Int) -> PHAsset? {
            let start = pageStart(for: index)
            let localIndex = index - start
            return pages[start]?.indices.contains(localIndex) == true
                ? pages[start]?[localIndex]
                : nil
        }

        private func loadPage(containing index: Int, in collectionView: UICollectionView?) {
            guard totalCount > 0, index >= 0, index < totalCount else { return }
            let start = pageStart(for: index)
            guard pages[start] == nil,
                  loadingPages.insert(start).inserted
            else { return }

            let limit = min(pageSize, totalCount - start)
            store.fetchUnsortedAssets(offset: start, limit: limit) { [weak self, weak collectionView] result in
                guard let self else { return }
                self.loadingPages.remove(start)
                guard case .success(let assets) = result else { return }

                self.pages[start] = assets
                self.pageOrder.removeAll { $0 == start }
                self.pageOrder.append(start)
                while self.pageOrder.count > self.maxCachedPages {
                    let evicted = self.pageOrder.removeFirst()
                    self.pages.removeValue(forKey: evicted)
                }

                guard let collectionView else { return }
                let end = min(self.totalCount, start + assets.count)
                let visiblePaths = (start..<end).compactMap { item -> IndexPath? in
                    let path = IndexPath(item: item, section: 0)
                    return collectionView.indexPathsForVisibleItems.contains(path) ? path : nil
                }
                if !visiblePaths.isEmpty { collectionView.reloadItems(at: visiblePaths) }
            }
        }
    }
}

/// Full-screen viewer for the indexed Unsorted list. Its UI intentionally
/// mirrors PhotoViewerView, but its pager and filmstrip never materialize the
/// entire result set.
struct IndexedPhotoViewerView: View {
    let title: String
    let totalCount: Int
    let initialIndex: Int
    @ObservedObject var store: PhotoLibraryStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var currentIndex: Int
    @State private var assetsByIndex: [Int: PHAsset] = [:]
    @State private var controlsVisible = true
    @State private var isShowingInfo = false
    @State private var isShowingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var shareTemporaryURLs: [URL] = []
    @State private var isFavorite = false
    @State private var dismissDragOffset: CGSize = .zero
    @State private var isFullScreen = false
    @State private var isShowingAlbumPicker = false
    @State private var alert: PhotoVaultAlert?

    init(
        title: String,
        totalCount: Int,
        initialIndex: Int,
        store: PhotoLibraryStore
    ) {
        self.title = title
        self.totalCount = max(0, totalCount)
        self.initialIndex = min(max(0, initialIndex), max(0, totalCount - 1))
        self.store = store
        _currentIndex = State(initialValue: self.initialIndex)
    }

    private var currentAsset: PHAsset? {
        assetsByIndex[currentIndex]
    }

    private var currentAssetID: String {
        currentAsset?.localIdentifier ?? "none-\(currentIndex)"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(Double(1 - dismissProgress * 0.72))
                .ignoresSafeArea()

            GeometryReader { proxy in
                IndexedAssetPager(
                    totalCount: totalCount,
                    store: store,
                    currentIndex: $currentIndex,
                    assetsByIndex: $assetsByIndex,
                    targetSize: mediaTargetSize(for: proxy.size),
                    contentMode: viewerContentMode
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .offset(dismissDragOffset)
                .scaleEffect(1 - dismissProgress * 0.08)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            controlsVisible.toggle()
                        }
                    }
                )
                .simultaneousGesture(dismissGesture)
            }
            .ignoresSafeArea(.container, edges: .all)

            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if totalCount > 0 {
                        IndexedViewerFilmstrip(
                            totalCount: totalCount,
                            store: store,
                            currentIndex: $currentIndex
                        )
                        .frame(height: 64)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 10)
                    }
                    bottomBar
                }
                .opacity(Double(1 - dismissProgress))
                .offset(y: dismissDragOffset.height * 0.28)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .presentationBackground(.black)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.automatic)
        .sheet(isPresented: $isShowingInfo) {
            if let currentAsset {
                PhotoInfoView(asset: currentAsset)
            }
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            if let currentAsset {
                AlbumPickerSheet(
                    albums: store.albums,
                    onCreate: { name in
                        store.createAlbum(named: name, containing: [currentAsset]) { result in
                            handle(result)
                        }
                    },
                    onSelect: { targetAlbum in
                        store.addAssets([currentAsset], to: targetAlbum) { result in
                            handle(result)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: shareItems)
                .onDisappear(perform: cleanupShareItems)
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onChange(of: currentAssetID) { _, _ in
            isFavorite = currentAsset?.isFavorite ?? false
        }
    }

    private var dismissProgress: CGFloat {
        min(max(dismissDragOffset.height / 420, 0), 1)
    }

    private var viewerContentMode: PHImageContentMode {
        isFullScreen ? .aspectFill : .aspectFit
    }

    private func toggleFullScreen() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullScreen.toggle()
            if isFullScreen {
                controlsVisible = false
            } else {
                controlsVisible = true
            }
        }
    }

    private func mediaTargetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let isVertical = value.translation.height > abs(value.translation.width) * 1.15
                guard isVertical else { return }
                dismissDragOffset = CGSize(
                    width: value.translation.width * 0.18,
                    height: max(0, value.translation.height)
                )
            }
            .onEnded { value in
                let isVertical = value.translation.height > abs(value.translation.width) * 1.15
                guard isVertical else {
                    resetDismissOffset()
                    return
                }
                if value.translation.height > 150 || value.predictedEndTranslation.height > 280 {
                    dismiss()
                } else {
                    resetDismissOffset()
                }
            }
    }

    private func resetDismissOffset() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            dismissDragOffset = .zero
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Text("\(min(currentIndex + 1, max(1, totalCount))) / \(totalCount)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()

            Button { isShowingInfo = true } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(currentAsset == nil)

            Button(action: toggleFullScreen) {
                Image(systemName: isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(isFullScreen ? "退出全屏" : "全屏显示")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                guard let currentAsset else { return }
                store.toggleFavorite(currentAsset)
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
            }
            .disabled(currentAsset == nil)

            Spacer()

            Text("左右滑动 · 双指缩放")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.76))

            Spacer()

            Menu {
                Button {
                    isShowingAlbumPicker = true
                } label: {
                    Label("移入相册", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.title3)
            }
            .disabled(currentAsset == nil)
            .accessibilityLabel("移入相册")

            Button {
                guard let currentAsset else { return }
                store.requestShareItems(for: [currentAsset]) { items, temporaryURLs in
                    guard !items.isEmpty else { return }
                    shareItems = items
                    shareTemporaryURLs = temporaryURLs
                    isShowingShareSheet = true
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
            }
            .disabled(currentAsset == nil)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
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
            alert = PhotoVaultAlert(title: "操作失败", message: error.localizedDescription)
        }
    }
}

/// A slideshow deliberately uses one visible page instead of a dynamically
/// rebuilt TabView window. TabView can restore its selection when that window
/// changes, which is what made autoplay bounce between the first two assets.
/// The current asset is still kept at full display size while only two small
/// neighbors are prefetched.
private struct SlideshowAssetPager: View {
    let assets: PHFetchResult<PHAsset>
    @Binding var currentIndex: Int
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onMediaReady: (Bool) -> Void
    let transitionStyle: SlideshowTransitionStyle

    @State private var cachedNeighbors: [String: PHAsset] = [:]
    @State private var prefetchHandles: [String: PhotoRequestHandle] = [:]
    @State private var isZooming = false
    @State private var transitionDirection = 1

    private var safeIndex: Int {
        min(max(0, currentIndex), max(0, assets.count - 1))
    }

    private var currentAsset: PHAsset? {
        guard assets.count > 0 else { return nil }
        return assets.object(at: safeIndex)
    }

    private var currentAssetID: String {
        currentAsset?.localIdentifier ?? "empty"
    }

    var body: some View {
        ZStack {
            Color.black

            if let currentAsset {
                ViewerMediaView(
                    asset: currentAsset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    requestPriority: .viewer,
                    onReady: onMediaReady,
                    onZoomingChanged: { zooming in
                        if zooming {
                            isZooming = true
                        } else {
                            DispatchQueue.main.async {
                                isZooming = false
                            }
                        }
                    }
                )
                .id("slideshow-\(currentAsset.localIdentifier)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    slideshowPageTransition(
                        style: transitionStyle,
                        direction: transitionDirection
                    )
                )
            } else {
                ContentUnavailableView(
                    "没有可显示的照片",
                    systemImage: "photo",
                    description: Text("这个相册暂时为空。")
                )
                .foregroundStyle(.white)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: currentAssetID)
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .onAppear(perform: updatePrefetch)
        .onChange(of: currentIndex) { oldValue, newValue in
            transitionDirection = newValue >= oldValue ? 1 : -1
            updatePrefetch()
        }
        .onChange(of: targetSize) { _, _ in
            updatePrefetch()
        }
        .onChange(of: contentMode.rawValue) { _, _ in
            updatePrefetch()
        }
        .onDisappear(perform: stopPrefetch)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isZooming else { return }
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard horizontal > 72, horizontal > vertical * 1.15 else { return }
                if value.translation.width < 0 {
                    onNext()
                } else {
                    onPrevious()
                }
            }
    }

    private var prefetchTargetSize: CGSize {
        let longestSide = max(targetSize.width, targetSize.height)
        let factor = longestSide > 900 ? 900 / longestSide : 1
        return CGSize(
            width: max(1, targetSize.width * factor),
            height: max(1, targetSize.height * factor)
        )
    }

    private var fullPrefetchTargetSize: CGSize {
        CGSize(
            width: max(1, targetSize.width),
            height: max(1, targetSize.height)
        )
    }

    private func prefetchKey(for asset: PHAsset) -> String {
        "\(asset.localIdentifier)-\(Int(fullPrefetchTargetSize.width.rounded()))-\(Int(fullPrefetchTargetSize.height.rounded()))-\(contentMode.rawValue)"
    }

    private func updatePrefetch() {
        guard assets.count > 0 else { return }
        let neighborIndexes = [safeIndex - 1, safeIndex + 1]
            .filter { $0 >= 0 && $0 < assets.count }
        let neighbors = neighborIndexes.map { assets.object(at: $0) }
        let next = Dictionary(uniqueKeysWithValues: neighbors.map {
            ($0.localIdentifier, $0)
        })

        let stale = cachedNeighbors.values.filter {
            next[$0.localIdentifier] == nil
        }
        if !stale.isEmpty {
            PhotoImageManager.shared.stopCaching(
                assets: Array(stale),
                targetSize: prefetchTargetSize,
                contentMode: contentMode,
                isNetworkAccessAllowed: true
            )
        }

        let desiredPrefetchKeys = Set(
            neighbors.map { prefetchKey(for: $0) }
        )
        let stalePrefetchKeys = prefetchHandles.keys.filter {
            !desiredPrefetchKeys.contains($0)
        }
        for key in stalePrefetchKeys {
            if let handle = prefetchHandles.removeValue(forKey: key) {
                PhotoImageManager.shared.cancel(handle)
            }
        }

        for neighbor in neighbors {
            let key = prefetchKey(for: neighbor)
            if prefetchHandles[key] == nil {
                prefetchHandles[key] = PhotoImageManager.shared.prefetchImage(
                    for: neighbor,
                    targetSize: fullPrefetchTargetSize,
                    contentMode: contentMode,
                    priority: .slideshow
                )
            }
        }
        cachedNeighbors = next
    }

    private func stopPrefetch() {
        for handle in prefetchHandles.values {
            PhotoImageManager.shared.cancel(handle)
        }
        prefetchHandles.removeAll()
        guard !cachedNeighbors.isEmpty else { return }
        PhotoImageManager.shared.stopCaching(
            assets: Array(cachedNeighbors.values),
            targetSize: prefetchTargetSize,
            contentMode: contentMode,
            isNetworkAccessAllowed: true
        )
        cachedNeighbors.removeAll()
    }
}

/// The unsorted list has no PHFetchResult containing all assets. This pager
/// resolves only the current 60-item metadata page and the next page, while
/// playback itself remains independent from iCloud image delivery.
private struct IndexedSlideshowAssetPager: View {
    let totalCount: Int
    let store: PhotoLibraryStore
    @Binding var currentIndex: Int
    @Binding var assetsByIndex: [Int: PHAsset]
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onMediaReady: (Bool) -> Void
    let transitionStyle: SlideshowTransitionStyle

    @State private var loadingOffsets = Set<Int>()
    @State private var loadedOffsets = Set<Int>()
    @State private var loadError: String?
    @State private var cachedNeighbors: [String: PHAsset] = [:]
    @State private var prefetchHandles: [String: PhotoRequestHandle] = [:]
    @State private var isZooming = false
    @State private var transitionDirection = 1

    private let pageSize = 60

    private var safeIndex: Int {
        min(max(0, currentIndex), max(0, totalCount - 1))
    }

    private var currentAsset: PHAsset? {
        assetsByIndex[safeIndex]
    }

    private var currentAssetID: String {
        currentAsset?.localIdentifier ?? "loading-\(safeIndex)"
    }

    var body: some View {
        ZStack {
            Color.black

            if let currentAsset {
                ViewerMediaView(
                    asset: currentAsset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    requestPriority: .viewer,
                    onReady: onMediaReady,
                    onZoomingChanged: { zooming in
                        if zooming {
                            isZooming = true
                        } else {
                            DispatchQueue.main.async {
                                isZooming = false
                            }
                        }
                    }
                )
                .id("indexed-slideshow-\(currentAsset.localIdentifier)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    slideshowPageTransition(
                        style: transitionStyle,
                        direction: transitionDirection
                    )
                )
            } else {
                ProgressView("正在读取照片…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: currentAssetID)
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .overlay {
            if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .font(.title2)
                    Text(loadError)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        self.loadError = nil
                        loadWindow(around: currentIndex)
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .onAppear {
            loadWindow(around: currentIndex)
            updatePrefetch()
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            transitionDirection = newValue >= oldValue ? 1 : -1
            loadWindow(around: newValue)
            trimAssetCache(around: newValue)
            updatePrefetch()
        }
        .onChange(of: targetSize) { _, _ in
            updatePrefetch()
        }
        .onChange(of: contentMode.rawValue) { _, _ in
            updatePrefetch()
        }
        .onDisappear(perform: stopPrefetch)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isZooming else { return }
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard horizontal > 72, horizontal > vertical * 1.15 else { return }
                if value.translation.width < 0 {
                    onNext()
                } else {
                    onPrevious()
                }
            }
    }

    private var prefetchTargetSize: CGSize {
        let longestSide = max(targetSize.width, targetSize.height)
        let factor = longestSide > 900 ? 900 / longestSide : 1
        return CGSize(
            width: max(1, targetSize.width * factor),
            height: max(1, targetSize.height * factor)
        )
    }

    private var fullPrefetchTargetSize: CGSize {
        CGSize(
            width: max(1, targetSize.width),
            height: max(1, targetSize.height)
        )
    }

    private func prefetchKey(for asset: PHAsset) -> String {
        "\(asset.localIdentifier)-\(Int(fullPrefetchTargetSize.width.rounded()))-\(Int(fullPrefetchTargetSize.height.rounded()))-\(contentMode.rawValue)"
    }

    private func loadWindow(around index: Int) {
        guard totalCount > 0 else { return }
        let offset = (min(max(0, index), totalCount - 1) / pageSize) * pageSize
        loadPage(at: offset)
        if offset + pageSize < totalCount {
            loadPage(at: offset + pageSize)
        }
    }

    private func loadPage(at offset: Int) {
        guard offset >= 0, offset < totalCount,
              !loadedOffsets.contains(offset),
              loadingOffsets.insert(offset).inserted
        else { return }

        let limit = min(pageSize, totalCount - offset)
        store.fetchUnsortedAssets(offset: offset, limit: limit) { result in
            loadingOffsets.remove(offset)
            switch result {
            case .failure(let error):
                loadError = error.localizedDescription
            case .success(let pageAssets):
                loadError = nil
                loadedOffsets.insert(offset)
                for (localIndex, asset) in pageAssets.enumerated() {
                    assetsByIndex[offset + localIndex] = asset
                }
                trimAssetCache(around: currentIndex)
                updatePrefetch()
            }
        }
    }

    private func trimAssetCache(around index: Int) {
        guard totalCount > 0 else {
            assetsByIndex.removeAll()
            loadedOffsets.removeAll()
            return
        }
        let clampedIndex = min(max(0, index), totalCount - 1)
        let lowerBound = max(0, clampedIndex - pageSize)
        let upperBound = min(totalCount, clampedIndex + pageSize * 2)
        assetsByIndex = assetsByIndex.filter {
            $0.key >= lowerBound && $0.key < upperBound
        }
        loadedOffsets = loadedOffsets.filter {
            $0 < upperBound && $0 + pageSize > lowerBound
        }
    }

    private func updatePrefetch() {
        let neighborAssets = [safeIndex - 1, safeIndex + 1]
            .compactMap { assetsByIndex[$0] }
        let next = Dictionary(uniqueKeysWithValues: neighborAssets.map {
            ($0.localIdentifier, $0)
        })
        let stale = cachedNeighbors.values.filter {
            next[$0.localIdentifier] == nil
        }
        if !stale.isEmpty {
            PhotoImageManager.shared.stopCaching(
                assets: Array(stale),
                targetSize: prefetchTargetSize,
                contentMode: contentMode,
                isNetworkAccessAllowed: true
            )
        }
        let desiredPrefetchKeys = Set(
            neighborAssets.map { prefetchKey(for: $0) }
        )
        let stalePrefetchKeys = prefetchHandles.keys.filter {
            !desiredPrefetchKeys.contains($0)
        }
        for key in stalePrefetchKeys {
            if let handle = prefetchHandles.removeValue(forKey: key) {
                PhotoImageManager.shared.cancel(handle)
            }
        }

        for neighbor in neighborAssets {
            let key = prefetchKey(for: neighbor)
            if prefetchHandles[key] == nil {
                prefetchHandles[key] = PhotoImageManager.shared.prefetchImage(
                    for: neighbor,
                    targetSize: fullPrefetchTargetSize,
                    contentMode: contentMode,
                    priority: .slideshow
                )
            }
        }
        cachedNeighbors = next
    }

    private func stopPrefetch() {
        for handle in prefetchHandles.values {
            PhotoImageManager.shared.cancel(handle)
        }
        prefetchHandles.removeAll()
        guard !cachedNeighbors.isEmpty else { return }
        PhotoImageManager.shared.stopCaching(
            assets: Array(cachedNeighbors.values),
            targetSize: prefetchTargetSize,
            contentMode: contentMode,
            isNetworkAccessAllowed: true
        )
        cachedNeighbors.removeAll()
    }
}

struct SlideshowView: View {
    let title: String
    let assets: PHFetchResult<PHAsset>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var currentIndex = 0
    @State private var controlsVisible = true
    @State private var isPaused = false
    @State private var interval: TimeInterval = 5
    @State private var isShuffled = false
    @State private var loops = true
    @State private var mediaReady = false
    @State private var previousIdleTimerDisabled = false
    @State private var isFullScreen = false
    @AppStorage(SlideshowTransitionStyle.storageKey)
    private var transitionStyleRawValue = SlideshowTransitionStyle.fade.rawValue

    private var transitionStyle: SlideshowTransitionStyle {
        SlideshowTransitionStyle(rawValue: transitionStyleRawValue) ?? .fade
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            GeometryReader { proxy in
                SlideshowAssetPager(
                    assets: assets,
                    currentIndex: $currentIndex,
                    targetSize: slideshowTargetSize(for: proxy.size),
                    contentMode: slideshowContentMode,
                    onNext: showNext,
                    onPrevious: showPrevious,
                    onMediaReady: { ready in
                        mediaReady = ready
                    },
                    transitionStyle: transitionStyle
                )
            }
            .ignoresSafeArea(.container, edges: .all)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    controlsVisible.toggle()
                }
            }

            if controlsVisible {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)

                        Button {
                            isPaused.toggle()
                        } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Button(action: toggleFullScreen) {
                            Image(systemName: isFullScreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel(isFullScreen ? "退出全屏" : "全屏显示")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 22) {
                            Button {
                                showPrevious()
                            } label: {
                                Image(systemName: "backward.fill")
                            }

                            Button {
                                isShuffled.toggle()
                            } label: {
                                Image(systemName: isShuffled ? "shuffle.circle.fill" : "shuffle")
                            }
                            .accessibilityLabel(isShuffled ? "关闭随机播放" : "随机播放")

                            Menu {
                                ForEach([3.0, 5.0, 8.0, 12.0], id: \.self) { value in
                                    Button("每 \(Int(value)) 秒") {
                                        interval = value
                                    }
                                }
                            } label: {
                                Label("\(Int(interval)) 秒", systemImage: "speedometer")
                            }

                            Button {
                                loops.toggle()
                            } label: {
                                Image(systemName: loops ? "repeat.circle.fill" : "repeat.circle")
                            }
                            .accessibilityLabel(loops ? "循环播放" : "播放到末尾停止")

                            Button {
                                showNext()
                            } label: {
                                Image(systemName: "forward.fill")
                            }
                        }
                        .font(.title3)

                        HStack {
                            Text(isPaused ? "已暂停" : "每 \(Int(interval)) 秒切换")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.76))
                            Spacer()
                            Text("\(currentIndex + 1) / \(assets.count)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .presentationBackground(.black)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.automatic)
        .onAppear {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
            } else {
                UIApplication.shared.isIdleTimerDisabled = false
                PhotoImageManager.shared.cancelRequests(exactly: .slideshow)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            mediaReady = false
        }
        .task(id: slideshowTaskID) {
            guard scenePhase == .active,
                  !isPaused,
                  assets.count > 1
            else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      scenePhase == .active,
                      !isPaused
                else { return }
                // iCloud delivery must never stop the sequence. The new
                // page shows a progress state if needed and the next tick
                // still advances in the requested asset order.
                showNext()
            }
        }
    }

    private var slideshowTaskID: String {
        "\(scenePhase)-\(isPaused)-\(interval)-\(currentIndex)-\(isShuffled)-\(loops)"
    }

    private var slideshowContentMode: PHImageContentMode {
        isFullScreen ? .aspectFill : .aspectFit
    }

    private func toggleFullScreen() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullScreen.toggle()
            controlsVisible = !isFullScreen
        }
    }

    private func showPrevious() {
        guard assets.count > 1 else { return }
        currentIndex = currentIndex == 0 ? assets.count - 1 : currentIndex - 1
    }

    private func showNext() {
        guard assets.count > 1 else { return }
        if isShuffled {
            var nextIndex = currentIndex
            while nextIndex == currentIndex {
                nextIndex = Int.random(in: 0..<assets.count)
            }
            currentIndex = nextIndex
        } else if currentIndex == assets.count - 1 {
            if loops {
                currentIndex = 0
            } else {
                isPaused = true
            }
        } else {
            currentIndex += 1
        }
    }

    private func slideshowTargetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }
}

/// Slideshow backed by the SQLite unsorted index. It requests only the small
/// window around the current offset and never materializes the complete
/// unassigned result.
struct IndexedSlideshowView: View {
    let title: String
    let totalCount: Int
    @ObservedObject var store: PhotoLibraryStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var currentIndex = 0
    @State private var assetsByIndex: [Int: PHAsset] = [:]
    @State private var mediaReady = false
    @State private var controlsVisible = true
    @State private var isPaused = false
    @State private var interval: TimeInterval = 5
    @State private var isShuffled = false
    @State private var loops = true
    @State private var previousIdleTimerDisabled = false
    @State private var isFullScreen = false
    @AppStorage(SlideshowTransitionStyle.storageKey)
    private var transitionStyleRawValue = SlideshowTransitionStyle.fade.rawValue

    private var transitionStyle: SlideshowTransitionStyle {
        SlideshowTransitionStyle(rawValue: transitionStyleRawValue) ?? .fade
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                IndexedSlideshowAssetPager(
                    totalCount: totalCount,
                    store: store,
                    currentIndex: $currentIndex,
                    assetsByIndex: $assetsByIndex,
                    targetSize: slideshowTargetSize(for: proxy.size),
                    contentMode: slideshowContentMode,
                    onNext: showNext,
                    onPrevious: showPrevious,
                    onMediaReady: { ready in mediaReady = ready },
                    transitionStyle: transitionStyle
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        controlsVisible.toggle()
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .all)

            if controlsVisible {
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)

                        Button { isPaused.toggle() } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Button(action: toggleFullScreen) {
                            Image(systemName: isFullScreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel(isFullScreen ? "退出全屏" : "全屏显示")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 22) {
                            Button { showPrevious() } label: {
                                Image(systemName: "backward.fill")
                            }

                            Button { isShuffled.toggle() } label: {
                                Image(systemName: isShuffled ? "shuffle.circle.fill" : "shuffle")
                            }

                            Menu {
                                ForEach([3.0, 5.0, 8.0, 12.0], id: \.self) { value in
                                    Button("每 \(Int(value)) 秒") { interval = value }
                                }
                            } label: {
                                Label("\(Int(interval)) 秒", systemImage: "speedometer")
                            }

                            Button { loops.toggle() } label: {
                                Image(systemName: loops ? "repeat.circle.fill" : "repeat.circle")
                            }

                            Button { showNext() } label: {
                                Image(systemName: "forward.fill")
                            }
                        }
                        .font(.title3)

                        HStack {
                            Text(isPaused ? "已暂停" : "每 \(Int(interval)) 秒切换")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.76))
                            Spacer()
                            Text("\(min(currentIndex + 1, max(1, totalCount))) / \(totalCount)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .presentationBackground(.black)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.automatic)
        .onAppear {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            if phase != .active {
                PhotoImageManager.shared.cancelRequests(exactly: .slideshow)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            mediaReady = false
        }
        .task(id: timerTaskID) {
            guard scenePhase == .active,
                  !isPaused,
                  totalCount > 1
            else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      scenePhase == .active,
                      !isPaused
                else { return }
                showNext()
            }
        }
    }

    private var timerTaskID: String {
        "\(scenePhase)-\(currentIndex)-\(isPaused)-\(interval)-\(isShuffled)-\(loops)"
    }

    private var slideshowContentMode: PHImageContentMode {
        isFullScreen ? .aspectFill : .aspectFit
    }

    private func toggleFullScreen() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullScreen.toggle()
            controlsVisible = !isFullScreen
        }
    }

    private func showPrevious() {
        guard totalCount > 1 else { return }
        currentIndex = currentIndex == 0 ? totalCount - 1 : currentIndex - 1
    }

    private func showNext() {
        guard totalCount > 1 else { return }
        if isShuffled {
            var nextIndex = currentIndex
            while nextIndex == currentIndex {
                nextIndex = Int.random(in: 0..<totalCount)
            }
            currentIndex = nextIndex
        } else if currentIndex == totalCount - 1 {
            if loops {
                currentIndex = 0
            } else {
                isPaused = true
            }
        } else {
            currentIndex += 1
        }
    }

    private func slideshowTargetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }
}

struct PhotoInfoView: View {
    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("尺寸") {
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                }

                if let creationDate = asset.creationDate {
                    LabeledContent("拍摄时间") {
                        Text(creationDate.formatted(date: .long, time: .shortened))
                    }
                }

                if let location = asset.location {
                    LabeledContent("位置") {
                        Text(
                            String(
                                format: "%.4f, %.4f",
                                location.coordinate.latitude,
                                location.coordinate.longitude
                            )
                        )
                    }
                }

                LabeledContent("标识符") {
                    Text(asset.localIdentifier)
                        .font(.caption)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            .navigationTitle("照片信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
