//
//  QueryAnalyzer.swift
//  PhotoVault
//
//  Turns a natural-language query into a structured plan.
//
//  Design principle, and the one that matters most here
//  ---------------------------------------------------
//  The model understands photos; this understands what the user is asking for.
//  Those are different jobs, and the boundary between them is the whole design.
//
//  So the analyzer extracts **only what the vector model cannot express**:
//
//      cannot express          ->  extracted here
//      ------------------------------------------------------------------
//      a date or date range        dateFilter
//      a place                     locationQuery
//      logical negation            negative clauses
//      exact text                  ocrTerms
//      media kind, favourite       mediaFilter
//      a count                     countConstraint
//      "and" vs "or" of concepts   combine + multiple clauses
//
//  Everything else is passed to the model close to verbatim. Stripping particles
//  and rewriting the phrasing feels like doing more, but it degrades the model's
//  input: SigLIP2 tokenizes Chinese natively and was trained on text like this.
//  Removing words it understands is a loss, not a cleanup. This is the deliberate
//  opposite of building "one model plus a cosine similarity" -- but the extra
//  machinery belongs in the *engine*, not in mangling the prompt.
//
//  Determinism
//  -----------
//  No LLM, no network, no hidden state. Relative dates ("last week") depend on
//  the current time, so `now` and `calendar` are injected rather than read from
//  the environment: a test that says "last month" must not change meaning
//  depending on when it runs.
//

import Foundation

/// How multiple visual clauses combine.
enum QueryCombine: String, Equatable, Sendable {
    /// Every clause should be present ("dog and beach"). Implemented as the
    /// minimum per-clause score: a photo must satisfy the weakest clause.
    case all
    /// Any clause may match ("dog or cat"). Implemented as the maximum: the best
    /// matching clause decides.
    case any
}

/// A half-open date range `[start, end)`, or an open-ended one.
struct DateRangeFilter: Equatable, Sendable {
    var start: Date?
    var end: Date?
    /// Human-readable description of what was understood, shown to the user so a
    /// misparse is visible instead of producing a mysteriously empty result.
    var label: String

    var isEmpty: Bool { start == nil && end == nil }
}

/// What kind of asset the query is asking for.
struct MediaFilter: Equatable, Sendable {
    enum Kind: String, Sendable {
        case image, video, screenshot, livePhoto
    }
    var kind: Kind
    /// `true` for "收藏的", "favourite", "starred".
    var favouritesOnly: Bool = false

    init(kind: Kind, favouritesOnly: Bool = false) {
        self.kind = kind
        self.favouritesOnly = favouritesOnly
    }
}

/// The structured interpretation of one query.
struct QueryPlan: Equatable, Sendable {
    /// Positive concepts for the vector search. Empty means the query is purely
    /// metadata-driven and no embedding needs to be computed at all.
    var positiveVisualClauses: [String] = []
    /// Concepts the photo must *not* match. A cosine score cannot express
    /// absence, so the engine rejects a candidate whose score against a negative
    /// clause exceeds a ceiling.
    var negativeVisualClauses: [String] = []
    /// How `positiveVisualClauses` combine.
    var combine: QueryCombine = .all
    /// Substrings that must appear in the OCR text, ANDed.
    var ocrTerms: [String] = []
    /// Substrings that must not appear in the OCR text.
    var excludedOCRTerms: [String] = []
    var dateFilter: DateRangeFilter?
    /// A place name as written. Resolution to coordinates is Phase 8's job; the
    /// analyzer only recognises that a place was mentioned.
    var locationQuery: String?
    var mediaFilter: MediaFilter?
    /// "一张"/"a single" is a *result* constraint, not an index constraint, so it
    /// is carried separately rather than folded into the media filter.
    var countConstraint: Int?
    /// Fragments that looked like a filter but could not be interpreted. Surfaced
    /// so the UI can say so; silently ignoring part of a query is how search
    /// starts feeling broken.
    var unparsed: [String] = []

