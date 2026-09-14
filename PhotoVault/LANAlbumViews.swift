import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Home entry

/// Sidebar entry for folders picked through the Files app (SMB/NAS shares
/// included) treated as albums.
struct LANAlbumHomeScreen: View {
    @State private var folders: [LANFolderAlbum] = LANFolderLibrary.load()
    @State private var isShowingPicker = false
    @State private var activeFolder: LANFolderAlbum?
    @State private var alert: PhotoVaultAlert?

    var body: some View {
        List {
            Section {
                if folders.isEmpty {
                    Text("还没有添加局域网文件夹。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        Button {
                            activeFolder = folder
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.name)
                                Text("添加于 \(folder.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets where folders.indices.contains(index) {
                            LANFolderThumbnailDiskCache.purge(folderID: folders[index].id)
                        }
                        folders.remove(atOffsets: offsets)
                        LANFolderLibrary.save(folders)
                    }
                }
            } header: {
                Text("已添加")
            } footer: {
                Text("来源不限：局域网 SMB/NAS 共享、本机文件夹、外接 U 盘都可以。先在文件 App 里连接服务器或挂载设备，再选择文件夹即可当作相册。")
            }

            Section {
                Button {
                    isShowingPicker = true
                } label: {
                    Label("添加文件夹", systemImage: "folder.badge.plus")
                }
            }
        }
        .navigationTitle("文件夹相册")
        .navigationDestination(item: $activeFolder) { folder in
            LANFolderGridScreen(folder: folder)
        }
        .onAppear {
            // Re-auth writes fresh bookmarks into storage behind this
            // screen; pick them up when the list reappears.
            folders = LANFolderLibrary.load()
        }
        .task {
            // Wake the provider daemons so the first folder tap does not
            // race the lazy mount on a cold start.
            await LANFolderLibrary.warmScopes()
        }
        .sheet(isPresented: $isShowingPicker) {
            LANFolderPicker { pickedURL in
                Task { @MainActor in
                    guard let result = await LANFolderLibrary.add(from: pickedURL) else {
                        alert = PhotoVaultAlert(
                            title: "无法添加文件夹",
                            message: "创建访问书签失败，请重试或换一个文件夹。"
                        )
                        return
                    }
                    folders = result.folders
                    // Re-picking a registered folder refreshes its access
                    // grant — open it right away, silently.
                    if case .duplicate(let healed) = result.outcome {
                        activeFolder = healed
                    }
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
    }
}

// MARK: - Files folder picker

/// Opens the Files app folder picker; the user can navigate into an SMB/NAS
/// share they connected there and hand the folder back as a security-scoped
/// URL.
struct LANFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    /// Makes the picker open directly at this location — used by
    /// re-authorization so the user never hunts through provider
    /// hierarchies to find the folder again.
    var initialDirectory: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        if let initialDirectory {
            picker.directoryURL = initialDirectory
        }
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            if let url = urls.first {
                onPick(url)
            }
        }
    }
}

// MARK: - Photo grid

struct LANFolderGridScreen: View {
    let folder: LANFolderAlbum

    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var folderURL: URL?
    @State private var isEnumerating = true
    @State private var enumerateError: String?
    @State private var enumerateAttempt = 0
    @State private var isShowingReauthPicker = false
    @State private var hasAutoPresentedPicker = false
    @State private var reauthDirectory: URL?
    @State private var viewerIndex: Int?
    @State private var isShowingSlideshow = false

    private let columns = [
        GridItem(.adaptive(minimum: 88, maximum: 150), spacing: 2)
    ]

