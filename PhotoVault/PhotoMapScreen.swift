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
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
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
    func merge(_ places: [PhotoMapPlace], coordinate: CLLocationCoordinate2D) throws -> PhotoMapPlace {
        var indices: [Int] = []
        for place in places { try Task.checkCancellation(); indices.append(contentsOf: place.indices) }
        // The most recent photo is the lowest index; no full sort is necessary.
        if let first = indices.enumerated().min(by: { $0.element < $1.element }) { indices.swapAt(0, first.offset) }
        return PhotoMapPlace(id: places.map(\.id).sorted().joined(separator: ","), latitude: coordinate.latitude,
                             longitude: coordinate.longitude, indices: indices)
    }
    func assets(_ snapshot: PhotoFetchSnapshot, indices: [Int]) throws -> PhotoFetchSnapshot {
        var ids: [String] = []
        for (offset, index) in indices.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            guard index >= 0 && index < snapshot.result.count else { continue }
            ids.append(snapshot.result.object(at: index).localIdentifier)
        }
        try Task.checkCancellation()
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PhotoFetchSnapshot(result: PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options))
    }
}

struct PhotoMapScreen: View {
    @ObservedObject var store: PhotoLibraryStore
    @State private var places: [PhotoMapPlace] = []
    @State private var selectedPlace: PhotoMapPlace?
    @State private var selectionPlace: MapPlaceSelection?
    @State private var snapshot: PhotoFetchSnapshot?
    @State private var loading = true
    @State private var mapRevision = UUID()
    @State private var loadedKey: String?
    private var requestKey: String { "\(store.libraryRevision):\(store.allPhotos?.count ?? -1)" }
    var body: some View {
        NavigationStack {
            PhotoPlacesMap(places: places, revision: mapRevision) { selectedPlace = $0 }
                .accessibilityIdentifier("photo-places-map")

            .overlay(alignment: .bottom) {
                if let place = selectedPlace {
                    Button { if let snapshot { selectionPlace = MapPlaceSelection(place: place, snapshot: snapshot) } } label: {
                        HStack(spacing: 12) {
                            if let snapshot, let index = place.indices.first, index < snapshot.result.count {
                                WorkspaceThumbnail(asset: snapshot.result.object(at: index))
                                    .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Text("查看这个地点的 \(place.indices.count.formatted()) 张照片")
                            Image(systemName: "chevron.right")
                        }.padding(12)
                    }
                    .buttonStyle(.plain).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding().accessibilityIdentifier("map-place-open")
                }
            }
            .overlay {
                if loading && places.isEmpty { ProgressView("正在整理拍摄地点…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
                else if places.isEmpty { ContentUnavailableView("没有带位置的照片", systemImage: "map", description: Text("地图使用照片已有的拍摄位置，无需访问你的当前位置。")) }
            }
            .navigationTitle("照片地图").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { if loading && !places.isEmpty { ProgressView() } } }
            .task(id: requestKey) {
                let key = requestKey
                guard loadedKey != key, let assets = store.allPhotos else { return }
                loading = true
                let source = PhotoFetchSnapshot(result: assets)
                do {
                    let result = try await PhotoMapWorker.shared.places(source)
                    try Task.checkCancellation(); snapshot = source; places = result; selectedPlace = nil; mapRevision = UUID(); loadedKey = key; loading = false
                } catch { if !Task.isCancelled { loading = false } }
            }
            .sheet(item: $selectionPlace) { selection in
                NavigationStack { MapPlaceGrid(place: selection.place, snapshot: selection.snapshot, store: store) }
            }
        }
    }
}

private struct MapPlaceSelection: Identifiable { let id = UUID(); let place: PhotoMapPlace; let snapshot: PhotoFetchSnapshot }

private struct MapPlaceGrid: View {
    let place: PhotoMapPlace
    let snapshot: PhotoFetchSnapshot
    @ObservedObject var store: PhotoLibraryStore
    @State private var assets: PHFetchResult<PHAsset>?
    var body: some View {
        PhotoGridScreen(title: "拍摄地点", assets: assets, store: store)
            .task {
                guard let result = try? await PhotoMapWorker.shared.assets(snapshot, indices: place.indices), !Task.isCancelled else { return }
                assets = result.result
            }
    }
}

/// MapKit recycles lightweight marker views and clusters them without hosting a
/// SwiftUI image tree per annotation. Camera movement never rebuilds annotations.
private struct PhotoPlacesMap: UIViewRepresentable {
    let places: [PhotoMapPlace]
    let revision: UUID
    var onSelection: (PhotoMapPlace?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "photo-place")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "photo-cluster")
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelection = onSelection
        guard context.coordinator.revision != revision else { return }
        context.coordinator.selectionTask?.cancel()
        context.coordinator.revision = revision
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        map.removeAnnotations(map.annotations)
        let annotations = places.map(PlaceAnnotation.init)
        map.addAnnotations(annotations)
        context.coordinator.annotationUpdateCount += 1
#if DEBUG
        map.accessibilityValue = "updates=\(context.coordinator.annotationUpdateCount); annotations=\(annotations.count)"
#endif
        if !annotations.isEmpty && !context.coordinator.didFitPlaces {
            context.coordinator.didFitPlaces = true
            map.showAnnotations(annotations, animated: false)
        }
    }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.selectionTask?.cancel()
        map.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var revision: UUID?
        var didFitPlaces = false
        var annotationUpdateCount = 0
        var isUpdating = false
        var selectionTask: Task<Void, Never>?
        var onSelection: (PhotoMapPlace?) -> Void
        init(onSelection: @escaping (PhotoMapPlace?) -> Void) { self.onSelection = onSelection }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            let count: Int
            let reuseID: String
            if let item = annotation as? PlaceAnnotation {
                count = item.place.indices.count; reuseID = "photo-place"
            } else if let cluster = annotation as? MKClusterAnnotation {
                count = cluster.memberAnnotations.reduce(0) { $0 + (($1 as? PlaceAnnotation)?.place.indices.count ?? 0) }; reuseID = "photo-cluster"
            } else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID, for: annotation) as! MKMarkerAnnotationView
            view.clusteringIdentifier = reuseID == "photo-place" ? "photos" : nil
            view.markerTintColor = .systemTeal
            view.glyphText = count.formatted(.number.notation(.compactName))
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            view.canShowCallout = false
            view.accessibilityLabel = "\(count) 张照片"
            view.accessibilityIdentifier = "photo-map-marker"
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            guard !isUpdating else { return }
            selectionTask?.cancel()
            if let item = annotation as? PlaceAnnotation { onSelection(item.place) }
            else if let cluster = annotation as? MKClusterAnnotation {
                let places = cluster.memberAnnotations.compactMap { ($0 as? PlaceAnnotation)?.place }
                let coordinate = cluster.coordinate
                selectionTask = Task { [weak self] in
                    guard let place = try? await PhotoMapWorker.shared.merge(places, coordinate: coordinate), !Task.isCancelled else { return }
                    self?.onSelection(place)
                }
            }
        }
        func mapView(_ mapView: MKMapView, didDeselect annotation: any MKAnnotation) {
            guard !isUpdating else { return }
            selectionTask?.cancel()
            onSelection(nil)
        }
    }

    final class PlaceAnnotation: NSObject, MKAnnotation {
        let place: PhotoMapPlace
        var coordinate: CLLocationCoordinate2D { place.coordinate }
        var title: String? { "\(place.indices.count) 张照片" }
        init(_ place: PhotoMapPlace) { self.place = place }
    }
}
