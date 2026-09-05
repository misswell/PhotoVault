import SwiftUI
import UniformTypeIdentifiers

// MARK: - Home entry

/// Sidebar entry for folders picked through the Files app (SMB/NAS shares
/// included) treated as albums.
struct LANAlbumHomeScreen: View {
    @State private var folders: [LANFolderAlbum] = LANFolderLibrary.load()
    @State private var isShowingPicker = false
    @State private var alert: PhotoVaultAlert?

    var body: some View {
        List {
            Section {
                if folders.isEmpty {
                    Text("还没有添加局域网文件夹。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        NavigationLink {
                            LANFolderGridScreen(folder: folder)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.name)
                                Text("添加于 \(folder.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
        .sheet(isPresented: $isShowingPicker) {
            LANFolderPicker { pickedURL in
                if let album = LANFolderLibrary.add(from: pickedURL) {
                    folders.append(album)
                    LANFolderLibrary.save(folders)
                } else {
                    alert = PhotoVaultAlert(
                        title: "无法添加文件夹",
                        message: "创建访问书签失败，请重试或换一个文件夹。"
                    )
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
                    Button("重新添加") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if files.isEmpty {
                ContentUnavailableView(
                    "文件夹里没有图片",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("这个文件夹（含子文件夹）里没有找到可显示的图片。")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(files.enumerated()), id: \.element) { index, fileURL in
                            Button {
                                viewerIndex = index
                            } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        LANFolderImageView(
                                            url: fileURL,
                                            folderID: folder.id,
                                            rootURL: folderURL ?? fileURL,
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
        .task(id: folder.id) {
            await enumerate()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { viewerIndex != nil },
                set: { if !$0 { viewerIndex = nil } }
            )
        ) {
            if let viewerBinding, let folderURL {
                LANFolderViewerScreen(
                    files: files,
                    folderID: folder.id,
                    rootURL: folderURL,
                    index: viewerBinding
                )
            }
        }
        .fullScreenCover(isPresented: $isShowingSlideshow) {
            if let folderURL {
                LANFolderSlideshowScreen(
                    files: files,
                    folderID: folder.id,
                    rootURL: folderURL
                )
            }
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
    }

    private func enumerate() async {
        // Re-entry replays the session cache: hitting the share again was
        // stacking a second full traversal on top of the first one.
        if let cached = LANFolderSessionCache.files(for: folder.id) {
            files = cached
            isEnumerating = false
            return
        }

        isEnumerating = files.isEmpty
        enumerateError = nil
        let album = folder
        // Resolve + activate + enumerate can each block against a dead or
        // slow share; cap the whole pass so the screen never spins forever.
        let outcome: EnumerationResult? = await LANFolderTimeout.run(seconds: 20) {
            guard let url = LANFolderLibrary.resolve(album) else {
                return EnumerationResult(url: nil, files: nil)
            }
            // Hold the security scope for the whole session; re-acquiring it
            // on every visit stalled the album behind provider round trips.
            LANFolderScopeManager.shared.activate(id: album.id, url: url)
            return EnumerationResult(
                url: url,
                files: LANFolderImageLoader.enumerateImageFiles(under: url)
            )
        }
        if let outcome, let url = outcome.url, let enumerated = outcome.files {
            folderURL = url
            files = enumerated
            LANFolderSessionCache.store(files: enumerated, for: album.id)
        } else {
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

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .tint(.secondary)
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
        let fileURL = files[index]
        ZStack {
            Color.black
                .opacity(1 - Double(dismissProgress) * 0.7)
                .ignoresSafeArea()

            LANFolderImageView(
                url: fileURL,
                folderID: folderID,
                rootURL: rootURL,
                maxPixelSize: 2048
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(dragOffset)
                .scaleEffect(1 - dismissProgress * 0.08)
                .contentShape(Rectangle())
                .gesture(pullDownGesture)

            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { step(-1) }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { step(1) }
            }

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
                    Text(fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .opacity(Double(1 - dismissProgress))
        }
    }

    private func step(_ direction: Int) {
        let next = index + direction
        guard files.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            index = next
        }
    }

    private var pullDownGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) * 1.15
                else { return }
                dragOffset = CGSize(
                    width: value.translation.width * 0.18,
                    height: max(0, value.translation.height)
                )
            }
            .onEnded { value in
                let shouldDismiss = value.translation.height > 150
                    || value.predictedEndTranslation.height > 280
                if shouldDismiss {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = .zero
                    }
                }
            }
    }
}

// MARK: - Slideshow

/// Single visible page advanced by a one-way controller with a crossfade —
/// same architecture rule as the local slideshows, never a rebuilt TabView.
struct LANFolderSlideshowScreen: View {
    let files: [URL]
    let folderID: UUID
    let rootURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var isPaused = false
    @State private var runner: Task<Void, Never>?

    private let interval: TimeInterval = 5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LANFolderImageView(
                url: files[index],
                folderID: folderID,
                rootURL: rootURL,
                maxPixelSize: 2048
            )
                .id(index)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: index)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isPaused.toggle()
                    }
                }

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
                    .accessibilityLabel("结束幻灯片")

                    Spacer()

                    Text("\(index + 1) / \(files.count)")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isPaused.toggle()
                        }
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.headline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel(isPaused ? "继续播放" : "暂停播放")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                HStack {
                    Text(files[index].lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
        .onAppear {
            startRunner()
        }
        .onDisappear {
            runner?.cancel()
            runner = nil
        }
    }

    private func startRunner() {
        guard runner == nil else { return }
        runner = Task { @MainActor in
            while !Task.isCancelled, files.indices.contains(index) {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, !isPaused else { continue }
                withAnimation(.easeInOut(duration: 0.6)) {
                    index = files.indices.contains(index + 1) ? index + 1 : 0
                }
            }
        }
    }
}
