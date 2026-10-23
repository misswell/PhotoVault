import SwiftUI

// MARK: - Add album flow

/// Login step of the add-album flow. Credentials are validated before
/// anything is persisted, so a failed login never leaves a half-added server
/// behind. On success the sheet closes and hands the share list back to the
/// caller: browsing continues in the main navigation stack, because a push
/// inside the sheet can land under the (stale) keyboard window, which then
/// swallows every tap on the share rows.
struct SMBAddAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onLoggedIn: (SMBServer, [SMBShareInfo]) -> Void

    @State private var servers = SMBServerLibrary.load()
    @State private var selectedServerID: UUID?
    @State private var host = ""
    @State private var port = "445"
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var displayName = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if !servers.isEmpty {
                    Section {
                        Picker("服务器", selection: $selectedServerID) {
                            Text("新服务器").tag(UUID?.none)
                            ForEach(servers) { server in
                                Text(server.name).tag(Optional(server.id))
                            }
                        }
                        .onChange(of: selectedServerID) { _, newValue in
                            applyServer(newValue)
                        }
                    } footer: {
                        Text("选择已保存的服务器可以免去重新输入地址和密码。")
                    }
                }

                Section {
                    TextField("地址", text: $host, prompt: Text("192.168.1.10 或 nas.local"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("smb-host")
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("smb-port")
                    TextField("用户名", text: $username, prompt: Text("留空为访客登录"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("smb-username")
                    SecureField("密码", text: $password)
                        .accessibilityIdentifier("smb-password")
                    TextField("域", text: $domain, prompt: Text("可选，Windows 域"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("显示名称", text: $displayName, prompt: Text("可选，默认使用地址"))
                        .accessibilityIdentifier("smb-display-name")
                } header: {
                    Text("服务器")
                } footer: {
                    Text("PhotoVault 直接连接局域网内的 SMB 共享（SMB 2.0/2.1），照片和密码都不会上传到任何服务器。首次连接时系统会询问本地网络权限。仅支持 SMB 1.0 的旧设备无法连接。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isConnecting ? "正在连接…" : "连接并选择共享")
                            Spacer()
                        }
                    }
                    .disabled(isConnecting)
                    .accessibilityIdentifier("smb-connect")
                }
            }
            .navigationTitle("添加 SMB 相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func applyServer(_ id: UUID?) {
        guard let id, let server = servers.first(where: { $0.id == id }) else { return }
        host = server.host
        port = String(server.port)
        username = server.username
        domain = server.domain
        password = SMBCredentialStore.password(for: server.id) ?? ""
        displayName = server.name
    }

    private func connect() {
        errorMessage = nil
        let trimmedHost = Self.normalizedHost(host)
        guard !trimmedHost.isEmpty else {
            errorMessage = "请输入服务器地址。"
            return
        }
        guard let portValue = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(portValue) else {
            errorMessage = "端口必须是 1 到 65535 之间的数字。"
            return
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        // Re-adding the same endpoint and account re-authenticates the saved
        // server instead of appending a duplicate row. Duplicates each keep
        // their own Keychain entry, so an old copy with a stale password
        // makes the same album list twice and fail to open.
        let matched = selectedServerID == nil ? servers.first(where: {
            $0.host.caseInsensitiveCompare(trimmedHost) == .orderedSame
                && $0.port == portValue
                && $0.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame
                && $0.domain.caseInsensitiveCompare(trimmedDomain) == .orderedSame
        }) : nil
        let serverID = selectedServerID ?? matched?.id ?? UUID()
        let existing = matched ?? servers.first(where: { $0.id == serverID })
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = SMBServer(
            id: serverID,
            name: trimmedName.isEmpty ? (existing?.name ?? trimmedHost) : trimmedName,
            host: trimmedHost,
            port: portValue,
            username: trimmedUsername,
            domain: trimmedDomain,
            addedAt: existing?.addedAt ?? .now
        )
        let config = SMBConnectionConfig(
            host: server.host,
            port: server.port,
            username: server.username,
            password: password,
            domain: server.domain
        )

        isConnecting = true
        Task { @MainActor in
            do {
                let shares = try await SMBShareBrowser.listShares(config: config)
                guard SMBCredentialStore.save(password: password, for: server.id) else {
                    errorMessage = "无法把密码写入钥匙串，请解锁设备后重试。"
                    isConnecting = false
                    return
                }
                var all = SMBServerLibrary.load()
                if let index = all.firstIndex(where: { $0.id == server.id }) {
                    all[index] = server
                } else {
                    all.append(server)
                }
                SMBServerLibrary.save(all)
                if matched != nil {
                    // Re-authenticating may replace the saved password;
                    // pooled sessions still hold the previous one.
                    SMBConnectionPool.shared.discardAll(serverID: server.id)
                }
                onLoggedIn(server, shares)
                dismiss()
            } catch {
                errorMessage = SMBError.describe(error)
            }
            isConnecting = false
        }
    }

    private static func normalizedHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("smb://") {
            value = String(value.dropFirst("smb://".count))
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

// MARK: - Share list

struct SMBBrowseSharesView: View {
    let server: SMBServer
    let shares: [SMBShareInfo]
    let onAdded: (SMBFolderAlbum) -> Void

    @State private var selectedShare: SMBShareInfo?

    private var config: SMBConnectionConfig? {
        SMBConfiguration.config(for: server)
    }

    var body: some View {
        Group {
            if let config {
                List(shares) { share in
                    Button {
                        selectedShare = share
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(share.name, systemImage: "externaldrive")
                                if !share.comment.isEmpty {
                                    Text(share.comment)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("smb-share-\(share.name)")
                }
                .navigationDestination(item: $selectedShare) { share in
                    SMBDirectoryBrowserView(
                        server: server,
                        config: config,
                        share: share.name,
                        path: "",
                        onAdded: onAdded
                    )
                }
            } else {
                ContentUnavailableView {
                    Label("需要重新登录", systemImage: "key.slash")
                } description: {
                    Text("没有找到这台服务器保存的密码，请返回重新添加。")
                }
            }
        }
        .navigationTitle("选择共享")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Directory picker

private struct SMBDirectoryBrowserView: View {
    let server: SMBServer
    let config: SMBConnectionConfig
    let share: String
    let path: String
    let onAdded: (SMBFolderAlbum) -> Void

    @State private var directories: [SMBRemoteFile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var isAdding = false

    private var displayName: String {
        SMBPath.displayName(for: path, fallback: share)
    }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("正在读取文件夹…")
                    Spacer()
                }
            } else if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("重试") {
                        attempt += 1
                    }
                }
            } else if directories.isEmpty {
                Section {
                    Text("这个文件夹下没有子文件夹，可以直接把当前文件夹添加为相册。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(directories) { directory in
                        NavigationLink {
                            SMBDirectoryBrowserView(
                                server: server,
                                config: config,
                                share: share,
                                path: directory.path,
                                onAdded: onAdded
                            )
                        } label: {
                            Label(directory.name, systemImage: "folder")
                        }
                    }
                } header: {
                    Text("子文件夹")
                }
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Text("共享：\(share)\(path.isEmpty ? "" : " · \(path)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    addCurrentFolder()
                } label: {
                    HStack {
                        if isAdding {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text("将「\(displayName)」添加为相册")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAdding || isLoading)
                .accessibilityIdentifier("smb-add-folder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .task(id: "\(path)#\(attempt)") {
            await loadDirectories()
        }
    }

    @MainActor
    private func loadDirectories() async {
        isLoading = true
        errorMessage = nil
        let connection = SMBConnectionPool.shared.connection(serverID: server.id, share: share)
        await connection.update(config: config)
        do {
            let entries = try await connection.listDirectory(at: path)
            // Navigating to a child or retrying cancels this task; a stale
            // listing must not overwrite the new folder's state.
            guard !Task.isCancelled else { return }
            directories = entries
                .filter(\.isDirectory)
                .filter { !$0.name.hasPrefix(".") && $0.name != "." && $0.name != ".." }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = SMBError.describe(error)
        }
        guard !Task.isCancelled else { return }
        isLoading = false
    }

    private func addCurrentFolder() {
        isAdding = true
        let result = SMBFolderLibrary.add(server: server, share: share, path: path, name: displayName)
        isAdding = false
        onAdded(result.album)
    }
}

// MARK: - Album grid

struct SMBFolderGridScreen: View {
    let folder: SMBFolderAlbum

    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var isEnumerating = true
    @State private var enumerateError: String?
    @State private var enumerateAttempt = 0
    @State private var navigator = PhotoViewerNavigator()
    @State private var isShowingSlideshowOptions = false
    @State private var isStartingSlideshow = false
    @State private var pendingSlideshowStart = false
    @State private var isShowingCredentials = false
    @State private var enumerateGeneration = 0

    private let rootURL = URL(fileURLWithPath: "/")
    private let columns = [
        GridItem(.adaptive(minimum: 88, maximum: 150), spacing: 2)
    ]

    private var server: SMBServer? {
        SMBServerLibrary.load().first(where: { $0.id == folder.serverID })
    }

    var body: some View {
        Group {
            if isEnumerating && files.isEmpty {
                ProgressView("正在读取 SMB 相册…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let enumerateError, files.isEmpty {
                ContentUnavailableView {
                    Label("无法读取 SMB 相册", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(enumerateError)
                } actions: {
                    Button("重新登录") {
                        isShowingCredentials = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("重试") {
                        enumerateAttempt += 1
                    }
                    Button("返回") {
                        dismiss()
                    }
                }
            } else if files.isEmpty {
                ContentUnavailableView {
                    Label("文件夹里没有图片", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("SMB 共享的这个文件夹（含子文件夹）里没有找到可显示的图片。")
                } actions: {
                    Button("重试") {
                        enumerateAttempt += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
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
                                            rootURL: rootURL,
                                            maxPixelSize: 512
                                        )
                                    }
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("smb-cell-\(index)")
                        }
                    }
                    .padding(2)
                }
                .accessibilityIdentifier("smb-grid")
                .refreshable {
                    LANFolderSessionCache.remove(id: folder.id)
                    enumerateAttempt += 1
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
        .sheet(isPresented: $isShowingCredentials) {
            if let server {
                SMBCredentialsSheet(server: server) {
                    LANFolderSessionCache.remove(id: folder.id)
                    enumerateError = nil
                    files = []
                    enumerateAttempt += 1
                }
            } else {
                ContentUnavailableView(
                    "服务器已被删除",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("请返回文件夹相册列表并重新添加。")
                )
            }
        }
        .sheet(isPresented: $isShowingSlideshowOptions) {
            SlideshowOptionsSheet(
                title: "\(folder.name)幻灯片",
                source: nil,
                onStart: { _ in
                    // Present the cover only after the sheet has closed;
                    // starting both in the same turn makes UIKit drop it.
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
            LANFolderSlideshowScreen(
                title: folder.name,
                files: files,
                folderID: folder.id,
                rootURL: rootURL
            )
        }
    }

    private func openViewer(at index: Int) {
        guard files.indices.contains(index) else { return }
        navigator.open(
            request: PhotoViewerRequest(
                index: index,
                assetIdentifier: files[index].absoluteString,
                previewImage: nil
            ),
            gridTransitionCoordinator: nil
        ) { state, close in
            AnyView(LANFolderViewerScreen(
                files: files,
                folderID: folder.id,
                rootURL: rootURL,
                initialIndex: index,
                transitionState: state,
                onClose: close
            ))
        }
    }

    @MainActor
    private func enumerate(generation: Int) async {
        if let cached = LANFolderSessionCache.entry(for: folder.id) {
            files = cached.files
            isEnumerating = false
            return
        }

        isEnumerating = true
        enumerateError = nil
        let album = SMBFolderLibrary.load().first(where: { $0.id == folder.id }) ?? folder
        do {
            let urls = try await SMBTimeout.run(seconds: 90) {
                try await SMBFolderEnumerator.enumerate(folder: album)
            }
            // A retry, refresh or screen exit may have superseded this walk;
            // its result must not overwrite the newer state.
            guard generation == enumerateGeneration, !Task.isCancelled else { return }
            files = urls
            if !urls.isEmpty {
                LANFolderSessionCache.store(rootURL: rootURL, files: urls, for: album.id)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == enumerateGeneration, !Task.isCancelled else { return }
            enumerateError = SMBError.describe(error)
        }
        guard generation == enumerateGeneration else { return }
        isEnumerating = false
    }
}

// MARK: - Credentials repair

/// Replaces the stored password of an existing server. Used when a NAS
/// changes its account or the Keychain entry is missing after a restore.
struct SMBCredentialsSheet: View {
    let server: SMBServer
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password: String
    @State private var domain: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(server: SMBServer, onSaved: @escaping () -> Void) {
        self.server = server
        self.onSaved = onSaved
        _username = State(initialValue: server.username)
        _password = State(initialValue: SMBCredentialStore.password(for: server.id) ?? "")
        _domain = State(initialValue: server.domain)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("服务器", value: server.host)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    TextField("域", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("留空用户名和密码表示访客登录。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isSaving ? "正在验证…" : "保存并重试")
                            Spacer()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle("重新登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func save() {
        errorMessage = nil
        isSaving = true
        let updated = SMBServer(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain.trimmingCharacters(in: .whitespacesAndNewlines),
            addedAt: server.addedAt
        )
        let config = SMBConnectionConfig(
            host: updated.host,
            port: updated.port,
            username: updated.username,
            password: password,
            domain: updated.domain
        )
        Task { @MainActor in
            do {
                // Validate before overwriting the stored credential, so a
                // typo cannot leave the album worse off than before.
                _ = try await SMBShareBrowser.listShares(config: config)
                guard SMBCredentialStore.save(password: password, for: updated.id) else {
                    errorMessage = "无法把密码写入钥匙串，请解锁设备后重试。"
                    isSaving = false
                    return
                }
                var all = SMBServerLibrary.load()
                if let index = all.firstIndex(where: { $0.id == updated.id }) {
                    all[index] = updated
                } else {
                    all.append(updated)
                }
                SMBServerLibrary.save(all)
                SMBConnectionPool.shared.discardAll(serverID: updated.id)
                onSaved()
                dismiss()
            } catch {
                errorMessage = SMBError.describe(error)
            }
            isSaving = false
        }
    }
}
