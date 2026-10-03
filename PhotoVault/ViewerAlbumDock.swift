import Photos
import SwiftUI

/// A stationary destination strip: page the photo, then add it with one tap.
/// Both viewers use this view, including the same pins and recent destinations.
struct ViewerAlbumDock: View {
    let asset: PHAsset?
    @ObservedObject var store: PhotoLibraryStore
    @Binding var isVisible: Bool

    @AppStorage("PhotoVault.viewer.albumDock.filter") private var filter = AlbumDockFilter.recent.rawValue
    @AppStorage("PhotoVault.viewer.albumDock.reversed") private var reversed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var isSearching = false
    @State private var loadedAssetID: String?
    @State private var displayedAssetID: String?
    @State private var memberships = Set<String>()
    @State private var pendingChanges = Set<AlbumDockMutation>()
    @State private var addedAlbumID: String?
    @State private var addedFeedback = 0
    @State private var isCreatingAlbum = false
    @State private var newAlbumName = ""
    @State private var isSavingAlbum = false
    @State private var alert: PhotoVaultAlert?
    @FocusState private var isSearchFocused: Bool

    private var assetID: String? { asset?.localIdentifier }
    private var isReady: Bool { assetID != nil && loadedAssetID == assetID }
    private var selectedFilter: AlbumDockFilter { AlbumDockFilter(rawValue: filter) ?? .recent }

    private var requestKey: AlbumDockRequest {
        AlbumDockRequest(
            assetID: assetID,
            structureRevision: store.albumStructureRevision,
            membershipRevision: store.albumMembershipRevision
        )
    }

