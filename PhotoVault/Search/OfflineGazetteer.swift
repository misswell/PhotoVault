//
//  OfflineGazetteer.swift
//  PhotoVault
//
//  Resolves a place name to a coordinate box, entirely on device.
//
//  Why a radius and not a polygon
//  ------------------------------
//  A real boundary dataset would answer "was this photo taken in 朝阳区" exactly.
//  It would also be tens of megabytes, need a licensing review, and be wrong in
//  a different way at the edges. A centre plus a kind-appropriate radius is
//  coarse, but its error is *predictable*: it over-selects near the boundary
//  rather than silently excluding a photo taken ten metres outside a line nobody
//  can see. For "在东京拍的照片" that is the right trade.
//
//  The radius is a property of what the place *is* (a landmark is not a
//  province), so it comes from `PlaceKind` rather than being tuned per entry.
//
//  Failing to resolve is reported, never silently ignored
//  ------------------------------------------------------
//  The analyzer extracts any place-like mention, including ones no gazetteer
//  will know. Dropping the filter in that case would quietly widen the search to
//  the whole library while still looking like it applied the constraint, so
//  resolution failure is surfaced to the caller instead.
//

import Foundation

/// A resolved place, with the box its photos are expected to fall inside.
struct ResolvedPlace: Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusKilometers: Double
    var kind: PlaceKind
    /// `true` when the caller asked for a name that resolved only by prefix or
    /// alias, so the UI can say what it actually matched.
    var matchedName: String

    var latitudeRange: ClosedRange<Double> {
        let delta = radiusKilometers / OfflineGazetteer.kilometersPerDegreeLatitude
        return max(-90, latitude - delta)...min(90, latitude + delta)
    }

    var longitudeRange: ClosedRange<Double> {
        // Degrees of longitude shrink toward the poles, and the scale is
        // undefined exactly at them. Clamping the cosine keeps a polar place from
        // producing an infinite span.
        let cosine = max(cos(latitude * .pi / 180), OfflineGazetteer.minimumLongitudeCosine)
        let delta = radiusKilometers / (OfflineGazetteer.kilometersPerDegreeLatitude * cosine)
        let lower = longitude - delta
        let upper = longitude + delta
        // Anything crossing the antimeridian, or wider than the globe, becomes
        // the full range. Clamping to [-180, 180] instead -- the first
        // implementation -- kept the interval valid but *dropped the far side of
        // the box*, so a search near Fiji silently missed every photo on the
        // other side of the line. Over-selecting is recoverable; missing is not.
        if lower < -180 || upper > 180 || delta >= 180 {
            return -180...180
        }
        return lower...upper
    }

    /// `true` when the box would cross the antimeridian (the ±180 line).
    ///
    /// The store filters longitude with `BETWEEN`, which cannot express a range
    /// that wraps. Rather than pretend, the range is widened to the whole globe
    /// and this flag lets the caller say so; every photo still passes, so the
    /// result over-selects instead of missing Fiji.
    var crossesAntimeridian: Bool {
        let delta = radiusKilometers / (OfflineGazetteer.kilometersPerDegreeLatitude
            * max(cos(latitude * .pi / 180), OfflineGazetteer.minimumLongitudeCosine))
        return longitude - delta < -180 || longitude + delta > 180
    }
}

enum GazetteerResolution: Equatable, Sendable {
    case resolved(ResolvedPlace)
    /// The name was looked up and is not in the database. Distinct from
    /// "resolved", because the caller must tell the user rather than silently
    /// searching the whole library.
    case unknown(String)

    var place: ResolvedPlace? {
        if case .resolved(let place) = self { return place }
        return nil
    }
}

final class OfflineGazetteer: Sendable {

    static let kilometersPerDegreeLatitude = 111.32
    /// cos(latitude) at 89.9 degrees is 0.0017; below this a longitude span
    /// explodes for no benefit.
    static let minimumLongitudeCosine = 0.01
    /// Suffixes stripped before lookup: "北京市" and "北京" are the same place.
    static let administrativeSuffixes = [
        "特别行政区", "自治区", "自治州", "自治县", "地区", "新区",
        "省", "市", "县", "区", "镇", "乡", "街道",
    ]

    private let entries: [PlaceEntry]
    /// Normalised name -> indices into `entries`. An array because a name can
    /// legitimately be ambiguous ("朝阳" is a district in both Beijing and
    /// Changchun); the first entry wins and the ambiguity is documented rather
    /// than hidden.
    private let index: [String: [Int]]

    init(entries: [PlaceEntry] = GazetteerData.all) {
        self.entries = entries
        var index: [String: [Int]] = [:]
        for (position, entry) in entries.enumerated() {
            for name in entry.names {
                for key in Self.lookupKeys(for: name) {
                    index[key, default: []].append(position)
                }
            }
        }
        self.index = index
    }

    var count: Int { entries.count }