    var body: some View {
        Group {
            if isEnumerating {
                ProgressView("正在读取文件夹…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let enumerateError, files.isEmpty {
                ContentUnavailableView {
                    Label("无法访问文件夹", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(enumerateError)
                } actions: {
                    Button("重新授权") {
                        isShowingReauthPicker = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("返回") {
                        dismiss()
                    }
                }
            } else if files.isEmpty {
                ContentUnavailableView {
                    Label("文件夹里没有图片", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("这个文件夹（含子文件夹）里没有找到可显示的图片。如果之前有图片，可能是文件提供方正忙或暂时断开。")
                } actions: {
                    Button("重试") {
                        enumerateAttempt += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        // Index-keyed so a swipe that rewrites `viewerIndex`
                        // does not rebuild an n-element `(offset, element)`
                        // array for a folder that can hold thousands of files.
                        ForEach(files.indices, id: \.self) { index in
                            Button {
                                viewerIndex = index
                            } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        LANFolderImageView(
                                            url: files[index],
                                            folderID: folder.id,
                                            rootURL: folderURL
                                                ?? URL(fileURLWithPath: "/"),
                                            maxPixelSize: 512
                                        )
                                    }
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !files.isEmpty {
                    Button {
                        isShowingSlideshow = true
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                }
            }
        }
        .task(id: "\(folder.id)#\(enumerateAttempt)") {
            await enumerate()
        }
        .sheet(isPresented: $isShowingReauthPicker) {
            LANFolderPicker(
                onPick: { pickedURL in
                    Task { @MainActor in
                        // Re-picking the same folder refreshes its stored
                        // bookmark with a fresh access grant; retry afterwards.
                        LANFolderDiagnostics.log("re-auth picked \(pickedURL.lastPathComponent)")
                        if let result = await LANFolderLibrary.add(from: pickedURL) {
                            for folder in result.folders where folder.id == self.folder.id {
                                LANFolderDiagnostics.log(
                                    "healed \(folder.name): bookmarkFP=\("len\(folder.bookmark.count):\(folder.bookmark.base64EncodedString().suffix(6))")"
                                )
                            }
                        }
                        enumerateError = nil
                        isEnumerating = files.isEmpty
                        enumerateAttempt += 1
                    }
                },
                initialDirectory: reauthDirectory
            )
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { viewerIndex != nil },
                set: { if !$0 { viewerIndex = nil } }
            )
        ) {
            // Never gate the content on folderURL: re-entering a folder
            // replays LANFolderSessionCache without resolving the bookmark,
            // so folderURL stays nil here and an empty full-screen cover
            // would trap the user with no close button. The disk thumbnail
            // cache already falls back to absolute-path keys when rootURL
            // doesn't prefix-match, so the fallback root is safe.
            if let viewerBinding {
                LANFolderViewerScreen(
                    files: files,
                    folderID: folder.id,
                    rootURL: folderURL ?? URL(fileURLWithPath: "/"),
                    index: viewerBinding
                )
            }
        }
        .fullScreenCover(isPresented: $isShowingSlideshow) {
            // Same rule as the viewer cover: never gate on folderURL (nil on
            // the session-cache replay path), otherwise the cover presents
            // empty with no exit controls.
            LANFolderSlideshowScreen(
                title: folder.name,
                files: files,
                folderID: folder.id,
                rootURL: folderURL ?? URL(fileURLWithPath: "/")
            )
        }
    }

    private var viewerBinding: Binding<Int>? {
        guard viewerIndex != nil else { return nil }
        return Binding(
            get: { viewerIndex ?? 0 },
            set: { viewerIndex = $0 }
        )
    }

    private struct EnumerationResult: Sendable {
        let url: URL?
        let files: [URL]?
        let scopeStarted: Bool
    }

    /// Main-actor bound on purpose: a nonisolated `async` function would hop
    /// to the global executor (SE-0338) and then write `@State` from there,
    /// racing the main-thread reads in `body`. All blocking work already runs
    /// on GCD inside `LANFolderTimeout.run`.
    @MainActor
    private func enumerate() async {
        // Re-entry replays the session cache: hitting the share again was
        // stacking a second full traversal on top of the first one. Restore
        // the resolved root as well, or every thumbnail cache key in the
        // folder collapses and the whole grid re-decodes over SMB.
        if let cached = LANFolderSessionCache.entry(for: folder.id) {
            folderURL = cached.rootURL
            files = cached.files
            isEnumerating = false
            return
        }

        isEnumerating = files.isEmpty
        enumerateError = nil
        // Re-authorization rotates the STORED bookmark; always enumerate with
        // the freshest stored entry instead of the snapshot passed at
        // navigation time, or the healed bookmark would never be used.
        let album = LANFolderLibrary.load().first(where: { $0.id == folder.id }) ?? folder
        LANFolderDiagnostics.log(
            "enumerating \(album.name): bookmarkFP=\("len\(album.bookmark.count):\(album.bookmark.base64EncodedString().suffix(6))")"
        )
        let startedAt = Date()
        // Resolve + activate + enumerate can each block against a dead or
        // slow share; cap the whole pass so the screen never spins forever.
        let outcome: EnumerationResult? = await LANFolderTimeout.run(seconds: 20) {
            guard let url = LANFolderLibrary.resolve(album) else {
                LANFolderDiagnostics.log("resolve failed for \(album.name)")
                return EnumerationResult(url: nil, files: nil, scopeStarted: false)
            }
            LANFolderDiagnostics.log(
                "resolved \(album.name): path=\(url.path), exists=\(FileManager.default.fileExists(atPath: url.path))"
            )
            // Hold the security scope for the whole session; re-acquiring it
            // on every visit stalled the album behind provider round trips.
            // No blocking retries: the folder list already warmed the
            // providers, and a failed grant goes straight to re-authorization.
            let scopeStarted = LANFolderScopeManager.shared.activate(id: album.id, url: url)
            // Heal bookmarks the provider marked stale after a remount — but
            // only while the scope is actually held: a bookmark minted
            // without scope credentials carries no access rights and would
            // permanently downgrade the stored one (folder dead after every
            // restart, retry never helps).
            if scopeStarted {
                LANFolderLibrary.refreshBookmarkIfStale(album, resolvedURL: url)
            }
            var enumerated = LANFolderImageLoader.enumerateImageFiles(under: url)
            // A failed grant is not necessarily the end: a coordinated read
            // through NSFileCoordinator can negotiate access with the file
            // provider even when startAccessing was refused. Probe it and
            // keep whatever it yields.
            var coordinatedWorked = false
            if enumerated.isEmpty && !scopeStarted {
                if let coordinatedFiles = LANFolderLibrary.coordinatedEnumerate(id: album.id, url: url),
                   !coordinatedFiles.isEmpty {
                    enumerated = coordinatedFiles
                    coordinatedWorked = true
                }
            }
            LANFolderDiagnostics.log(
                "enumerated \(album.name): \(enumerated.count) files, scopeStarted=\(scopeStarted), coordinated=\(coordinatedWorked) in \(Int(-startedAt.timeIntervalSinceNow * 1000)) ms"
            )
            return EnumerationResult(
                url: url,
                files: enumerated,
                scopeStarted: scopeStarted || coordinatedWorked
            )
        }
        if let outcome, let url = outcome.url, let enumerated = outcome.files {
            if enumerated.isEmpty && !outcome.scopeStarted {
                // The stored bookmark no longer grants access (app reinstall,
                // provider re-auth): resolving succeeds by path, but the
                // provider serves nothing. Reporting "no images" here would
                // silently bury the entry — pop the folder picker right away
                // so the user re-picks the same folder and taps 打开, which
                // refreshes the stored bookmark and re-enumerates.
                LANFolderDiagnostics.log(
                    "access lost for \(album.name): scope denied, 0 files, bookmarkFP=\("len\(album.bookmark.count):\(album.bookmark.base64EncodedString().suffix(6))"), resolvedPath=\(url.path), exists=\(FileManager.default.fileExists(atPath: url.path))"
                )
                enumerateError = "无法获得文件夹的访问权限：该文件夹位于其他 App 的目录内，iOS 出于沙盒安全不允许跨启动记住此类授权。建议在文件 App 中将它移动到“我的 iPhone”顶层后，在这里删除并重新添加；或每次进入时重新选择一次。"
                // Open the picker at the folder's parent so the folder is
                // visible and selectable in one tap.
                reauthDirectory = url.deletingLastPathComponent()
                // Pop the picker once automatically per visit; afterwards the
                // error view's 重新授权 button opens it on demand.
                if !hasAutoPresentedPicker {
                    hasAutoPresentedPicker = true
                    isShowingReauthPicker = true
                }
            } else {
                folderURL = url
                files = enumerated
                // An empty pass is usually a provider hiccup, not a genuinely
                // empty folder; caching it would pin "no images" for the whole
                // session and hide recoverable content. Leave it uncached so
                // the next visit (or 重试) enumerates again.
                if !enumerated.isEmpty {
                    LANFolderSessionCache.store(
                        rootURL: url,
                        files: enumerated,
                        for: album.id
                    )
                }
            }
        } else {
            LANFolderDiagnostics.log("enumerate timed out for \(album.name)")
            enumerateError = "文件夹访问超时或已不可访问，请检查共享连接后重试，或删除后重新添加。"
        }
        isEnumerating = false
    }
}

// MARK: - Image views

private struct LANFolderImageView: View {
    let url: URL
    let folderID: UUID
    let rootURL: URL
    let maxPixelSize: CGFloat
    /// Grid thumbnails crop to their square cell (fill); the viewer and
    /// slideshow show the whole photo like the album viewer (fit).
    var fillsContainer: Bool = true

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                // scaledToFill reports the image's overflow size, which would
                // inflate the parent ZStack and push sibling controls
                // off-screen (the viewer showed a full-bleed photo with the
                // close button laid out outside the display). Contain the
                // scaling inside a proposal-sized base so this view always
                // reports the size it was offered.
                Color.clear
                    .overlay {
                        if fillsContainer {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        }
                    }
                    .clipped()
            } else {
                Color.clear
                    .overlay {
                        if fillsContainer {
                            // Grid cells: a static tile, never a spinner. A
                            // folder with hundreds of thumbnails would other-
                            // wise animate hundreds of indicators while
                            // scrolling over SMB.
                            PhotoGridPlaceholder(cornerRadius: 0)
                        } else {
                            // Full-screen viewer: one indicator for the single
                            // visible photo is real information, not noise.
                            ProgressView()
                                .tint(.secondary)
                        }
                    }
            }
        }
        .task(id: "\(url.path)#\(Int(maxPixelSize))") {
            image = await LANFolderImageLoaderQueue.load(
                at: url,
                folderID: folderID,
                rootURL: rootURL,
                maxPixelSize: maxPixelSize
            )
        }
    }
}

// MARK: - Full-screen viewer

struct LANFolderViewerScreen: View {
    let files: [URL]
    let folderID: UUID
    let rootURL: URL
    @Binding var index: Int

    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGSize = .zero

    private var dismissProgress: CGFloat {
        min(max(dragOffset.height / 420, 0), 1)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(dismissProgress) * 0.7)
                .ignoresSafeArea()

            // Same interaction model as the album viewer: continuous
            // horizontal paging plus the pull-down dismissal — no tap zones.
            LANFolderPager(
                files: files,
                folderID: folderID,
                rootURL: rootURL,
                currentIndex: $index,
                onDismissDragChanged: { translation in
                    guard translation.height > 0,
                          translation.height > abs(translation.width) * 1.15
                    else { return }
                    dragOffset = CGSize(
                        width: translation.width * 0.18,
                        height: max(0, translation.height)
                    )
                },
                onDismissDragEnded: { translation, predicted, cancelled in
                    let shouldDismiss = !cancelled
                        && (translation.height > 150 || predicted.height > 280)
                    if shouldDismiss {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = .zero
                        }
                    }
                }
            )
            .offset(dragOffset)
            .scaleEffect(1 - dismissProgress * 0.08)

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel("关闭")

                    Spacer()

                    Text("\(index + 1) / \(files.count)")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                HStack {
                    Text(files.indices.contains(index) ? files[index].lastPathComponent : "")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        guard files.indices.contains(index) else { return }
                        ActivityPresenter.present(items: [files[index]])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.headline.weight(.semibold))
                            .frame(width: 46, height: 46)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel("分享")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

                LANFolderFilmstrip(
                    files: files,
                    folderID: folderID,
                    rootURL: rootURL,
                    index: $index
                )
            }
            .opacity(Double(1 - dismissProgress))
        }
        .onAppear {
            prefetchNeighbors(around: index)
        }
        .onChange(of: index) { _, newValue in
            prefetchNeighbors(around: newValue)
        }
    }

    /// Warm the disk/memory cache for the neighbors so the next page shows
    /// instantly — the same "prefetch before switching" rule as the album
    /// viewer, routed through the shared coalescing loader queue.
    private func prefetchNeighbors(around index: Int) {
        for offset in [-1, 1] {
            let candidate = index + offset
            guard files.indices.contains(candidate) else { continue }
            Task.detached(priority: .utility) { [files, folderID, rootURL] in
                _ = await LANFolderImageLoaderQueue.load(
                    at: files[candidate],
                    folderID: folderID,
                    rootURL: rootURL,
                    maxPixelSize: 2048
                )
            }
        }
    }
}

