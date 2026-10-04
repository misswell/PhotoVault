import Photos
import SwiftUI
import Translation
import Vision

struct PhotoNoteSheet: View {
    let asset: PHAsset
    @ObservedObject private var workspace = PhotoWorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var createDiary = false
    var body: some View {
        NavigationStack {
            Form {
                Section("照片备注") { TextEditor(text: $text).frame(minHeight: 180).accessibilityIdentifier("photo-note-text") }
                Toggle("同时保存到日记", isOn: $createDiary)
            }
            .navigationTitle("备注 / 日记").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        workspace.setNote(text, for: asset.localIdentifier)
                        if createDiary && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            workspace.saveEntry(PhotoJournalEntry(date: asset.creationDate ?? .now, text: text, assetID: asset.localIdentifier))
                        }
                        dismiss()
                    }.accessibilityIdentifier("photo-note-save")
                }
            }
        }.onAppear { text = workspace.notes[asset.localIdentifier] ?? "" }
    }
}

actor WorkspaceTextRecognizer {
    static let shared = WorkspaceTextRecognizer()
    func recognize(_ data: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(data: data).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
}

struct PhotoTextSheet: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loading = true
    @State private var translate = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("正在识别文字…") }
                else if let error { ContentUnavailableView("无法识别", systemImage: "text.viewfinder", description: Text(error)) }
                else if text.isEmpty { ContentUnavailableView("未发现文字", systemImage: "text.viewfinder") }
                else { ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() } }
            }
            .navigationTitle("识别文字").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("复制") { UIPasteboard.general.string = text }.disabled(text.isEmpty)
                    Spacer()
                    Button("翻译") { translate = true }.disabled(text.isEmpty)
                    Spacer()
                    ShareLink(item: text).disabled(text.isEmpty)
                }
            }
        }
        .translationPresentation(isPresented: $translate, text: text)
        .task {
            do {
                let data = try await WorkspacePhotoAccess.imageData(asset)
                var options = PhotoExportOptions(); options.maxDimension = 2000
                let image = try await PhotoRenderWorker.shared.render(data: data, recipe: .init(), options: options)
                let result = try await WorkspaceTextRecognizer.shared.recognize(image.data)
                try Task.checkCancellation(); text = result; loading = false
            } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
}

/// A stable captured asset prevents a late sheet open from editing a new page.
struct ViewerWorkspaceSheets: ViewModifier {
    let asset: PHAsset?
    @ObservedObject var store: PhotoLibraryStore
    @Binding var editor: WorkspaceAsset?
    @Binding var note: WorkspaceAsset?
    @Binding var text: WorkspaceAsset?
    func body(content: Content) -> some View {
        content
            .sheet(item: $editor) { item in
                if item.asset.mediaType == .video { VideoCompressionSheet(asset: item.asset, store: store) }
                else { PhotoEditorScreen(asset: item.asset, store: store) }
            }
            .sheet(item: $note) { item in PhotoNoteSheet(asset: item.asset) }
            .sheet(item: $text) { item in PhotoTextSheet(asset: item.asset) }
    }
}
