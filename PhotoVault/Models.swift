import Foundation
import Photos

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

enum PhotoSection: Hashable {
    case library
    case unsorted
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

struct PhotoViewerRequest: Identifiable {
    let id = UUID()
    let index: Int
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
