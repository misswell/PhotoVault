//
//  EmbeddingStoreFile.swift
//  PhotoVault
//
//  The on-disk embedding matrix: a header page followed by fixed-size Float16
//  vectors, memory-mapped for search.
//
//  Design note: the matrix is kept **dense**
//  -----------------------------------------
//  The obvious layout is a slot allocator with a free list, so deletions leave
//  holes that get reused. That is the wrong trade here. Search is the hot path
//  and it wants to stream a contiguous block of vectors; holes force either a
//  gather (random access, defeats prefetching, and is awkward to express in a
//  Metal kernel) or per-slot validity checks inside the inner loop.
//
//  So deletion uses swap-remove: the last row is copied into the hole and the
//  count drops by one. The matrix stays dense, search iterates `0..<count` with
//  a constant stride, and the only cost is one row copy per deletion plus a
//  SQLite row update for the asset that moved. Deletions are rare next to
//  searches, so this is the right side of the trade.
//
//  Consequence worth knowing: slot indices are **not stable**. Anything that
//  caches a slot across a deletion is wrong. SQLite is the source of truth for
//  `asset_id -> slot`, and `swapRemove` returns the asset that moved so the
//  caller can fix its row in the same transaction.
//
//  Why the header has a checksum but no journal
//  -------------------------------------------
//  Everything in this file is derived from PhotoKit and the model: it can be
//  rebuilt. So a damaged header is not a data-loss event, it is a cache miss.
//  The checksum exists to *detect* that cheaply and force a rebuild, rather than
//  to enable surgical recovery that nobody needs. This matches how
//  `PhotoIndexStore` treats its own database.
//

import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

/// Failures that mean "this file is unusable; rebuild it".
enum EmbeddingStoreError: LocalizedError {
    case cannotCreateDirectory(Error)
    case cannotOpen(Error)
    case notAnEmbeddingFile
    case unsupportedVersion(UInt32)
    case headerCorrupt
    case dimensionMismatch(expected: Int, found: Int)
    case modelMismatch(expected: String, found: String)
    case shortRead(expected: Int, got: Int)
    case shortWrite(expected: Int, got: Int)
    case io(Error)
    case slotOutOfRange(Int)

    /// Whether this failure means "the file is damaged; replace it", rather than
    /// "report and give up".
    ///
    /// Deliberately limited to corruption: the file is unparseable, was written
    /// by an unknown version, or is truncated. Nothing here says anything about
    /// the caller, so rebuilding cannot mask a bug at the call site.
    ///
    /// Recovery matters because the alternative is permanent. Failing loudly
    /// here means every later launch reopens the same damaged file and fails
    /// identically -- which is exactly how the offset bug bricked the index on
    /// the test device, where a full reinstall was the only cure.
    ///
    /// `dimensionMismatch` and `modelMismatch` are pointedly *not* included.
    /// They are a tested contract: opening a matrix with the wrong dimension or
    /// from a different model must be rejected, not silently rebuilt, because
    /// doing so would quietly discard a perfectly good index and hide a caller
    /// passing the wrong values. The environment failures are excluded for the
    /// same reason -- a full disk would fail the rebuild identically, so
    /// deleting a readable matrix on the way to failing again only makes it
    /// worse.
    var isRebuildable: Bool {
        switch self {
        case .notAnEmbeddingFile, .unsupportedVersion, .headerCorrupt, .shortRead:
            return true
        case .dimensionMismatch, .modelMismatch, .cannotCreateDirectory, .cannotOpen,
             .shortWrite, .io, .slotOutOfRange:
            return false
        }
    }

    /// Whether the file was built by a different model or dimension.
    ///
    /// These are *not* corruption -- the file is perfectly readable, it just
    /// cannot be reused by the current build. `open` rejects them on purpose,
    /// but the app has a legitimate recovery (see
    /// `AIPhotoSearchStore.openRebuildingIfIncompatible`), so the two kinds of
    /// failure are distinguishable rather than lumped together.
    var isIncompatible: Bool {
        switch self {
        case .dimensionMismatch, .modelMismatch: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let e): "could not create the embedding directory: \(e.localizedDescription)"
        case .cannotOpen(let e): "could not open the embedding matrix: \(e.localizedDescription)"
        case .notAnEmbeddingFile: "the embedding matrix has an unrecognised file signature"
        case .unsupportedVersion(let v): "the embedding matrix uses unsupported format version \(v)"
        case .headerCorrupt: "the embedding matrix header failed its checksum"
        case .dimensionMismatch(let e, let f):
            "the embedding matrix stores \(f)-dimensional vectors but \(e) were expected"
        case .modelMismatch(let e, let f):
            "the embedding matrix was built by a different model (\(f.prefix(12))… vs \(e.prefix(12))…)"
        case .shortRead(let e, let g): "short read from the embedding matrix: wanted \(e) bytes, got \(g)"
        case .shortWrite(let e, let g): "short write to the embedding matrix: wanted \(e) bytes, got \(g)"
        case .io(let e): "embedding matrix I/O failed: \(e.localizedDescription)"
        case .slotOutOfRange(let s): "embedding slot \(s) is outside the matrix"
        }
    }
}

