import Photos
import SwiftUI

enum WorkspaceMediaScope: String, CaseIterable, Identifiable, Sendable {
    case all, photos, videos, favorites, screenshots, live
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "全部"; case .photos: "照片"; case .videos: "视频"; case .favorites: "收藏"; case .screenshots: "截屏"; case .live: "Live Photo" }
    }
}

actor WorkspaceLibraryQuery {
    static let shared = WorkspaceLibraryQuery()
    func fetch(scope: WorkspaceMediaScope, oldestFirst: Bool, start: Date? = nil, end: Date? = nil) -> PhotoFetchSnapshot {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: oldestFirst)]
        if let start, let end {
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
        }
        func addPredicate(_ predicate: NSPredicate) {
            options.predicate = options.predicate.map { NSCompoundPredicate(andPredicateWithSubpredicates: [$0, predicate]) } ?? predicate
        }
        switch scope {
        case .photos: addPredicate(NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue))
        case .videos: addPredicate(NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue))
        case .favorites: addPredicate(NSPredicate(format: "favorite = YES"))
        case .screenshots, .live:
            let subtype: PHAssetCollectionSubtype = scope == .screenshots ? .smartAlbumScreenshots : .smartAlbumLivePhotos
            if let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject {
                return PhotoFetchSnapshot(result: PHAsset.fetchAssets(in: album, options: options))
            }
            return PhotoFetchSnapshot(result: PHFetchResult<PHAsset>())
        case .all: break
        }
        return PhotoFetchSnapshot(result: PHAsset.fetchAssets(with: options))
    }
}

enum LibraryBrowseMode: String, CaseIterable, Identifiable, Sendable {
    case years, months, days, journal, expanded, compact
    var id: String { rawValue }
    var title: String {
        switch self { case .years: "年"; case .months: "月"; case .days: "日"; case .journal: "日记"; case .expanded: "展开"; case .compact: "紧凑" }
    }
    var isGrid: Bool { self == .expanded || self == .compact }
}

struct LibraryPeriod: Identifiable, Sendable {
    let start: Date
    let end: Date
    let count: Int
    let previews: [String]
    var id: Date { start }
}

struct PhotoFetchSnapshot: @unchecked Sendable { let result: PHFetchResult<PHAsset> }

actor LibraryTimelineWorker {
    static let shared = LibraryTimelineWorker()
    func periods(_ snapshot: PhotoFetchSnapshot, mode: LibraryBrowseMode, journalDates: [Date] = [], oldestFirst: Bool = false) throws -> [LibraryPeriod] {
        let calendar = Calendar.current
        let component: Calendar.Component = mode == .years ? .year : (mode == .months ? .month : .day)
        var groups: [Date: (end: Date, count: Int, previews: [String])] = [:]
        for index in 0..<snapshot.result.count {
            if index % 256 == 0 { try Task.checkCancellation() }
            let asset = snapshot.result.object(at: index)
            guard let date = asset.creationDate, let interval = calendar.dateInterval(of: component, for: date) else { continue }
            var group = groups[interval.start] ?? (interval.end, 0, [])
            group.count += 1
            if group.previews.count < 6 { group.previews.append(asset.localIdentifier) }
            groups[interval.start] = group
        }
        if mode == .journal {
            for date in journalDates {
                guard let interval = calendar.dateInterval(of: .day, for: date), groups[interval.start] == nil else { continue }
                groups[interval.start] = (interval.end, 0, [])
            }
        }
        return groups.map { LibraryPeriod(start: $0.key, end: $0.value.end, count: $0.value.count, previews: $0.value.previews) }
            .sorted { oldestFirst ? $0.start < $1.start : $0.start > $1.start }
    }

}

private struct TimelineRequest: Equatable {
    let mode: LibraryBrowseMode
    let assets: ObjectIdentifier
    let revision: Int
    let journalDates: [Date]
    let scope: WorkspaceMediaScope
    let oldestFirst: Bool
}

