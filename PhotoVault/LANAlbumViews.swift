import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Home entry

/// Sidebar entry for external folders treated as albums: direct SMB shares
/// (no Files-app mount, no re-authorization after launch) and folders picked
/// through the Files app (local, USB, iCloud Drive).
struct LANAlbumHomeScreen: View {
    @State private var folders: [LANFolderAlbum] = LANFolderLibrary.load()
    @State private var smbFolders: [SMBFolderAlbum] = SMBFolderLibrary.load()
    @State private var servers: [SMBServer] = SMBServerLibrary.load()
    @State private var isShowingPicker = false
    @State private var isShowingSMBAdd = false
    @State private var route: FolderRoute?
    @State private var pendingSMBLogin: SMBLoginResult?
    @State private var alert: HomeAlert?

    private struct SMBLoginResult: Hashable {
        let server: SMBServer
        let shares: [SMBShareInfo]
    }

    private enum FolderRoute: Hashable {
        case local(LANFolderAlbum)
        case smb(SMBFolderAlbum)
        case smbShares(SMBLoginResult)
    }

    private enum HomeAlert: Identifiable {
        case message(title: String, message: String)
        case deleteServers([SMBServer])

        var id: String {
            switch self {
            case .message(let title, let message):
                return "message-\(title)-\(message)"
            case .deleteServers(let servers):
                return "servers-\(servers.map(\.id.uuidString).joined(separator: ","))"
            }
        }
    }

    private var iCloudFolders: [LANFolderAlbum] {
        folders.filter(\.isICloudDrive)
    }

    private var filesAppFolders: [LANFolderAlbum] {
        folders.filter { !$0.isICloudDrive }
    }