/// Read-only, memory-mapped view of an embedding matrix. Safe to share once
/// constructed: `Data` owns the mapping and the header is captured by value.
///
/// The header is snapshotted at open. A concurrent writer can grow the file, so
/// consumers that must not miss rows should re-open (the store does this when a
/// write completes) rather than holding a reader across an index pass.
final class EmbeddingMatrixReader: @unchecked Sendable {
    let dimension: Int
    let count: Int
    let capacity: Int
    let sourceModelSHA256: String
    let generation: UInt64

    private let data: Data
    private let rowsOffset: Int

    /// Bytes per row. Float16, so two bytes per component.
    var rowStride: Int { dimension * MemoryLayout<Float16>.size }

    init(url: URL) throws {
        do {
            self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw EmbeddingStoreError.cannotOpen(error)
        }
        let header = try EmbeddingHeader(parsing: data)
        self.dimension = header.dimension
        self.count = header.count
        self.capacity = header.capacity
        self.sourceModelSHA256 = header.sourceModelSHA256
        self.generation = header.generation
        self.rowsOffset = EmbeddingHeader.pageSize
    }

    /// Copies row `slot` out as Float32.
    func row(at slot: Int) throws -> [Float] {
        guard slot >= 0, slot < count else { throw EmbeddingStoreError.slotOutOfRange(slot) }
        var out = [Float](repeating: 0, count: dimension)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: rowsOffset + slot * rowStride)
            let halves = base.assumingMemoryBound(to: Float16.self)
            for i in 0..<dimension { out[i] = Float(halves[i]) }
        }
        return out
    }

    /// Exact similarity of `query` against every stored vector.
    ///
    /// Vectors are L2-normalized inside the Core ML graph, so the dot product
    /// *is* the cosine similarity and no norm correction is needed. The query is
    /// normalized here defensively, because a caller that forgets would get
    /// silently wrong rankings rather than an error.
    ///
    /// This is the Accelerate fallback required by the plan; the Metal kernel
    /// lands in Phase 4 and must produce identical rankings.
    func scores(query: [Float]) throws -> [Float] {
        let normalized = try normalizedQuery(query)
        var result = [Float](repeating: 0, count: count)
        let dim = dimension

        #if canImport(Accelerate)
        // Float16 rows are converted to Float32 in blocks and multiplied with
        // `cblas_sgemv`.
        //
        // The first version of this used a scalar per-component loop, which
        // measured 62 ms for 100k rows -- about 3x slower than NumPy on the same
        // machine, and exactly the "no scalar double loop" case the plan calls
        // out. Converting the whole matrix up front would be faster still but
        // doubles resident memory (307 MB instead of 153 MB), which defeats the
        // point of storing Float16. Block-wise conversion keeps the working set
        // at a few hundred KB and lets BLAS do the arithmetic.
        let blockRows = 512
        var floatBlock = [Float](repeating: 0, count: blockRows * dim)
        var blockScores = [Float](repeating: 0, count: blockRows)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: rowsOffset)
            normalized.withUnsafeBufferPointer { queryBuffer in
                result.withUnsafeMutableBufferPointer { out in
                    floatBlock.withUnsafeMutableBufferPointer { block in
                        blockScores.withUnsafeMutableBufferPointer { scores in
                            var start = 0
                            while start < count {
                                let rows = min(blockRows, count - start)
                                let halves = base
                                    .advanced(by: start * dim * MemoryLayout<Float16>.size)
                                    .assumingMemoryBound(to: Float16.self)
                                // `vDSP_vflt16` is the *integer* 16-bit
                                // converter, so it would reinterpret IEEE
                                // halves as Int16 and produce garbage. The
                                // Accelerate overlay has no Float16 -> Float
                                // `convertElements` candidate either, so the
                                // conversion stays an explicit scalar loop
                                // and BLAS still does the arithmetic.
                                let sourceHalves = UnsafeBufferPointer(start: halves, count: rows * dim)
                                var destinationFloats = UnsafeMutableBufferPointer(
                                    start: block.baseAddress!, count: rows * dim
                                )
                                for i in 0 ..< rows * dim {
                                    destinationFloats[i] = Float(sourceHalves[i])
                                }
                                cblas_sgemv(
                                    CblasRowMajor,
                                    CblasNoTrans,
                                    Int32(rows),
                                    Int32(dim),
                                    1,
                                    block.baseAddress!,
                                    Int32(dim),
                                    queryBuffer.baseAddress!,
                                    1,
                                    0,
                                    scores.baseAddress!,
                                    1
                                )
                                for i in 0..<rows { out[start + i] = scores[i] }
                                start += rows
                            }
                        }
                    }
                }
            }
        }
        #else
        // No Accelerate: keep a correct, obviously-slow reference so the ranking
        // semantics are still testable on platforms without the framework.
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: rowsOffset)
            normalized.withUnsafeBufferPointer { queryBuffer in
                let queryPointer = queryBuffer.baseAddress!
                result.withUnsafeMutableBufferPointer { out in
                    for slot in 0..<count {
                        let halves = base
                            .advanced(by: slot * dim * MemoryLayout<Float16>.size)
                            .assumingMemoryBound(to: Float16.self)
                        var accumulator: Float = 0
                        for i in 0..<dim {
                            accumulator += Float(halves[i]) * queryPointer[i]
                        }
                        out[slot] = accumulator
                    }
                }
            }
        }
        #endif
        return result
    }

    /// L2-normalizes the query, which is what makes scoring a single
    /// multiply-add per component: the rows are already unit length because the
    /// Core ML graph bakes normalization in.
    private func normalizedQuery(_ query: [Float]) throws -> [Float] {
        guard query.count == dimension else {
            throw EmbeddingStoreError.dimensionMismatch(expected: dimension, found: query.count)
        }
        var normalized = query
        var magnitude: Float = 0
        #if canImport(Accelerate)
        vDSP_svesq(normalized, 1, &magnitude, vDSP_Length(normalized.count))
        #else
        magnitude = normalized.reduce(0) { $0 + $1 * $1 }
        #endif
        let norm = magnitude.squareRoot()
        if norm > 0 {
            var divisor = norm
            #if canImport(Accelerate)
            vDSP_vsdiv(normalized, 1, &divisor, &normalized, 1, vDSP_Length(normalized.count))
            #else
            normalized = normalized.map { $0 / norm }
            #endif
        }
        return normalized
    }

    /// Scores an arbitrary subset of rows, returning values in the order the
    /// slots were given.
    ///
    /// This exists so a metadata filter can *restrict* the work rather than
    /// post-filter a global ranking. Post-filtering a global top-K would return
    /// fewer than K results whenever the filter is selective -- and would look
    /// like the filter working, which is worse than an obvious error. Scoring
    /// only the candidate rows is both correct and, for a selective filter, much
    /// less work.
    ///
    /// Rows are gathered into a contiguous Float32 block because `cblas_sgemv`
    /// needs a stride of exactly `dimension`; the gather is a copy of
    /// `blockRows * dimension` halves, which is a few hundred KB.
    func scores(query: [Float], slots: [Int]) throws -> [Float] {
        let normalized = try normalizedQuery(query)
        guard !slots.isEmpty else { return [] }
        let dim = dimension
        var result = [Float](repeating: 0, count: slots.count)
        for slot in slots where slot < 0 || slot >= count {
            throw EmbeddingStoreError.slotOutOfRange(slot)
        }

        #if canImport(Accelerate)
        let blockRows = 512
        var floatBlock = [Float](repeating: 0, count: blockRows * dim)
        var blockScores = [Float](repeating: 0, count: blockRows)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: rowsOffset)
            normalized.withUnsafeBufferPointer { queryBuffer in
                result.withUnsafeMutableBufferPointer { out in
                    floatBlock.withUnsafeMutableBufferPointer { block in
                        blockScores.withUnsafeMutableBufferPointer { scores in
                            var start = 0
                            while start < slots.count {
                                let rows = min(blockRows, slots.count - start)
                                for row in 0..<rows {
                                    let slot = slots[start + row]
                                    let halves = base
                                        .advanced(by: slot * dim * MemoryLayout<Float16>.size)
                                        .assumingMemoryBound(to: Float16.self)
                                    let source = UnsafeBufferPointer(start: halves, count: dim)
                                    var destination = UnsafeMutableBufferPointer(
                                        start: block.baseAddress! + row * dim, count: dim
                                    )
                                    for i in 0 ..< dim {
                                        destination[i] = Float(source[i])
                                    }
                                }
                                cblas_sgemv(
                                    CblasRowMajor, CblasNoTrans,
                                    Int32(rows), Int32(dim), 1,
                                    block.baseAddress!, Int32(dim),
                                    queryBuffer.baseAddress!, 1, 0,
                                    scores.baseAddress!, 1
                                )
                                for row in 0..<rows { out[start + row] = scores[row] }
                                start += rows
                            }
                        }
                    }
                }
            }
        }
        #else
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: rowsOffset)
            normalized.withUnsafeBufferPointer { queryBuffer in
                let queryPointer = queryBuffer.baseAddress!
                result.withUnsafeMutableBufferPointer { out in
                    for (index, slot) in slots.enumerated() {
                        let halves = base
                            .advanced(by: slot * dim * MemoryLayout<Float16>.size)
                            .assumingMemoryBound(to: Float16.self)
                        var accumulator: Float = 0
                        for i in 0..<dim { accumulator += Float(halves[i]) * queryPointer[i] }
                        out[index] = accumulator
                    }
                }
            }
        }
        #endif
        return result
    }

    /// Verifies the invariant `scores` depends on: every stored row is already
    /// L2-normalized, because the Core ML graph bakes the normalization in.
    ///
    /// `scores` normalizes only the query, which is what makes it a single
    /// multiply-add per component. If a row ever arrived un-normalized, the
    /// result would not be an error -- it would be a *ranking*, silently wrong
    /// in proportion to that row's magnitude. So the store calls this once after
    /// a write batch and treats a deviation as a failed batch, turning a silent
    /// quality bug into a loud one. The cost is one pass over the matrix, which
    /// is why it is not run on every search.
    func validateNormalization(tolerance: Float = 0.01) -> (checked: Int, worstDeviation: Float) {
        var worst: Float = 0
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: rowsOffset)
            for slot in 0..<count {
                let halves = base
                    .advanced(by: slot * dimension * MemoryLayout<Float16>.size)
                    .assumingMemoryBound(to: Float16.self)
                var sum: Float = 0
                for i in 0..<dimension {
                    let value = Float(halves[i])
                    sum += value * value
                }
                worst = max(worst, abs(sum.squareRoot() - 1))
            }
        }
        _ = tolerance
        return (count, worst)
    }

    /// Top-`k` slots by descending score, ties broken by ascending slot so the
    /// ordering is deterministic (important: the benchmark and the tests compare
    /// rankings between the Accelerate and Metal paths).
    func topK(query: [Float], k: Int) throws -> [(slot: Int, score: Float)] {
        let all = try scores(query: query)
        guard k > 0 else { return [] }
        if k >= all.count {
            return all.enumerated()
                .sorted { $0.element == $1.element ? $0.offset < $1.offset : $0.element > $1.element }
                .map { (slot: $0.offset, score: $0.element) }
        }
        // Partial selection: keep a bounded worst-first buffer instead of
        // sorting all N. For 100k rows this is the difference between a full
        // sort and a single pass.
        var heap: [(slot: Int, score: Float)] = []
        heap.reserveCapacity(k + 1)
        for (slot, score) in all.enumerated() {
            if heap.count < k {
                heap.append((slot, score))
                if heap.count == k { heap.sort { $0.score < $1.score } }
            } else if score > heap[0].score {
                heap[0] = (slot, score)
                // Restore the min-heap property cheaply by re-sorting the small
                // buffer; k is a page of results, so this is negligible.
                heap.sort { $0.score < $1.score }
            }
        }
        return heap.sorted { $0.score == $1.score ? $0.slot < $1.slot : $0.score > $1.score }
    }
}