    /// `true` when the vector search can be skipped entirely.
    var isMetadataOnly: Bool { positiveVisualClauses.isEmpty }

    /// The text to send to the text tower for one clause.
    var semanticText: String? { positiveVisualClauses.first }

    var isEmpty: Bool {
        positiveVisualClauses.isEmpty && negativeVisualClauses.isEmpty
            && ocrTerms.isEmpty && excludedOCRTerms.isEmpty
            && dateFilter == nil && locationQuery == nil && mediaFilter == nil
            && countConstraint == nil
    }
}

/// A range of a calendar unit, used while parsing.
private struct UnitRange {
    var start: Date
    var end: Date
}

struct QueryAnalyzer: Sendable {

    var calendar: Calendar
    /// Injected so tests are stable; production passes `Date()`.
    var now: Date

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Lexicon

    /// Words that mean "the user is asking for something" and carry no visual
    /// meaning. Only stripped from the *front* of a clause.
    private static let leadingFillers = [
        // Camera verbs, longest first. These become *leading* only after the date
        // is extracted: "2023年拍的猫" still has 拍的 in the middle when the
        // suffix stripper runs, so the clause went to the text tower as "拍的猫".
        // A model asked about "拍的猫" is being asked about a shutter action.
        "拍摄的", "拍照的", "拍的", "拍摄", "拍照", "拍",
        "请帮我", "帮我", "帮忙", "麻烦", "请", "我要", "我想", "我想要", "给我", "替我",
        "找一下", "找找", "查找", "搜索", "搜一下", "搜", "找", "查一下", "查",
        "show me", "find me", "search for", "look for", "show", "find", "search",
        "i want", "i need", "give me",
    ]

    /// Measure words and generic nouns that add nothing for the model once the
    /// surrounding scaffolding is gone. Kept deliberately small.
    private static let trailingNoise = [
        "的照片", "的图片", "的图", "照片", "图片", "相片",
        "photos", "pictures", "pics", "photo", "picture", "images", "image",
    ]

    /// Negation markers, longest first so "不要" wins over "不".
    ///
    /// Bare "不" is deliberately absent: it is a prefix inside common compounds
    /// ("不错", "不同", "不清晰"), so treating it as negation would split
    /// "一张不错的照片" into a positive "一张" and a negative "错的照片". The
    /// multi-character forms below are unambiguous, and dropping a rare real
    /// negation is far better than mangling a common positive query.
    private static let negations = [
        "不要有", "不含有", "不包含", "不要", "没有", "不是", "别", "无",
        "without any", "without", "doesn't have", "does not have", "don't have",
        "do not have", "not a", "not an", "excluding", "except", "no", "not",
    ]

    private static let conjunctions = [
        "还有", "以及", "和", "与", "跟", "及", "、", "＋", "+",
        " as well as ", " along with ", " and ", "&",
    ]

    /// "or" semantics: the best-matching clause wins.
    private static let alternatives = ["或者", "或是", "或", " either ", " or "]

    private static let favouriteWords = [
        "收藏的", "收藏", "最喜欢的", "最爱", "favourite", "favorite", "starred",
    ]

    private static let mediaWords: [(String, MediaFilter.Kind)] = [
        ("截屏", .screenshot), ("截图", .screenshot), ("screenshot", .screenshot),
        ("屏幕快照", .screenshot), ("screen shot", .screenshot),
        ("实况照片", .livePhoto), ("live photo", .livePhoto), ("livephoto", .livePhoto),
        ("视频", .video), ("录像", .video), ("影片", .video),
        ("video", .video), ("movie", .video), ("clip", .video),
    ]

    // MARK: - Entry point

