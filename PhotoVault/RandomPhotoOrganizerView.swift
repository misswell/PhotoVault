import Foundation
import Photos
import SwiftUI
import UIKit

/// A lazy Fisher-Yates sampler. It produces a uniform, non-repeating random
/// order without allocating an `[Int]` proportional to a 100,000-item photo
/// library, and the actual assets remain inside their PHFetchResult.
private struct RandomAssetIndexSampler {
    private(set) var remainingCount = 0
    private var replacements: [Int: Int] = [:]

    mutating func reset(count: Int) {
        remainingCount = max(0, count)
        replacements.removeAll(keepingCapacity: true)
    }

    mutating func next() -> Int? {
        guard remainingCount > 0 else { return nil }

        let randomPosition = Int.random(in: 0..<remainingCount)
        let lastPosition = remainingCount - 1
        let selectedIndex = replacements[randomPosition] ?? randomPosition
        let lastIndex = replacements[lastPosition] ?? lastPosition

        if randomPosition != lastPosition {
            replacements[randomPosition] = lastIndex
        }
        replacements.removeValue(forKey: lastPosition)
        remainingCount -= 1
        return selectedIndex
    }
}

private enum OrganizerPendingTrashStore {
    static let storageKey = "PhotoVault.organizer.pendingTrashAssetIDs.v1"
}

private enum OrganizerDecision: String {
    case recycle
    case keep
    case album

    var title: String {
        switch self {
        case .recycle:
            return "待回收"
        case .keep:
            return "保留"
        case .album:
            return "放入相册"
        }
    }

    var systemImage: String {
        switch self {
        case .recycle:
            return "trash.fill"
        case .keep:
            return "checkmark"
        case .album:
            return "folder.fill.badge.plus"
        }
    }

    var color: Color {
        switch self {
        case .recycle:
            return .red
        case .keep:
            return .green
        case .album:
            return .blue
        }
    }
}

private struct OrganizerAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct RandomPhotoOrganizerView: View {
    @ObservedObject var store: PhotoLibraryStore

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var sampler = RandomAssetIndexSampler()
    @State private var sessionAssets: PHFetchResult<PHAsset>?
    @State private var currentAsset: PHAsset?
    @State private var nextAsset: PHAsset?
    @State private var previewAsset: PHAsset?

    @State private var pendingTrash: [PHAsset] = []
    @State private var pendingTrashIDs = Set<String>()
    @State private var hasRestoredPendingTrash = false

    @State private var isSessionActive = false
    @State private var isSessionComplete = false
    @State private var sessionTotal = 0
    @State private var reviewedCount = 0
    @State private var keptCount = 0
    @State private var recycledCount = 0
    @State private var albumCount = 0

    @State private var cardOffset = CGSize.zero
    @State private var cardRotation = 0.0
    @State private var cardScale: CGFloat = 1
    @State private var cardOpacity = 1.0
    @State private var activeDecision: OrganizerDecision?
    @State private var decisionBadgeScale: CGFloat = 0.72
    @State private var decisionBadgeOpacity = 0.0
    @State private var cardCanvasSize = CGSize(width: 390, height: 560)
    @State private var isAnimatingDecision = false

    @State private var isShowingAlbumPicker = false
    @State private var isAddingToAlbum = false
    @State private var isShowingPendingTrash = false
    @State private var isDeletingPendingTrash = false
    @State private var alert: OrganizerAlert?