/// Mutable, append-mostly writer for an embedding matrix.
///
/// Not thread-safe by design: the owning store serializes access on its own
/// queue, and keeping the locking out here makes the failure modes obvious.
final class EmbeddingMatrixWriter {
    private let url: URL
    private let dimension: Int
    private let sourceModelSHA256: String
    private var descriptor: Int32 = -1
    private var header: EmbeddingHeader

    /// Rows added per growth step. 4096 rows at 768 dimensions is 6 MiB, which
    /// amortises `ftruncate` without wasting much on a small library.
    private let growthChunk = 4096

    var count: Int { header.count }
    var capacity: Int { header.capacity }
    var generation: UInt64 { header.generation }

    /// Opens an existing matrix or creates one. Fails loudly on a dimension or
    /// model mismatch rather than silently mixing incompatible vectors.
    init(url: URL, dimension: Int, sourceModelSHA256: String) throws {
        self.url = url
        self.dimension = dimension
        self.sourceModelSHA256 = sourceModelSHA256

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw EmbeddingStoreError.cannotCreateDirectory(error)
        }

        let existed = FileManager.default.fileExists(atPath: url.path)
        if !existed {
            self.header = EmbeddingHeader(
                dimension: dimension,
                count: 0,
                capacity: 0,
                sourceModelSHA256: sourceModelSHA256,
                generation: 0
            )
            try createFile()
        } else {
            let existing = try Data(contentsOf: url, options: .mappedIfSafe)
            self.header = try EmbeddingHeader(parsing: existing)
            guard header.dimension == dimension else {
                throw EmbeddingStoreError.dimensionMismatch(expected: dimension, found: header.dimension)
            }
            guard header.sourceModelSHA256 == sourceModelSHA256 else {
                throw EmbeddingStoreError.modelMismatch(
                    expected: sourceModelSHA256, found: header.sourceModelSHA256
                )
            }
        }

        descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else {
            throw EmbeddingStoreError.cannotOpen(
                NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            )
        }
        try excludeFromBackup()
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    private func createFile() throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw EmbeddingStoreError.cannotOpen(
                NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            )
        }
        // Make the file exactly one header page; rows are appended on demand.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(EmbeddingHeader.pageSize))
        // The offset must be set explicitly. `truncate(atOffset:)` leaves the
        // handle positioned at the *new end of file* on iOS, so writing straight
        // after it put the header at byte 4096 and left a page of zeros in front
        // of it. The file then grew to 8192 bytes with no magic at offset 0.
        //
        // That failed in the worst possible way: the first `open` succeeds,
        // because the header it just built is still in memory and the file is
        // never re-read. Every `open` after that parses the file and throws
        // `notAnEmbeddingFile`, so the index worked exactly once and then broke
        // permanently -- per install, per device, with no way back.
        //
        // It survived every local test because macOS leaves the offset at 0, so
        // the file came out correct there. Only running on a device -- where the
        // container persists between launches -- exposed it.
        try handle.seek(toOffset: 0)
        // The checksum has to be set here too, not only in `writeHeader()`.
        let bytes = header.serializedWithValidChecksum()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }

    /// The matrix is derived data: it must never be uploaded to iCloud or
    /// restored onto a different device, where the asset identifiers in SQLite
    /// would not match anyway.
    private func excludeFromBackup() throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        do {
            try mutable.setResourceValues(values)
        } catch {
            // Not fatal: the index is rebuildable, so a failure to set the
            // backup bit degrades storage hygiene, not correctness.
        }
    }

    /// Appends a vector and returns its slot.
    func append(_ vector: [Float]) throws -> Int {
        guard vector.count == dimension else {
            throw EmbeddingStoreError.dimensionMismatch(expected: dimension, found: vector.count)
        }
        if header.count >= header.capacity {
            try grow()
        }
        let slot = header.count
        try writeRow(vector, at: slot)
        header.count += 1
        header.generation += 1
        try writeHeader()
        return slot
    }

    /// Removes `slot` by moving the last row into it.
    ///
    /// Returns the slot that became vacant and, when a row actually moved, the
    /// slot it moved *from* is always `count - 1` before the decrement. The
    /// caller needs to know which asset now lives at `slot`, which it can only
    /// learn from SQLite, so this returns nothing but the caller must have
    /// already read the last row's asset id.
    @discardableResult
    func swapRemove(slot: Int) throws -> Bool {
        guard slot >= 0, slot < header.count else { throw EmbeddingStoreError.slotOutOfRange(slot) }
        let last = header.count - 1
        var moved = false
        if slot != last {
            let lastRow = try readRow(at: last)
            try writeRow(lastRow, at: slot)
            moved = true
        }
        header.count -= 1
        header.generation += 1
        try writeHeader()
        return moved
    }

    func row(at slot: Int) throws -> [Float] {
        try readRow(at: slot)
    }

    /// Forces the header and rows to stable storage. The index is rebuildable,
    /// so this is about avoiding a surprise rebuild after a crash, not about
    /// durability guarantees.
    func flush() throws {
        guard descriptor >= 0 else { return }
        if fcntl(descriptor, F_FULLFSYNC) == -1 {
            // F_FULLFSYNC is not supported on every volume; fsync is an
            // acceptable fallback since nothing here is unrebuildable.
            if fsync(descriptor) == -1 {
                throw EmbeddingStoreError.io(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
        }
    }

    // MARK: - Row and header I/O

    private func rowOffset(_ slot: Int) -> off_t {
        off_t(EmbeddingHeader.pageSize + slot * dimension * MemoryLayout<Float16>.size)
    }

    private func writeRow(_ vector: [Float], at slot: Int) throws {
        var halves = [Float16](repeating: 0, count: dimension)
        for i in 0..<dimension { halves[i] = Float16(vector[i]) }
        let byteCount = halves.count * MemoryLayout<Float16>.size
        let written = halves.withUnsafeBytes { buffer -> Int in
            pwrite(descriptor, buffer.baseAddress, byteCount, rowOffset(slot))
        }
        guard written == byteCount else { throw EmbeddingStoreError.shortWrite(expected: byteCount, got: written) }
    }

    private func readRow(at slot: Int) throws -> [Float] {
        let byteCount = dimension * MemoryLayout<Float16>.size
        var raw = [UInt8](repeating: 0, count: byteCount)
        let got = raw.withUnsafeMutableBytes { buffer -> Int in
            pread(descriptor, buffer.baseAddress, byteCount, rowOffset(slot))
        }
        guard got == byteCount else { throw EmbeddingStoreError.shortRead(expected: byteCount, got: got) }
        return raw.withUnsafeBytes { buffer in
            let halves = buffer.baseAddress!.assumingMemoryBound(to: Float16.self)
            return (0..<dimension).map { Float(halves[$0]) }
        }
    }

    private func writeHeader() throws {
        let bytes = header.serializedWithValidChecksum()
        let written = bytes.withUnsafeBytes { buffer -> Int in
            pwrite(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard written == bytes.count else {
            throw EmbeddingStoreError.shortWrite(expected: bytes.count, got: written)
        }
    }

    private func grow() throws {
        let newCapacity = max(growthChunk, header.capacity == 0 ? growthChunk : header.capacity * 2)
        let totalBytes = off_t(EmbeddingHeader.pageSize + newCapacity * dimension * MemoryLayout<Float16>.size)
        guard ftruncate(descriptor, totalBytes) == 0 else {
            throw EmbeddingStoreError.io(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        header.capacity = newCapacity
        header.generation += 1
        try writeHeader()
    }
}

/// The fixed header page. Kept as a value type so readers snapshot it atomically.
struct EmbeddingHeader {
    static let magic = "PVEMB001"
    static let currentVersion: UInt32 = 1
    /// One page. Rows begin here, which also makes the first row page-aligned.
    static let pageSize = 4096

    var version: UInt32 = EmbeddingHeader.currentVersion
    var dimension: Int
    var count: Int
    var capacity: Int
    var sourceModelSHA256: String
    var generation: UInt64
    var checksum: UInt64 = 0

    init(dimension: Int, count: Int, capacity: Int, sourceModelSHA256: String, generation: UInt64) {
        self.dimension = dimension
        self.count = count
        self.capacity = capacity
        self.sourceModelSHA256 = sourceModelSHA256
        self.generation = generation
    }

    /// Layout (little-endian):
    ///   0   magic 8s
    ///   8   u32 version
    ///   12  u32 dimension
    ///   16  u64 count
    ///   24  u64 capacity
    ///   32  u32 flags (reserved)
    ///   36  u32 reserved
    ///   40  sourceModelSHA256 64s (hex text, zero padded)
    ///   104 u64 generation
    ///   112 u64 reserved
    ///   120 u64 checksum (FNV-1a over bytes 0..<120)
    ///   128 ..< 4096 zero padding
    ///
    /// The hash field holds the full 64-character hex digest, not the 32 raw
    /// bytes: a truncated digest still compares unequal, so shortening it would
    /// not fail loudly, it would just weaken the check that a matrix was built
    /// by the model the app is currently using.
    static let hashFieldOffset = 40
    static let hashFieldLength = 64
    static let checksumOffset = 120
    static let checksumCoverage = 120
    func serialized() -> Data {
        var out = Data(count: EmbeddingHeader.pageSize)
        out.replaceSubrange(0..<8, with: Array(EmbeddingHeader.magic.utf8))
        func put(_ value: UInt32, _ offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { out.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        func put64(_ value: UInt64, _ offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { out.replaceSubrange(offset..<(offset + 8), with: $0) }
        }
        put(version, 8)
        put(UInt32(dimension), 12)
        put64(UInt64(count), 16)
        put64(UInt64(capacity), 24)
        let sha = Array(sourceModelSHA256.utf8.prefix(EmbeddingHeader.hashFieldLength))
        out.replaceSubrange(
            EmbeddingHeader.hashFieldOffset..<(EmbeddingHeader.hashFieldOffset + sha.count),
            with: sha
        )
        put64(generation, 104)
        put64(0, 112)
        put64(checksum, EmbeddingHeader.checksumOffset)
        return out
    }

    /// The header bytes with the checksum refreshed -- the only supported way to
    /// obtain bytes for writing.
    ///
    /// This exists because `createFile()` wrote `serialized()` directly while
    /// only `writeHeader()` remembered to set the checksum first. A brand new
    /// matrix therefore went to disk with a zero checksum and threw
    /// `headerCorrupt` on the very next open. Routing both through one mutating
    /// method makes forgetting impossible.
    ///
    /// It cannot live in `serialized()`: `computedChecksum()` is built on top of
    /// `serialized()`, so calling back into it from there is infinite recursion.
    mutating func serializedWithValidChecksum() -> Data {
        checksum = computedChecksum()
        return serialized()
    }

    init(parsing data: Data) throws {
        guard data.count >= EmbeddingHeader.pageSize else { throw EmbeddingStoreError.notAnEmbeddingFile }
        let magic = String(decoding: data[0..<8], as: UTF8.self)
        guard magic == EmbeddingHeader.magic else { throw EmbeddingStoreError.notAnEmbeddingFile }

        func u32(_ offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func u64(_ offset: Int) -> UInt64 {
            data[offset..<(offset + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }

        let version = u32(8)
        guard version == EmbeddingHeader.currentVersion else {
            throw EmbeddingStoreError.unsupportedVersion(version)
        }
        self.version = version
        self.dimension = Int(u32(12))
        self.count = Int(u64(16))
        self.capacity = Int(u64(24))
        let hashStart = EmbeddingHeader.hashFieldOffset
        let hashEnd = hashStart + EmbeddingHeader.hashFieldLength
        let hashBytes = Array(data[hashStart..<hashEnd])
        self.sourceModelSHA256 = String(decoding: hashBytes.prefix { $0 != 0 }, as: UTF8.self)
        self.generation = u64(104)
        self.checksum = u64(EmbeddingHeader.checksumOffset)

        guard dimension > 0, dimension <= 8192,
              count >= 0, capacity >= count
        else { throw EmbeddingStoreError.headerCorrupt }

        // Verify the checksum over the same range the writer used, with the
        // stored checksum zeroed so the comparison is like-for-like.
        var copy = Data(data[0..<EmbeddingHeader.pageSize])
        copy.replaceSubrange(
            EmbeddingHeader.checksumOffset..<(EmbeddingHeader.checksumOffset + 8),
            with: [UInt8](repeating: 0, count: 8)
        )
        guard EmbeddingHeader.fnv1a(copy[0..<EmbeddingHeader.checksumCoverage]) == checksum else {
            throw EmbeddingStoreError.headerCorrupt
        }
    }

    func computedChecksum() -> UInt64 {
        var copy = serialized()
        copy.replaceSubrange(
            EmbeddingHeader.checksumOffset..<(EmbeddingHeader.checksumOffset + 8),
            with: [UInt8](repeating: 0, count: 8)
        )
        return EmbeddingHeader.fnv1a(copy[0..<EmbeddingHeader.checksumCoverage])
    }

    /// FNV-1a, 64-bit. Small, dependency-free, and entirely adequate for
    /// detecting a torn or truncated header.
    static func fnv1a<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