    func analyze(_ rawQuery: String) -> QueryPlan {
        var plan = QueryPlan()
        let query = Self.normalizeWidth(rawQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return plan }

        // Quoted text is an exact-text request by convention: if the user quoted
        // it, they mean those characters, not a vibe. Pulled out before anything
        // else so the quotes cannot be mistaken for visual phrasing.
        var working = query
        var quoted: [String] = []
        working = Self.extractQuoted(working, into: &quoted)
        for term in quoted {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { plan.ocrTerms.append(trimmed) }
        }

        // Combine mode is decided by the *first* connective, and "or" wins over
        // "and" when both appear. "dogs and cats or birds" is genuinely
        // ambiguous; preferring "any" errs toward returning something.
        var combine: QueryCombine = .all
        var segments = Self.split(working, on: Self.conjunctions)
        if segments.count > 1 { combine = .all }
        let alternativesSplit = Self.split(working, on: Self.alternatives)
        if alternativesSplit.count > 1 {
            segments = alternativesSplit
            combine = .any
        }

        for segment in segments {
          for (isNegative, chunk) in Self.splitOnNegation(segment) {
            var text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Date first: it is the most specific pattern and its keywords could
            // otherwise be swallowed into the visual clause.
            var dateConsumed = false
            if plan.dateFilter == nil, let (range, remainder, matched) = extractDate(text) {
                plan.dateFilter = range
                text = remainder
                dateConsumed = !matched.isEmpty
            }

            if let (kind, remainder) = Self.extractMedia(text) {
                plan.mediaFilter = MediaFilter(
                    kind: kind, favouritesOnly: plan.mediaFilter?.favouritesOnly ?? false
                )
                text = remainder
            }

            if Self.containsFavourite(text) {
                plan.mediaFilter = MediaFilter(
                    kind: plan.mediaFilter?.kind ?? .image,
                    favouritesOnly: true
                )
                text = Self.removeFavouriteWords(text)
            }

            if plan.locationQuery == nil, let (place, remainder) = extractLocation(text) {
                plan.locationQuery = place
                text = remainder
            }

            if let count = Self.extractCount(text) {
                plan.countConstraint = count
                text = Self.removeCountWords(text)
            }

            text = Self.stripFillers(text)
            _ = dateConsumed

            if text.isEmpty { continue }
            if isNegative {
                plan.negativeVisualClauses.append(text)
            } else {
                plan.positiveVisualClauses.append(text)
            }
          }
        }

        // A query that is only a date or only a media kind needs no embedding.
        // Deciding this here keeps the engine from computing a vector for
        // "screenshots from last year".
        plan.combine = combine
        if plan.positiveVisualClauses.isEmpty {
            plan.combine = .all
        }
        return plan
    }

    // MARK: - Normalisation