    private var displayedAlbums: [PhotoAlbum] {
        let userAlbums = store.albums.filter { $0.kind == .user }
        let byID = Dictionary(uniqueKeysWithValues: userAlbums.map { ($0.id, $0) })
        let candidates: [PhotoAlbum]
        switch selectedFilter {
        case .joined:
            candidates = isReady ? userAlbums.filter { memberships.contains($0.id) } : []
        case .recent:
            let recent = store.recentAlbumIDs.compactMap { byID[$0] }
            // Make the first use useful before any destination history exists.
            candidates = recent.isEmpty ? Array(userAlbums.prefix(24)) : recent
        case .all:
            candidates = userAlbums
        case .starred:
            candidates = store.quickAlbumIDs.compactMap { byID[$0] }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty ? candidates : candidates.filter {
            $0.title.localizedStandardContains(trimmed)
        }
        return reversed ? Array(matches.reversed()) : matches
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    TextField("搜索相册", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit { isSearchFocused = false }
                        .accessibilityIdentifier("album-dock-search-field")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("清除搜索")
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .frame(height: 40)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(displayedAlbums) { album in
                        albumButton(album)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }
            .scrollIndicators(.hidden)
            .frame(height: 82)
            .overlay {
                if displayedAlbums.isEmpty {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .accessibilityIdentifier("viewer-album-dock")
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onChange(of: assetID, initial: true) { _, id in
            displayedAssetID = id
            if loadedAssetID != id { memberships = [] }
            addedAlbumID = nil
        }
        .task(id: requestKey) {
            let requestedID = assetID
            guard let asset else {
                loadedAssetID = nil
                memberships = []
                return
            }
            if loadedAssetID != requestedID {
                memberships = []
                addedAlbumID = nil
            }
            let result = await store.albumMembershipIDs(for: asset)
            guard !Task.isCancelled, requestedID == displayedAssetID else { return }
            memberships = result
            loadedAssetID = requestedID
        }
        .alert("新建相册", isPresented: $isCreatingAlbum) {
            TextField("相册名称", text: $newAlbumName)
            Button("取消", role: .cancel) {}
            Button("创建并加入") { createAlbum() }
                .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("创建相册并加入当前照片。")
        }
        .alert(item: $alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(AlbumDockFilter.allCases) { item in
                Button {
                    filter = item.rawValue
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: selectedFilter == item ? .bold : .regular))
                        .padding(.horizontal, 6)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if selectedFilter == item {
                                Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
                            }
                        }
                }
                .accessibilityIdentifier("album-dock-filter-\(item.id)")
                .accessibilityAddTraits(selectedFilter == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if !isReady && asset != nil {
                ProgressView().controlSize(.mini).frame(width: 16)
            }
            headerAction("arrow.up.arrow.down", label: "反转相册顺序", id: "album-dock-sort") {
                reversed.toggle()
            }
            headerAction("magnifyingglass", label: "搜索相册", id: "album-dock-search") {
                isSearching.toggle()
                isSearchFocused = isSearching
                if !isSearching { query = "" }
            }
            headerAction("plus", label: "新建相册", id: "album-dock-create") {
                newAlbumName = ""
                isCreatingAlbum = true
            }
            .disabled(asset == nil || isSavingAlbum)
            headerAction("xmark", label: "收起相册快捷栏", id: "album-dock-close") {
                isVisible = false
            }
        }
        .padding(.horizontal, 6)
    }

    private func headerAction(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 32, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func albumButton(_ album: PhotoAlbum) -> some View {
        let joined = isReady && memberships.contains(album.id)
        let pending = assetID.map { pendingChanges.contains(AlbumDockMutation(assetID: $0, albumID: album.id)) } ?? false
        return Menu {
            Button {
                store.toggleQuickAlbum(album.id)
            } label: {
                Label(store.isQuickAlbum(album.id) ? "取消星标" : "设为星标", systemImage: "star")
            }
            if joined {
                Button(role: .destructive) { remove(from: album) } label: {
                    Label("从此相册移出", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            VStack(spacing: 4) {
                Color.secondary.opacity(0.15)
                    .frame(width: 48, height: 48)
                    .overlay {
                        if let preview = album.previewAsset {
                            AssetImageView(
                                asset: preview,
                                targetSize: CGSize(width: 160, height: 160),
                                cacheResult: true,
                                cacheScope: .albumThumbnail,
                                usesPhotoKitCaching: false
                            )
                        } else {
                            Image(systemName: album.symbolName).foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if pending {
                            ProgressView().tint(.white).padding(8).background(.black.opacity(0.5), in: Circle())
                        } else if joined {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .shadow(radius: 2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if store.isQuickAlbum(album.id) {
                            Image(systemName: "star.fill").font(.system(size: 9))
                                .foregroundStyle(.yellow).shadow(radius: 1).padding(3)
                        }
                    }
                    .overlay {
                        AlbumDockAddedFeedback(
                            trigger: addedFeedback, isActive: addedAlbumID == album.id, reduceMotion: reduceMotion
                        )
                    }
                Text(album.title)
                    .font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(width: 64, height: 27, alignment: .top)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        } primaryAction: {
            add(to: album)
        }
        .disabled(!isReady || pending)
        .accessibilityLabel(album.title)
        .accessibilityValue(pending ? "正在保存" : joined ? "已加入" : "未加入")
        .accessibilityHint(joined ? "长按可移出相册或设置星标" : "点一下加入此相册")
        .accessibilityIdentifier("album-dock-album-\(album.id)")
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "没有匹配的相册" }
        if !isReady && selectedFilter == .joined { return "正在读取相册归属…" }
        switch selectedFilter {
        case .joined: return "这张照片还没有加入相册"
        case .starred: return "长按相册设为星标，也可以在相册选择器中标记"
        case .recent, .all: return "点右上角 + 创建第一个相册"
        }
    }

    private func add(to album: PhotoAlbum) {
        guard isReady, let asset, !memberships.contains(album.id) else { return }
        let mutation = AlbumDockMutation(assetID: asset.localIdentifier, albumID: album.id)
        guard pendingChanges.insert(mutation).inserted else { return }
        store.addAssets([asset], to: album) { result in
            pendingChanges.remove(mutation)
            switch result {
            case .success:
                if displayedAssetID == mutation.assetID {
                    memberships.insert(album.id)
                    addedAlbumID = album.id
                    addedFeedback += 1
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failure(let error):
                alert = PhotoVaultAlert(title: "加入相册失败", message: error.localizedDescription)
            }
        }
    }

    private func remove(from album: PhotoAlbum) {
        guard isReady, let asset else { return }
        let mutation = AlbumDockMutation(assetID: asset.localIdentifier, albumID: album.id)
        guard pendingChanges.insert(mutation).inserted else { return }
        store.removeAssets([asset], from: album) { result in
            pendingChanges.remove(mutation)
            switch result {
            case .success:
                if displayedAssetID == mutation.assetID { memberships.remove(album.id) }
            case .failure(let error):
                alert = PhotoVaultAlert(title: "移出相册失败", message: error.localizedDescription)
            }
        }
    }

    private func createAlbum() {
        guard let asset, !isSavingAlbum else { return }
        isSavingAlbum = true
        store.createAlbum(named: newAlbumName, containing: [asset]) { result in
            isSavingAlbum = false
            switch result {
            case .success:
                filter = AlbumDockFilter.all.rawValue
                query = ""
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failure(let error):
                alert = PhotoVaultAlert(title: "创建相册失败", message: error.localizedDescription)
            }
        }
    }
}

private enum AlbumDockFilter: String, CaseIterable, Identifiable {
    case joined = "已加入", recent = "最近", all = "全部", starred = "星标"
    var id: String {
        switch self {
        case .joined: "joined"
        case .recent: "recent"
        case .all: "all"
        case .starred: "starred"
        }
    }
}

private struct AlbumDockRequest: Equatable {
    let assetID: String?
    let structureRevision: Int
    let membershipRevision: Int
}

private struct AlbumDockMutation: Hashable {
    let assetID: String
    let albumID: String
}

private struct AlbumDockAddedFeedback: View {
    let trigger: Int
    let isActive: Bool
    let reduceMotion: Bool

    var body: some View {
        Text("+1").font(.title2.bold()).foregroundStyle(.white).shadow(radius: 2)
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { content, opacity in
                content.opacity(isActive ? opacity : 0).offset(y: reduceMotion ? 0 : -12 * opacity)
            } keyframes: { _ in
                LinearKeyframe(1, duration: 0.1)
                LinearKeyframe(1, duration: 0.5)
                LinearKeyframe(0, duration: 0.3)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Feedback belongs to this viewer's current asset; it never intercepts paging.
struct ViewerFavoriteFeedback: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let disablesMotion = reduceMotion
        return Image(systemName: "heart.fill")
            .font(.system(size: 84)).foregroundStyle(.red).shadow(radius: 5)
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { content, progress in
                content.opacity(progress).scaleEffect(disablesMotion ? 1 : 0.8 + 0.2 * progress)
            } keyframes: { _ in
                LinearKeyframe(1, duration: 0.12)
                LinearKeyframe(1, duration: 0.35)
                LinearKeyframe(0, duration: 0.3)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
