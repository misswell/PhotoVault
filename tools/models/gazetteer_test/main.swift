// Offline gazetteer tests: the data, the resolution rules, the bounding-box
// maths, and the path from a natural-language mention all the way to rows
// filtered out of SQLite.
//
// The last part is the one that matters. A gazetteer that resolves correctly but
// produces a box the store cannot use would pass every unit test and return
// nothing in the app.

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  [PASS] \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  [FAIL] \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func section(_ title: String) { print("\n\(title)") }

let gazetteer = OfflineGazetteer()

// ---------------------------------------------------------------------------
section("data integrity")

let problems = gazetteer.validate()
for problem in problems.prefix(8) { print("         \(problem)") }
check(problems.isEmpty, "every entry has a valid coordinate and radius",
      "\(problems.count) problems")
print("         \(gazetteer.count) places")

do {
    let kinds = Dictionary(grouping: gazetteer.allEntries, by: \.kind).mapValues(\.count)
    print("         by kind: \(kinds.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", "))")
    check(kinds[.country, default: 0] > 10, "countries are covered")
    check(kinds[.province, default: 0] >= 30, "China's province-level divisions are covered",
          "got \(kinds[.province, default: 0])")
    check(kinds[.landmark, default: 0] >= 15, "landmarks are covered")
}

// ---------------------------------------------------------------------------
section("plausibility: catching wrong coordinates without a reference dataset")

/// Great-circle distance in kilometres.
func haversine(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    let radius = 6371.0088
    let dLat = (b.0 - a.0) * .pi / 180
    let dLon = (b.1 - a.1) * .pi / 180
    let lat1 = a.0 * .pi / 180
    let lat2 = b.0 * .pi / 180
    let h = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * radius * asin(min(1, h.squareRoot()))
}

// A bounding box for China. Every entry in the China table must fall inside it:
// a coordinate that is wildly wrong -- a transposed pair, a sign slip, a value
// from the wrong city -- almost always leaves the country, and this catches it
// without needing a reference dataset.
do {
    let outside = GazetteerData.china.filter {
        !(18.0...54.0).contains($0.latitude) || !(73.0...135.5).contains($0.longitude)
    }
    for entry in outside.prefix(5) {
        print("         outside China: \(entry.primaryName) \(entry.latitude), \(entry.longitude)")
    }
    check(outside.isEmpty, "every China entry lies inside China's bounding box",
          "\(outside.count) outside")
}

// Distance between well-known pairs. Broad tolerance: this is here to catch a
// coordinate that is wrong, not to certify the ones that are right.
do {
    let expected: [(String, String, Double)] = [
        ("北京", "上海", 1067),
        ("伦敦", "巴黎", 344),
        ("纽约", "伦敦", 5570),
        ("东京", "首尔", 1160),
        ("悉尼", "墨尔本", 714),
        ("北京", "东京", 2100),
        ("纽约", "洛杉矶", 3940),
        ("巴黎", "罗马", 1105),
        ("北京", "香港", 1970),
        ("新加坡", "曼谷", 1430),
    ]
    var mismatches: [String] = []
    for (first, second, expectedKilometers) in expected {
        guard let a = gazetteer.resolve(first).place, let b = gazetteer.resolve(second).place else {
            mismatches.append("\(first)/\(second) did not resolve")
            continue
        }
        let actual = haversine((a.latitude, a.longitude), (b.latitude, b.longitude))
        let error = abs(actual - expectedKilometers) / expectedKilometers
        if error > 0.08 {
            mismatches.append(String(format: "%@-%@ %.0f km vs %.0f km",
                                     first, second, actual, expectedKilometers))
        }
    }
    for mismatch in mismatches.prefix(6) { print("         \(mismatch)") }
    check(mismatches.isEmpty, "distances between well-known cities are plausible",
          "\(mismatches.count) implausible")
}

// A capital must sit inside its own province's radius. This is the check that
// would expose a province centre placed in the wrong part of the country.
do {
    var failures: [String] = []
    for entry in GazetteerData.china where entry.kind == .province {
        // Match a city entry that shares the province's name.
        guard let city = GazetteerData.china.first(where: {
            $0.kind == .city && $0.names.contains(entry.primaryName)
        }) else { continue }
        let distance = haversine((entry.latitude, entry.longitude), (city.latitude, city.longitude))
        let radius = entry.radiusKilometers ?? entry.kind.defaultRadiusKilometers
        if distance > radius {
            failures.append(String(format: "%@ %.0f km > %.0f km radius",
                                   entry.primaryName, distance, radius))
        }
    }
    for failure in failures.prefix(5) { print("         \(failure)") }
    check(failures.isEmpty, "each province's centre contains its identically-named city",
          "\(failures.count) failures")
}

// ---------------------------------------------------------------------------
section("resolution")

do {
    if case .resolved(let place) = gazetteer.resolve("北京") {
        check(place.name == "北京", "a Chinese name resolves", "\(place.name)")
        check(place.kind == .province, "and keeps its kind")
        check(abs(place.latitude - 39.9042) < 0.01, "with the expected latitude")
    } else {
        check(false, "北京 resolves")
    }
}