// MARK: - Filmstrip

/// Bottom thumbnail strip mirroring the album viewer's filmstrip: the
/// current photo highlighted and kept centered, any thumbnail tappable.
private struct LANFolderFilmstrip: View {
    let files: [URL]
    let folderID: UUID
    let rootURL: URL
    @Binding var index: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(files.indices, id: \.self) { i in
                        Button {
                            guard i != index else { return }
                            index = i
                        } label: {
                            LANFolderImageView(
                                url: files[i],
                                folderID: folderID,
                                rootURL: rootURL,
                                maxPixelSize: 512,
                                fillsContainer: true
                            )
                            .frame(width: 48, height: 48)
                            .clipped()
                            .overlay {
                                if i == index {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .strokeBorder(.white, lineWidth: 2)
                                }
                            }
                            .opacity(i == index ? 1 : 0.5)
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: index) { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(height: 52)
        .background(Color.black.opacity(0.55))
    }
}

// MARK: - URL pager

/// URL-driven sibling of the album viewer's NativePhotoPager: a
/// UIPageViewController that keeps the current page plus its neighbors
/// alive, writes swipes back into the index binding, supports programmatic
/// jumps, and arbitrates the vertical dismiss drag against its own
/// horizontal scroll gesture.
private struct LANFolderPager: UIViewControllerRepresentable {
    let files: [URL]
    let folderID: UUID
    let rootURL: URL
    @Binding var currentIndex: Int
    let onDismissDragChanged: (CGSize) -> Void
    let onDismissDragEnded: (CGSize, CGSize, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(currentIndex: $currentIndex)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.attach(controller: controller)
        context.coordinator.update(
            files: files,
            folderID: folderID,
            rootURL: rootURL,
            currentIndex: currentIndex,
            onDismissDragChanged: onDismissDragChanged,
            onDismissDragEnded: onDismissDragEnded
        )
        return controller
    }

