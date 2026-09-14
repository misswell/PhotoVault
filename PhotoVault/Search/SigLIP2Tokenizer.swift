//
//  SigLIP2Tokenizer.swift
//  PhotoVault
//
//  On-device tokenizer for the SigLIP2 text tower.
//
//  This is a direct port of google/sentencepiece `src/bpe_model.cc`
//  (Apache-2.0, v0.2.0), specialised to the configuration the
//  `google/siglip2-base-patch16-256` checkpoint was trained with, and validated
//  against both the real sentencepiece processor and a Swift-independent
//  ground-truth dump (`tools/models/verify_siglip2.py --mode tokenizer`).
//
//  Why port instead of depend
//  --------------------------
//  The alternatives were worse. Vendoring sentencepiece means building a C++
//  library for iOS. Loading `tokenizer.json` means parsing 34 MB of JSON. And
//  re-deriving merges from the vocabulary "by intuition" produces a tokenizer
//  that looks right and quietly tokenises differently -- which, because the
//  text tower was trained against these exact ids, degrades search quality
//  without any visible error.
//
//  The configuration is read from the artifact, never assumed
//  ---------------------------------------------------------
//  For this checkpoint the normalizer is the identity: `precompiled_charsmap`
//  is empty (so no NFKC and no case folding), `add_dummy_prefix` is false (no
//  leading "▁"), and `remove_extra_whitespaces` is false. Only whitespace
//  escaping applies, turning U+0020 into U+2581. That is the entire normalizer,
//  which is why no double-array trie is needed here.
//
//  Two things a from-scratch implementation gets wrong
//  ---------------------------------------------------
//  1. The initial split is *not* "one character each". The prefix matcher is
//     built from the USER_DEFINED pieces only (245 here: `<start_of_turn>`,
//     newline runs, `▁▁`, HTML tags, ...). One character is the fallback when
//     that set has no match. Matched symbols are frozen and never merge.
//  2. Merging is by piece *score*, not by training order -- this is not classic
//     rank-based BPE. Rebuilding merges from a merge list gives different
//     tokens.
//

import Foundation

/// A SigLIP2 (Gemma sentencepiece BPE) tokenizer backed by a compact binary
/// artifact. Immutable and safe to share across concurrency domains.
public struct SigLIP2Tokenizer: Sendable {

    public struct Configuration: Sendable, Equatable {
        public let vocabSize: Int
        public let unkID: Int32
        public let bosID: Int32
        public let eosID: Int32
        public let padID: Int32
        public let byteFallback: Bool
        public let escapeWhitespaces: Bool
        public let addDummyPrefix: Bool
        public let removeExtraWhitespaces: Bool
        public let userDefinedCount: Int
        /// SHA-256 of the source `tokenizer.model`, for provenance checks.
        public let sourceSHA256: String
    }

    public enum TokenizerError: Error, CustomStringConvertible {
        case artifactTooSmall
        case badMagic(String)
        case truncated(String)
        case io(Error)

        public var description: String {
            switch self {
            case .artifactTooSmall: "tokenizer artifact is too small to contain a header"
            case .badMagic(let magic): "unexpected tokenizer artifact magic '\(magic)'"
            case .truncated(let what): "tokenizer artifact is truncated: \(what)"
            case .io(let error): "could not read tokenizer artifact: \(error)"
            }
        }
    }

    /// The scalar substituted for a space. Named rather than inlined because it
    /// is meaningless as a literal.
    private static let spaceMarker: UInt8 = 0xE2   // first byte of U+2581 (▁)
    private static let spaceScalar = Character("\u{2581}")

    public let configuration: Configuration

    // Artifact image, held as bytes so the type stays Sendable without any
    // unsafe-pointer lifetime juggling. Total resident cost is the artifact
    // size (about 5 MB), not the tens of MB a 256k-entry dictionary would cost.
    private let bytes: [UInt8]