do {
    if case .resolved(let place) = gazetteer.resolve("Tokyo") {
        check(place.name == "东京", "an English name resolves to the canonical Chinese name",
              "\(place.name)")
    } else {
        check(false, "Tokyo resolves")
    }
}

do {
    if case .resolved(let place) = gazetteer.resolve("Peking") {
        check(place.name == "北京", "a historic alias resolves", "\(place.name)")
    } else {
        check(false, "Peking resolves")
    }
}

do {
    if case .resolved(let place) = gazetteer.resolve("北京市") {
        check(place.name == "北京", "an administrative suffix is stripped", "\(place.name)")
    } else {
        check(false, "北京市 resolves")
    }
}

do {
    // Users type "北京朝阳" constantly; that exact string is not a place.
    if case .resolved(let place) = gazetteer.resolve("北京朝阳") {
        check(place.name == "北京", "a compound mention resolves by longest prefix",
              "\(place.name)")
    } else {
        check(false, "北京朝阳 resolves")
    }
}

do {
    if case .resolved(let place) = gazetteer.resolve("  上海  ") {
        check(place.name == "上海", "surrounding whitespace is tolerated", "\(place.name)")
    } else {
        check(false, "padded 上海 resolves")
    }
}

// A one-character prefix would match nearly anything, so it must not resolve.
do {
    if case .unknown = gazetteer.resolve("北") {
        check(true, "a single character does not prefix-match")
    } else {
        check(false, "a single character does not prefix-match")
    }
}

do {
    // Unknown must be *reported*, not silently treated as "no filter": dropping
    // the constraint would widen the search to the whole library while still
    // looking like it applied.
    if case .unknown(let name) = gazetteer.resolve("瓦坎达") {
        check(name == "瓦坎达", "an unknown place is reported as unknown", "\(name)")
    } else {
        check(false, "an unknown place reports .unknown")
    }
    check(gazetteer.resolve("").place == nil, "an empty query resolves to nothing")
}

// ---------------------------------------------------------------------------
section("bounding boxes")

do {
    // Hand-computed: 250 km at 39.9042 degrees latitude.
    //   dLat = 250 / 111.32            = 2.246
    //   dLon = 250 / (111.32 * cos(39.9042)) = 2.929
    let place = ResolvedPlace(
        name: "test", latitude: 39.9042, longitude: 116.4074,
        radiusKilometers: 250, kind: .province, matchedName: "test"
    )
    let expectedLatitudeDelta = 250.0 / 111.32
    let expectedLongitudeDelta = 250.0 / (111.32 * cos(39.9042 * .pi / 180))
    let latitudeDelta = place.latitudeRange.upperBound - place.latitude
    let longitudeDelta = place.longitudeRange.upperBound - place.longitude
    check(abs(latitudeDelta - expectedLatitudeDelta) < 0.001,
          "latitude delta matches the hand-computed value",
          String(format: "%.4f vs %.4f", latitudeDelta, expectedLatitudeDelta))
    check(abs(longitudeDelta - expectedLongitudeDelta) < 0.001,
          "longitude delta accounts for the latitude",
          String(format: "%.4f vs %.4f", longitudeDelta, expectedLongitudeDelta))
    check(longitudeDelta > latitudeDelta,
          "a degree of longitude is shorter than a degree of latitude away from the equator")
    check(place.latitudeRange.contains(place.latitude), "the box contains its centre")
    check(place.longitudeRange.contains(place.longitude), "in both axes")
}

do {
    // At high latitude the same radius must span more degrees of longitude.
    let equator = ResolvedPlace(name: "e", latitude: 0, longitude: 0, radiusKilometers: 100,
                                kind: .city, matchedName: "e")
    let arctic = ResolvedPlace(name: "a", latitude: 70, longitude: 0, radiusKilometers: 100,
                               kind: .city, matchedName: "a")
    let equatorSpan = equator.longitudeRange.upperBound - equator.longitudeRange.lowerBound
    let arcticSpan = arctic.longitudeRange.upperBound - arctic.longitudeRange.lowerBound
    check(arcticSpan > equatorSpan * 2,
          "a polar box spans far more longitude",
          String(format: "%.3f vs %.3f", arcticSpan, equatorSpan))
}

do {
    // Exactly at the pole the cosine is undefined; the clamp must keep the range
    // finite and ordered rather than producing NaN or an inverted interval.
    let pole = ResolvedPlace(name: "p", latitude: 90, longitude: 0, radiusKilometers: 50,
                             kind: .city, matchedName: "p")
    check(pole.longitudeRange.lowerBound <= pole.longitudeRange.upperBound,
          "a box at the pole is still a valid interval")
    check(pole.latitudeRange.upperBound <= 90, "and does not exceed the valid latitude range")
    check(!pole.latitudeRange.isEmpty, "and is not empty")
}