    /// The forms a name may be looked up by: itself, and itself with any
    /// administrative suffix removed. Case-folded for the Latin aliases.
    static func lookupKeys(for name: String) -> [String] {
        var keys: Set<String> = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        keys.insert(trimmed)
        var stripped = trimmed
        var changed = true
        while changed {
            changed = false
            for suffix in administrativeSuffixes where stripped.hasSuffix(suffix) && stripped.count > suffix.count {
                stripped = String(stripped.dropLast(suffix.count))
                keys.insert(stripped)
                changed = true
                break
            }
        }
        return keys.map { $0.lowercased() }
    }

    /// Exact match only, with no prefix fallback.
    ///
    /// Needed to cut a place name out of a longer clause: `resolve` would match
    /// "北京" inside "北京烤鸭" by prefix, but the caller has to know *which*
    /// characters matched in order to keep the rest. Returning the place without
    /// that boundary would silently discard "烤鸭".
    func resolveExact(_ text: String) -> ResolvedPlace? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        for key in Self.lookupKeys(for: normalized) {
            if let position = index[key]?.first {
                return makeResolved(
                    entry: entries[position], query: text,
                    matchedName: entries[position].primaryName
                )
            }
        }
        return nil
    }

    /// Resolves a place mention.
    ///
    /// Order: exact (or suffix-stripped) match, then longest prefix. Prefix
    /// matching is what makes "北京朝阳" resolve even though that exact string is
    /// not a place -- something users type constantly and a strict dictionary
    /// would reject.
    func resolve(_ query: String) -> GazetteerResolution {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .unknown(query) }

        // Exact, including administrative-suffix variants of the query itself.
        for key in Self.lookupKeys(for: normalized) {
            if let position = index[key]?.first {
                return .resolved(makeResolved(entry: entries[position], query: query, matchedName: entries[position].primaryName))
            }
        }

        // Longest *token* prefix: "New York City" -> "New York" -> hit. Tried
        // before character prefixes because a multi-word name is a whole unit,
        // and dropping a word is a better candidate than truncating one.
        var tokens = normalized.split(separator: " ").map(String.init)
        while tokens.count > 1 {
            tokens.removeLast()
            let candidate = tokens.joined(separator: " ")
            if let position = index[candidate]?.first {
                return .resolved(makeResolved(
                    entry: entries[position], query: query,
                    matchedName: entries[position].primaryName
                ))
            }
        }

        // Longest character prefix. "北京朝阳" -> try "北京朝", then "北京" -> hit.
        let characters = Array(normalized)
        // Two characters is the shortest meaningful Chinese place name; a single
        // character would match almost everything.
        var length = characters.count - 1
        while length >= 2 {
            let prefix = String(characters[0..<length])
            if let position = index[prefix]?.first {
                return .resolved(makeResolved(entry: entries[position], query: query, matchedName: entries[position].primaryName))
            }
            length -= 1
        }

        return .unknown(query)
    }

    private func makeResolved(entry: PlaceEntry, query: String, matchedName: String) -> ResolvedPlace {
        ResolvedPlace(
            name: entry.primaryName,
            latitude: entry.latitude,
            longitude: entry.longitude,
            radiusKilometers: entry.radiusKilometers ?? entry.kind.defaultRadiusKilometers,
            kind: entry.kind,
            matchedName: matchedName
        )
    }

    /// All entries, for a settings screen or a coverage check.
    var allEntries: [PlaceEntry] { entries }

    /// Self-consistency check, cheap enough to run from a test or a debug menu.
    ///
    /// Catches the data errors that matter: a coordinate outside the valid range
    /// would silently produce an empty or absurd box, and a duplicate name would
    /// make resolution nondeterministic in a way that depends on array order.
    func validate() -> [String] {
        var problems: [String] = []
        var seen: [String: String] = [:]
        for entry in entries {
            guard (-90...90).contains(entry.latitude) else {
                problems.append("\(entry.primaryName): latitude \(entry.latitude) out of range")
                continue
            }
            guard (-180...180).contains(entry.longitude) else {
                problems.append("\(entry.primaryName): longitude \(entry.longitude) out of range")
                continue
            }
            let radius = entry.radiusKilometers ?? entry.kind.defaultRadiusKilometers
            guard radius > 0, radius <= 2_000 else {
                problems.append("\(entry.primaryName): radius \(radius) km is implausible")
                continue
            }
            // At the poles a latitude band must still be a real interval.
            let place = makeResolved(entry: entry, query: entry.primaryName, matchedName: entry.primaryName)
            guard place.latitudeRange.lowerBound <= place.latitudeRange.upperBound else {
                problems.append("\(entry.primaryName): inverted latitude range")
                continue
            }
            guard place.longitudeRange.lowerBound <= place.longitudeRange.upperBound else {
                problems.append("\(entry.primaryName): inverted longitude range")
                continue
            }
            for name in entry.names {
                let key = name.lowercased()
                if let existing = seen[key], existing != entry.primaryName {
                    problems.append("duplicate name \(name): \(existing) and \(entry.primaryName)")
                }
                seen[key] = entry.primaryName
            }
        }
        return problems
    }
}
