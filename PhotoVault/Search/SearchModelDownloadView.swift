import Foundation
import SwiftUI

@MainActor
@Observable
final class SearchModelDownloadStore {
    static let shared = SearchModelDownloadStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(received: Int64, total: Int64)
        case installing
        case installed
        case failed(String)
    }

    private(set) var state: State
    private var task: Task<Void, Never>?
    private var downloadID: UUID?

    var isInstalled: Bool { state == .installed }
    var isBusy: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: SearchModelCatalog.production.totalBytes, countStyle: .file)
    }

    private init() {
        state = SearchModelResources().isInstalled ? .installed : .notDownloaded
    }

    func download() {
        guard !isInstalled else {
            state = .installed
            return
        }
        // A cancelled task is allowed to be replaced, but only after it has
        // actually exited: the new attempt sweeps `.download-*` staging
        // folders that the old one may still be writing into.
        if let task, !task.isCancelled { return }
        let previous = task
        let id = UUID()
        downloadID = id
        state = .downloading(received: 0, total: SearchModelCatalog.production.totalBytes)
        task = Task.detached(priority: .utility) { [self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                if !SearchModelResources().isInstalled {
                    try await SearchModelDownloader.install(
                        catalog: .production, destination: SearchModelInstallation.directory
                    ) { [self] progress in
                        Task { @MainActor [self] in
                            guard self.downloadID == id else { return }
                            switch progress {
                            case .downloading(let received, let total):
                                if self.state == .installing { return }
                                if case .downloading(let previous, _) = self.state, received < previous { return }
                                self.state = .downloading(received: received, total: total)
                            case .installing:
                                self.state = .installing
                            }
                        }
                    }
                }
                await self.finish(id: id, error: nil)
            } catch {
                await self.finish(id: id, error: error)
            }
        }
    }

    func cancel() {
        // Keep the task reference: a retry must wait for this cancelled work
        // to leave the staging directory before sweeping it. Clearing the
        // download id makes its eventual `finish` a no-op, so a user-requested
        // cancel never surfaces as a failure.
        task?.cancel()
        downloadID = nil
        state = SearchModelResources().isInstalled ? .installed : .notDownloaded
    }

    private func finish(id: UUID, error: Error?) {
        guard downloadID == id else { return }
        task = nil
        downloadID = nil
        if SearchModelResources().isInstalled {
            state = .installed
        } else if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .failed("模型安装未完成，请重新下载。")
        }
    }
}

/// Shared between settings and search; navigating away never starts a second download.
struct SearchModelDownloadControl: View {
    @State private var downloads = SearchModelDownloadStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("智能搜索模型", systemImage: "sparkle.magnifyingglass")
                .font(.headline)
            Text("可选下载，\(downloads.sizeDescription)。下载后可按照片内容搜索，搜索和索引全部在本机完成。照片不会上传。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            switch downloads.state {
            case .installed:
                Label("已下载，可离线使用", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(total))
                    .accessibilityIdentifier("search-model-download-progress")
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(downloads.sizeDescription)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消下载") { downloads.cancel() }
                        .accessibilityIdentifier("search-model-cancel")
                }
            case .installing:
                HStack {
                    ProgressView()
                    Text("正在准备模型…").font(.footnote)
                    Spacer()
                    Button("取消下载") { downloads.cancel() }
                        .accessibilityIdentifier("search-model-cancel")
                }
            case .notDownloaded, .failed:
                if case .failed(let message) = downloads.state {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                Button {
                    downloads.download()
                } label: {
                    Label(downloads.state == .notDownloaded ? "下载模型" : "重试下载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search-model-download")
                Text("建议连接 Wi-Fi。未下载不影响浏览、编辑和管理照片。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
