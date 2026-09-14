import Foundation
import Photos
import UIKit

enum PhotoAlbumKind: String, Codable, Equatable {
    case user
    case smart
    case shared
}

struct PhotoAlbum: Identifiable {
    let collection: PHAssetCollection
    let kind: PhotoAlbumKind
    let title: String
    let assetCount: Int
    let previewAsset: PHAsset?

    var id: String {
        collection.localIdentifier
    }

    var symbolName: String {
        switch kind {
        case .user:
            return "rectangle.stack"
        case .smart:
            return "sparkles.rectangle.stack"
        case .shared:
            return "person.2.fill"
        }
    }
}

struct PhotoAlbumCacheEntry: Codable {
    let id: String
    let kind: PhotoAlbumKind
    let title: String
    let assetCount: Int
    let previewAssetID: String?
}

struct PhotoAlbumFolderCacheEntry: Codable {
    let id: String
    let title: String
    let albumIDs: [String]
    let subfolders: [PhotoAlbumFolderCacheEntry]
}

struct PhotoAlbumCacheSnapshot: Codable {
    let version: Int
    let albums: [PhotoAlbumCacheEntry]
    let folders: [PhotoAlbumFolderCacheEntry]

    static let currentVersion = 1
}

/// A PhotoKit folder can contain albums and other folders. Keep this separate
/// from the flat album list used by indexing, search, and album pickers so the
/// sidebar can mirror Photos' hierarchy without changing those operations.
final class PhotoAlbumFolder: Identifiable {
    let collection: PHCollectionList
    let title: String
    let albums: [PhotoAlbum]
    let subfolders: [PhotoAlbumFolder]
    let albumCount: Int
    let assetCount: Int
    let previewAsset: PHAsset?
    private let flattenedAlbums: [PhotoAlbum]

    init(
        collection: PHCollectionList,
        title: String,
        albums: [PhotoAlbum],
        subfolders: [PhotoAlbumFolder]
    ) {
        self.collection = collection
        self.title = title
        self.albums = albums
        self.subfolders = subfolders
        albumCount = albums.count + subfolders.reduce(0) { $0 + $1.albumCount }
        assetCount = albums.reduce(0) { $0 + $1.assetCount }
            + subfolders.reduce(0) { $0 + $1.assetCount }
        previewAsset = albums.first?.previewAsset ?? subfolders.first?.previewAsset
        flattenedAlbums = albums + subfolders.flatMap(\.allAlbums)
    }

    var id: String {
        collection.localIdentifier
    }

    var allAlbums: [PhotoAlbum] {
        flattenedAlbums
    }
}

enum AlbumTileColumnCount: Int, CaseIterable, Identifiable {
    case automatic = 0
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    static let storageKey = "PhotoVault.home.albumTileColumns"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动"
        case .two:
            return "2 列"
        case .three:
            return "3 列"
        case .four:
            return "4 列"
        case .five:
            return "5 列"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "根据可用宽度和双指缩放自动排列。"
        case .two, .three, .four, .five:
            return "文件夹内和普通/共享相册平铺时固定显示为 \(rawValue) 列。"
        }
    }
}

enum PhotoGridPreferences {
    static let preferredCellSideKey = "PhotoVault.photoGrid.preferredCellSide"
    static let defaultPreferredCellSide = 50.0
}

/// Manual app icon choice. "system" restores the primary icon set, which
/// switches between its light and dark appearance variants automatically;
/// "light"/"dark" pin one of the compiled alternate icons.
enum AppIconPreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "PhotoVault.appIconPreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "亮色"
        case .dark:
            return "暗色"
        }
    }

    var detail: String {
        switch self {
        case .system:
            return "外观切换时自动使用亮色或暗色图标。"
        case .light:
            return "始终使用亮色图标。"
        case .dark:
            return "始终使用暗色图标。"
        }
    }

    /// Alternate icon name passed to setAlternateIconName; nil restores the
    /// primary icon and its automatic appearance switching.
    var alternateIconName: String? {
        switch self {
        case .system:
            return nil
        case .light:
            return "AppIconLight"
        case .dark:
            return "AppIconDark"
        }
    }
}

