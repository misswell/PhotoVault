import Photos
import SwiftUI
import UIKit

struct AssetImageView: View {
    let asset: PHAsset
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let requestPriority: PhotoRequestPriority
    let cacheResult: Bool
    let cacheScope: PhotoImageCacheScope
    let usesPhotoKitCaching: Bool
    let onLoadStateChange: ((Bool) -> Void)?
    /// Overrides the default canvas behind the image. The zoom-transitioned
    /// viewer passes `.clear` so the system dimming shows through the
    /// letterbox and the zoom-out morphs the photo — not an opaque
    /// full-screen rectangle — back into its grid cell.
    let canvasBackground: Color?

    @State private var image: UIImage?
    @State private var requestHandle: PhotoRequestHandle?
    @State private var loadProgress: Double?
    @State private var loadError: String?
    @State private var loadAttempt = 0
    @State private var activeRequestKey: String?
    @State private var displayedAssetIdentifier: String?
    /// Set once the asset has been on screen for longer than
    /// `AppLoadingPolicy.indicatorDelay` without a usable frame. Until then a
    /// blank page stays black instead of flashing a spinner.
    @State private var showsDelayedLoading = false

    private var requestKey: String {
        "\(asset.localIdentifier)-\(Int(targetSize.width))-\(Int(targetSize.height))-\(contentMode.rawValue)"
    }

    init(
        asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        requestPriority: PhotoRequestPriority = .visibleGrid,
        cacheResult: Bool? = nil,
        cacheScope: PhotoImageCacheScope = .standard,
        usesPhotoKitCaching: Bool = true,
        initialImage: UIImage? = nil,
        onLoadStateChange: ((Bool) -> Void)? = nil,
        canvasBackground: Color? = nil
    ) {
        self.asset = asset
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.requestPriority = requestPriority
        self.cacheResult = cacheResult ?? (requestPriority <= .slideshow)
        self.cacheScope = cacheScope
        self.usesPhotoKitCaching = usesPhotoKitCaching
        self.onLoadStateChange = onLoadStateChange
        self.canvasBackground = canvasBackground
        // Seed the first frame from an already-decoded thumbnail (typically
        // the grid cell the viewer was opened from). Binding the displayed
        // identifier at the same time keeps the "same asset" branch in
        // `loadImage()` from clearing the frame we just seeded.
        _image = State(initialValue: initialImage)
        _displayedAssetIdentifier = State(
            initialValue: initialImage == nil ? nil : asset.localIdentifier
        )
    }