    var body: some View {
        NavigationStack {
            ZStack {
                organizerBackground
                    .ignoresSafeArea()

                if isSessionActive {
                    sessionView
                } else {
                    welcomeView
                }
            }
            .navigationTitle("随机整理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if isSessionActive {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("结束") {
                            endSession()
                        }
                        .foregroundStyle(.white)
                        .disabled(isAnimatingDecision || isAddingToAlbum)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingPendingTrash = true
                    } label: {
                        Label(
                            pendingTrash.count.formatted(),
                            systemImage: pendingTrash.isEmpty ? "trash" : "trash.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(pendingTrash.isEmpty ? Color.secondary : Color.white)
                    .disabled(pendingTrash.isEmpty)
                    .accessibilityLabel("待回收站，共 \(pendingTrash.count) 项")
                }
            }
        }
        .sheet(isPresented: $isShowingAlbumPicker) {
            AlbumPickerSheet(
                albums: store.albums,
                folders: store.albumFolders,
                quickAlbumIDs: store.quickAlbumIDs,
                onToggleQuickAlbum: { store.toggleQuickAlbum($0) },
                onCreate: addCurrentAssetToNewAlbum(named:),
                onSelect: addCurrentAsset(to:)
            )
        }
        .sheet(isPresented: $isShowingPendingTrash) {
            OrganizerPendingTrashSheet(
                assets: pendingTrash,
                isDeleting: isDeletingPendingTrash,
                onRemove: removeFromPendingTrash,
                onDelete: deletePendingTrash
            )
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onAppear {
            restorePendingTrashIfNeeded()
            choosePreviewAsset()
        }
        .onChange(of: store.allPhotos?.count ?? 0) { _, _ in
            guard !isSessionActive else { return }
            choosePreviewAsset()
        }
    }

