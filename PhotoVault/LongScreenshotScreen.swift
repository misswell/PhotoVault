import CoreTransferable
import Photos
import UniformTypeIdentifiers
import PhotosUI
import SwiftUI

/// The receiver's file is only valid during the transfer callback. Copy it to
/// an owned URL and release it automatically if selection is cancelled.
final class LongScreenshotTransferFile: Transferable, @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit {
        let url = url
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
    }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoVault-Transfer-\(UUID())")
            try FileManager.default.copyItem(at: received.file, to: url)
            return LongScreenshotTransferFile(url: url)
        }
    }
}

@MainActor
final class LongScreenshotModel: ObservableObject {
    @Published var inputs: [LongScreenshotInput] = []
    @Published var thumbnails: [UUID: UIImage] = [:]
    @Published var recipe = LongScreenshotRecipe()
    @Published var output: LongScreenshotOutput?
    @Published var preview: UIImage?
    @Published var error: String?
    @Published var importing = false
    @Published var working = false
    @Published var sharing = false
    @Published var saving = false
    @Published var saved = false
    private(set) var directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoVault-LongScreenshot-\(UUID())", isDirectory: true)
    private var revision = UUID()
    private var importedItems: [PhotosPickerItem] = []

    deinit {
        let directory = directory
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
    }

    func importItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, items != importedItems else { return }
        invalidate(); importing = true
        let key = revision
        var next: [LongScreenshotInput] = [], images: [UUID: UIImage] = [:]
        defer { if revision == key { importing = false } }
        do {
            for item in items {
                try Task.checkCancellation()
                guard let file = try await item.loadTransferable(type: LongScreenshotTransferFile.self) else { throw LongScreenshotError.unreadable }
                let input = try await LongScreenshotEngine.shared.importFile(file.url, directory: directory)
                next.append(input)
                images[input.id] = try await LongScreenshotEngine.shared.thumbnail(input)
            }
            try Task.checkCancellation()
            let previous = inputs.map(\.url)
            inputs = next; thumbnails = images; importedItems = items
            recipe.overlaps = Array(repeating: 0, count: next.count)
            await LongScreenshotEngine.shared.removeFiles(previous)
        } catch {
            await LongScreenshotEngine.shared.removeFiles(next.map(\.url))
            if !(error is CancellationError), revision == key { self.error = error.localizedDescription }
        }
    }

    #if DEBUG
    func loadFixture() async {
        guard inputs.isEmpty else { return }
        do {
            for data in try LongScreenshotEngine.fixtureData() {
                let input = try await LongScreenshotEngine.shared.importImage(data, directory: directory)
                inputs.append(input)
                thumbnails[input.id] = try await LongScreenshotEngine.shared.thumbnail(input)
            }
            recipe.overlaps = [0, 0]
        } catch { self.error = error.localizedDescription }
    }
    #endif

    func invalidate() {
        if let url = output?.url { Task { await LongScreenshotEngine.shared.removeFiles([url]) } }
        revision = UUID(); output = nil; preview = nil; saved = false; error = nil
    }

    func move(from: IndexSet, to: Int) {
        inputs.move(fromOffsets: from, toOffset: to)
        recipe.overlaps = Array(repeating: 0, count: inputs.count); invalidate()
    }

    func remove(at offsets: IndexSet) {
        let urls = offsets.map { inputs[$0].url }
        inputs.remove(atOffsets: offsets)
        Task { await LongScreenshotEngine.shared.removeFiles(urls) }
        recipe.overlaps = Array(repeating: 0, count: inputs.count); invalidate()
    }

    func build(automatic: Bool) async {
        invalidate()
        let key = revision, inputs = inputs
        var settings = recipe
        working = true
        var produced: URL?
        defer {
            if revision == key { working = false }
            if let produced, output?.url != produced { Task { await LongScreenshotEngine.shared.removeFiles([produced]) } }
        }
        do {
            if automatic {
                settings.overlaps = try await LongScreenshotEngine.shared.detectOverlaps(inputs, recipe: settings)
            }
            let rendered = try await LongScreenshotEngine.shared.render(inputs, recipe: settings, directory: directory)
            produced = rendered.url
            let frame = try await LongScreenshotEngine.shared.preview(rendered)
            try Task.checkCancellation()
            guard revision == key else { return }
            recipe = settings; output = rendered; preview = frame
        } catch is CancellationError { } catch { if revision == key { self.error = error.localizedDescription } }
    }

    func save() async {
        guard let output, !saving, !saved else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            // Generated images use a regular album; PhotoKit does not permit
            // apps to assign the system's screenshot media subtype.
            let album = await Task.detached(priority: .userInitiated) {
                let options = PHFetchOptions(); options.fetchLimit = 1
                options.predicate = NSPredicate(format: "localizedTitle == %@", "长截图")
                return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
            }.value
            try Task.checkCancellation()
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: output.url, options: nil)
                if let asset = request.placeholderForCreatedAsset {
                    let collection = album.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                        ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "长截图")
                    collection.addAssets([asset] as NSArray)
                }
            }
            saved = true
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    func share() {
        guard let output, !sharing else { return }
        sharing = true; error = nil
        // Share owns a separate file, so leaving this screen cannot invalidate
        // the activity controller's URL. Its dismissal owns cleanup.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("长截图-\(UUID()).png")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: output.url, to: copy) }.value
                ActivityPresenter.present(items: [copy]) { [weak self] in
                    try? FileManager.default.removeItem(at: copy)
                    Task { @MainActor [weak self] in self?.sharing = false }
                }
            } catch { self.sharing = false; self.error = error.localizedDescription }
        }
    }
}