    func updateUIViewController(
        _ controller: UIPageViewController,
        context: Context
    ) {
        context.coordinator.update(
            files: files,
            folderID: folderID,
            rootURL: rootURL,
            currentIndex: currentIndex,
            onDismissDragChanged: onDismissDragChanged,
            onDismissDragEnded: onDismissDragEnded
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: UIPageViewController,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource,
        UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        private weak var pageController: UIPageViewController?
        private var files: [URL] = []
        private var folderID = UUID()
        private var rootURL: URL?
        private var pageCount = 0
        private var displayedIndex: Int?
        private var pages: [Int: LANFolderPageController] = [:]
        private var currentIndexBinding: Binding<Int>
        private var pendingProgrammaticIndex: Int?
        private var isManualTransitionInProgress = false
        private var dismissPanGesture: UIPanGestureRecognizer?
        private var onDismissDragChanged: (CGSize) -> Void = { _ in }
        private var onDismissDragEnded: (CGSize, CGSize, Bool) -> Void = { _, _, _ in }

        init(currentIndex: Binding<Int>) {
            currentIndexBinding = currentIndex
        }

        func attach(controller: UIPageViewController) {
            pageController = controller
            let dismissPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleDismissPan(_:))
            )
            dismissPan.delegate = self
            dismissPan.cancelsTouchesInView = false
            dismissPan.maximumNumberOfTouches = 1
            controller.view.addGestureRecognizer(dismissPan)
            dismissPanGesture = dismissPan

            // Decide vertical dismissal before UIKit's horizontal scroll
            // view is allowed to begin; a horizontal pan makes this
            // recognizer fail and the page controller owns the gesture.
            if let pageScrollView = controller.view.subviews
                .compactMap({ $0 as? UIScrollView })
                .first {
                pageScrollView.panGestureRecognizer.require(toFail: dismissPan)
            }
        }