    private let pieceTableOffset: Int
    private let blobOffset: Int
    private let blobLength: Int
    private let scoreOffset: Int
    private let udOffset: Int
    private let udCount: Int
    private let byteOffset: Int
    private let sortedOffset: Int

    /// USER_DEFINED pieces as raw UTF-8, bucketed by first byte. 245 entries, so
    /// linear longest-match within a bucket is cheaper than a trie.
    private let userDefinedByFirstByte: [UInt8: [[UInt8]]]

    // MARK: - Loading

    public init(artifactURL: URL) throws {
        do {
            try self.init(artifactBytes: [UInt8](Data(contentsOf: artifactURL, options: .mappedIfSafe)))
        } catch let error as TokenizerError {
            throw error
        } catch {
            throw TokenizerError.io(error)
        }
    }

    public init(artifactBytes: [UInt8]) throws {
        // magic(8) flags(4) vocab(4) ids(16) udCount(4) + 10 offsets(40) = 76
        let headerSize = 76
        guard artifactBytes.count >= headerSize else { throw TokenizerError.artifactTooSmall }

        let magic = String(decoding: artifactBytes[0..<8], as: UTF8.self)
        guard magic == "PVTOK002" else { throw TokenizerError.badMagic(magic) }

        @inline(__always)
        func u32(_ source: [UInt8], _ offset: Int) -> UInt32 {
            UInt32(source[offset])
                | (UInt32(source[offset + 1]) << 8)
                | (UInt32(source[offset + 2]) << 16)
                | (UInt32(source[offset + 3]) << 24)
        }

        let flags = u32(artifactBytes, 8)
        let vocabSize = Int(u32(artifactBytes, 12))
        let ids = (16, 20, 24, 28)
        let udCount = Int(u32(artifactBytes, 32))
        let pieceTableOffset = Int(u32(artifactBytes, 36))
        let blobOffset = Int(u32(artifactBytes, 40))
        let blobLength = Int(u32(artifactBytes, 44))
        let scoreOffset = Int(u32(artifactBytes, 48))
        let udOffset = Int(u32(artifactBytes, 56))
        let byteOffset = Int(u32(artifactBytes, 60))
        let sortedOffset = Int(u32(artifactBytes, 64))
        let shaOffset = Int(u32(artifactBytes, 68))
        let shaLength = Int(u32(artifactBytes, 72))

        for (name, end) in [
            ("piece table", pieceTableOffset + 4 * (vocabSize + 1)),
            ("string blob", blobOffset + blobLength),
            ("scores", scoreOffset + 4 * vocabSize),
            ("user-defined ids", udOffset + 4 * udCount),
            ("byte table", byteOffset + 4 * 256),
            ("sorted index", sortedOffset + 4 * vocabSize),
            ("source hash", shaOffset + shaLength),
        ] where end > artifactBytes.count {
            throw TokenizerError.truncated(name)
        }

        self.bytes = artifactBytes
        self.pieceTableOffset = pieceTableOffset
        self.blobOffset = blobOffset
        self.blobLength = blobLength
        self.scoreOffset = scoreOffset
        self.udOffset = udOffset
        self.udCount = udCount
        self.byteOffset = byteOffset
        self.sortedOffset = sortedOffset
        self.configuration = Configuration(
            vocabSize: vocabSize,
            unkID: Int32(bitPattern: u32(artifactBytes, ids.0)),
            bosID: Int32(bitPattern: u32(artifactBytes, ids.1)),
            eosID: Int32(bitPattern: u32(artifactBytes, ids.2)),
            padID: Int32(bitPattern: u32(artifactBytes, ids.3)),
            byteFallback: flags & 1 != 0,
            escapeWhitespaces: flags & 2 != 0,
            addDummyPrefix: flags & 4 != 0,
            removeExtraWhitespaces: flags & 8 != 0,
            userDefinedCount: udCount,
            sourceSHA256: String(decoding: artifactBytes[shaOffset..<(shaOffset + shaLength)], as: UTF8.self)
        )

        // The prefix matcher runs on every character of every query, so bucket
        // the 245 user-defined pieces by first byte rather than scanning all of
        // them per position.
        var buckets: [UInt8: [[UInt8]]] = [:]
        let vocab = self.bytes
        for k in 0..<udCount {
            let id = Int(u32(vocab, udOffset + 4 * k))
            let (start, end) = Self.pieceRange(
                in: vocab, pieceTable: pieceTableOffset, blob: blobOffset, id: id
            )
            guard start < end else { continue }
            buckets[vocab[start], default: []].append(Array(vocab[start..<end]))
        }
        self.userDefinedByFirstByte = buckets
    }