struct LibraryTimelineContent: View {
    let assets: PHFetchResult<PHAsset>
    let mode: LibraryBrowseMode
    var scope: WorkspaceMediaScope = .all
    var oldestFirst = false
    @ObservedObject var store: PhotoLibraryStore
    @ObservedObject private var workspace = PhotoWorkspaceStore.shared
    @State private var periods: [LibraryPeriod] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        ScrollView {
            if mode == .years || mode == .months {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: mode == .years ? 100 : 130))], spacing: 18) {
                    ForEach(periods) { period in
                        VStack(alignment: .leading, spacing: 8) {
                            NavigationLink { LibraryPeriodScreen(period: period, store: store, scope: scope, oldestFirst: oldestFirst) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let id = period.previews.first, let asset = WorkspacePhotoAccess.asset(id) {
                                        WorkspaceThumbnail(asset: asset).frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                    Text(period.start.formatted(mode == .years ? .dateTime.year() : .dateTime.year().month())).font(.headline)
                                    Text("\(period.count.formatted()) 项").font(.caption).foregroundStyle(.secondary)
                                }.foregroundStyle(.primary)
                            }.buttonStyle(.plain).accessibilityIdentifier("timeline-period")
                            if mode == .months { MiniMonthCalendar(month: period.start, store: store, scope: scope, oldestFirst: oldestFirst) }
                        }
                    }
                }.padding()
            } else {
                LazyVStack(spacing: 18) {
                    ForEach(periods) { period in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink { LibraryPeriodScreen(period: period, store: store, scope: scope, oldestFirst: oldestFirst) } label: {
                                HStack { Text(period.start.formatted(date: .complete, time: .omitted)).font(.headline); Spacer(); Text("\(period.count) 项").foregroundStyle(.secondary); Image(systemName: "chevron.right") }.foregroundStyle(.primary)
                            }.accessibilityIdentifier("timeline-period")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                                ForEach(period.previews, id: \.self) { id in
                                    if let asset = WorkspacePhotoAccess.asset(id) {
                                        NavigationLink { LibraryPeriodScreen(period: period, store: store, scope: scope, oldestFirst: oldestFirst) } label: {
                                            WorkspaceThumbnail(asset: asset).frame(height: 100)
                                        }
                                    }
                                }
                            }.clipShape(RoundedRectangle(cornerRadius: 12))
                            if mode == .journal {
                                ForEach(workspace.journal.filter { $0.date >= period.start && $0.date < period.end }) { entry in
                                    Text(entry.text).font(.body).textSelection(.enabled)
                                }
                                NavigationLink("写下这一天", destination: JournalEditorSheet(date: period.start))
                                    .font(.caption)
                            }
                        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 18))
                    }
                }.padding()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay {
            if loading && periods.isEmpty { ProgressView("正在整理时间线…") }
            else if let error { ContentUnavailableView("无法读取时间线", systemImage: "calendar", description: Text(error)) }
            else if periods.isEmpty { ContentUnavailableView("没有拍摄日期", systemImage: "calendar") }
        }
        .accessibilityIdentifier("library-timeline")
        .task(id: TimelineRequest(mode: mode, assets: ObjectIdentifier(assets), revision: store.libraryRevision, journalDates: mode == .journal ? workspace.journal.map(\.date) : [], scope: scope, oldestFirst: oldestFirst)) {
            loading = true; error = nil
            do {
                let result = try await LibraryTimelineWorker.shared.periods(PhotoFetchSnapshot(result: assets), mode: mode, journalDates: workspace.journal.map(\.date), oldestFirst: oldestFirst)
                try Task.checkCancellation(); periods = result; loading = false
            } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
    }
}

struct LibraryPeriodScreen: View {
    let period: LibraryPeriod
    @ObservedObject var store: PhotoLibraryStore
    var scope: WorkspaceMediaScope = .all
    var oldestFirst = false
    @State private var assets: PHFetchResult<PHAsset>?
    var body: some View {
        PhotoGridScreen(title: period.start.formatted(date: .abbreviated, time: .omitted), assets: assets, store: store)
            .task(id: "\(period.id)-\(store.libraryRevision)-\(scope.rawValue)-\(oldestFirst)") {
                let result = await WorkspaceLibraryQuery.shared.fetch(scope: scope, oldestFirst: oldestFirst, start: period.start, end: period.end)
                if !Task.isCancelled { assets = result.result }
            }
    }
}

private struct MiniMonthCalendar: View {
    let month: Date
    @ObservedObject var store: PhotoLibraryStore
    var scope: WorkspaceMediaScope = .all
    var oldestFirst = false
    private var calendar: Calendar { .current }
    var body: some View {
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 3) {
            ForEach(0..<(offset + count), id: \.self) { index in
                if index < offset { Color.clear.frame(height: 12) }
                else {
                    let day = calendar.date(byAdding: .day, value: index - offset, to: month)!
                    NavigationLink {
                        LibraryPeriodScreen(period: LibraryPeriod(start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!, count: 0, previews: []), store: store, scope: scope, oldestFirst: oldestFirst)
                    } label: {
                        Text("\(index - offset + 1)").font(.system(size: 9, weight: calendar.isDateInToday(day) ? .bold : .regular)).foregroundStyle(calendar.isDateInToday(day) ? .blue : .secondary)
                    }
                }
            }
        }
    }
}
