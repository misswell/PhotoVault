import MapKit
import Photos
import SwiftUI

struct PhotoMapPlace: Identifiable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    var indices: [Int]
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

actor PhotoMapWorker {
    static let shared = PhotoMapWorker()
    func places(_ snapshot: PhotoFetchSnapshot) throws -> [PhotoMapPlace] {
        var groups: [String: PhotoMapPlace] = [:]
        for index in 0..<snapshot.result.count {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard let location = snapshot.result.object(at: index).location else { continue }
            let coordinate = location.coordinate
            let key = "\(Int(floor(coordinate.latitude * 50))):\(Int(floor(coordinate.longitude * 50)))"
            if groups[key] == nil { groups[key] = PhotoMapPlace(id: key, latitude: coordinate.latitude, longitude: coordinate.longitude, indices: []) }
            groups[key]!.indices.append(index)
        }
        // Keep MapKit's annotation count bounded even for a world-spanning
        // library. Only compact index metadata is merged; no assets are loaded.
        var values = Array(groups.values), cellSize = 0.04
        while values.count > 400 {
            try Task.checkCancellation()
            var clustered: [String: PhotoMapPlace] = [:]
            for place in values {
                let key = "\(Int(floor(place.latitude / cellSize))):\(Int(floor(place.longitude / cellSize)))"
                if clustered[key] == nil { clustered[key] = PhotoMapPlace(id: key, latitude: place.latitude, longitude: place.longitude, indices: []) }
                clustered[key]!.indices.append(contentsOf: place.indices)
            }
            values = Array(clustered.values); cellSize *= 2
        }
        return values.sorted { $0.indices.count > $1.indices.count }
    }
    func assets(_ snapshot: PhotoFetchSnapshot, indices: [Int]) -> PhotoFetchSnapshot {
        let ids = indices.compactMap { index -> String? in
            guard index >= 0 && index < snapshot.result.count else { return nil }
            return snapshot.result.object(at: index).localIdentifier
        }
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PhotoFetchSnapshot(result: PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options))
    }
}

struct PhotoMapScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    @State private var places: [PhotoMapPlace] = []
    @State private var selected: String?
    @State private var selectionPlace: PhotoMapPlace?
    @State private var snapshot: PhotoFetchSnapshot?
    @State private var loading = true
    @State private var camera = MapCameraPosition.automatic
    var body: some View {
        NavigationStack {
            Map(position: $camera, selection: $selected) {
                ForEach(places) { place in
                    Annotation("\(place.indices.count) 张", coordinate: place.coordinate) {
                        VStack(spacing: 2) {
                            if let snapshot, let index = place.indices.first, index < snapshot.result.count {
                                WorkspaceThumbnail(asset: snapshot.result.object(at: index)).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            Text(place.indices.count.formatted()).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3).background(.regularMaterial, in: Capsule())
                        }
                    }.tag(place.id)
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .overlay(alignment: .bottom) {
                if let selected, let place = places.first(where: { $0.id == selected }) {
                    Button("查看这个地点的 \(place.indices.count.formatted()) 张照片") { selectionPlace = place }
                        .buttonStyle(.borderedProminent).padding().background(.regularMaterial, in: Capsule()).padding()
                }
            }
            .overlay {
                if loading { ProgressView("正在整理拍摄地点…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
                else if places.isEmpty { ContentUnavailableView("没有带位置的照片", systemImage: "map", description: Text("地图使用照片已有的拍摄位置，无需访问你的当前位置。")) }
            }
            .navigationTitle("照片地图").navigationBarTitleDisplayMode(.inline)
            .task(id: "\(store.libraryRevision)") {
                guard let assets = store.allPhotos else { return }
                loading = true
                let source = PhotoFetchSnapshot(result: assets)
                do {
                    let result = try await PhotoMapWorker.shared.places(source)
                    try Task.checkCancellation(); snapshot = source; places = result; loading = false
                } catch { if !Task.isCancelled { loading = false } }
            }
            .sheet(item: $selectionPlace) { place in
                if let snapshot { NavigationStack { MapPlaceGrid(place: place, snapshot: snapshot, store: store) } }
            }
        }
    }
}

private struct MapPlaceGrid: View {
    let place: PhotoMapPlace
    let snapshot: PhotoFetchSnapshot
    @ObservedObject var store: PhotoLibraryStore
    @State private var assets: PHFetchResult<PHAsset>?
    var body: some View {
        PhotoGridScreen(title: "拍摄地点", assets: assets, store: store)
            .task {
                let result = await PhotoMapWorker.shared.assets(snapshot, indices: place.indices)
                if !Task.isCancelled { assets = result.result }
            }
    }
}
