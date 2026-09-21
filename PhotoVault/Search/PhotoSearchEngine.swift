//
//  PhotoSearchEngine.swift
//  PhotoVault
//
//  Runs one search: text in, ranked photos out.
//
//  This is the piece that makes the rest a *search* rather than a set of
//  verified libraries. Its job is to decide, for a given query, what work is
//  actually necessary -- because the expensive path (embedding text, scanning
//  vectors) is only needed for the part of a query a vector model can express.
//
//  The ordering rule the whole design rests on:
//
//      the model decides what a photo *looks like*;
//      this engine decides which photos are even candidates, and how the
//      model's opinions combine.
//
//  So a query like "2023年在北京拍的发票" never reaches the vector scan for the
//  date or the place: those are answered by SQL, and the vector model is asked
//  only about the part it is good at. Scoring 100k rows to answer a question
//  about a calendar is the failure mode this exists to prevent.
//
//  Filter-first, not post-filter
//  -----------------------------
//  Candidates are selected in SQLite *before* any vector is computed. The
//  alternative -- rank everything, then drop what doesn't match -- returns fewer
//  than K results whenever the filter is selective, and looks like the filter
//  working. Restricting the scan is both correct and, for a selective filter,
//  far less work.
//

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Text encoding

/// Turns a query into a vector.
///
/// A protocol rather than a concrete dependency so the engine can be tested
/// against designed similarities instead of a 376 MB model. The retrieval
/// *mechanics* -- how clauses combine, how negation rejects, how filters
/// restrict -- are what need testing, and they are testable far more sharply
/// with vectors whose relationships are known exactly than with real ones whose
/// relationships are merely plausible.
protocol QueryTextEncoding: Sendable {
    func encodeQuery(_ text: String) throws -> [Float]
    /// Dimension the encoder produces, checked against the matrix.
    var dimension: Int { get }
}

/// The shipping encoder: SigLIP2 text tower, on device.
final class SigLIP2QueryEncoder: QueryTextEncoding, @unchecked Sendable {
    private let encoder: SigLIP2TextEncoder
    private let tokenizer: SigLIP2Tokenizer

    init(encoder: SigLIP2TextEncoder, tokenizer: SigLIP2Tokenizer) {
        self.encoder = encoder
        self.tokenizer = tokenizer
    }

    var dimension: Int { encoder.dimension }