enum PhotoSection: Hashable {
    case home
    case library
    case unsorted
    /// AI content search: a query over the on-device embedding index.
    case smartSearch
    case lan
    case album(String)
    case search(String)
}

enum PhotoSwipeStyle: String, CaseIterable, Identifiable {
    case system = "system"
    case fade = "fade"
    case push = "push"
    case zoom = "zoom"

    static let storageKey = "PhotoVault.viewer.swipeStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "系统滑动"
        case .fade:
            return "淡入淡出"
        case .push:
            return "推入切换"
        case .zoom:
            return "缩放切换"
        }
    }

    var detail: String {
        switch self {
        case .system:
            return "使用 iOS 原生的左右分页动效。"
        case .fade:
            return "下一张图片淡入，切换过程更柔和。"
        case .push:
            return "下一张从滑动方向推入，上一张同步退出。"
        case .zoom:
            return "下一张轻微放大进入，减少 iCloud 加载时的突兀感。"
        }
    }
}

enum SlideshowTransitionStyle: String, CaseIterable, Identifiable {
    case fade = "fade"
    case slide = "slide"
    case zoom = "zoom"
    case dissolve = "dissolve"

    static let storageKey = "PhotoVault.slideshow.transitionStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fade:
            return "淡入淡出"
        case .slide:
            return "左右滑入"
        case .zoom:
            return "缩放进入"
        case .dissolve:
            return "柔和溶解"
        }
    }

    var detail: String {
        switch self {
        case .fade:
            return "经典的照片幻灯片淡入淡出。"
        case .slide:
            return "按照播放方向左右移动切换。"
        case .zoom:
            return "下一张从较小比例平滑放大。"
        case .dissolve:
            return "更慢、更柔和的叠化过渡。"
        }
    }
}

enum SlideshowSettings {
    static let intervalStorageKey = "PhotoVault.slideshow.interval"
    static let loopsStorageKey = "PhotoVault.slideshow.loops"
    static let defaultInterval: TimeInterval = 5
    static let defaultLoops = true
    static let intervalValues: [TimeInterval] = [3, 5, 8, 12]
}

/// What a slideshow is allowed to play.
///
/// The launch sheet offers one of these; `all` is the plain "play everything
/// in the order it is already in" behaviour the app had before the sheet
/// existed, so it stays first and stays the default. Every other case is a
/// filter *by picture*, never by metadata the viewer would have to download:
/// width/height, media subtype and the favourite flag are all local metadata,
/// which is what keeps "play only landscapes" instant on a 100k library.
///
/// Names say what is **kept**, never what is dropped, so the label the user
/// taps is the same thing the filter asserts.
enum SlideshowContentFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case landscape = "landscape"
    case portrait = "portrait"
    case square = "square"
    case panorama = "panorama"
    case highQuality = "highQuality"

    static let storageKey = "PhotoVault.slideshow.contentFilter"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部照片"
        case .landscape: return "横屏照片"
        case .portrait: return "竖屏照片"
        case .square: return "方形照片"
        case .panorama: return "全景照片"
        case .highQuality: return "高清照片"
        }
    }

    var detail: String {
        switch self {
        case .all:
            return "按图库顺序播放全部内容，照片和视频都会出现。"
        case .landscape:
            return "只播放宽大于高的照片，适合横着看。"
        case .portrait:
            return "只播放高大于宽的照片。"
        case .square:
            return "只播放长短边接近的照片。"
        case .panorama:
            return "只播放系统标记的全景照片。"
        case .highQuality:
            return "只播放像素不低于屏幕的照片，铺满全屏也不会糊。"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "photo.stack"
        case .landscape: return "rectangle"
        case .portrait: return "rectangle.portrait"
        case .square: return "square"
        case .panorama: return "pano"
        case .highQuality: return "sparkles"
        }
    }
}

