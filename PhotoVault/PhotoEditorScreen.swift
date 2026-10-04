import Photos
import SwiftUI
import UIKit

struct PhotoEditorScreen: View {
    let asset: PHAsset
    @ObservedObject var store: PhotoLibraryStore
    @ObservedObject private var workspace = PhotoWorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var preview: UIImage?
    @State private var original: UIImage?
    @State private var thumbnailSource: Data?
    @State private var recipe = PhotoEditRecipe()
    @State private var undo: [PhotoEditRecipe] = []
    @State private var redo: [PhotoEditRecipe] = []
    @State private var sliderStart: PhotoEditRecipe?
    @State private var tab = EditorTab.crop
    @State private var adjustment = PhotoAdjustment.exposure
    @State private var comparing = false
    @State private var isRendering = false
    @State private var showExport = false
    @State private var showSaveLook = false
    @State private var lookName = ""
    @State private var error: String?

    private enum EditorTab: String, CaseIterable, Identifiable {
        case crop = "旋转 / 裁剪", filters = "滤镜", adjustments = "调色"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .crop: "crop.rotate"; case .filters: "camera.filters"; case .adjustments: "slider.horizontal.3" }
        }
    }

    private var previewRecipe: PhotoEditRecipe {
        var result = recipe
        if tab == .crop { result.crop = .full }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ZStack {
                        Color.black
                        if let image = comparing ? original : preview {
                            let ratio = image.size.width / max(1, image.size.height)
                            let width = min(proxy.size.width - 48, proxy.size.height * ratio)
                            let height = width / ratio
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: width, height: height)
                                .overlay {
                                    if tab == .crop && !comparing {
                                        PhotoCropOverlay(crop: $recipe.crop, onBegin: beginSlider, onEnd: endSlider)
                                    }
                                }
                                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        } else { ProgressView("正在读取 iCloud 原图…").tint(.white) }
                        if isRendering { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(16).allowsHitTesting(false) }
                    }
                }
                .accessibilityIdentifier("editor-preview")

                VStack(spacing: 12) { controls }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground))

                HStack(spacing: 16) {
                    ForEach(EditorTab.allCases) { item in
                        Button { tab = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .labelStyle(.iconOnly).font(.title3)
                                .frame(width: 46, height: 46)
                        }
                        .foregroundStyle(tab == item ? .blue : .secondary)
                        .accessibilityLabel(item.rawValue)
                    }
                    Spacer(minLength: 0)
                    Button("压缩 / 保存") { showExport = true }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .disabled(data == nil)
                        .accessibilityIdentifier("editor-export")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .background(.black)
            .navigationTitle("编辑照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { if let previous = undo.popLast() { redo.append(recipe); recipe = previous } } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(undo.isEmpty).accessibilityLabel("撤销")
                    Button { if let next = redo.popLast() { undo.append(recipe); recipe = next } } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(redo.isEmpty).accessibilityLabel("重做")
                    Text("原图对比").font(.caption).padding(8)
                        .background(.thinMaterial, in: Capsule())
                        .onLongPressGesture(minimumDuration: 0.01, pressing: { comparing = $0 }, perform: {})
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { comparing.toggle() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            do {
                let value = try await WorkspacePhotoAccess.imageData(asset)
                try Task.checkCancellation()
                data = value
                let frame = try await PhotoRenderWorker.shared.render(data: value, recipe: .init(), options: .init(), preview: true)
                original = UIImage(data: frame.data)
                thumbnailSource = frame.data
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .task(id: PreviewRequest(dataLoaded: data != nil, recipe: previewRecipe)) {
            guard let data else { return }
            do {
                try await Task.sleep(for: .milliseconds(90))
                isRendering = true
                let image = try await PhotoRenderWorker.shared.render(data: data, recipe: previewRecipe, options: .init(), preview: true)
                try Task.checkCancellation()
                preview = UIImage(data: image.data)
                isRendering = false
            } catch is CancellationError {} catch { isRendering = false; self.error = error.localizedDescription }
        }
        .sheet(isPresented: $showExport) {
            if let data {
                PhotoCompressionSheet(asset: asset, data: data, recipe: recipe, store: store)
            }
        }
        .alert("存为滤镜", isPresented: $showSaveLook) {
            TextField("滤镜名称", text: $lookName)
            Button("保存") { workspace.saveLook(recipe, named: lookName); lookName = "" }
            Button("取消", role: .cancel) {}
        }
        .alert("无法编辑", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private struct PreviewRequest: Equatable { let dataLoaded: Bool; let recipe: PhotoEditRecipe }

    @ViewBuilder private var controls: some View {
        switch tab {
        case .crop:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    tool("还原", "arrow.counterclockwise") { change { $0 = .init() } }
                    tool("左旋 90°", "rotate.left") { change { $0.quarterTurns -= 1; $0.crop = .full } }
                    tool("右旋 90°", "rotate.right") { change { $0.quarterTurns += 1; $0.crop = .full } }
                    tool("水平镜像", "arrow.left.and.right.righttriangle.left.righttriangle.right") { change { $0.mirrored.toggle() } }
                    Menu {
                        Button("自由 / 原始") { change { $0.crop = .full } }
                        ForEach(["1:1", "16:9", "3:2", "4:3", "3:4", "2:3", "9:16"], id: \.self) { ratio in
                            Button(ratio) { setRatio(ratio) }
                        }
                    } label: { VStack(spacing: 6) { Image(systemName: "aspectratio"); Text("比例").font(.caption2) }.frame(minWidth: 44, minHeight: 44) }
                }.padding(.horizontal)
            }
            HStack {
                Text("旋转").font(.caption)
                Slider(value: $recipe.angle, in: -45...45, step: 0.1, onEditingChanged: sliderChanged)
                Text(recipe.angle.formatted(.number.precision(.fractionLength(1))) + "°").font(.caption).monospacedDigit().frame(width: 48)
            }.padding(.horizontal)
            HStack(spacing: 20) {
                Button("−0.1°") { change { $0.angle = max(-45, $0.angle - 0.1) } }
                Button("归零") { change { $0.angle = 0 } }
                Button("+0.1°") { change { $0.angle = min(45, $0.angle + 0.1) } }
            }.font(.caption)
        case .filters:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PhotoLook.allCases) { look in
                        Button { change { $0.look = look } } label: {
                            VStack {
                                LookThumbnail(data: thumbnailSource, look: look)
                                    .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(recipe.look == look ? Color.blue : .clear, lineWidth: 3))
                                Text(look.title).font(.caption2)
                            }
                        }.buttonStyle(.plain)
                    }
                    ForEach(workspace.savedLooks.keys.sorted(), id: \.self) { name in
                        Button(name) { if let look = workspace.savedLooks[name] { change { $0.look = look.look; $0.adjustments = look.adjustments; $0.automatic = look.automatic } } }
                            .contextMenu { Button("删除滤镜", role: .destructive) { workspace.deleteLook(name) } }
                    }
                }.padding(.horizontal)
            }
        case .adjustments:
            HStack {
                Button("清零") { change { $0.adjustments = [:]; $0.automatic = false } }
                Button("自动") { change { $0.automatic.toggle() } }.tint(recipe.automatic ? .blue : .secondary)
                Spacer()
                Button("存为滤镜") { showSaveLook = true }
            }.font(.caption).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(PhotoAdjustment.allCases) { value in
                        Button { adjustment = value } label: {
                            VStack(spacing: 6) { Image(systemName: value.symbol); Text(value.title).font(.caption2) }
                                .foregroundStyle(adjustment == value ? .blue : .primary).frame(minWidth: 44, minHeight: 44)
                        }
                    }
                }.padding(.horizontal)
            }
            HStack {
                Slider(value: Binding(get: { recipe[adjustment] }, set: { recipe[adjustment] = $0 }),
                       in: adjustment == .noise || adjustment == .sharpness || adjustment == .sepia || adjustment == .bloom || adjustment == .highlights ? 0...1 : -1...1,
                       onEditingChanged: sliderChanged)
                Text(recipe[adjustment].formatted(.number.precision(.fractionLength(2)))).font(.caption).monospacedDigit().frame(width: 45)
            }.padding(.horizontal)
        }
    }

    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 6) { Image(systemName: symbol); Text(title).font(.caption2) }.frame(minWidth: 44, minHeight: 44) }
    }

    private func change(_ edit: (inout PhotoEditRecipe) -> Void) {
        let before = recipe; edit(&recipe)
        if recipe != before { undo.append(before); redo.removeAll() }
    }
    private func beginSlider() { sliderStart = recipe }
    private func endSlider() { if let before = sliderStart, before != recipe { undo.append(before); redo.removeAll() }; sliderStart = nil }
    private func sliderChanged(_ editing: Bool) { if editing { beginSlider() } else { endSlider() } }
    private func setRatio(_ text: String) {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, let preview else { return }
        let ratio = parts[0] / parts[1] / (preview.size.width / preview.size.height)
        change { value in
            let w = min(1, ratio), h = min(1, 1 / ratio)
            value.crop = PhotoCrop(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        }
    }
}

