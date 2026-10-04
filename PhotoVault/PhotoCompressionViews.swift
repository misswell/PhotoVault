import AVFoundation
import Photos
import SwiftUI

struct PhotoCompressionSheet: View {
    let asset: PHAsset
    let data: Data
    let recipe: PhotoEditRecipe
    @ObservedObject var store: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var options = PhotoExportOptions()
    @State private var rendered: RenderedPhoto?
    @State private var sourceImage: UIImage?
    @State private var resultImage: UIImage?
    @State private var busy = false
    @State private var rendering = true
    @State private var saved: CompressionRecord?
    @State private var error: String?
    @State private var showHistory = false
    @State private var compareOriginal = false
    private var live: Bool { asset.mediaSubtypes.contains(.photoLive) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        preview(sourceImage, title: "原文件", bytes: Int64(data.count), width: asset.pixelWidth, height: asset.pixelHeight)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        preview(compareOriginal ? sourceImage : resultImage, title: saved == nil ? "压缩后" : "已保存", bytes: rendered.map { Int64($0.data.count) }, width: rendered?.width ?? 0, height: rendered?.height ?? 0)
                    }
                    .frame(height: 250)
                    .onLongPressGesture(minimumDuration: 0.01, pressing: { compareOriginal = $0 }, perform: {})
                    if let rendered {
                        let delta = Int64(data.count) - Int64(rendered.data.count)
                        LabeledContent(delta >= 0 ? "减少" : "增加", value: ByteCountFormatter.string(fromByteCount: abs(delta), countStyle: .file))
                        if delta < 0 { Text("当前设置比原文件更大，可降低画质或分辨率。").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                Section("画质") {
                    Slider(value: $options.quality, in: 0.1...1, step: 0.05)
                        .disabled(options.format == .png || busy || live)
                        .accessibilityIdentifier("compression-quality")
                    HStack {
                        Text("更小文件").foregroundStyle(.secondary)
                        Spacer()
                        Text(options.format == .png ? "无损" : options.quality.formatted(.percent.precision(.fractionLength(0))))
                    }.font(.caption)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach([0.1, 0.3, 0.5, 0.7, 1.0], id: \.self) { value in
                                Button(value.formatted(.percent.precision(.fractionLength(0)))) { options.quality = value }
                                    .buttonStyle(.bordered).tint(options.quality == value ? .accentColor : .secondary)
                            }
                            Button("推荐") { options.quality = 0.7; options.format = .heic }
                                .buttonStyle(.bordered)
                        }
                    }.disabled(busy || live || options.format == .png)
                    Picker("格式", selection: $options.format) {
                        ForEach(PhotoExportFormat.allCases) { format in Text(format == .png ? "PNG · 无损" : format.title).tag(format) }
                    }.disabled(busy || live)
                }
                Section("分辨率") {
                    Picker("最长边", selection: $options.maxDimension) {
                        ForEach(PhotoExportOptions.resolutions, id: \.self) { value in Text(PhotoExportOptions.resolutionTitle(value)).tag(value) }
                    }.disabled(busy || live)
                    Text("保持比例，只缩小，不放大。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if live {
                        Text("Live Photo 将保存可还原的动态编辑，保留照片和视频配对。画质与分辨率由系统管理，此处大小只代表静态预览。")
                    } else {
                        Text("另存保留拍摄日期、位置、收藏、相册和备注。覆盖编辑可在系统照片中还原，系统会保留原片，因此不等同于释放原片空间。")
                    }
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("设置画质")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(busy) } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if busy { ProgressView("正在保存…") }
                    if rendering { ProgressView("正在计算实际文件大小…") }
                    HStack {
                        Button(live ? "保存动态编辑" : "压缩另存") { save(replace: live) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("compression-save-copy")
                        if !live {
                            Button("覆盖编辑") { save(replace: true) }.buttonStyle(.bordered).disabled(options.format == .png)
                                .accessibilityIdentifier("compression-replace")
                        }
                        Button("查看对比") { showHistory = true }.buttonStyle(.bordered).disabled(saved == nil)
                    }.disabled(busy || rendering || rendered == nil)
                    if options.format == .png { Text("PNG 无损结果使用另存保存。").font(.caption).foregroundStyle(.secondary) }
                    if saved != nil { Label("已保存到照片库", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption).accessibilityIdentifier("compression-saved") }
                }.padding().frame(maxWidth: .infinity).background(.bar)
            }
        }
        .interactiveDismissDisabled(busy)
        .task {
            if let source = try? await PhotoRenderWorker.shared.render(data: data, recipe: .init(), options: .init(), preview: true) {
                sourceImage = UIImage(data: source.data)
            }
        }
        .task(id: options) {
            rendering = true; saved = nil
            do {
                try await Task.sleep(for: .milliseconds(180))
                let result = try await PhotoRenderWorker.shared.render(data: data, recipe: recipe, options: options)
                try Task.checkCancellation()
                rendered = result
                var previewOptions = options; previewOptions.maxDimension = 1400
                let small = try await PhotoRenderWorker.shared.render(data: result.data, recipe: .init(), options: previewOptions, preview: true)
                try Task.checkCancellation()
                resultImage = UIImage(data: small.data); rendering = false
            } catch is CancellationError {} catch { rendering = false; self.error = error.localizedDescription }
        }
        .sheet(isPresented: $showHistory) { NavigationStack { CompressionHistoryScreen(store: store) } }
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func preview(_ image: UIImage?, title: String, bytes: Int64?, width: Int, height: Int) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Color.clear.overlay { if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView() } }
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "计算中…").font(.headline).monospacedDigit()
            Text("\(width) × \(height)").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func save(replace: Bool) {
        guard !busy, let rendered else { return }
        busy = true
        let albums = store.userAlbums(containing: asset)
        Task {
            defer { busy = false }
            do {
                saved = try await PhotoEditSaver.save(rendered, sourceData: data, asset: asset, recipe: recipe, options: options, replace: replace, albums: albums)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CompressionHistoryScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    @ObservedObject private var workspace = PhotoWorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: CompressionRecord?
    @State private var error: String?
    @State private var deleting = false
    var body: some View {
        List {
            ForEach(workspace.compressionHistory) { record in
                Button { selected = record } label: {
                    HStack(spacing: 12) {
                        if let asset = WorkspacePhotoAccess.asset(record.resultID) { WorkspaceThumbnail(asset: asset).frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 10)) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.primary)
                            Text("\(ByteCountFormatter.string(fromByteCount: record.originalBytes, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: record.resultBytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                            if record.replaced { Text("可还原编辑").font(.caption2).foregroundStyle(.blue) }
                        }
                    }
                }.accessibilityIdentifier("compression-history-record")
            }
        }
        .overlay { if workspace.compressionHistory.isEmpty { ContentUnavailableView("还没有压缩记录", systemImage: "arrow.down.right.and.arrow.up.left", description: Text("在照片详情中打开编辑并保存，结果会显示在这里。")) } }
        .navigationTitle("查看对比")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .sheet(item: $selected) { record in
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            ComparisonAssetView(id: record.originalID, original: record.replaced, label: "原文件")
                            ComparisonAssetView(id: record.resultID, original: false, label: "压缩文件")
                        }.frame(height: 340)
                        LabeledContent("原文件", value: ByteCountFormatter.string(fromByteCount: record.originalBytes, countStyle: .file))
                        LabeledContent("压缩文件", value: ByteCountFormatter.string(fromByteCount: record.resultBytes, countStyle: .file))
                        if record.replaced {
                            Button("还原原片") { revert(record) }.buttonStyle(.bordered).disabled(deleting).accessibilityIdentifier("compression-revert")
                        } else {
                            HStack {
                                Button("删除原文件", role: .destructive) { delete(record.originalID) }
                                Button("删除压缩文件", role: .destructive) { delete(record.resultID) }
                            }.buttonStyle(.bordered).disabled(deleting)
                        }
                        if deleting { ProgressView() }
                    }.padding()
                }
                .navigationTitle("压缩前后对比").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selected = nil } } }
                .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
            }
        }
    }
    private func delete(_ id: String) {
        guard let asset = WorkspacePhotoAccess.asset(id) else { return }
        deleting = true
        store.deleteAssets([asset]) { result in
            deleting = false
            if case .failure(let error) = result { self.error = error.localizedDescription }
            if WorkspacePhotoAccess.asset(id) == nil { selected = nil }
        }
    }
    private func revert(_ record: CompressionRecord) {
        guard let asset = WorkspacePhotoAccess.asset(record.resultID) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do { try await PHPhotoLibrary.shared().performChanges { @Sendable in PHAssetChangeRequest(for: asset).revertAssetContentToOriginal() }; selected = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ComparisonAssetView: View {
    let id: String
    let original: Bool
    let label: String
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        VStack {
            Text(label).font(.caption)
            Color.clear.overlay {
                if let asset = WorkspacePhotoAccess.asset(id), asset.mediaType == .video {
                    VideoAssetViewer(asset: asset, requestPriority: .viewer, transparentCanvas: false, onReady: { _ in })
                } else if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                else { ProgressView() }
            }
        }
        .task(id: id) {
            guard let asset = WorkspacePhotoAccess.asset(id) else { error = "已删除"; return }
            if asset.mediaType == .video { return }
            do {
                let data = try await WorkspacePhotoAccess.imageData(asset, original: original)
                let result = try await PhotoRenderWorker.shared.render(data: data, recipe: .init(), options: .init(), preview: true)
                try Task.checkCancellation(); image = UIImage(data: result.data)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct WorkspaceThumbnail: View {
    let asset: PHAsset
    var body: some View {
        Color.clear.overlay {
            AssetImageView(asset: asset, targetSize: CGSize(width: 220, height: 220), contentMode: .aspectFill,
                           cacheResult: true, cacheScope: .albumThumbnail, usesPhotoKitCaching: false)
        }.clipped()
    }
}

struct VideoCompressionSheet: View {
    let asset: PHAsset
    @ObservedObject var store: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var resolution = 1920
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false
    @State private var outputDimensions = ""
    @State private var outputBytes: Int64?
    var body: some View {
        NavigationStack {
            Form {
                Section { WorkspaceThumbnail(asset: asset).frame(height: 230); LabeledContent("时长", value: "\(Int(asset.duration)) 秒") }
                Section("分辨率") {
                    Picker("最长边", selection: $resolution) {
                        ForEach(PhotoExportOptions.resolutions, id: \.self) { value in Text(PhotoExportOptions.resolutionTitle(value)).tag(value) }
                    }
                    Text("使用系统视频编码器，保留声音、拍摄时间、位置、收藏和相册。不会放大原视频。").font(.footnote).foregroundStyle(.secondary)
                }
                if saved { Label("已保存到照片库", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("video-compression-saved")
                    LabeledContent("导出分辨率", value: outputDimensions)
                    if let outputBytes { LabeledContent("导出大小", value: ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)) }
                    NavigationLink("查看对比") { CompressionHistoryScreen(store: store) }
                }
            }
            .navigationTitle("压缩视频").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) } }
            .safeAreaInset(edge: .bottom) {
                VStack { if busy { ProgressView("正在导出视频…") }; Button("压缩另存") { compress() }.buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("video-compression-save") }.padding().frame(maxWidth: .infinity).background(.bar)
            }
        }.interactiveDismissDisabled(busy)
        .onChange(of: resolution) { _, _ in saved = false; outputBytes = nil }
        .alert("无法压缩", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func compress() {
        busy = true; saved = false
        let albums = store.userAlbums(containing: asset)
        Task {
            defer { busy = false }
            do {
                let input = try await WorkspacePhotoAccess.editingInput(asset)
                guard let avAsset = input.audiovisualAsset else { throw MediaWorkspaceError.unavailable }
                let targetEdge = resolution == 0 ? max(asset.pixelWidth, asset.pixelHeight) : resolution
                let edge = min(targetEdge, max(asset.pixelWidth, asset.pixelHeight))
                let preset: String = edge <= 854 ? AVAssetExportPreset640x480 : (edge <= 1280 ? AVAssetExportPreset1280x720 : (edge <= 1920 ? AVAssetExportPreset1920x1080 : AVAssetExportPreset3840x2160))
                guard let session = AVAssetExportSession(asset: avAsset, presetName: preset),
                      let track = try await avAsset.loadTracks(withMediaType: .video).first else { throw MediaWorkspaceError.encoding }
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
                guard bounds.width > 0, bounds.height > 0 else { throw MediaWorkspaceError.encoding }
                let scale = min(1, CGFloat(targetEdge) / max(bounds.width, bounds.height))
                let width = max(2, floor(bounds.width * scale / 2) * 2)
                let height = max(2, floor(bounds.height * scale / 2) * 2)
                let composition = AVMutableVideoComposition()
                composition.renderSize = CGSize(width: width, height: height)
                let fps = try await track.load(.nominalFrameRate)
                composition.frameDuration = CMTime(value: 1000, timescale: Int32((min(240, max(1, fps > 0 ? fps : 30)) * 1000).rounded()))
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: try await avAsset.load(.duration))
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(transform
                    .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                    .concatenating(CGAffineTransform(scaleX: width / bounds.width, y: height / bounds.height)), at: .zero)
                instruction.layerInstructions = [layer]; composition.instructions = [instruction]
                session.videoComposition = composition
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                defer { try? FileManager.default.removeItem(at: url) }
                session.metadata = try await avAsset.load(.metadata)
                try await session.export(to: url, as: .mov)
                guard let outputTrack = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { throw MediaWorkspaceError.encoding }
                let outputSize = try await outputTrack.load(.naturalSize)
                let outputTransform = try await outputTrack.load(.preferredTransform)
                let outputBounds = CGRect(origin: .zero, size: outputSize).applying(outputTransform)
                guard outputBounds.width <= bounds.width + 1, outputBounds.height <= bounds.height + 1 else { throw MediaWorkspaceError.encoding }
                outputDimensions = "\(Int(outputBounds.width.rounded())) × \(Int(outputBounds.height.rounded()))"
                let box = CreatedAssetID()
                try await PHPhotoLibrary.shared().performChanges { @Sendable in
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: url, options: nil)
                    request.creationDate = asset.creationDate; request.location = asset.location; request.isFavorite = asset.isFavorite
                    if let placeholder = request.placeholderForCreatedAsset {
                        box.set(placeholder.localIdentifier)
                        for album in albums where album.kind == .user { PHAssetCollectionChangeRequest(for: album.collection)?.addAssets([placeholder] as NSArray) }
                    }
                }
                let bytes = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let sourceBytes: Int64 = (input.audiovisualAsset as? AVURLAsset).flatMap { try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0
                if let id = box.get() { PhotoWorkspaceStore.shared.recordCompression(CompressionRecord(date: .now, originalID: asset.localIdentifier, resultID: id, originalBytes: sourceBytes, resultBytes: bytes, replaced: false)) }
                outputBytes = bytes; saved = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