struct LongScreenshotScreen: View {
    @StateObject private var model = LongScreenshotModel()
    @State private var items: [PhotosPickerItem] = []
    @State private var buildTask: Task<Void, Never>?
    @State private var editMode: EditMode = .inactive
    private var busy: Bool { model.importing || model.working || model.saving || model.sharing }

    var body: some View {
        let pickerTitle = model.inputs.isEmpty ? "选择截图" : "重新选择截图"
        List {
            Section {
                PhotosPicker(selection: $items, maxSelectionCount: 12, selectionBehavior: .ordered, matching: .images) {
                    Label(pickerTitle, systemImage: "photo.on.rectangle.angled")
                }
                .accessibilityIdentifier("long-screenshot-picker")
                .disabled(busy)
                Text("按从上到下的顺序选择 2–12 张截图，点“排序”后拖动把手调整顺序。原图会保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.inputs.count == 1 {
                Section { Text("再选择至少一张截图，即可开始拼接。") }
            }
            if !model.inputs.isEmpty {
                Section("拼接顺序") {
                    ForEach(Array(model.inputs.enumerated()), id: \.element.id) { index, input in
                        HStack {
                            if let image = model.thumbnails[input.id] {
                                Image(uiImage: image).resizable().scaledToFit().frame(width: 42, height: 64)
                            }
                            VStack(alignment: .leading) {
                                Text("第 \(index + 1) 张")
                                Text("\(input.width) × \(input.height)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { model.move(from: $0, to: $1) }
                    .onDelete { model.remove(at: $0) }
                }
                .disabled(busy)
                Section {
                    trimSlider("每张去掉顶部", value: $model.recipe.header, range: 0...0.25)
                    trimSlider("每张去掉底部", value: $model.recipe.footer, range: 0...0.25)
                    Button("自动识别接缝并预览", systemImage: "wand.and.stars") { build(automatic: true) }
                        .accessibilityIdentifier("long-screenshot-auto")
                    Button("直接拼接并预览", systemImage: "rectangle.portrait.on.rectangle.portrait") { build(automatic: false) }
                        .accessibilityIdentifier("long-screenshot-build")
                    if model.inputs.count > 1 {
                        ForEach(1..<model.inputs.count, id: \.self) { index in
                            trimSlider("第 \(index + 1) 张去掉重复顶部", value: Binding(
                                get: { model.recipe.overlaps.indices.contains(index) ? model.recipe.overlaps[index] : 0 },
                                set: { value in
                                    if model.recipe.overlaps.indices.contains(index) { model.recipe.overlaps[index] = value }
                                }), range: 0...0.95)
                        }
                    }
                } footer: {
                    Text("自动识别适合带有重叠内容的滚动截图。固定顶栏、底栏可先裁掉；接缝不准确时调整重复顶部，再点直接拼接。")
                }
                .disabled(busy || model.inputs.count < 2)
            }
            if let output = model.output, let image = model.preview {
                Section {
                    NavigationLink {
                        LongScreenshotPreviewScreen(output: output, thumbnail: image)
                    } label: {
                        VStack {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 220)
                            Text("查看长截图预览")
                        }
                    }
                    .accessibilityIdentifier("long-screenshot-preview").accessibilityLabel("查看长截图预览").disabled(busy)
                    Text("\(output.width) × \(output.height) · PNG\(output.reduced ? " · 已适配长图尺寸" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.saved ? "已保存到「长截图」相册" : "保存到「长截图」相册", systemImage: model.saved ? "checkmark" : "square.and.arrow.down") {
                        // An accepted save completes even if navigation changes.
                        Task { await model.save() }
                    }.disabled(busy || model.saved).accessibilityIdentifier("long-screenshot-save")
                    Button("分享长截图", systemImage: "square.and.arrow.up") { model.share() }.disabled(busy)
                }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("长截图")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy { ProgressView().controlSize(.small) }
                else {
                    Button(editMode.isEditing ? "完成排序" : "排序") {
                        editMode = editMode.isEditing ? .inactive : .active
                    }.disabled(model.inputs.count < 2)
                }
            }
        }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("--pv-long-screenshot-fixture") { await model.loadFixture() } }
        #endif
        .task(id: items) { await model.importItems(items) }
        .onDisappear { buildTask?.cancel() }
    }

    private func trimSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title).font(.subheadline); Spacer(); Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; model.invalidate() }), in: range, step: 0.01)
        }
    }

    private func build(automatic: Bool) {
        editMode = .inactive
        buildTask?.cancel()
        buildTask = Task { await model.build(automatic: automatic) }
    }
}


private struct LongScreenshotPreviewScreen: View {
    let output: LongScreenshotOutput
    let thumbnail: UIImage
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Image(uiImage: image ?? thumbnail).resizable()
                    .aspectRatio(CGFloat(output.width) / CGFloat(output.height), contentMode: .fit)
                    .frame(width: geometry.size.width)
            }
        }
        .navigationTitle("长截图预览").navigationBarTitleDisplayMode(.inline)
        .toolbar { if image == nil && error == nil { ToolbarItem(placement: .topBarTrailing) { ProgressView().controlSize(.small) } } }
        .overlay(alignment: .bottom) { if let error { Text(error).font(.footnote).padding().background(.regularMaterial) } }
        .task {
            do {
                let frame = try await LongScreenshotEngine.shared.fullPreview(output)
                try Task.checkCancellation(); image = frame
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}