        func invalidate() {
            guard pageController != nil || !pages.isEmpty else { return }
            // Detach before releasing hosted pages so a late UIKit callback
            // cannot write into a screen that is already going away.
            pageController?.dataSource = nil
            pageController?.delegate = nil
            pageController?.view.isUserInteractionEnabled = false
            if let dismissPanGesture {
                dismissPanGesture.delegate = nil
                dismissPanGesture.view?.removeGestureRecognizer(dismissPanGesture)
                self.dismissPanGesture = nil
            }
            pages.removeAll()
            pendingProgrammaticIndex = nil
            displayedIndex = nil
            onDismissDragChanged = { _ in }
            onDismissDragEnded = { _, _, _ in }
            files = []
            pageController = nil
        }

        func update(
            files: [URL],
            folderID: UUID,
            rootURL: URL,
            currentIndex: Int,
            onDismissDragChanged: @escaping (CGSize) -> Void,
            onDismissDragEnded: @escaping (CGSize, CGSize, Bool) -> Void
        ) {
            self.files = files
            self.folderID = folderID
            self.rootURL = rootURL
            self.onDismissDragChanged = onDismissDragChanged
            self.onDismissDragEnded = onDismissDragEnded
            pageCount = max(0, files.count)

            guard pageCount > 0, let pageController else { return }
            let clampedIndex = min(max(0, currentIndex), pageCount - 1)

            guard let displayedIndex else {
                setInitialPage(to: clampedIndex)
                return
            }

            if displayedIndex != clampedIndex {
                // Do not restart the same transition while SwiftUI re-renders
                // around an in-flight jump.
                if pendingProgrammaticIndex == clampedIndex { return }
                guard pendingProgrammaticIndex == nil,
                      !isManualTransitionInProgress
                else { return }
                guard let visiblePage = pageController.viewControllers?
                    .first as? LANFolderPageController
                else { return }

                let direction: UIPageViewController.NavigationDirection =
                    clampedIndex > visiblePage.index ? .forward : .reverse
                guard let targetPage = page(at: clampedIndex) else { return }
                pendingProgrammaticIndex = clampedIndex
                pageController.setViewControllers(
                    [targetPage],
                    direction: direction,
                    animated: true
                ) { [weak self] _ in
                    guard let self else { return }
                    self.pendingProgrammaticIndex = nil
                    self.displayedIndex = clampedIndex
                    self.refreshPages(around: clampedIndex)
                }
            }
        }