    @ViewBuilder
    private func folderRows(_ subset: [LANFolderAlbum], identifierPrefix: String) -> some View {
        ForEach(subset) { folder in
            Button {
                route = .local(folder)
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
            .accessibilityIdentifier("\(identifierPrefix)\(folder.name)")
        }
        .onDelete { offsets in
            deleteFolders(at: offsets, from: subset)
        }
    }

    private func deleteFolders(at offsets: IndexSet, from subset: [LANFolderAlbum]) {
        let ids = Set(offsets.compactMap { subset.indices.contains($0) ? subset[$0].id : nil })
        guard !ids.isEmpty else { return }
        for id in ids {
            LANFolderThumbnailDiskCache.purge(folderID: id)
        }
        folders.removeAll { ids.contains($0.id) }
        LANFolderLibrary.save(folders)
    }

    var body: some View {
        List {
            Section {
                if smbFolders.isEmpty {
                    Text("还没有添加 SMB 相册。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(smbFolders) { folder in
                        Button {
                            route = .smb(folder)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.name)
                                Text("\(serverLabel(for: folder)) · \(folder.displayPath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("smb-album-\(folder.name)")
                    }
                    .onDelete { offsets in
                        // Resolve every row before mutating: each removal
                        // rewrites the stored list, so reading offsets against
                        // the updated array would hit shifted indices.
                        let ids = offsets.compactMap {
                            smbFolders.indices.contains($0) ? smbFolders[$0].id : nil
                        }
                        for id in ids {
                            smbFolders = SMBFolderLibrary.remove(albumID: id)
                        }
                    }
                }
                Button {
                    isShowingSMBAdd = true
                } label: {
                    Label("添加 SMB 相册", systemImage: "externaldrive.badge.plus")
                }
                .accessibilityIdentifier("smb-add-album-home")
            } header: {
                Text("SMB 相册")
            } footer: {
                Text("直接连接 NAS 或 SMB 共享，不需要在文件 App 里挂载，也不会因为重启而丢失访问权限。")
            }

            Section {
                folderRows(iCloudFolders, identifierPrefix: "icloud-folder-")
                if iCloudFolders.isEmpty {
                    Text("还没有添加 iCloud Drive 文件夹。")
                        .foregroundStyle(.secondary)
                }
                Button {
                    isShowingPicker = true
                } label: {
                    Label("从 iCloud Drive 添加文件夹", systemImage: "icloud.and.arrow.down")
                }
                .accessibilityIdentifier("icloud-add-folder-home")
            } header: {
                Text("iCloud Drive")
            } footer: {
                Text("在文件选择器侧栏进入 iCloud Drive 选择文件夹。添加后直接读取原文件、不复制；权限由系统书签跨启动恢复，原图未下载时会按需下载。")
            }

            Section {
                folderRows(filesAppFolders, identifierPrefix: "folder-")
                if filesAppFolders.isEmpty {
                    Text("还没有添加其他文件夹。")
                        .foregroundStyle(.secondary)
                }
                Button {
                    isShowingPicker = true
                } label: {
                    Label("添加其他文件夹", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("folder-add-home")
            } header: {
                Text("其他文件夹")
            } footer: {
                Text("本机、外接 U 盘或文件 App 里连接的共享。其他 App「我的 iPhone」目录内的文件夹无法跨启动保留授权，请改用 SMB 或 iCloud Drive。")
            }

            if !servers.isEmpty {
                Section {
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.name)
                            Text("\(server.username.isEmpty ? "访客" : server.username)@\(server.displayAddress)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let targets = offsets.compactMap {
                            servers.indices.contains($0) ? servers[$0] : nil
                        }
                        guard !targets.isEmpty else { return }
                        alert = .deleteServers(targets)
                    }
                } header: {
                    Text("SMB 服务器")
                } footer: {
                    Text("删除服务器会移除它的相册条目和保存的密码，不会删除服务器上的照片。")
                }
            }
        }
        .navigationTitle("文件夹相册")
        .navigationDestination(item: $route) { route in
            switch route {
            case .local(let folder):
                LANFolderGridScreen(folder: folder)
            case .smb(let folder):
                SMBFolderGridScreen(folder: folder)
            case .smbShares(let login):
                SMBBrowseSharesView(server: login.server, shares: login.shares) { _ in
                    smbFolders = SMBFolderLibrary.load()
                    servers = SMBServerLibrary.load()
                    // The album is now in the home list; popping back makes
                    // the result visible instead of pushing a second detail
                    // on top of the picker stack.
                    self.route = nil
                }
            }
        }
        .onAppear {
            // Re-auth writes fresh bookmarks into storage behind this
            // screen; pick them up when the list reappears.
            folders = LANFolderLibrary.load()
            smbFolders = SMBFolderLibrary.load()
            servers = SMBServerLibrary.load()
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
                        alert = .message(
                            title: "无法添加文件夹",
                            message: "创建访问书签失败，请重试或换一个文件夹。"
                        )
                        return
                    }
                    folders = result.folders
                    // Re-picking a registered folder refreshes its access
                    // grant — open it right away, silently.
                    if case .duplicate(let healed) = result.outcome {
                        route = .local(healed)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSMBAdd, onDismiss: {
            smbFolders = SMBFolderLibrary.load()
            servers = SMBServerLibrary.load()
            // Browsing continues in this screen's navigation stack. Pushing
            // from inside the credential sheet leaves the keyboard's
            // text-effects window above the share list, where it silently
            // swallows every tap on a row.
            if let pendingSMBLogin {
                self.pendingSMBLogin = nil
                route = .smbShares(pendingSMBLogin)
            }
        }) {
            SMBAddAlbumSheet { server, shares in
                pendingSMBLogin = SMBLoginResult(server: server, shares: shares)
            }
        }
        .alert(item: $alert) { alert in
            switch alert {
            case .message(let title, let message):
                return Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            case .deleteServers(let targets):
                let albumCount = smbFolders.filter { folder in
                    targets.contains { $0.id == folder.serverID }
                }.count
                let names = targets.map(\.name).joined(separator: "、")
                return Alert(
                    title: Text(targets.count == 1 ? "删除 SMB 服务器？" : "删除 \(targets.count) 台 SMB 服务器？"),
                    message: Text("将移除「\(names)」的 \(albumCount) 个相册条目和保存的密码。服务器上的照片不会被删除。"),
                    primaryButton: .destructive(Text("删除")) {
                        for server in targets {
                            smbFolders = SMBFolderLibrary.remove(serverID: server.id)
                        }
                        servers = SMBServerLibrary.load()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private func serverLabel(for folder: SMBFolderAlbum) -> String {
        servers.first(where: { $0.id == folder.serverID })?.name ?? "SMB"
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
    /// Pushes/pops the viewer on the folder detail's navigation stack, so the
    /// folder viewer gets the same system zoom transition and interactive
    /// pull-down dismissal as the album, unsorted and search viewers.
    @State private var navigator = PhotoViewerNavigator()
    /// Folder slideshows are set up in the same sheet as album slideshows,
    /// minus the content filters: a folder is `[URL]`-backed, so orientation
    /// and resolution are not known without decoding every file.
    @State private var isShowingSlideshowOptions = false
    @State private var isStartingSlideshow = false
    @State private var pendingSlideshowStart = false
    @State private var enumerateGeneration = 0

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
                        // Index-keyed so the grid never rebuilds an n-element
                        // `(offset, element)` array for a folder that can
                        // hold thousands of files.
                        ForEach(files.indices, id: \.self) { index in
                            Button {
                                openViewer(at: index)
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
        .background(PhotoViewerNavigationAnchor(navigator: navigator))
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !files.isEmpty {
                    Button {
                        isShowingSlideshowOptions = true
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                }
            }
        }
        .task(id: "\(folder.id)#\(enumerateAttempt)") {
            enumerateGeneration += 1
            await enumerate(generation: enumerateGeneration)
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
        .sheet(isPresented: $isShowingSlideshowOptions) {
            SlideshowOptionsSheet(
                title: "\(folder.name)幻灯片",
                source: nil,
                onStart: { _ in
                    // The cover must wait for the options sheet to finish
                    // dismissing; presenting both in one turn drops the cover.
                    pendingSlideshowStart = true
                    isShowingSlideshowOptions = false
                }
            )
        }
        .onChange(of: isShowingSlideshowOptions) { _, isShowing in
            guard !isShowing, pendingSlideshowStart else { return }
            pendingSlideshowStart = false
            isStartingSlideshow = true
        }
        .fullScreenCover(
            isPresented: $isStartingSlideshow,
            onDismiss: { isStartingSlideshow = false }
        ) {
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

    /// Opens the folder viewer by pushing it onto the folder detail's
    /// navigation stack. The LazyVGrid has no collection view to resolve a
    /// zoom source cell from, so the transition zooms from the window center;
    /// the interactive pull-down dismissal behaves like every other entry.
    private func openViewer(at index: Int) {
        guard files.indices.contains(index) else { return }
        navigator.open(
            request: PhotoViewerRequest(index: index, assetIdentifier: files[index].absoluteString, previewImage: nil),
            gridTransitionCoordinator: nil
        ) { state, close in
            AnyView(LANFolderViewerScreen(
                files: files, folderID: folder.id,
                rootURL: folderURL ?? URL(fileURLWithPath: "/"),
                initialIndex: index, transitionState: state, onClose: close
            ))
        }
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
    private func enumerate(generation: Int) async {
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
            "enumerating \(album.name): iCloudDrive=\(album.isICloudDrive) bookmarkFP=\("len\(album.bookmark.count):\(album.bookmark.base64EncodedString().suffix(6))")"
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
            LANFolderLibrary.markICloudDriveIfNeeded(id: album.id, resolvedURL: url)
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
            // provider even when startAccessing was refused. iCloud Drive also
            // reports a started scope while a direct FileManager traversal
            // comes back empty, so probe the coordinated channel whenever the
            // enumeration is empty rather than only after a denied grant.
            var coordinatedWorked = false
            if enumerated.isEmpty {
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
            // A retry or a re-authorization may have started a newer pass
            // while this one was blocked on the share; its result is stale.
            guard generation == enumerateGeneration else { return }
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
                enumerateError = (album.isICloudDrive || LANFolderProvider.isICloudDrive(url))
                    ? "无法访问 iCloud Drive 文件夹：请确认已在系统设置登录 iCloud、开启 iCloud 云盘并有可用网络。点“重新授权”重新选择该文件夹即可恢复；如果它已被移动，请先在文件 App 中确认位置。"
                    : "无法获得文件夹的访问权限：该文件夹可能位于其他 App 的目录内，iOS 出于沙盒安全不允许跨启动记住此类授权。建议把它移到 iCloud Drive 顶层或改用 SMB 直连，然后在这里重新选择一次。"
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
            guard generation == enumerateGeneration else { return }
            LANFolderDiagnostics.log("enumerate timed out for \(album.name)")
            enumerateError = album.isICloudDrive
                ? "读取 iCloud Drive 超时，请检查网络和 iCloud 云盘状态后重试。"
                : "文件夹访问超时或已不可访问，请检查共享连接后重试，或删除后重新添加。"
        }
        isEnumerating = false
    }
}

// MARK: - Image views

struct LANFolderImageView: View {
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
    /// Popping is owned by the navigation stack the viewer was pushed onto;
    /// the close button routes through it like every other exit.
    let transitionState: PhotoViewerTransitionState
    let onClose: () -> Void
    @State private var prefetchTasks: [Task<Void, Never>] = []

    /// The viewer is hosted outside the grid's SwiftUI tree, so the displayed
    /// page must be owned here — a binding back to the grid updates the pager
    /// but never re-renders the counter or filmstrip.
    @State private var index: Int
    @State private var isPreparingShare = false
    @State private var isShowingShareError = false

    init(
        files: [URL],
        folderID: UUID,
        rootURL: URL,
        initialIndex: Int,
        transitionState: PhotoViewerTransitionState,
        onClose: @escaping () -> Void
    ) {
        self.files = files
        self.folderID = folderID
        self.rootURL = rootURL
        self.transitionState = transitionState
        self.onClose = onClose
        _index = State(initialValue: min(max(0, initialIndex), max(0, files.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // Same interaction model as the album viewer: continuous
            // horizontal paging plus the pull-down dismissal — no tap zones.
            LANFolderPager(
                files: files,
                folderID: folderID,
                rootURL: rootURL,
                currentIndex: $index
            )

            VStack {
                HStack {
                    Button {
                        onClose()
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
                        guard files.indices.contains(index), !isPreparingShare else { return }
                        let source = files[index]
                        isPreparingShare = true
                        Task { @MainActor in
                            // SMB URLs must become real files before the
                            // share sheet can read them; local folders pass
                            // through immediately.
                            let materialized = await SMBFileMaterializer.materialized(for: source)
                            isPreparingShare = false
                            guard let materialized else {
                                isShowingShareError = true
                                return
                            }
                            ActivityPresenter.present(
                                items: [materialized.url],
                                onDismiss: materialized.cleanup
                            )
                        }
                    } label: {
                        if isPreparingShare {
                            ProgressView()
                                .tint(.white)
                                .frame(width: 46, height: 46)
                                .glassEffect(.regular, in: Circle())
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.headline.weight(.semibold))
                                .frame(width: 46, height: 46)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                    }
                    .disabled(isPreparingShare)
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
        }
        .onAppear {
            prefetchNeighbors(around: index)
        }
        .onChange(of: index) { _, newValue in
            transitionState.update(index: newValue, assetIdentifier: files.indices.contains(newValue) ? files[newValue].absoluteString : nil)
            prefetchNeighbors(around: newValue)
        }
        .alert("无法分享", isPresented: $isShowingShareError) {
            Button("好", role: .cancel) { }
        } message: {
            Text("无法从 SMB 服务器读取这张照片，请检查共享连接后重试。")
        }
        .onDisappear {
            cancelPrefetch()
        }
    }

    /// Warm the disk/memory cache for the neighbors so the next page shows
    /// instantly — the same "prefetch before switching" rule as the album
    /// viewer, routed through the shared coalescing loader queue. A swipe
    /// replaces the window, so the previous pair is cancelled rather than
    /// left holding decode-gate slots for photos the user already passed.
    private func prefetchNeighbors(around index: Int) {
        cancelPrefetch()
        for offset in [-1, 1] {
            let candidate = index + offset
            guard files.indices.contains(candidate) else { continue }
            prefetchTasks.append(Task.detached(priority: .utility) { [files, folderID, rootURL] in
                guard !Task.isCancelled else { return }
                _ = await LANFolderImageLoaderQueue.load(
                    at: files[candidate],
                    folderID: folderID,
                    rootURL: rootURL,
                    maxPixelSize: 2048
                )
            })
        }
    }

    private func cancelPrefetch() {
        for task in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
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

/// URL-driven sibling of the album viewer's pager: both run on the shared
/// `ViewerPagerEngine` (a horizontal paging UICollectionView). The engine
/// keeps the current page and its neighbors alive via cell reuse, writes
/// swipes back into the index binding at settle, and refuses vertical pans so
/// the system zoom dismissal owns the pull-down.
private struct LANFolderPager: View {
    let files: [URL]
    let folderID: UUID
    let rootURL: URL
    @Binding var currentIndex: Int

    var body: some View {
        GeometryReader { proxy in
            ViewerPagingCollectionRepresentable(
                pageCount: files.count, currentIndex: currentIndex, isScrubbing: false,
                assetProvider: { _ in nil },
                pageIdentity: { index in files.indices.contains(index) ? files[index].absoluteString : "missing" },
                pageRootView: { index, _, _, _, _ in
                    guard files.indices.contains(index) else { return AnyView(Color.black) }
                    return AnyView(LANFolderImageView(url: files[index], folderID: folderID, rootURL: rootURL,
                                                     maxPixelSize: 2048, fillsContainer: false))
                },
                targetSize: proxy.size, contentMode: .aspectFit, neighborPriority: .slideshow,
                initialPreviewImage: nil, initialAssetIdentifier: nil,
                onIndexChanged: { currentIndex = $0 }, onMediaReady: nil, onZoomingChanged: nil, onPagingChanged: nil
            )
        }
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
    /// Shared with the album slideshows: the launch sheet writes these keys,
    /// so "随机顺序" and "填充满画面" mean the same thing in every slideshow.
    @AppStorage(SlideshowPlaybackSettings.shufflesKey)
    private var isShuffled = SlideshowPlaybackSettings.defaultShuffles
    @AppStorage(SlideshowPlaybackSettings.fillsScreenKey)
    private var fillsScreen = SlideshowPlaybackSettings.defaultFillsScreen
    @AppStorage(SlideshowSettings.loopsStorageKey)
    private var loops = SlideshowSettings.defaultLoops
    @AppStorage(SlideshowSettings.intervalStorageKey)
    private var interval: TimeInterval = SlideshowSettings.defaultInterval
    @State private var stoppedAtEnd = false
    @State private var previousIdleTimerDisabled = false
    @State private var prefetchTasks: [Task<Void, Never>] = []
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
                fillsContainer: fillsScreen,
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
            cancelPrefetch()
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
        cancelPrefetch()
        for offset in [-1, 1] {
            let candidate = index + offset
            guard files.indices.contains(candidate) else { continue }
            prefetchTasks.append(Task.detached(priority: .utility) { [files, folderID, rootURL] in
                guard !Task.isCancelled else { return }
                _ = await LANFolderImageLoaderQueue.load(
                    at: files[candidate],
                    folderID: folderID,
                    rootURL: rootURL,
                    maxPixelSize: 2048
                )
            })
        }
    }

    private func cancelPrefetch() {
        for task in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
    }
}

/// Single visible slideshow page with the user's configured transition and
/// the same swipe thresholds as the album's SlideshowAssetPager.
private struct LANFolderSlideshowPage: View {
    let fillsContainer: Bool
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
                    fillsContainer: fillsContainer
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
