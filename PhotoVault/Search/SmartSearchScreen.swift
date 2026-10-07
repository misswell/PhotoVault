//
//  SmartSearchScreen.swift
//  PhotoVault
//
//  The smart-search screen: a query field, ranked results, and the index state.
//
//  This screen is the only place the AI index is filled from. Indexing 100k
//  photos is hours of work, so it does not start at app launch: a user who never
//  opens search should not pay for it. Opening the screen is the signal that the
//  feature is wanted.
//
//  Results are ranked, so they are rendered from an *ordered* array rather than
//  the shared `PhotoGridView`. That view is built on `PHFetchResult` and cannot
//  express a ranking, and the ranking is the entire output of the search.
//

import Photos
import SwiftUI

struct SmartSearchScreen: View {
    @State private var model = SmartSearchModel()
    @State private var downloads = SearchModelDownloadStore.shared
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    /// The library store, needed only to hand the shared detail viewer over to
    /// the same machinery the grids use -- so paging, zoom, share, delete and
    /// the filmstrip all behave identically to a photo opened from the library.
    @ObservedObject var store: PhotoLibraryStore

    /// Same navigator the photo grids use: whichever screen opens the viewer,
    /// it is one shared push/pop architecture with session-scoped transition
    /// state. The results grid is a SwiftUI `LazyVGrid`, so there is no
    /// `PhotoGridTransitionCoordinator` here and UIKit falls back to its
    /// default morph — but paging, dismissal and interruption behaviour are
    /// identical to the library.
    @StateObject private var viewerNavigator = PhotoViewerNavigator()

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 2)]

    init(store: PhotoLibraryStore) {
        self.store = store
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            content
        }
        .navigationTitle("智能搜索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $draft,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "描述你想找的照片"
        )
        .onSubmit(of: .search) { model.search(draft) }
        .task(id: downloads.isInstalled) { await model.prepare() }
        .background(
            PhotoViewerNavigationAnchor(navigator: viewerNavigator)
                .frame(width: 0, height: 0)
        )
    }

    // MARK: - Status

    /// A single line that says what the index is doing.
    ///
    /// It is inline rather than an overlay because this project's convention is
    /// that progress never changes layout: an overlay here would cover results
    /// the moment they arrived.
    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isIndexing, let progress = model.indexProgress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 140)
                    .accessibilityLabel("正在建立索引")
                Text(verbatim: "\(Int(progress.fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(.secondary)
            }

            Text(model.statusMessage ?? "准备中…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if model.isIndexing {
                Button("暂停") { model.cancelIndexing() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            } else if model.isReady, model.indexProgress?.isComplete != true {
                Button(model.indexProgress == nil ? "建立索引" : "继续建立索引") { model.startIndexing() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .modelRequired:
            ScrollView {
                SearchModelDownloadControl()
                    .padding(24)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        case .preparingModel:
            ContentUnavailableView(
                "正在载入模型",
                systemImage: "cpu",
                description: Text("首次载入需要几秒钟，之后会常驻内存。")
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("无法搜索", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试载入") { Task { await model.prepare() } }
            }
        default:
            if model.query.isEmpty {
                emptyState
            } else if model.assets.isEmpty, case .results = model.phase {
                ContentUnavailableView.search(text: model.query)
            } else {
                resultsGrid
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "搜索照片内容",
            systemImage: "sparkle.magnifyingglass",
            description: Text(
                "描述照片里有什么，例如「海边的猫」「2023 年拍的发票」「北京的夜景」。\n"
                + "全部在本机完成，照片不会离开设备。"
            )
        )
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(model.assets.enumerated()), id: \.element.localIdentifier) { pair in
                    Button {
                        open(pair.element, at: pair.offset)
                    } label: {
                        AssetImageView(
                            asset: pair.element,
                            targetSize: CGSize(width: 240, height: 240),
                            contentMode: .aspectFill,
                            requestPriority: .visibleGrid,
                            cacheResult: true,
                            cacheScope: .gridThumbnail,
                            usesPhotoKitCaching: true,
                            onLoadStateChange: nil,
                            canvasBackground: nil
                        )
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            model.search(similarTo: pair.element)
                        } label: {
                            Label("查找相似照片", systemImage: "square.on.square")
                        }
                    }
                    .accessibilityLabel("第 \(pair.offset + 1) 个结果")
                }
            }
            .padding(2)

            if let diagnostics = model.diagnostics {
                diagnosticsFooter(diagnostics)
            }
        }
        // Cancelling the in-flight query when the screen goes away keeps a slow
        // scan from publishing into a view that no longer exists.
        .onDisappear { model.clear() }
    }

    /// Opens the shared viewer at the tapped result, paging in **relevance order**.
    ///
    /// `fetchAssets(withLocalIdentifiers:)` is the only way to turn ranked index
    /// rows back into `PHAsset`s, but its result order is unrelated to the order
    /// of the identifiers passed in -- Apple documents it as unspecified, and
    /// measurement agrees (requested `AA91AB0D, F80027A9`, returned
    /// `106E99A1, 99D53A1F`). So the fetch is used purely as a lookup table and
    /// the ranking is rebuilt explicitly: the viewer then swipes through the
    /// results best-first instead of jumping around the library.
    ///
    /// Rows whose asset has since been deleted simply drop out, and the tapped
    /// asset is located by identifier rather than trusting `rank`, so a stale hit
    /// cannot open the wrong photo.
    private func open(_ asset: PHAsset, at rank: Int) {
        let identifiers = model.hits.map(\.assetID)
        guard !identifiers.isEmpty else { return }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byIdentifier: [String: PHAsset] = [:]
        byIdentifier.reserveCapacity(fetched.count)
        fetched.enumerateObjects { candidate, _, _ in
            byIdentifier[candidate.localIdentifier] = candidate
        }

        let ranked = identifiers.compactMap { byIdentifier[$0] }
        guard let resolved = ranked.firstIndex(where: {
            $0.localIdentifier == asset.localIdentifier
        }) else { return }

        viewerNavigator.open(
            request: PhotoViewerRequest(
                index: resolved,
                assetIdentifier: asset.localIdentifier,
                previewImage: nil
            ),
            // No grid transition coordinator: the results are a SwiftUI grid,
            // so the zoom has no cell to morph from and UIKit uses its default.
            gridTransitionCoordinator: nil,
            makeRootView: { state, onDismiss in
                AnyView(
                    PhotoViewerView(
                        // Ranked, not a `PHFetchResult`: the viewer pages in
                        // relevance order. See the note on `open(_:at:)`.
                        assets: .ordered(ranked),
                        initialIndex: state.currentIndex,
                        store: store,
                        album: nil,
                        initialPreviewImage: nil,
                        initialAssetIdentifier: asset.localIdentifier,
                        transitionState: state,
                        onDismissRequested: onDismiss
                    )
                )
            }
        )
    }

    /// What the engine actually did, shown rather than hidden.
    ///
    /// A search that quietly dropped an unresolved place, or fell back to
    /// metadata-only, looks like a worse search. Saying so is the difference
    /// between a limitation the user can work around and one that looks like a
    /// bug in the model.
    private func diagnosticsFooter(_ diagnostics: PhotoSearchDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                String(
                    format: "%d 个候选 · 打分 %d · %.0f ms",
                    diagnostics.candidateCount,
                    diagnostics.scoredCount,
                    diagnostics.elapsedSeconds * 1000
                )
            )
            ForEach(diagnostics.warnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