do {
    // A box that wraps the antimeridian cannot be expressed as BETWEEN, so it is
    // widened to the whole globe and flagged. Over-selecting is acceptable;
    // silently missing every photo near Fiji is not.
    let fiji = ResolvedPlace(name: "f", latitude: -17.7, longitude: 179.9, radiusKilometers: 400,
                             kind: .province, matchedName: "f")
    check(fiji.crossesAntimeridian, "a box crossing the antimeridian is detected")
    check(fiji.longitudeRange == -180...180,
          "and widened rather than wrapped",
          "\(fiji.longitudeRange)")
}

// ---------------------------------------------------------------------------
section("from a query to rows in the database")

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pv-geo-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

let store = AIPhotoSearchStore(
    databaseURL: workDirectory.appendingPathComponent("AIPhotoSearch.sqlite"),
    embeddingURL: workDirectory.appendingPathComponent("embeddings-v1.bin")
)
try store.open(dimension: 8, sourceModelSHA256: String(repeating: "bb", count: 32))

// A small library with known locations, including a photo with no GPS at all.
struct Fixture {
    var id: String
    var latitude: Double?
    var longitude: Double?
}
let fixtures: [Fixture] = [
    Fixture(id: "beijing-1", latitude: 39.9042, longitude: 116.4074),
    Fixture(id: "beijing-2", latitude: 40.0500, longitude: 116.3000),   // ~20 km out
    Fixture(id: "shanghai-1", latitude: 31.2304, longitude: 121.4737),
    Fixture(id: "tokyo-1", latitude: 35.6762, longitude: 139.6503),
    Fixture(id: "newyork-1", latitude: 40.7128, longitude: -74.0060),
    Fixture(id: "no-gps", latitude: nil, longitude: nil),               // a screenshot
]

for (index, fixture) in fixtures.enumerated() {
    try store.upsertMetadata([AIPhotoSearchStore.AssetMetadata(
        assetID: fixture.id,
        creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
        modificationDate: nil,
        mediaType: 1,
        latitude: fixture.latitude,
        longitude: fixture.longitude
    )])
    var vector = [Float](repeating: 0, count: 8)
    vector[0] = Float(index + 1)
    let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    vector = vector.map { $0 / norm }
    try store.storeEmbedding(assetID: fixture.id, vector: vector)
}

/// The whole chain: text -> analyzer -> gazetteer -> store filter.
func locatedAssetIDs(for query: String) throws -> [String] {
    let analyzer = QueryAnalyzer()
    let plan = analyzer.analyze(query)
    guard let mention = plan.locationQuery else { return [] }
    guard let place = gazetteer.resolve(mention).place else { return [] }
    var filter = AISearchCandidateFilter()
    filter.requiresLocation = true
    filter.latitudeRange = place.latitudeRange
    filter.longitudeRange = place.longitudeRange
    filter.limit = 100
    return try store.candidateAssetIDs(filter: filter)
}

do {
    let beijing = try locatedAssetIDs(for: "在北京拍的照片")
    check(Set(beijing) == ["beijing-1", "beijing-2"],
          "北京 returns both Beijing photos and nothing else", "\(beijing.sorted())")
    check(!beijing.contains("no-gps"), "a photo without GPS is not returned by a location query")
}

do {
    let shanghai = try locatedAssetIDs(for: "在上海拍的照片")
    check(shanghai == ["shanghai-1"], "上海 returns exactly its photo", "\(shanghai)")
}

do {
    let tokyo = try locatedAssetIDs(for: "photos taken in Tokyo")
    check(tokyo == ["tokyo-1"], "an English place name works end to end", "\(tokyo)")
}

do {
    let nowhere = try locatedAssetIDs(for: "在瓦坎达拍的照片")
    check(nowhere.isEmpty, "an unknown place yields nothing rather than everything",
          "\(nowhere)")
}

do {
    // Country-level resolution must be coarse enough to include its cities.
    let japan = try locatedAssetIDs(for: "在日本拍的")
    check(japan.contains("tokyo-1"), "a country query includes its cities", "\(japan)")
}

do {
    // Two different cities must not bleed into each other.
    let newYork = try locatedAssetIDs(for: "in New York")
    check(newYork == ["newyork-1"], "New York does not pick up Beijing", "\(newYork)")
    check(!newYork.contains("beijing-1"), "and the two boxes are disjoint")
}

// ---------------------------------------------------------------------------
section("results are ordered and bounded")

do {
    let beijing = try locatedAssetIDs(for: "在北京拍的照片")
    check(beijing.count == 2, "the count is exactly the geotagged matches")
    // The filter orders by creation date descending, so the later fixture wins.
    check(beijing.first == "beijing-2", "results are newest-first", "\(beijing)")
}

// ---------------------------------------------------------------------------
print("\nchecks: \(checks), failures: \(failures)")
if failures == 0 {
    print("RESULT: all \(checks) gazetteer checks passed")
    exit(0)
} else {
    print("RESULT: \(failures) of \(checks) checks FAILED")
    exit(1)
}