    func encodeQuery(_ text: String) throws -> [Float] {
        try encoder.embedding(text: text, tokenizer: tokenizer)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Results

struct PhotoSearchHit: Equatable, Sendable {
    var assetID: String
    /// Cosine similarity after combination. Metadata-only hits carry
    /// `PhotoSearchEngine.metadataOnlyScore`, because there is nothing to rank
    /// them against and pretending otherwise would invent a number.
    var score: Float
    /// The clauses this asset survived. Empty for a metadata-only query.
    var matchedClauses: [String]
    /// `true` when the hit was selected by metadata alone, so the UI can avoid
    /// presenting a relevance figure that does not exist.
    var isMetadataOnly: Bool
}

struct PhotoSearchDiagnostics: Equatable, Sendable {
    /// Rows the metadata filter admitted, before any vector was computed.
    var candidateCount = 0
    /// Rows actually scored. Equal to `candidateCount` when vectors were used.
    var scoredCount = 0
    var usedVectorSearch = false
    var encodedClauses: [String] = []
    /// Set when the query named a place the gazetteer does not know. The caller
    /// must surface this: the alternative is a search that silently ignores part
    /// of what was asked for.
    var unresolvedLocation: String?
    var warnings: [String] = []
    var elapsedSeconds: TimeInterval = 0
}

struct PhotoSearchResponse: Equatable, Sendable {
    var hits: [PhotoSearchHit]
    var plan: QueryPlan
    var diagnostics: PhotoSearchDiagnostics
}

// ---------------------------------------------------------------------------
// MARK: - Configuration

struct PhotoSearchConfiguration: Equatable, Sendable {
    /// Cosine floor.
    ///
    /// Measured on a real 17-photo library through the shipping pipeline, this
    /// floor currently rejects **nothing**: every asset cleared 0.02 for every
    /// query tried, including ones with no plausible match ("a red square" kept
    /// 17/17, mean 0.060; "mountain waterfall" kept 16/17, mean 0.044). Retrieved
    /// scores occupied a narrow band roughly 0.05-0.14, so the old claim here --
    /// that a small positive floor "removes the long tail of noise" -- is not
    /// supported. The tail sits well above the floor.
    ///
    /// The value is left where it is, deliberately. The discrimination that does
    /// exist is in the *ordering*, not the threshold: for "green" the top hit
    /// scored 0.136 against a ~0.072 tail. Raising the floor to where it would
    /// actually bite (~0.08) would cut into that same band and start returning
    /// nothing for hard queries -- which the user reads as "the feature is
    /// broken", the one outcome worth avoiding.
    ///
    /// So: not a noise filter, and not tuned from a 17-photo corpus, which would
    /// only overfit. If stronger filtering is ever wanted, the mechanism has to be
    /// *relative* (a margin below the top score, or a per-query calibration),
    /// because an absolute floor cannot separate a 0.088 top hit from a 0.078
    /// tail without also discarding the hit.
    var minimumScore: Float = 0.02
    /// How similar a *negative* clause must be before the asset is rejected.
    /// Higher than `minimumScore` on purpose: excluding a photo needs more
    /// evidence than including one, because "not a cat" wrongly applied is
    /// indistinguishable from a missing photo.
    var negativeScoreCeiling: Float = 0.10
    /// Upper bound on rows the metadata filter will hand to the scorer. A filter
    /// matching the whole library is not a filter, and scoring 100k rows for a
    /// query that named a date is the case this design exists to avoid.
    var maximumCandidates: Int = 50_000
    /// Ceiling on `limit`, so a caller cannot accidentally ask for the library.
    var maximumResults: Int = 500

    static let `default` = PhotoSearchConfiguration()
}

// ---------------------------------------------------------------------------
// MARK: - Engine

final class PhotoSearchEngine: Sendable {

    /// Score carried by a metadata-only hit. Not a similarity: it exists so the
    /// result type needs no optional, and `isMetadataOnly` is what callers check.
    static let metadataOnlyScore: Float = 1.0

    private let store: AIPhotoSearchStore
    private let embeddings: EmbeddingMatrixReader
    private let encoder: QueryTextEncoding
    private let gazetteer: OfflineGazetteer
    private let analyzer: QueryAnalyzer
    private let configuration: PhotoSearchConfiguration

    init(
        store: AIPhotoSearchStore,
        embeddings: EmbeddingMatrixReader,
        encoder: QueryTextEncoding,
        gazetteer: OfflineGazetteer = OfflineGazetteer(),
        analyzer: QueryAnalyzer = QueryAnalyzer(),
        configuration: PhotoSearchConfiguration = .default
    ) {
        self.store = store
        self.embeddings = embeddings
        self.encoder = encoder
        self.gazetteer = gazetteer
        self.analyzer = analyzer
        self.configuration = configuration
    }

    func search(_ query: String, limit: Int = 60) throws -> PhotoSearchResponse {
        let started = Date()
        let plan = analyzer.analyze(query)
        var diagnostics = PhotoSearchDiagnostics()
        let effectiveLimit = max(1, min(limit, configuration.maximumResults))

        var searchPlan = plan

        // A query that constrains nothing is a mistake, not a request for the
        // whole library. Returning everything would look like a result set and
        // be useless, so it is reported as empty with a reason.
        guard !searchPlan.isEmpty else {
            diagnostics.warnings.append("the query contained nothing searchable")
            diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
            return PhotoSearchResponse(hits: [], plan: searchPlan, diagnostics: diagnostics)
        }

        // -- 1. Metadata filter: everything the vector model is bad at --------
        // A place named without a locative marker ("北京 猫", "tokyo cat") is
        // found here rather than in the analyzer: knowing that 北京 is a place is
        // a *lookup* fact, and the gazetteer lives on this side of the boundary.
        let impliedPlace = extractImpliedPlace(from: &searchPlan)
        var filter = try makeFilter(
            from: searchPlan, impliedPlace: impliedPlace, diagnostics: &diagnostics
        )
        filter.limit = configuration.maximumCandidates

        // -- 2. Clauses the model must answer ---------------------------------
        var positiveClauses = searchPlan.positiveVisualClauses
        // An unresolved place is put back as a visual clause rather than dropped.
        // The mention was in the query for a reason; letting the vector model
        // have a guess is recoverable, whereas discarding it silently changes
        // what was asked.
        if let unresolved = diagnostics.unresolvedLocation {
            positiveClauses.append(unresolved)
        }
        let needsVectors = !positiveClauses.isEmpty || !searchPlan.negativeVisualClauses.isEmpty

        // -- 3. Metadata-only: order by recency and stop -----------------------
        guard needsVectors else {
            let assetIDs = try store.candidateAssetIDs(filter: filter)
            diagnostics.candidateCount = assetIDs.count
            diagnostics.scoredCount = 0
            diagnostics.usedVectorSearch = false
            let hits = assetIDs.prefix(effectiveLimit).map {
                PhotoSearchHit(
                    assetID: $0, score: Self.metadataOnlyScore,
                    matchedClauses: [], isMetadataOnly: true
                )
            }
            diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
            return PhotoSearchResponse(hits: Array(hits), plan: searchPlan, diagnostics: diagnostics)
        }

        guard encoder.dimension == embeddings.dimension else {
            throw PhotoSearchError.dimensionMismatch(
                encoder: encoder.dimension, matrix: embeddings.dimension
            )
        }

        // -- 4. Candidates, then their vectors ---------------------------------
        let candidateAssetIDs = try store.candidateAssetIDs(filter: filter)
        diagnostics.candidateCount = candidateAssetIDs.count
        guard !candidateAssetIDs.isEmpty else {
            diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
            return PhotoSearchResponse(hits: [], plan: searchPlan, diagnostics: diagnostics)
        }

        let slotByAssetID = try store.embeddingSlots(for: candidateAssetIDs)
        // Order is preserved from the SQL query; the slot lookup is a dictionary
        // so it must not be used to drive iteration.
        var orderedAssetIDs: [String] = []
        var orderedSlots: [Int] = []
        orderedAssetIDs.reserveCapacity(candidateAssetIDs.count)
        orderedSlots.reserveCapacity(candidateAssetIDs.count)
        for assetID in candidateAssetIDs {
            guard let slot = slotByAssetID[assetID] else { continue }
            orderedAssetIDs.append(assetID)
            orderedSlots.append(slot)
        }
        guard !orderedSlots.isEmpty else {
            diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
            return PhotoSearchResponse(hits: [], plan: searchPlan, diagnostics: diagnostics)
        }

        // -- 5. Score each clause over the candidate set only ------------------
        var positiveScores: [[Float]] = []
        for clause in positiveClauses {
            let vector = try encoder.encodeQuery(clause)
            positiveScores.append(try embeddings.scores(query: vector, slots: orderedSlots))
            diagnostics.encodedClauses.append(clause)
        }
        var negativeScores: [[Float]] = []
        for clause in searchPlan.negativeVisualClauses {
            let vector = try encoder.encodeQuery(clause)
            negativeScores.append(try embeddings.scores(query: vector, slots: orderedSlots))
            diagnostics.encodedClauses.append("NOT \(clause)")
        }
        diagnostics.usedVectorSearch = true
        diagnostics.scoredCount = orderedSlots.count

        // -- 6. Combine --------------------------------------------------------
        var hits: [PhotoSearchHit] = []
        hits.reserveCapacity(orderedAssetIDs.count)
        for (index, assetID) in orderedAssetIDs.enumerated() {
            var combined: Float
            switch searchPlan.combine {
            case .all:
                // `min` is a heuristic for AND, not a proof of it: a true AND
                // needs a per-concept threshold, and one low score currently
                // drags the whole result down without evidence that the concept
                // is *absent*. It is the conservative direction -- an AND that
                // demands every concept be present rather than averaging them
                // away -- which is what a user typing "cat on a beach" wants.
                combined = positiveScores.map { $0[index] }.min() ?? 0
            case .any:
                combined = positiveScores.map { $0[index] }.max() ?? 0
            }

            // Negation rejects rather than penalises. Subtracting a score would
            // let a strong enough positive clause overwhelm "not a cat", which
            // is the one outcome the user explicitly ruled out.
            if negativeScores.contains(where: { $0[index] > configuration.negativeScoreCeiling }) {
                continue
            }
            guard combined >= configuration.minimumScore else { continue }

            hits.append(PhotoSearchHit(
                assetID: assetID, score: combined,
                matchedClauses: positiveClauses, isMetadataOnly: false
            ))
        }

        hits.sort { first, second in
            // Ties break on asset ID so the order is deterministic; an unstable
            // sort here would make results shuffle between identical searches.
            first.score == second.score ? first.assetID < second.assetID : first.score > second.score
        }
        if hits.count > effectiveLimit { hits.removeLast(hits.count - effectiveLimit) }

        diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
        return PhotoSearchResponse(hits: hits, plan: searchPlan, diagnostics: diagnostics)
    }

    // MARK: - Similar-image search

    /// Finds photos that look like a given one.
    ///
    /// This is the one search that never touches the text tower. The query
    /// vector is the reference asset's own stored embedding, so "more like this"
    /// is exactly the operation the index was built to answer: one dot product
    /// per candidate against a vector that is already in the matrix.
    ///
    /// Reading the vector back from the matrix rather than re-encoding the image
    /// is deliberate and is not a shortcut. The stored row is what every other
    /// search compares against, so using it makes the reference and the results
    /// live in the same space by construction. Re-encoding would introduce a
    /// second, slightly different vector -- and float16 storage alone moves a
    /// unit vector by ~1.65e-5 -- so results could differ from an identical
    /// search run a moment earlier.
    func search(similarTo assetID: String, limit: Int = 60) throws -> PhotoSearchResponse {
        let started = Date()
        var diagnostics = PhotoSearchDiagnostics()
        let effectiveLimit = max(1, min(limit, configuration.maximumResults))

        // An asset with no embedding cannot be a reference. Reporting an empty
        // result with a reason beats throwing: an unindexed photo is a normal
        // state while the index is still filling, not an error.
        guard let referenceSlot = try store.embeddingSlots(for: [assetID])[assetID] else {
            diagnostics.warnings.append(
                "that photo is not indexed yet, so there is nothing to compare against"
            )
            diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
            return PhotoSearchResponse(
                hits: [], plan: QueryPlan(), diagnostics: diagnostics
            )
        }

        guard encoder.dimension == embeddings.dimension else {
            throw PhotoSearchError.dimensionMismatch(
                encoder: encoder.dimension, matrix: embeddings.dimension
            )
        }

        // No metadata filter: "more like this" is a statement about appearance,
        // and narrowing it by date or place would silently answer a different
        // question than the one asked.
        var filter = AISearchCandidateFilter()
        filter.limit = configuration.maximumCandidates
        let candidateAssetIDs = try store.candidateAssetIDs(filter: filter)
        diagnostics.candidateCount = candidateAssetIDs.count
        guard !candidateAssetIDs.isEmpty else {
            diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
            return PhotoSearchResponse(hits: [], plan: QueryPlan(), diagnostics: diagnostics)
        }

        let slotByAssetID = try store.embeddingSlots(for: candidateAssetIDs)
        var orderedAssetIDs: [String] = []
        var orderedSlots: [Int] = []
        for candidate in candidateAssetIDs {
            guard let slot = slotByAssetID[candidate] else { continue }
            // The reference must not rank against itself, or it would always be
            // the top hit at a similarity of 1.0 and the feature would look
            // broken in exactly the way it looks when it works.
            guard candidate != assetID else { continue }
            orderedAssetIDs.append(candidate)
            orderedSlots.append(slot)
        }
        guard !orderedSlots.isEmpty else {
            diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
            return PhotoSearchResponse(hits: [], plan: QueryPlan(), diagnostics: diagnostics)
        }

        let query = try embeddings.row(at: referenceSlot)
        let scores = try embeddings.scores(query: query, slots: orderedSlots)
        diagnostics.usedVectorSearch = true
        diagnostics.scoredCount = orderedSlots.count
        diagnostics.encodedClauses = []

        var hits: [PhotoSearchHit] = []
        hits.reserveCapacity(orderedAssetIDs.count)
        for (index, candidate) in orderedAssetIDs.enumerated() {
            // The same floor as a text search, for the same reason: below it the
            // "similar" claim is not supported by the vectors. An unrelated photo
            // still has a similarity of roughly 0.05.
            guard scores[index] >= configuration.minimumScore else { continue }
            hits.append(PhotoSearchHit(
                assetID: candidate, score: scores[index],
                matchedClauses: [], isMetadataOnly: false
            ))
        }
        hits.sort { first, second in
            first.score == second.score ? first.assetID < second.assetID : first.score > second.score
        }
        if hits.count > effectiveLimit { hits.removeLast(hits.count - effectiveLimit) }

        diagnostics.elapsedSeconds = Date().timeIntervalSince(started)
        return PhotoSearchResponse(hits: hits, plan: QueryPlan(), diagnostics: diagnostics)
    }

    /// Applies a place's bounding box to the filter and warns about the one case
    /// the box cannot express.
    private func apply(
        place: ResolvedPlace,
        to filter: inout AISearchCandidateFilter,
        diagnostics: inout PhotoSearchDiagnostics
    ) {
        filter.requiresLocation = true
        filter.latitudeRange = place.latitudeRange
        filter.longitudeRange = place.longitudeRange
        if place.crossesAntimeridian {
            diagnostics.warnings.append(
                "the search area around \(place.name) crosses the antimeridian; "
                + "longitude filtering is wider than the place"
            )
        }
    }

    /// Finds a place named without a locative marker and removes it from the
    /// clause it was hiding in.
    ///
    /// "北京 猫" and "tokyo cat" are how people actually type, and without this
    /// the place name is just another word handed to a text tower that has no
    /// reliable idea where a photo was taken -- so the search would be geo-blind
    /// for exactly the queries Phase 8 exists to serve.
    ///
    /// Only runs when the analyzer found no explicit location, so an explicit
    /// "in Tokyo" is never second-guessed.
    ///
    /// Known false-positive class: a place name embedded in a longer common word
    /// ("大理石" contains 大理, "长春花" contains 长春). The cost is a needlessly
    /// narrowed result set, and detecting it properly needs a language model --
    /// which is the thing being avoided. Longest match first keeps the common
    /// cases right.
    private func extractImpliedPlace(from plan: inout QueryPlan) -> ResolvedPlace? {
        guard plan.locationQuery == nil else { return nil }
        var found: ResolvedPlace?
        var remainingClauses: [String] = []
        remainingClauses.reserveCapacity(plan.positiveVisualClauses.count)

        for clause in plan.positiveVisualClauses {
            // A phrase handed to the model whole is worth more than its parts, so
            // only the earliest clause is mined and only once per query.
            guard found == nil, clause.count >= 2 else {
                remainingClauses.append(clause)
                continue
            }
            guard let (place, remainder) = longestExactPlace(in: clause) else {
                remainingClauses.append(clause)
                continue
            }
            found = place
            // An empty remainder means the clause was only the place, which makes
            // this a metadata query and must not leave a blank clause behind --
            // a blank string would be encoded and matched against nothing.
            if !remainder.isEmpty { remainingClauses.append(remainder) }
        }

        if found != nil { plan.positiveVisualClauses = remainingClauses }
        return found
    }

    /// Longest exact gazetteer match inside a clause, with the rest of the clause.
    private func longestExactPlace(in clause: String) -> (ResolvedPlace, String)? {
        let characters = Array(clause)
        // Eight characters covers the longest names in the gazetteer
        // ("宁夏回族自治区" is seven) without turning the scan into a full
        // quadratic pass over a long phrase.
        let maximumLength = min(8, characters.count)
        guard maximumLength >= 2 else { return nil }
        for length in stride(from: maximumLength, through: 2, by: -1) {
            for start in 0...(characters.count - length) {
                let candidate = String(characters[start..<(start + length)])
                // A candidate of only whitespace or punctuation is not a name.
                guard candidate.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
                guard let place = gazetteer.resolveExact(candidate) else { continue }
                var remainder = String(characters[0..<start])
                    + String(characters[(start + length)...])
                remainder = remainder.split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                return (place, remainder)
            }
        }
        return nil
    }

    // -----------------------------------------------------------------------
    // MARK: - Metadata filter

    /// Translates the parts of a query that are not visual into SQL.
    ///
    /// Each piece is independent: a date filter with no place still works, and a
    /// query naming only a month never touches the vector index.
    private func makeFilter(
        from plan: QueryPlan,
        impliedPlace: ResolvedPlace?,
        diagnostics: inout PhotoSearchDiagnostics
    ) throws -> AISearchCandidateFilter {
        var filter = AISearchCandidateFilter()

        if let dateFilter = plan.dateFilter {
            filter.creationDateAfter = dateFilter.start
            filter.creationDateBefore = dateFilter.end
        }
        switch plan.mediaFilter?.kind {
        case .image?: filter.mediaType = 1
        case .video?: filter.mediaType = 2
        // Screenshots and Live Photos are subtypes, not media types, so they
        // cannot be expressed through this field and are left for Phase 12
        // rather than silently mapped to the wrong column.
        default: break
        }
        if plan.mediaFilter?.favouritesOnly == true { filter.favoritesOnly = true }

        if let place = impliedPlace {
            apply(place: place, to: &filter, diagnostics: &diagnostics)
        }

        if let mention = plan.locationQuery {
            switch gazetteer.resolve(mention) {
            case .resolved(let place):
                apply(place: place, to: &filter, diagnostics: &diagnostics)
            case .unknown(let name):
                // Reported, not ignored: dropping the constraint would widen the
                // search to the whole library while still looking like it applied.
                diagnostics.unresolvedLocation = name
                diagnostics.warnings.append("no location known for “\(name)”")
            }
        }

        filter.requiredTextTerms = plan.ocrTerms
        // A negative OCR term is a hard exclusion: the text either appears or it
        // does not, with none of the ambiguity a visual negation carries.
        filter.excludedTextTerms = plan.excludedOCRTerms
        return filter
    }
}

enum PhotoSearchError: LocalizedError {
    case dimensionMismatch(encoder: Int, matrix: Int)

    var errorDescription: String? {
        switch self {
        case .dimensionMismatch(let encoder, let matrix):
            """
            the query encoder produces \(encoder)-dimensional vectors but the \
            index stores \(matrix); searching would compare unlike vectors
            """
        }
    }
}