private struct LookThumbnail: View {
    let data: Data?
    let look: PhotoLook
    @State private var image: UIImage?
    var body: some View {
        Color.clear.overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }.clipped()
            .task(id: data != nil) {
                guard let data else { return }
                var options = PhotoExportOptions(); options.maxDimension = 120
                var recipe = PhotoEditRecipe(); recipe.look = look
                if let result = try? await PhotoRenderWorker.shared.render(data: data, recipe: recipe, options: options, preview: true), !Task.isCancelled {
                    image = UIImage(data: result.data)
                }
            }
    }
}

private struct PhotoCropOverlay: View {
    @Binding var crop: PhotoCrop
    let onBegin: () -> Void
    let onEnd: () -> Void
    @State private var start: PhotoCrop?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height, width: crop.width * size.width, height: crop.height * size.height)
            ZStack(alignment: .topLeading) {
                Path { path in path.addRect(CGRect(origin: .zero, size: size)); path.addRect(rect) }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .gesture(DragGesture().onChanged { drag in
                        if start == nil { start = crop; onBegin() }
                        guard let start else { return }
                        crop = PhotoCrop(x: start.x + drag.translation.width / size.width, y: start.y + drag.translation.height / size.height,
                                         width: start.width, height: start.height).clamped
                    }.onEnded { _ in start = nil; onEnd() })
                Path { path in
                    path.addRect(rect)
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
                    }
                }.stroke(.white.opacity(0.7), lineWidth: 1).allowsHitTesting(false)
                ForEach(0..<4) { corner in
                    let right = corner % 2 == 1, bottom = corner >= 2
                    Image(systemName: "plus").font(.title3.bold()).foregroundStyle(.white)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                        .position(x: right ? rect.maxX : rect.minX, y: bottom ? rect.maxY : rect.minY)
                        .gesture(DragGesture().onChanged { drag in
                            if start == nil { start = crop; onBegin() }
                            guard let start else { return }
                            let dx = drag.translation.width / size.width, dy = drag.translation.height / size.height
                            let x = right ? start.x : min(start.x + start.width - 0.05, max(0, start.x + dx))
                            let y = bottom ? start.y : min(start.y + start.height - 0.05, max(0, start.y + dy))
                            let maxX = right ? max(x + 0.05, min(1, start.x + start.width + dx)) : start.x + start.width
                            let maxY = bottom ? max(y + 0.05, min(1, start.y + start.height + dy)) : start.y + start.height
                            crop = PhotoCrop(x: x, y: y, width: maxX - x, height: maxY - y).clamped
                        }.onEnded { _ in start = nil; onEnd() })
                }
            }
        }
    }
}