        private func setInitialPage(to index: Int) {
            guard let pageController, let initialPage = page(at: index) else { return }
            pageController.setViewControllers(
                [initialPage],
                direction: .forward,
                animated: false
            )
            displayedIndex = index
            refreshPages(around: index)
        }

        private func page(at index: Int) -> LANFolderPageController? {
            guard index >= 0, index < pageCount else { return nil }
            if let existing = pages[index] {
                return existing
            }
            let page = LANFolderPageController(
                index: index,
                rootView: makePageView(for: index)
            )
            pages[index] = page
            return page
        }

        private func makePageView(for index: Int) -> AnyView {
            guard files.indices.contains(index) else {
                return AnyView(Color.black)
            }
            return AnyView(
                ZStack {
                    Color.black
                    LANFolderImageView(
                        url: files[index],
                        folderID: folderID,
                        rootURL: rootURL ?? URL(fileURLWithPath: "/"),
                        maxPixelSize: 2048,
                        fillsContainer: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            )
        }

        private func refreshPages(around index: Int) {
            let nearbyIndexes = Set(
                [index - 1, index, index + 1]
                    .filter { $0 >= 0 && $0 < pageCount }
            )
            for nearbyIndex in nearbyIndexes {
                if let existing = pages[nearbyIndex] {
                    existing.rootView = makePageView(for: nearbyIndex)
                } else {
                    _ = page(at: nearbyIndex)
                }
            }
            pages = pages.filter { nearbyIndexes.contains($0.key) }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dismissPanGesture,
                  let dismissPan = gestureRecognizer as? UIPanGestureRecognizer,
                  !isManualTransitionInProgress,
                  pendingProgrammaticIndex == nil
            else { return false }

            let coordinateView = dismissPan.view?.window ?? dismissPan.view
            let velocity = dismissPan.velocity(in: coordinateView)
            let translation = dismissPan.translation(in: coordinateView)
            let horizontalVelocity = abs(velocity.x)
            let downwardVelocity = velocity.y
            let isClearlyDownward: Bool
            if max(horizontalVelocity, abs(downwardVelocity)) >= 80 {
                isClearlyDownward = downwardVelocity > 0
                    && downwardVelocity > horizontalVelocity * 1.3
            } else {
                isClearlyDownward = translation.y > 0
                    && translation.y > abs(translation.x) * 1.3
            }
            return isClearlyDownward
        }

        @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let coordinateView = view.window ?? view.superview ?? view
            let translationPoint = recognizer.translation(in: coordinateView)
            let velocity = recognizer.velocity(in: coordinateView)
            let translation = CGSize(
                width: translationPoint.x,
                height: translationPoint.y
            )
            let projectionDuration: CGFloat = 0.2
            let predicted = CGSize(
                width: translationPoint.x + velocity.x * projectionDuration,
                height: translationPoint.y + velocity.y * projectionDuration
            )

            switch recognizer.state {
            case .began, .changed:
                onDismissDragChanged(translation)
            case .ended:
                onDismissDragEnded(translation, predicted, false)
            case .cancelled, .failed:
                onDismissDragEnded(translation, predicted, true)
            default:
                break
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isManualTransitionInProgress = true
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let photoPage = viewController as? LANFolderPageController else {
                return nil
            }
            return page(at: photoPage.index - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let photoPage = viewController as? LANFolderPageController else {
                return nil
            }
            return page(at: photoPage.index + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isManualTransitionInProgress = false

            guard finished, completed,
                  let visiblePage = pageViewController.viewControllers?
                  .first as? LANFolderPageController
            else {
                if let stableIndex = displayedIndex {
                    refreshPages(around: stableIndex)
                }
                return
            }

            let newIndex = visiblePage.index
            pendingProgrammaticIndex = nil
            displayedIndex = newIndex
            if currentIndexBinding.wrappedValue != newIndex {
                currentIndexBinding.wrappedValue = newIndex
            }
            refreshPages(around: newIndex)
        }
    }
}

@MainActor
private final class LANFolderPageController: UIHostingController<AnyView> {
    let index: Int

    init(index: Int, rootView: AnyView) {
        self.index = index
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Slideshow

/// Folder slideshow mirroring the album's SlideshowView: one visible page
/// advanced by a one-way controller honoring the interval/shuffle/loop
/// settings, the user's configured transition style, swipe or button
/// stepping, and neighbor prefetching. Never a rebuilt TabView.
struct LANFolderSlideshowScreen: View {
    let title: String
    let files: [URL]
    let folderID: UUID
    let rootURL: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentIndex = 0
    @State private var controlsVisible = true
    @State private var isPaused = false
    @State private var isShuffled = false
    @AppStorage(SlideshowSettings.loopsStorageKey)
    private var loops = SlideshowSettings.defaultLoops
    @AppStorage(SlideshowSettings.intervalStorageKey)
    private var interval: TimeInterval = SlideshowSettings.defaultInterval
    @State private var stoppedAtEnd = false
    @State private var previousIdleTimerDisabled = false
    @AppStorage(SlideshowTransitionStyle.storageKey)
    private var transitionStyleRawValue = SlideshowTransitionStyle.fade.rawValue

    private var transitionStyle: SlideshowTransitionStyle {
        SlideshowTransitionStyle(rawValue: transitionStyleRawValue) ?? .fade
    }

    private var safeIndex: Int {
        min(max(0, currentIndex), max(0, files.count - 1))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LANFolderSlideshowPage(
                files: files,
                folderID: folderID,
                rootURL: rootURL,
                index: $currentIndex,
                transitionStyle: transitionStyle,
                onNext: { showNext() },
                onPrevious: { showPrevious() }
            )
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
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel("结束幻灯片")

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
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel(isPaused ? "继续播放" : "暂停播放")
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
                                ForEach(SlideshowSettings.intervalValues, id: \.self) { value in
                                    Button("每 \(Int(value)) 秒") {
                                        interval = value
                                    }
                                }
                            } label: {
                                Label("\(Int(interval)) 秒", systemImage: "speedometer")
                            }

                            Button {
                                toggleLooping()
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
                            Text("\(safeIndex + 1) / \(files.count)")
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
        .statusBarHidden(!controlsVisible)
        .onAppear {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
        .onChange(of: currentIndex) { _, newValue in
            LANFolderDiagnostics.log("slideshow index → \(newValue + 1)/\(files.count)")
            prefetchNeighbors(around: newValue)
        }
        .task(id: slideshowTaskID) {
            // Same runner contract as the album slideshow: iCloud/provider
            // delivery never stops the sequence, and backgrounding pauses it.
            guard scenePhase == .active, !isPaused, files.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled, scenePhase == .active, !isPaused else { return }
                showNext()
            }
        }
    }

    private var slideshowTaskID: String {
        "\(scenePhase)-\(isPaused)-\(interval)-\(currentIndex)-\(isShuffled)-\(loops)"
    }

    private func showPrevious() {
        guard files.count > 1 else { return }
        stoppedAtEnd = false
        currentIndex = currentIndex == 0 ? files.count - 1 : currentIndex - 1
    }

    private func showNext() {
        guard files.count > 1 else { return }
        if isShuffled {
            stoppedAtEnd = false
            var nextIndex = currentIndex
            while nextIndex == currentIndex {
                nextIndex = Int.random(in: 0..<files.count)
            }
            currentIndex = nextIndex
        } else if currentIndex == files.count - 1 {
            if loops {
                stoppedAtEnd = false
                isPaused = false
                currentIndex = 0
            } else {
                stoppedAtEnd = true
                isPaused = true
            }
        } else {
            stoppedAtEnd = false
            currentIndex += 1
        }
    }

    private func toggleLooping() {
        loops.toggle()
        if loops && stoppedAtEnd {
            stoppedAtEnd = false
            isPaused = false
        }
    }

    private func prefetchNeighbors(around index: Int) {
        for offset in [-1, 1] {
            let candidate = index + offset
            guard files.indices.contains(candidate) else { continue }
            Task.detached(priority: .utility) { [files, folderID, rootURL] in
                _ = await LANFolderImageLoaderQueue.load(
                    at: files[candidate],
                    folderID: folderID,
                    rootURL: rootURL,
                    maxPixelSize: 2048
                )
            }
        }
    }
}

/// Single visible slideshow page with the user's configured transition and
/// the same swipe thresholds as the album's SlideshowAssetPager.
private struct LANFolderSlideshowPage: View {
    let files: [URL]
    let folderID: UUID
    let rootURL: URL
    @Binding var index: Int
    let transitionStyle: SlideshowTransitionStyle
    let onNext: () -> Void
    let onPrevious: () -> Void

    @State private var transitionDirection = 1

    var body: some View {
        ZStack {
            Color.black

            if files.indices.contains(index) {
                LANFolderImageView(
                    url: files[index],
                    folderID: folderID,
                    rootURL: rootURL,
                    maxPixelSize: 2048,
                    fillsContainer: false
                )
                .id("lan-slideshow-\(index)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(
                    lanSlideshowTransition(style: transitionStyle, direction: transitionDirection)
                )
            }
        }
        .animation(.easeInOut(duration: 0.32), value: index)
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .onChange(of: index) { oldValue, newValue in
            transitionDirection = newValue >= oldValue ? 1 : -1
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
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
}

private func lanSlideshowTransition(
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