/// Independent switches applied *on top of* the content filter. They are not
/// part of it because they combine with every case: "landscapes, camera
/// shots only, favourites only" is a legitimate thing to ask for.
struct SlideshowRefinements: Equatable {
    var skipsScreenshots = false
    var onlyFavorites = false
    var photosOnly = false

    static let skipsScreenshotsKey = "PhotoVault.slideshow.skipsScreenshots"
    static let onlyFavoritesKey = "PhotoVault.slideshow.onlyFavorites"
    static let photosOnlyKey = "PhotoVault.slideshow.photosOnly"

    var isDefault: Bool { !skipsScreenshots && !onlyFavorites && !photosOnly }
}

/// How the slideshow plays, as opposed to what it plays. `interval` and
/// `loops` already existed in the settings panel; `fillsScreen` and `shuffles`
/// moved here so the launch sheet is the single place a slideshow is set up.
enum SlideshowPlaybackSettings {
    static let fillsScreenKey = "PhotoVault.slideshow.fillsScreen"
    static let shufflesKey = "PhotoVault.slideshow.shuffles"
    static let defaultFillsScreen = false
    static let defaultShuffles = false
}

/// A content filter with everything it needs to decide. The screen size is
/// captured when the slideshow is set up: "higher resolution than the screen"
/// is only meaningful against a concrete display.
struct SlideshowFilter: Equatable {
    var content: SlideshowContentFilter = .all
    var refinements = SlideshowRefinements()
    var screenPixelSize: CGSize = .zero

    /// True when nothing is filtered out, which lets a slideshow play a
    /// `PHFetchResult` directly instead of materialising an index map.
    var keepsEverything: Bool {
        content == .all && refinements.isDefault
    }

    var summary: String {
        var parts: [String] = []
        if content != .all {
            parts.append(content.title)
        }
        if refinements.skipsScreenshots {
            parts.append("不含截屏")
        }
        if refinements.onlyFavorites {
            parts.append("仅收藏")
        }
        if refinements.photosOnly {
            parts.append("仅照片")
        }
        return parts.isEmpty ? "全部照片" : parts.joined(separator: " · ")
    }
}

/// The page that should be selected when the app creates its root view.
/// Album destinations store the PhotoKit local identifier rather than the
/// localized title so renaming an album does not invalidate the preference.
enum PhotoVaultStartupDestination {
    static let storageKey = "PhotoVault.startup.destination"
    static let homeRawValue = "home"
    static let libraryRawValue = "library"
    static let unsortedRawValue = "unsorted"
    static let lanRawValue = "lan"
    static let organizerRawValue = "organizer"
    private static let albumPrefix = "album:"

    static func albumRawValue(for id: String) -> String {
        albumPrefix + id
    }

    static func albumID(from rawValue: String) -> String? {
        guard rawValue.hasPrefix(albumPrefix) else { return nil }
        let id = String(rawValue.dropFirst(albumPrefix.count))
        return id.isEmpty ? nil : id
    }
}

/// UI-only description of "the user tapped this grid cell". It carries the
/// already-decoded thumbnail so the viewer can paint a first frame without
/// waiting for PhotoKit; it is deliberately not a PhotoKit domain model.
struct PhotoOpenContext {
    let index: Int
    let assetIdentifier: String
    let previewImage: UIImage?
}

struct PhotoViewerRequest: Identifiable {
    let id = UUID()
    let index: Int
    let assetIdentifier: String
    let previewImage: UIImage?

    init(
        index: Int,
        assetIdentifier: String,
        previewImage: UIImage?
    ) {
        self.index = index
        self.assetIdentifier = assetIdentifier
        self.previewImage = previewImage
    }
}

struct PhotoVaultAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum PhotoVaultError: LocalizedError {
    case changeFailed
    case noAlbumChangeRequest

    var errorDescription: String? {
        switch self {
        case .changeFailed:
            return "照片操作没有完成，请稍后重试。"
        case .noAlbumChangeRequest:
            return "无法打开这个相册。"
        }
    }
}