    private var organizerBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.035, green: 0.055, blue: 0.05),
                Color(red: 0.035, green: 0.12, blue: 0.095),
                .black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var welcomeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                welcomeHero
                queueSummary

                Text("整理方式")
                    .font(.headline)
                    .foregroundStyle(.white)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    organizerModeGuide(
                        decision: .recycle,
                        detail: "先暂存，统一确认"
                    )
                    organizerModeGuide(
                        decision: .keep,
                        detail: "保留并继续下一张"
                    )
                    organizerModeGuide(
                        decision: .album,
                        detail: "加入指定系统相册"
                    )
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var welcomeHero: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                if let previewAsset {
                    AssetImageView(
                        asset: previewAsset,
                        targetSize: targetSize(for: proxy.size),
                        contentMode: .aspectFill,
                        requestPriority: .viewer,
                        cacheResult: true
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    LinearGradient(
                        colors: [.teal.opacity(0.55), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 72, weight: .light))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.18), .black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("随机整理")
                            .font(.largeTitle.bold())
                        Text("随机出现照片，用一次选择清理图库。")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.76))
                    }

                    Spacer(minLength: 8)

                    Button {
                        startSession()
                    } label: {
                        HStack(spacing: 7) {
                            Text("开始")
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 46)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .disabled((store.allPhotos?.count ?? 0) == 0)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 1)
            }
        }
        .frame(height: 350)
    }

    private var queueSummary: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.mint)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("随机队列")
                        .font(.headline)
                    Text("不会复制整座图库，只按随机索引逐张读取。")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer(minLength: 8)

                Text("\((store.allPhotos?.count ?? 0).formatted()) 张")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            if !pendingTrash.isEmpty {
                Divider()
                    .overlay(.white.opacity(0.12))

                Button {
                    isShowingPendingTrash = true
                } label: {
                    HStack {
                        Label("待回收站", systemImage: "trash")
                        Spacer()
                        Text("\(pendingTrash.count) 项")
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func organizerModeGuide(
        decision: OrganizerDecision,
        detail: String
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: decision.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(decision.color)
                .frame(width: 42, height: 42)
                .background(decision.color.opacity(0.14), in: Circle())

            Text(decision.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, minHeight: 126)
        .padding(.horizontal, 6)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var sessionView: some View {
        GeometryReader { proxy in
            VStack(spacing: 16) {
                sessionProgressHeader

                if isSessionComplete || currentAsset == nil {
                    completionCard
                } else {
                    photoCardStack
                        .frame(
                            height: max(300, min(590, proxy.size.height - 210))
                        )

                    actionBar
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                cardCanvasSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                cardCanvasSize = newSize
            }
        }
    }

    private var sessionProgressHeader: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isSessionComplete ? "本轮已完成" : "随机整理中")
                        .font(.headline)
                    Text("已处理 \(reviewedCount) 张")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer()

                HStack(spacing: 12) {
                    Label("\(keptCount)", systemImage: "checkmark")
                        .foregroundStyle(.green)
                    Label("\(recycledCount)", systemImage: "trash")
                        .foregroundStyle(.red)
                    Label("\(albumCount)", systemImage: "folder")
                        .foregroundStyle(.blue)
                }
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            }

            ProgressView(
                value: min(Double(reviewedCount), Double(max(1, sessionTotal))),
                total: Double(max(1, sessionTotal))
            )
            .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var photoCardStack: some View {
        GeometryReader { proxy in
            ZStack {
                if let nextAsset {
                    OrganizerPhotoCard(
                        asset: nextAsset,
                        targetSize: targetSize(for: proxy.size),
                        requestPriority: .slideshow
                    )
                    .scaleEffect(0.945)
                    .offset(y: 13)
                    .opacity(0.76)
                    .allowsHitTesting(false)
                }

                if let currentAsset {
                    OrganizerPhotoCard(
                        asset: currentAsset,
                        targetSize: targetSize(for: proxy.size),
                        requestPriority: .viewer
                    )
                    .id(currentAsset.localIdentifier)
                    .overlay {
                        if let displayDecision {
                            OrganizerDecisionBadge(decision: displayDecision)
                                .scaleEffect(decisionBadgeScale)
                                .opacity(decisionBadgeOpacity)
                        }
                    }
                    .scaleEffect(cardScale)
                    .rotationEffect(.degrees(cardRotation))
                    .offset(cardOffset)
                    .opacity(cardOpacity)
                    .contentShape(Rectangle())
                    .gesture(cardDragGesture)
                    .allowsHitTesting(!actionsLocked)
                    .accessibilityHint("向左滑放入待回收站，向右滑保留，向上滑选择相册")
                }
            }
            .onAppear {
                cardCanvasSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                cardCanvasSize = newSize
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            organizerActionButton(decision: .recycle) {
                commitDecision(.recycle)
            }

            organizerActionButton(decision: .keep) {
                commitDecision(.keep)
            }

            organizerActionButton(decision: .album) {
                isShowingAlbumPicker = true
            }
        }
    }

    private func organizerActionButton(
        decision: OrganizerDecision,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                if decision == .album, isAddingToAlbum {
                    ProgressView()
                        .tint(decision.color)
                } else {
                    Image(systemName: decision.systemImage)
                        .font(.title3.weight(.semibold))
                }
                Text(decision.title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(decision.color)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                decision.color.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(actionsLocked)
        .accessibilityLabel(decision.title)
    }

    private var completionCard: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 66))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)

            VStack(spacing: 6) {
                Text("本轮整理完成")
                    .font(.title2.bold())
                Text("共处理 \(reviewedCount) 张照片")
                    .foregroundStyle(.white.opacity(0.62))
            }

            if !pendingTrash.isEmpty {
                Button {
                    isShowingPendingTrash = true
                } label: {
                    Label(
                        "处理待回收站（\(pendingTrash.count)）",
                        systemImage: "trash"
                    )
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }

            Button("再来一轮") {
                startSession()
            }
            .font(.headline)
            .foregroundStyle(.white)
            .buttonStyle(.plain)

            Spacer()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var actionsLocked: Bool {
        isAnimatingDecision || isAddingToAlbum || currentAsset == nil
    }

    private var displayDecision: OrganizerDecision? {
        activeDecision ?? dragPreviewDecision
    }

    private var dragPreviewDecision: OrganizerDecision? {
        let horizontalDistance = abs(cardOffset.width)
        let verticalDistance = abs(cardOffset.height)
        if horizontalDistance > 28, horizontalDistance > verticalDistance * 1.08 {
            return cardOffset.width < 0 ? .recycle : .keep
        }
        if cardOffset.height < -28, verticalDistance > horizontalDistance * 1.08 {
            return .album
        }
        return nil
    }

    private var cardDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !actionsLocked else { return }
                cardOffset = value.translation
                cardRotation = Double(value.translation.width / max(280, cardCanvasSize.width)) * 10
                let travel = min(
                    1,
                    hypot(value.translation.width, value.translation.height)
                        / max(320, cardCanvasSize.width)
                )
                cardScale = 1 - travel * 0.025

                let hasPreview = dragPreviewDecision != nil
                decisionBadgeScale = hasPreview ? 1 : 0.72
                decisionBadgeOpacity = hasPreview ? 1 : 0
            }
            .onEnded { value in
                guard !actionsLocked else { return }

                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)
                let predictedHorizontal = abs(value.predictedEndTranslation.width)
                let predictedVertical = abs(value.predictedEndTranslation.height)

                if value.translation.width < 0,
                   horizontalDistance > verticalDistance * 1.08,
                   horizontalDistance > 96 || predictedHorizontal > 190 {
                    commitDecision(.recycle)
                } else if value.translation.width > 0,
                          horizontalDistance > verticalDistance * 1.08,
                          horizontalDistance > 96 || predictedHorizontal > 190 {
                    commitDecision(.keep)
                } else if value.translation.height < 0,
                          verticalDistance > horizontalDistance * 1.08,
                          verticalDistance > 96 || predictedVertical > 190 {
                    resetCardPosition()
                    isShowingAlbumPicker = true
                } else {
                    resetCardPosition()
                }
            }
    }

    private func startSession() {
        guard let assets = store.allPhotos, assets.count > 0 else {
            alert = OrganizerAlert(
                title: "没有可整理的照片",
                message: "请先确认 PhotoVault 已获得照片访问权限。"
            )
            return
        }

        sessionAssets = assets
        sampler.reset(count: assets.count)
        sessionTotal = max(0, assets.count - pendingTrashIDs.count)
        reviewedCount = 0
        keptCount = 0
        recycledCount = 0
        albumCount = 0
        isSessionComplete = false
        isSessionActive = true
        resetCardStateWithoutAnimation()

        currentAsset = drawNextAsset()
        nextAsset = drawNextAsset()

        if currentAsset == nil {
            isSessionActive = false
            alert = OrganizerAlert(
                title: "没有新的照片",
                message: "当前可见照片都已在待回收站中，请先处理待回收站。"
            )
        }
    }

    private func endSession() {
        isSessionActive = false
        isSessionComplete = false
        sessionAssets = nil
        currentAsset = nil
        nextAsset = nil
        resetCardStateWithoutAnimation()
        choosePreviewAsset()
    }

    private func drawNextAsset() -> PHAsset? {
        guard let sessionAssets else { return nil }

        while let index = sampler.next() {
            guard index >= 0, index < sessionAssets.count else { continue }
            let asset = sessionAssets.object(at: index)
            if !pendingTrashIDs.contains(asset.localIdentifier) {
                return asset
            }
        }
        return nil
    }

    private func commitDecision(_ decision: OrganizerDecision) {
        guard let currentAsset, !actionsLocked else { return }

        switch decision {
        case .recycle:
            enqueueForPendingTrash(currentAsset)
            recycledCount += 1
        case .keep:
            keptCount += 1
        case .album:
            albumCount += 1
        }
        reviewedCount += 1

        isAnimatingDecision = true
        activeDecision = decision
        decisionBadgeScale = 1
        decisionBadgeOpacity = 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.72)

        let animation: Animation = accessibilityReduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.4, dampingFraction: 0.9)
        let delay: Duration = accessibilityReduceMotion
            ? .milliseconds(170)
            : .milliseconds(340)

        withAnimation(animation) {
            if accessibilityReduceMotion {
                cardOpacity = 0
                cardScale = 0.96
            } else {
                switch decision {
                case .recycle:
                    cardOffset = CGSize(
                        width: -max(520, cardCanvasSize.width * 1.25),
                        height: max(20, cardOffset.height * 0.22)
                    )
                    cardRotation = -12
                case .keep:
                    cardOffset = CGSize(
                        width: max(520, cardCanvasSize.width * 1.25),
                        height: min(-12, cardOffset.height * 0.18)
                    )
                    cardRotation = 12
                case .album:
                    cardOffset = CGSize(
                        width: cardOffset.width * 0.12,
                        height: -max(680, cardCanvasSize.height * 1.18)
                    )
                    cardRotation = 0
                }
                cardScale = 0.9
                cardOpacity = 0.08
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: delay)
            advanceToNextAsset()
        }
    }

    private func advanceToNextAsset() {
        let newCurrent = nextAsset
        let newNext = drawNextAsset()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentAsset = newCurrent
            nextAsset = newNext
            resetCardStateWithoutAnimation()
            isAnimatingDecision = false
            if newCurrent == nil {
                isSessionComplete = true
            }
        }
    }

    private func resetCardPosition() {
        let animation: Animation = accessibilityReduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.38, dampingFraction: 0.84)
        withAnimation(animation) {
            cardOffset = .zero
            cardRotation = 0
            cardScale = 1
            cardOpacity = 1
            activeDecision = nil
            decisionBadgeScale = 0.72
            decisionBadgeOpacity = 0
        }
    }

    private func resetCardStateWithoutAnimation() {
        cardOffset = .zero
        cardRotation = 0
        cardScale = 1
        cardOpacity = 1
        activeDecision = nil
        decisionBadgeScale = 0.72
        decisionBadgeOpacity = 0
    }

    private func addCurrentAsset(to album: PhotoAlbum) {
        guard let currentAsset, !actionsLocked else { return }
        isAddingToAlbum = true
        store.addAssets([currentAsset], to: album) { result in
            isAddingToAlbum = false
            switch result {
            case .success:
                commitDecision(.album)
            case .failure(let error):
                alert = OrganizerAlert(
                    title: "无法加入相册",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func addCurrentAssetToNewAlbum(named name: String) {
        guard let currentAsset, !actionsLocked else { return }
        isAddingToAlbum = true
        store.createAlbum(named: name, containing: [currentAsset]) { result in
            isAddingToAlbum = false
            switch result {
            case .success:
                commitDecision(.album)
            case .failure(let error):
                alert = OrganizerAlert(
                    title: "无法创建相册",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func enqueueForPendingTrash(_ asset: PHAsset) {
        guard !pendingTrashIDs.contains(asset.localIdentifier) else { return }
        updatePendingTrash(pendingTrash + [asset])
    }

    private func removeFromPendingTrash(_ asset: PHAsset) {
        updatePendingTrash(
            pendingTrash.filter { $0.localIdentifier != asset.localIdentifier }
        )
    }

    private func deletePendingTrash() {
        let candidates = pendingTrash
        guard !candidates.isEmpty, !isDeletingPendingTrash else { return }

        isDeletingPendingTrash = true
        store.deleteAssets(candidates) { result in
            isDeletingPendingTrash = false
            switch result {
            case .failure(let error):
                alert = OrganizerAlert(
                    title: "无法删除照片",
                    message: error.localizedDescription
                )
            case .success:
                // PhotoLibraryStore deliberately maps the user's cancellation
                // to success so no error UI appears. Resolve the identifiers
                // again: cancelled assets remain and therefore stay queued.
                let candidateIDs = candidates.map(\.localIdentifier)
                let survivingResult = PHAsset.fetchAssets(
                    withLocalIdentifiers: candidateIDs,
                    options: nil
                )
                var survivingIDs = Set<String>()
                survivingResult.enumerateObjects { asset, _, _ in
                    survivingIDs.insert(asset.localIdentifier)
                }

                let candidateIDSet = Set(candidateIDs)
                let untouched = pendingTrash.filter {
                    !candidateIDSet.contains($0.localIdentifier)
                }
                let surviving = candidates.filter {
                    survivingIDs.contains($0.localIdentifier)
                }
                updatePendingTrash(untouched + surviving)

                if untouched.isEmpty, surviving.isEmpty {
                    isShowingPendingTrash = false
                }
            }
        }
    }

    private func restorePendingTrashIfNeeded() {
        guard !hasRestoredPendingTrash else { return }
        hasRestoredPendingTrash = true

        let identifiers = UserDefaults.standard.stringArray(
            forKey: OrganizerPendingTrashStore.storageKey
        ) ?? []
        guard !identifiers.isEmpty else { return }

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: nil
        )
        var assetsByID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }
        updatePendingTrash(identifiers.compactMap { assetsByID[$0] })
    }

    private func updatePendingTrash(_ assets: [PHAsset]) {
        var seen = Set<String>()
        let uniqueAssets = assets.filter {
            seen.insert($0.localIdentifier).inserted
        }
        pendingTrash = uniqueAssets
        pendingTrashIDs = seen
        UserDefaults.standard.set(
            uniqueAssets.map(\.localIdentifier),
            forKey: OrganizerPendingTrashStore.storageKey
        )
    }

    private func choosePreviewAsset() {
        guard let assets = store.allPhotos, assets.count > 0 else {
            previewAsset = nil
            return
        }

        for _ in 0..<min(24, assets.count) {
            let candidate = assets.object(at: Int.random(in: 0..<assets.count))
            if !pendingTrashIDs.contains(candidate.localIdentifier) {
                previewAsset = candidate
                return
            }
        }
        previewAsset = assets.firstObject
    }

    private func targetSize(for size: CGSize) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }
}

private struct OrganizerPhotoCard: View {
    let asset: PHAsset
    let targetSize: CGSize
    let requestPriority: PhotoRequestPriority

    var body: some View {
        ZStack(alignment: .bottom) {
            AssetImageView(
                asset: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                requestPriority: requestPriority,
                cacheResult: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [.clear, .black.opacity(0.03), .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "未知日期")
                        .font(.headline)
                    Text(mediaDescription)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                Image(systemName: mediaSymbol)
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular, in: Circle())
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
    }

    private var mediaDescription: String {
        if asset.mediaType == .video {
            return "视频 · \(formattedDuration)"
        }
        if asset.mediaSubtypes.contains(.photoLive) {
            return "实况照片"
        }
        return "照片"
    }

    private var mediaSymbol: String {
        if asset.mediaType == .video {
            return "play.fill"
        }
        if asset.mediaSubtypes.contains(.photoLive) {
            return "livephoto"
        }
        return "photo"
    }

    private var formattedDuration: String {
        let totalSeconds = max(0, Int(asset.duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct OrganizerDecisionBadge: View {
    let decision: OrganizerDecision

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: decision.systemImage)
                .font(.system(size: 34, weight: .bold))
            Text(decision.title)
                .font(.headline)
        }
        .foregroundStyle(decision.color)
        .frame(width: 112, height: 96)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct OrganizerPendingTrashSheet: View {
    let assets: [PHAsset]
    let isDeleting: Bool
    let onRemove: (PHAsset) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView(
                        "待回收站为空",
                        systemImage: "trash",
                        description: Text("整理时选择“待回收”的照片会先出现在这里。")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                pendingTrashCell(asset)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .navigationTitle("待回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .disabled(isDeleting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !assets.isEmpty {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "trash.fill")
                            }
                            Text(isDeleting ? "正在处理…" : "删除 \(assets.count) 项")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isDeleting)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func pendingTrashCell(_ asset: PHAsset) -> some View {
        ZStack(alignment: .topTrailing) {
            AssetImageView(
                asset: asset,
                targetSize: CGSize(
                    width: 220 * max(1, displayScale),
                    height: 220 * max(1, displayScale)
                ),
                contentMode: .aspectFill,
                requestPriority: .visibleGrid
            )
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                onRemove(asset)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .disabled(isDeleting)
            .accessibilityLabel("移出待回收站")
            .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            Text(asset.creationDate?.formatted(date: .numeric, time: .omitted) ?? "")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.46), in: Capsule())
                .padding(7)
        }
    }
}