    var body: some View {
        ZStack {
            // A viewer uses aspectFit over a black canvas, while grid cells
            // retain the grouped-background placeholder used by Photos.
            canvasBackground
                ?? (contentMode == .aspectFit
                    ? Color.black
                    : Color(uiColor: .secondarySystemGroupedBackground))

            if let image {
                if contentMode == .aspectFit {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .transition(shouldAnimateAppearance ? .opacity : .identity)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(shouldAnimateAppearance ? .opacity : .identity)
                }
            } else if let loadError {
                VStack(spacing: 5) {
                    Image(systemName: "icloud.slash")
                        .font(.caption)
                    Text("无法读取")
                        .font(.caption2)
                    Button("重试") {
                        loadAttempt &+= 1
                    }
                    .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel(loadError)
            } else if showsDelayedLoading {
                // Only reached when there is no image at all: a seeded grid
                // thumbnail or a previously displayed frame suppresses this.
                if let loadProgress, loadProgress > 0, loadProgress < 1 {
                    ProgressView(value: loadProgress)
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
                }
            }

            if asset.mediaSubtypes.contains(.photoLive) {
                Image(systemName: "livephoto")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if asset.mediaType == .video {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                    Text(videoDuration)
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .clipped()
        // `requestPriority` is deliberately NOT part of the task identity.
        // The viewer promotes a page from neighbour to current (and back)
        // with every swipe; re-keying the task on that made each swipe cancel
        // an in-flight full-size PhotoKit request and issue an identical one.
        .task(id: "\(requestKey)-\(loadAttempt)") {
            loadImage()
        }
        .onDisappear {
            cancelImageRequest()
        }
    }

    private func loadImage() {
        cancelImageRequest()
        let requestKey = self.requestKey
        let isSameAsset = displayedAssetIdentifier == asset.localIdentifier
        displayedAssetIdentifier = asset.localIdentifier
        activeRequestKey = requestKey
        // Keep the last frame while the same asset is being re-requested
        // (for example when its size changes after rotation). A new asset
        // still clears the frame so one photo can never bleed into another.
        if !isSameAsset {
            image = nil
        }
        loadProgress = nil
        loadError = nil
        // Any frame already on screen (a seeded grid thumbnail, a cached page,
        // a kept frame for the same asset) is enough to keep the spinner away
        // forever. Only a genuinely blank page arms the delayed indicator.
        showsDelayedLoading = false
        if image == nil {
            armDelayedLoadingIndicator(requestKey: requestKey)
        }
        // "Ready" means the viewer has a frame a user can look at, not that
        // the final PhotoKit result has landed. A seeded preview (or a kept
        // frame for the same asset) is already usable, so do not report the
        // page as blank and flash a spinner over an image that is on screen.
        onLoadStateChange?(image != nil)
        if contentMode == .aspectFit, image != nil {
            ViewerPerformanceTrace.viewerFirstFrame()
        }

        if usesPhotoKitCaching {
            PhotoImageManager.shared.startCaching(
                asset: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                isNetworkAccessAllowed: requestPriority <= .slideshow
            )
        }
        requestHandle = PhotoImageManager.shared.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            priority: requestPriority,
            cacheResult: cacheResult,
            cacheScope: cacheScope,
            progressHandler: { progress, error, _, _ in
                Task { @MainActor in
                    guard self.activeRequestKey == requestKey else { return }
                    self.loadProgress = progress
                    if let error {
                        self.loadError = self.errorMessage(for: error, isCloudOnly: false)
                    }
                }
            }
        ) { image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let hasError = info?[PHImageErrorKey] as? Error
            let isCloudOnly = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
            Task { @MainActor in
                guard !cancelled, self.activeRequestKey == requestKey else { return }
                if let hasError {
                    self.loadError = self.errorMessage(
                        for: hasError,
                        isCloudOnly: isCloudOnly
                    )
                    // Keep reporting the frame that is still on screen: a
                    // failed high-quality fetch must not blank a usable preview.
                    self.onLoadStateChange?(self.image != nil)
                    return
                }
                guard let image else {
                    self.loadError = self.errorMessage(
                        for: nil,
                        isCloudOnly: isCloudOnly
                    )
                    self.onLoadStateChange?(self.image != nil)
                    return
                }
                self.loadError = nil
                self.loadProgress = 1
                self.showsDelayedLoading = false
                self.traceViewerDelivery(
                    isDegraded: (info?[PHImageResultIsDegradedKey] as? Bool) ?? false,
                    didSetImage: true
                )
                if self.shouldAnimateAppearance {
                    withAnimation(.easeOut(duration: 0.16)) {
                        self.image = image
                    }
                } else {
                    self.image = image
                }
                // A degraded iCloud thumbnail is still a valid displayable
                // frame. Signal readiness only after assigning the image so
                // the slideshow never advances into a blank page.
                self.onLoadStateChange?(true)
            }
        }
    }

    /// `@autoclosure` so call sites that would build a string every frame stay
    /// free in release builds.
    private func traceViewerDelivery(isDegraded: Bool, didSetImage: Bool) {
        guard contentMode == .aspectFit else { return }
        if didSetImage, isDegraded {
            ViewerPerformanceTrace.viewerFirstFrame()
        } else if didSetImage {
            ViewerPerformanceTrace.viewerHighQualityReady()
        } else if image != nil {
            // The request finished without replacing the frame — the seeded
            // grid thumbnail (or a kept frame) is what the user is seeing.
            ViewerPerformanceTrace.viewerFirstFrame()
        }
    }

    /// Arm the delayed spinner for a blank page. A local thumbnail resolves
    /// well before the deadline, so this only fires for genuinely slow sources
    /// (iCloud download, stalled network) where feedback is actually useful.
    private func armDelayedLoadingIndicator(requestKey: String) {
        Task { @MainActor in
            try? await Task.sleep(for: AppLoadingPolicy.indicatorDelay)
            guard activeRequestKey == requestKey,
                  image == nil,
                  loadError == nil
            else { return }
            showsDelayedLoading = true
        }
    }

    private func errorMessage(for error: Error?, isCloudOnly: Bool) -> String {
        if isCloudOnly {
            return "这张照片需要从 iCloud 下载"
        }
        if let urlError = error as? URLError,
           urlError.code == .notConnectedToInternet {
            return "当前没有网络连接，无法从 iCloud 读取"
        }
        return error?.localizedDescription ?? "照片暂时无法读取"
    }

    private var shouldAnimateAppearance: Bool {
        // The full-screen pager owns the configured page transition. A
        // separate opacity animation here makes a cached neighbor slide in
        // while an iCloud neighbor appears to fade, so consecutive swipes
        // look inconsistent. Grid thumbnails are aspect-fill and already
        // return false here.
        false
    }

    private func cancelImageRequest() {
        PhotoImageManager.shared.cancel(requestHandle)
        if usesPhotoKitCaching {
            PhotoImageManager.shared.stopCaching(
                asset: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                isNetworkAccessAllowed: requestPriority <= .slideshow
            )
        }
        requestHandle = nil
        activeRequestKey = nil
    }

    private var videoDuration: String {
        let totalSeconds = max(0, Int(asset.duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

struct ZoomableAssetView: View {
    let asset: PHAsset
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let requestPriority: PhotoRequestPriority
    let initialImage: UIImage?
    let canvasBackground: Color?
    let onLoadStateChange: ((Bool) -> Void)?
    let onZoomingChanged: ((Bool) -> Void)?

    init(
        asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit,
        requestPriority: PhotoRequestPriority = .viewer,
        initialImage: UIImage? = nil,
        canvasBackground: Color? = nil,
        onLoadStateChange: ((Bool) -> Void)? = nil,
        onZoomingChanged: ((Bool) -> Void)? = nil
    ) {
        self.asset = asset
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.requestPriority = requestPriority
        self.initialImage = initialImage
        self.canvasBackground = canvasBackground
        self.onLoadStateChange = onLoadStateChange
        self.onZoomingChanged = onZoomingChanged
    }

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isPinching = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let image = AssetImageView(
                asset: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                requestPriority: requestPriority,
                initialImage: initialImage,
                onLoadStateChange: onLoadStateChange,
                canvasBackground: canvasBackground
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(scale)
            .offset(offset)

            // Keep the gesture tree stable while the scale crosses 1.01.
            // Rebuilding it in the middle of a pinch interrupts the first
            // gesture update and produces the visible zoom-pause-zoom hitch.
            // The drag handler is inert at scale 1, so one-finger paging can
            // still be handled by the surrounding pager.
            image
                .highPriorityGesture(magnificationGesture)
                // At the base scale the page controller must receive the
                // one-finger drag. Keep the gesture modifier stable to avoid
                // interrupting a pinch, but make its recognizer inactive
                // until the image is actually zoomed.
                .simultaneousGesture(
                    dragGesture,
                    including: scale > 1.01 ? .all : .subviews
                )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    if scale > 1.05 {
                        scale = 1
                        lastScale = 1
                        offset = .zero
                        lastOffset = .zero
                        onZoomingChanged?(false)
                    } else {
                        scale = 2
                        lastScale = 2
                        onZoomingChanged?(true)
                    }
                }
            }
        }
        .clipped()
        .onDisappear {
            isPinching = false
            isDragging = false
            PagerDiagnostics.log(
                "image viewer disappear asset=\(asset.localIdentifier)"
            )
            onZoomingChanged?(false)
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if !isPinching {
                    isPinching = true
                    PagerDiagnostics.log(
                        "pinch began asset=\(asset.localIdentifier) scale=\(scale)"
                    )
                    onZoomingChanged?(true)
                }
                scale = min(max(lastScale * value, 1), 4)
            }
            .onEnded { _ in
                isPinching = false
                lastScale = scale
                if scale == 1 {
                    offset = .zero
                    lastOffset = .zero
                }
                PagerDiagnostics.log(
                    "pinch ended asset=\(asset.localIdentifier) scale=\(scale)"
                )
                onZoomingChanged?(scale > 1.01)
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: scale > 1.01 ? 1 : 10_000)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    PagerDiagnostics.log(
                        "image drag began asset=\(asset.localIdentifier) scale=\(scale) pinching=\(isPinching)"
                    )
                }
                guard scale > 1.01, !isPinching else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                let didDrag = isDragging
                isDragging = false
                if didDrag {
                    PagerDiagnostics.log(
                        "image drag ended asset=\(asset.localIdentifier) scale=\(scale)"
                    )
                }
                guard scale > 1.01 else { return }
                lastOffset = offset
            }
    }
}