    /// Folds full-width Latin letters and digits to ASCII so "２０２３年" and
    /// "2023年" take the same path. Full-width punctuation is left alone: it is
    /// meaningful in Chinese text and the tokenizer handles it.
    static func normalizeWidth(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                // Full-width ASCII block.
                if let folded = Unicode.Scalar(scalar.value - 0xFEE0) {
                    result.unicodeScalars.append(folded)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            case 0x3000:
                result.append(" ")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func extractQuoted(_ text: String, into terms: inout [String]) -> String {
        var result = ""
        var current = ""
        var openQuote: Character?
        for character in text {
            if openQuote == nil, character == "\"" || character == "\u{201C}" || character == "'" {
                openQuote = character
                continue
            }
            if let open = openQuote {
                let closers: [Character] = open == "\u{201C}" ? ["\u{201D}"] : [open, "\u{201D}"]
                if closers.contains(character) {
                    terms.append(current)
                    current = ""
                    openQuote = nil
                    continue
                }
                current.append(character)
                continue
            }
            result.append(character)
        }
        // An unclosed quote is not a quote; put it back rather than eating the
        // rest of the query.
        if let open = openQuote {
            result.append(open)
            result.append(current)
        }
        return result
    }

    /// Splits on any of `separators`, longest separator first so "还有" is not
    /// split as "和".
    static func split(_ text: String, on separators: [String]) -> [String] {
        let ordered = separators.sorted { $0.count > $1.count }
        var segments = [text]
        for separator in ordered {
            segments = segments.flatMap { segment -> [String] in
                guard segment.contains(separator) else { return [segment] }
                return segment.components(separatedBy: separator)
            }
        }
        return segments.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Splits a clause into positive and negative chunks around negation markers
    /// appearing **anywhere**, not just at the start.
    ///
    /// Prefix-only detection was the first implementation and it was wrong in a
    /// way that produced a plausible-looking answer: "海边的狗不要其他人" came
    /// back as one positive clause searching for that literal string, so the
    /// negation did nothing and the search returned photos with other people.
    static func splitOnNegation(_ text: String) -> [(isNegative: Bool, text: String)] {
        var chunks: [(isNegative: Bool, text: String)] = []
        var remaining = Substring(text)
        var carry = ""

        while !remaining.isEmpty {
            guard let (range, _) = firstNegation(in: remaining) else {
                carry += remaining
                break
            }
            carry += remaining[remaining.startIndex..<range.lowerBound]
            if !carry.trimmingCharacters(in: .whitespaces).isEmpty {
                chunks.append((false, carry))
            }
            carry = ""
            remaining = remaining[range.upperBound...]

            // The negated span runs to the next marker, so
            // "不要A不要B" yields two separate negative clauses rather than one
            // clause containing both.
            if let (nextRange, _) = firstNegation(in: remaining) {
                chunks.append((true, String(remaining[remaining.startIndex..<nextRange.lowerBound])))
                remaining = remaining[nextRange.lowerBound...]
            } else {
                chunks.append((true, String(remaining)))
                remaining = ""
            }
        }
        if !carry.trimmingCharacters(in: .whitespaces).isEmpty {
            chunks.append((false, carry))
        }
        return chunks
    }

    private static func firstNegation(in text: Substring) -> (Range<String.Index>, String)? {
        let lowered = text.lowercased()
        var best: (Range<String.Index>, String)?
        for marker in negations {
            let needle = marker.lowercased()
            var searchStart = lowered.startIndex
            while let found = lowered.range(of: needle, range: searchStart..<lowered.endIndex) {
                if !hasWordBoundaries(found, in: text, marker: marker) {
                    searchStart = lowered.index(after: found.lowerBound)
                    continue
                }
                if best == nil || found.lowerBound < best!.0.lowerBound {
                    best = (found, marker)
                }
                break
            }
        }
        return best
    }

    /// ASCII markers must sit on word boundaries, or "no" matches "note" and
    /// "not" matches "notebook".
    private static func hasWordBoundaries(
        _ range: Range<String.Index>, in text: Substring, marker: String
    ) -> Bool {
        guard let first = marker.first, first.isASCII, first.isLetter else { return true }
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    static func stripFillers(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            let lowered = result.lowercased()
            for filler in leadingFillers where lowered.hasPrefix(filler.lowercased()) {
                result = String(result.dropFirst(filler.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
            if changed { continue }
            for noise in trailingNoise where lowered.hasSuffix(noise.lowercased()) {
                result = String(result.dropLast(noise.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        // Leading particles left over after the imperative is gone ("的猫").
        while let first = result.first, "的了着".contains(first) {
            result = String(result.dropFirst())
        }
        // Separators left behind once a date or clause was extracted. Without
        // this, "2023年的发票，不要报销单" leaves the positive clause as "发票，".
        let edgePunctuation = CharacterSet(charactersIn: "，,。.；;：:！!？?、·-—\u{3000} ")
        result = result.trimmingCharacters(in: edgePunctuation)
        while let first = result.first, "的了着".contains(first) {
            result = String(result.dropFirst())
        }
        return result.trimmingCharacters(in: edgePunctuation)
    }

    static func containsFavourite(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return favouriteWords.contains { lowered.contains($0.lowercased()) }
    }

    static func removeFavouriteWords(_ text: String) -> String {
        var result = text
        let lowered = result.lowercased()
        for word in favouriteWords.sorted(by: { $0.count > $1.count })
        where lowered.contains(word.lowercased()) {
            if let range = result.range(of: word, options: [.caseInsensitive]) {
                result.removeSubrange(range)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractMedia(_ text: String) -> (MediaFilter.Kind, String)? {
        let lowered = text.lowercased()
        for (word, kind) in mediaWords {
            guard lowered.contains(word.lowercased()) else { continue }
            var result = text
            if let range = result.range(of: word, options: [.caseInsensitive]) {
                result.removeSubrange(range)
            }
            return (kind, result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func extractCount(_ text: String) -> Int? {
        let patterns = ["一张", "两张", "三张", "四张", "五张", "一张张"]
        for (index, pattern) in patterns.enumerated() where text.contains(pattern) {
            return index + 1
        }
        let english = ["one ", "a single ", "two ", "three "]
        let lowered = text.lowercased()
        for (index, pattern) in english.enumerated() where lowered.contains(pattern) {
            return index == 0 || index == 1 ? 1 : index
        }
        return nil
    }

    static func removeCountWords(_ text: String) -> String {
        var result = text
        for word in ["一张", "两张", "三张", "四张", "五张", "a single", "one"] {
            if let range = result.range(of: word, options: [.caseInsensitive]) {
                result.removeSubrange(range)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Location

    /// Recognises that a place was mentioned and returns it unresolved.
    ///
    /// Only the *grammatical* patterns are handled here. Knowing that "上海" is a
    /// place with coordinates is a gazetteer question (Phase 8); conflating the
    /// two would mean the analyzer silently stops recognising any place missing
    /// from the list.
    func extractLocation(_ text: String) -> (place: String, remainder: String)? {
        // Chinese first: "在" is a strong grammatical signal on its own.
        if let range = text.range(of: "在") {
            if let extracted = finishLocation(
                tail: String(text[range.upperBound...]),
                head: String(text[text.startIndex..<range.lowerBound])
            ) {
                return extracted
            }
        }

        // English prepositions are promiscuous: "in" marks a location in
        // "in Beijing" and an ordinary description in "in a meeting room".
        // Rejecting a determiner ("a", "the", "my") is what stops the analyser
        // reading "a whiteboard with diagrams in a meeting room" as a query about
        // the place "a meeting room" -- which it did.
        //
        // Capitalisation is deliberately *not* required: "in new york" is a place
        // and users type in lower case. The gazetteer is the authority on whether
        // a mention is real; this only filters the cases grammar can settle.
        for pattern in ["at ", "in ", "near "] {
            guard let range = text.range(of: pattern, options: [.caseInsensitive]) else { continue }
            let tail = String(text[range.upperBound...])
            guard Self.looksLikePlaceName(tail) else { continue }
            if let extracted = finishLocation(
                tail: tail, head: String(text[text.startIndex..<range.lowerBound])
            ) {
                return extracted
            }
        }
        return nil
    }

    /// Rejects a mention that grammar alone rules out: an empty one, or one led
    /// by a determiner ("a meeting room", "my car"). Everything else is left to
    /// the gazetteer, which is the only thing that actually knows.
    static func looksLikePlaceName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        for determiner in Self.placeNameDeterminers where lowered.hasPrefix(determiner) {
            return false
        }
        return true
    }

    private static let placeNameDeterminers = [
        "a ", "an ", "the ", "my ", "your ", "his ", "her ", "its ", "our ", "their ",
        "this ", "that ", "these ", "those ", "some ", "any ", "no ",
    ]

    private func finishLocation(tail rawTail: String, head: String) -> (place: String, remainder: String)? {
        var tail = rawTail.trimmingCharacters(in: .whitespacesAndNewlines)
        var remainder = head

        // The locative marker can sit in the *middle* of the tail: in
        // "在北京拍的猫" the place is 北京, but "猫" is the subject of the photo,
        // not part of the place name. Only checking trailing suffixes turned the
        // whole thing into the place "北京拍的猫" and left no subject at all.
        //
        // Earliest wins; at the same position the longest marker wins, so
        // "拍的照片" is preferred over "拍的".
        var earliest: (index: String.Index, marker: String)?
        for marker in Self.locativeMarkers {
            guard let found = tail.range(of: marker) else { continue }
            if let current = earliest {
                if found.lowerBound < current.index
                    || (found.lowerBound == current.index && marker.count > current.marker.count) {
                    earliest = (found.lowerBound, marker)
                }
            } else {
                earliest = (found.lowerBound, marker)
            }
        }

        if let earliest, let range = tail.range(of: earliest.marker, range: earliest.index..<tail.endIndex) {
            remainder += String(tail[range.upperBound...])
            tail = String(tail[tail.startIndex..<range.lowerBound])
        }
        // With no marker the whole tail is the mention, and the gazetteer decides
        // where the name ends. Splitting on the first space here -- an earlier
        // attempt -- turned "in New York" into the place "New", which resolves to
        // nothing. Choosing the longest resolvable prefix is a lookup question,
        // not a grammar one, so it belongs with the lookup.

        tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["市", "省"] where tail.hasSuffix(suffix) && tail.count > 2 {
            tail = String(tail.dropLast())
        }
        let place = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        // 40 rather than 20: "islands of Langerhans" is a legitimate place name
        // and the earlier bound rejected it outright.
        guard !place.isEmpty, place.count <= 40 else { return nil }
        return (place, remainder)
    }

    /// Markers that end the place phrase. Longest-first so the earliest-position
    /// search prefers the more specific match.
    private static let locativeMarkers = [
        "拍的照片", "拍摄的", "的照片", "的图片", "拍的照", "拍的", "照的", "取景",
    ].sorted { $0.count > $1.count }

    // MARK: - Dates

    /// Parses a date expression and returns the range plus whatever text remains.
    ///
    /// Returns `nil` when nothing date-like is present, so an ordinary query is
    /// not rewritten.
    func extractDate(_ text: String) -> (DateRangeFilter, String, String)? {
        let lowered = text.lowercased()

        // Absolute forms first: they are unambiguous, and a relative keyword
        // cannot also be present in the same clause in practice.
        if let absolute = parseAbsoluteDate(text) {
            return absolute
        }

        for (keyword, builder) in Self.relativeKeywords {
            guard let range = lowered.range(of: keyword) else { continue }
            guard let unit = builder(self) else { continue }
            let remainder = String(text[text.startIndex..<range.lowerBound])
                + String(text[range.upperBound...])
            return (unit, remainder.trimmingCharacters(in: .whitespacesAndNewlines), keyword)
        }

        for (keyword, builder) in Self.rollingKeywords {
            guard let range = lowered.range(of: keyword) else { continue }
            guard let unit = builder(self) else { continue }
            let remainder = String(text[text.startIndex..<range.lowerBound])
                + String(text[range.upperBound...])
            return (unit, remainder.trimmingCharacters(in: .whitespacesAndNewlines), keyword)
        }
        return nil
    }

    /// (keyword, range builder). Ordered longest-first by the lookup below.
    private static let relativeKeywords: [(String, @Sendable (QueryAnalyzer) -> DateRangeFilter?)] = [
        ("前天", { $0.dayRange(offset: -2, label: "前天") }),
        ("昨天", { $0.dayRange(offset: -1, label: "昨天") }),
        ("今天", { $0.dayRange(offset: 0, label: "今天") }),
        ("yesterday", { $0.dayRange(offset: -1, label: "yesterday") }),
        ("today", { $0.dayRange(offset: 0, label: "today") }),
        ("上上周", { $0.weekRange(offset: -2, label: "上上周") }),
        ("上周", { $0.weekRange(offset: -1, label: "上周") }),
        ("本周", { $0.weekRange(offset: 0, label: "本周") }),
        ("这周", { $0.weekRange(offset: 0, label: "这周") }),
        ("last week", { $0.weekRange(offset: -1, label: "last week") }),
        ("this week", { $0.weekRange(offset: 0, label: "this week") }),
        ("上个月", { $0.monthRange(offset: -1, label: "上个月") }),
        ("本月", { $0.monthRange(offset: 0, label: "本月") }),
        ("这个月", { $0.monthRange(offset: 0, label: "这个月") }),
        ("last month", { $0.monthRange(offset: -1, label: "last month") }),
        ("this month", { $0.monthRange(offset: 0, label: "this month") }),
        ("前年", { $0.yearRange(offset: -2, label: "前年") }),
        ("去年", { $0.yearRange(offset: -1, label: "去年") }),
        ("今年", { $0.yearRange(offset: 0, label: "今年") }),
        ("last year", { $0.yearRange(offset: -1, label: "last year") }),
        ("this year", { $0.yearRange(offset: 0, label: "this year") }),
        ("春天", { $0.seasonRange(.spring) }),
        ("夏天", { $0.seasonRange(.summer) }),
        ("秋天", { $0.seasonRange(.autumn) }),
        ("冬天", { $0.seasonRange(.winter) }),
    ]

    /// (keyword, rolling window). "最近一周" means the last 7 days, not a
    /// calendar week -- a distinction users notice.
    private static let rollingKeywords: [(String, @Sendable (QueryAnalyzer) -> DateRangeFilter?)] = [
        ("最近一周", { $0.rollingDays(7, label: "最近一周") }),
        ("最近7天", { $0.rollingDays(7, label: "最近 7 天") }),
        ("最近一个月", { $0.rollingDays(30, label: "最近一个月") }),
        ("最近30天", { $0.rollingDays(30, label: "最近 30 天") }),
        ("最近三个月", { $0.rollingDays(90, label: "最近三个月") }),
        ("最近半年", { $0.rollingDays(182, label: "最近半年") }),
        ("最近一年", { $0.rollingDays(365, label: "最近一年") }),
        ("最近", { $0.rollingDays(30, label: "最近一个月") }),
        ("past week", { $0.rollingDays(7, label: "past week") }),
        ("past month", { $0.rollingDays(30, label: "past month") }),
        ("past year", { $0.rollingDays(365, label: "past year") }),
    ]

    enum Season { case spring, summer, autumn, winter }

    func rollingDays(_ days: Int, label: String) -> DateRangeFilter? {
        guard let start = calendar.date(byAdding: .day, value: -days, to: now) else { return nil }
        return DateRangeFilter(start: start, end: now, label: label)
    }

    func dayRange(offset: Int, label: String) -> DateRangeFilter? {
        guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateRangeFilter(start: start, end: end, label: label)
    }

    func weekRange(offset: Int, label: String) -> DateRangeFilter? {
        guard let week = calendar.date(byAdding: .weekOfYear, value: offset, to: now),
              let interval = calendar.dateInterval(of: .weekOfYear, for: week)
        else { return nil }
        return DateRangeFilter(start: interval.start, end: interval.end, label: label)
    }

    func monthRange(offset: Int, label: String) -> DateRangeFilter? {
        guard let month = calendar.date(byAdding: .month, value: offset, to: now),
              let interval = calendar.dateInterval(of: .month, for: month)
        else { return nil }
        return DateRangeFilter(start: interval.start, end: interval.end, label: label)
    }

    func yearRange(offset: Int, label: String) -> DateRangeFilter? {
        guard let year = calendar.date(byAdding: .year, value: offset, to: now),
              let interval = calendar.dateInterval(of: .year, for: year)
        else { return nil }
        return DateRangeFilter(start: interval.start, end: interval.end, label: label)
    }

    func seasonRange(_ season: Season) -> DateRangeFilter? {
        let year = calendar.component(.year, from: now)
        let months: (Int, Int) = switch season {
        case .spring: (3, 5)
        case .summer: (6, 8)
        case .autumn: (9, 11)
        case .winter: (12, 12)
        }
        var components = DateComponents()
        components.year = year
        components.month = months.0
        components.day = 1
        guard let start = calendar.date(from: components) else { return nil }
        if season == .winter {
            components.year = year + 1
            components.month = 3
        } else {
            components.month = months.1 + 1
        }
        guard let end = calendar.date(from: components) else { return nil }
        let name = switch season {
        case .spring: "春天"; case .summer: "夏天"; case .autumn: "秋天"; case .winter: "冬天"
        }
        return DateRangeFilter(start: start, end: end, label: name)
    }

    /// Absolute dates: `2023`, `2023年5月`, `2023-05-01`, `2023/5`, `5月1日`.
    ///
    /// Written with `Scanner`-style manual parsing rather than a regex so the
    /// failure modes are visible: an unrecognised shape returns `nil` and the
    /// text stays in the visual clause, which is a better outcome than a regex
    /// that half-matches and silently eats the wrong substring.
    func parseAbsoluteDate(_ text: String) -> (DateRangeFilter, String, String)? {
        let characters = Array(text)
        var index = 0

        func digits(_ count: Int) -> (Int, Int)? {
            let start = index
            var value = 0
            var taken = 0
            while index < characters.count, characters[index].isNumber, taken < count {
                value = value * 10 + (characters[index].wholeNumberValue ?? 0)
                index += 1
                taken += 1
            }
            return taken > 0 ? (value, start) : nil
        }

        guard let (year, yearStart) = digits(4), year >= 1900, year <= 2200 else { return nil }
        var month: Int?
        var day: Int?
        let separator: Character? = index < characters.count ? characters[index] : nil

        if let separator, separator == "-" || separator == "/" || separator == "." {
            // YYYY-MM[-DD]
            index += 1
            if let (value, _) = digits(2), (1...12).contains(value) {
                month = value
                if index < characters.count, characters[index] == separator {
                    index += 1
                    if let (value, _) = digits(2), (1...31).contains(value) { day = value }
                }
            }
        } else if let separator, separator == "年" {
            index += 1
            if let (value, _) = digits(2), (1...12).contains(value) {
                month = value
                if index < characters.count, characters[index] == "月" {
                    index += 1
                    if let (value, _) = digits(2), (1...31).contains(value) {
                        day = value
                        if index < characters.count, characters[index] == "日" { index += 1 }
                    }
                }
            }
        } else {
            // A bare four-digit year. This is the risky case: "2001" could be a
            // room number or a year. Accepted only when the digits stand alone or
            // are followed by a year suffix, so "2001太空漫游" keeps its meaning.
            let next = index < characters.count ? characters[index] : nil
            if next == "年" {
                index += 1
            } else if next != nil {
                return nil
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month ?? 1
        components.day = day ?? 1
        guard let start = calendar.date(from: components) else { return nil }

        let end: Date?
        let label: String
        if let day {
            end = calendar.date(byAdding: .day, value: 1, to: start)
            label = String(format: "%04d-%02d-%02d", year, month ?? 1, day)
        } else if let month {
            end = calendar.date(byAdding: .month, value: 1, to: start)
            label = String(format: "%04d-%02d", year, month)
        } else {
            end = calendar.date(byAdding: .year, value: 1, to: start)
            label = String(format: "%04d", year)
        }

        // Rebuild the query without the matched span, preserving anything on
        // either side: "2023年5月 在海边" must yield both a range and "在海边".
        let consumedEnd = index
        var remainder = ""
        if yearStart > 0 { remainder += String(characters[0..<yearStart]) }
        if consumedEnd < characters.count { remainder += String(characters[consumedEnd...]) }
        let matched = String(characters[yearStart..<consumedEnd])
        return (
            DateRangeFilter(start: start, end: end, label: label),
            remainder.trimmingCharacters(in: .whitespacesAndNewlines),
            matched
        )
    }
}