    // MARK: - Byte-level accessors

    private static func pieceRange(
        in bytes: [UInt8], pieceTable: Int, blob: Int, id: Int
    ) -> (Int, Int) {
        @inline(__always)
        func u32(_ offset: Int) -> Int {
            Int(UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24))
        }
        let start = blob + u32(pieceTable + 4 * id)
        let end = blob + u32(pieceTable + 4 * (id + 1))
        return (start, end)
    }

    /// Lexicographic comparison of two UTF-8 byte sequences, with a shorter
    /// prefix ordering before a longer one. Must match `sorted()` on the encoded
    /// bytes in `siglip2_tokenizer.py` exactly.
    private static func compare(
        _ lhs: [UInt8], _ lhsRange: Range<Int>,
        _ rhs: [UInt8], _ rhsRange: Range<Int>
    ) -> Int {
        var i = lhsRange.lowerBound
        var j = rhsRange.lowerBound
        while i < lhsRange.upperBound && j < rhsRange.upperBound {
            let a = lhs[i]
            let b = rhs[j]
            if a != b { return a < b ? -1 : 1 }
            i += 1
            j += 1
        }
        let lhsDone = i == lhsRange.upperBound
        let rhsDone = j == rhsRange.upperBound
        if lhsDone && rhsDone { return 0 }
        return lhsDone ? -1 : 1
    }

    /// Vocabulary lookup by binary search over the lexicographically sorted id
    /// index. Returns nil when the bytes are not a piece.
    private func pieceID(_ candidate: [UInt8], _ range: Range<Int>) -> Int32? {
        var low = 0
        var high = configuration.vocabSize - 1
        let bytes = self.bytes
        while low <= high {
            let mid = (low + high) / 2
            // Sorted index is u32 but ids fit in Int32 for 256k vocabularies.
            let id = Int(UInt32(bytes[sortedOffset + 4 * mid])
                | (UInt32(bytes[sortedOffset + 4 * mid + 1]) << 8)
                | (UInt32(bytes[sortedOffset + 4 * mid + 2]) << 16)
                | (UInt32(bytes[sortedOffset + 4 * mid + 3]) << 24))
            let (start, end) = Self.pieceRange(
                in: bytes, pieceTable: pieceTableOffset, blob: blobOffset, id: id
            )
            let order = Self.compare(bytes, start..<end, candidate, range)
            if order == 0 { return Int32(id) }
            if order < 0 { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    private func score(of id: Int32) -> Float {
        let o = scoreOffset + 4 * Int(id)
        let raw = UInt32(bytes[o])
            | (UInt32(bytes[o + 1]) << 8)
            | (UInt32(bytes[o + 2]) << 16)
            | (UInt32(bytes[o + 3]) << 24)
        return Float(bitPattern: raw)
    }

    private func bytePieceID(_ byte: UInt8) -> Int32 {
        let o = byteOffset + 4 * Int(byte)
        return Int32(bitPattern: UInt32(bytes[o])
            | (UInt32(bytes[o + 1]) << 8)
            | (UInt32(bytes[o + 2]) << 16)
            | (UInt32(bytes[o + 3]) << 24))
    }

    // MARK: - Normalization

    /// The entire normalizer for this checkpoint's configuration.
    func normalize(_ text: String) -> String {
        var result = text
        if configuration.escapeWhitespaces {
            result = result.replacingOccurrences(of: " ", with: String(Self.spaceScalar))
        }
        if configuration.addDummyPrefix {
            result = String(Self.spaceScalar) + result
        }
        if configuration.removeExtraWhitespaces {
            var collapsed = String()
            collapsed.reserveCapacity(result.count)
            var previousWasSpace = false
            for character in result {
                let isSpace = character == Self.spaceScalar
                if isSpace && previousWasSpace { continue }
                collapsed.append(character)
                previousWasSpace = isSpace
            }
            result = collapsed
        }
        return result
    }

    // MARK: - Encoding

    /// Token ids for `text`, EOS-terminated and right-padded with `<pad>`.
    ///
    /// This is the shape the text encoder expects: exactly `maxLength` ids.
    public func encode(_ text: String, addEOS: Bool = true, maxLength: Int = 64) -> [Int32] {
        var ids = tokenIDs(for: text, addEOS: addEOS)
        if ids.count > maxLength {
            ids.removeSubrange(maxLength...)
        } else if ids.count < maxLength {
            ids.append(contentsOf: repeatElement(configuration.padID, count: maxLength - ids.count))
        }
        return ids
    }

    /// Token ids for `text` with no padding or truncation.
    public func tokenIDs(for text: String, addEOS: Bool = true) -> [Int32] {
        let pieces = bpe(normalize(text))
        var ids: [Int32] = []
        ids.reserveCapacity(pieces.count + 1)
        for piece in pieces {
            if let id = pieceID(piece, piece.startIndex..<piece.endIndex),
               id != configuration.unkID {
                ids.append(id)
            } else if configuration.byteFallback {
                // Unknown text is decomposed into per-byte pieces, matching
                // `SentencePieceProcessor::Encode`.
                for byte in piece {
                    ids.append(bytePieceID(byte))
                }
            } else {
                ids.append(configuration.unkID)
            }
        }
        if addEOS { ids.append(configuration.eosID) }
        return ids
    }

    /// Port of `bpe::Model::SampleEncode` with `alpha = 0` (BPE-dropout off).
    ///
    /// The reference uses a priority queue; this recomputes the best mergeable
    /// pair each round instead. That is equivalent -- the queue is only an
    /// optimisation for long inputs, and staleness there is handled by the same
    /// length check used below -- and it removes a class of heap-ordering bugs.
    /// Each round is one pass over the surviving pairs, so a query-length input
    /// costs single-digit microseconds.
    private func bpe(_ normalized: String) -> [[UInt8]] {
        let input = Array(normalized.utf8)
        guard !input.isEmpty else { return [] }

        // Pieces live in a shared scratch buffer and are referenced by range, so
        // merging is an append rather than an allocation per candidate.
        var scratch: [UInt8] = []
        scratch.reserveCapacity(input.count * 2)

        struct Symbol {
            var start: Int
            var end: Int
            var previous: Int
            var next: Int
            var frozen: Bool
            var isAlive: Bool { start < end }
            var length: Int { end - start }
        }

        var symbols: [Symbol] = []
        symbols.reserveCapacity(input.count)

        var cursor = 0
        while cursor < input.count {
            let (length, found) = prefixMatch(input, at: cursor)
            let start = scratch.count
            scratch.append(contentsOf: input[cursor..<(cursor + length)])
            let index = symbols.count
            symbols.append(Symbol(
                start: start,
                end: scratch.count,
                previous: index - 1,
                next: index + 1,
                frozen: found
            ))
            cursor += length
        }
        guard !symbols.isEmpty else { return [] }
        symbols[symbols.count - 1].next = -1

        /// The bytes of the merge of `left` and `right`, or nil when the pair is
        /// not mergeable (absent, dead, or frozen).
        ///
        /// Built into a fresh array rather than appended straight onto `scratch`:
        /// appending a slice of an array to itself is an overlapping access and
        /// traps under Swift's exclusivity checking.
        func mergedBytes(_ left: Int, _ right: Int) -> [UInt8]? {
            guard left >= 0, right >= 0,
                  symbols[left].isAlive, symbols[right].isAlive,
                  !symbols[left].frozen, !symbols[right].frozen
            else { return nil }
            var merged: [UInt8] = []
            merged.reserveCapacity(symbols[left].length + symbols[right].length)
            merged.append(contentsOf: scratch[symbols[left].start..<symbols[left].end])
            merged.append(contentsOf: scratch[symbols[right].start..<symbols[right].end])
            return merged
        }

        /// Score of a merge candidate, or nil when the concatenation is not a
        /// piece in the vocabulary.
        func mergedScore(_ left: Int, _ right: Int) -> Float? {
            guard let merged = mergedBytes(left, right),
                  let id = pieceID(merged, merged.startIndex..<merged.endIndex)
            else { return nil }
            return score(of: id)
        }

        while true {
            // Best score wins; ties go to the leftmost pair, matching the
            // reference comparator (`score <` then `left >`). The reference uses
            // a priority queue and discards stale entries by re-checking piece
            // lengths; recomputing the best valid pair each round is equivalent
            // for query-length inputs and has no ordering subtleties.
            var bestIndex = -1
            var bestScore = -Float.infinity
            var index = 0
            while index >= 0 {
                let right = symbols[index].next
                if right >= 0, let candidate = mergedScore(index, right),
                   candidate > bestScore {
                    bestScore = candidate
                    bestIndex = index
                }
                index = symbols[index].next
            }
            guard bestIndex >= 0, let merged = mergedBytes(bestIndex, symbols[bestIndex].next)
            else { break }

            let right = symbols[bestIndex].next
            symbols[bestIndex].start = scratch.count
            scratch.append(contentsOf: merged)
            symbols[bestIndex].end = scratch.count
            symbols[bestIndex].next = symbols[right].next
            if symbols[right].next >= 0 {
                symbols[symbols[right].next].previous = bestIndex
            }
            symbols[right].start = 0
            symbols[right].end = 0
        }

        var output: [[UInt8]] = []
        var index = 0
        while index >= 0 {
            if symbols[index].isAlive {
                output.append(Array(scratch[symbols[index].start..<symbols[index].end]))
            }
            index = symbols[index].next
        }
        return output
    }

    /// Port of `PrefixMatcher::PrefixMatch`: the longest USER_DEFINED piece
    /// starting here, else a single character.
    private func prefixMatch(_ input: [UInt8], at offset: Int) -> (length: Int, found: Bool) {
        if let candidates = userDefinedByFirstByte[input[offset]] {
            var longest = 0
            for piece in candidates where piece.count > longest {
                if offset + piece.count <= input.count,
                   input[offset..<(offset + piece.count)].elementsEqual(piece) {
                    longest = piece.count
                }
            }
            if longest > 0 { return (longest, true) }
        }
        return (Self.utf8CharacterLength(input[offset]), false)
    }

    /// Byte length of the UTF-8 sequence beginning with `lead`.
    private static func utf8CharacterLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0x00...0x7F: 1
        case 0xC0...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF7: 4
        default: 1  // continuation or invalid byte: advance one byte
        }
    }

    // MARK: - Debugging

    /// The piece strings for `text`, for diagnostics and parity tests.
    public func pieces(for text: String) -> [String] {
        bpe(normalize(text)).map { String(decoding: $0, as: UTF8.self) }
    }

    public var description: String {
        let c = configuration
        return "SigLIP2Tokenizer(vocab: \(c.vocabSize), unk: \(c.unkID), eos: \(c.eosID), "
            + "pad: \(c.padID), byteFallback: \(c.byteFallback), "
            + "userDefined: \(c.userDefinedCount))"
    }
}
