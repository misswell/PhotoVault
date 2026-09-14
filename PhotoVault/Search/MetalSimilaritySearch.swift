//
//  MetalSimilaritySearch.swift
//  PhotoVault
//
//  GPU exact-search path over the embedding matrix, with the Accelerate path in
//  `EmbeddingStoreFile.swift` as the fallback.
//
//  The matrix is mapped, not copied
//  --------------------------------
//  The rows are wrapped with `makeBuffer(bytesNoCopy:)` over the existing mmap,
//  so the GPU reads the file-backed pages directly. Copying 147 MiB into a Metal
//  buffer per search would cost more than the search itself and would put a
//  second full copy of the library in memory -- the exact thing Float16 storage
//  was chosen to avoid.
//
//  Because of that the mmap must outlive the Metal buffer, so it is held as a
//  stored property rather than a local.
//
//  What stays on the CPU
//  ---------------------
//  Only the dot products go to the GPU. Selecting the top k from 100k floats is
//  a single linear pass (well under a millisecond) and moving it to the GPU would
//  add a reduction, a dispatch and a readback to save nothing. The expensive part
//  is the multiply-accumulate, and that is the part that is parallelised.
//

import Foundation
import Metal

enum EmbeddingSearchError: LocalizedError {
    case metalUnavailable
    case libraryUnavailable
    case kernelMissing(String)
    case bufferAllocationFailed
    case commandFailed(String)
    case matrixTooSmall

    var errorDescription: String? {
        switch self {
        case .metalUnavailable: "no Metal device is available"
        case .libraryUnavailable: "no Metal library containing the search kernel"
        case .kernelMissing(let name): "Metal kernel \(name) is missing"
        case .bufferAllocationFailed: "could not allocate a Metal buffer for the matrix"
        case .commandFailed(let detail): "Metal search failed: \(detail)"
        case .matrixTooSmall: "the embedding matrix is shorter than its header claims"
        }
    }
}

/// Exact cosine search over an `embeddings-v1.bin` matrix, on the GPU.
///
/// Not `Sendable`: it owns a command queue and mutable buffers, and the store
/// serialises access on its own queue. Making it look thread-safe would hide
/// that.
final class MetalSimilaritySearch {

    static let kernelName = "embedding_dot_fp16"
    /// 256 threads per group: enough to hide memory latency on every Apple GPU
    /// family, and a multiple of the SIMD width so no lanes are wasted.
    static let threadsPerThreadgroup = 256

    let dimension: Int
    let rowCount: Int

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let rowBuffer: MTLBuffer
    private let queryBuffer: MTLBuffer
    private let scoreBuffer: MTLBuffer
    /// Keeps the memory the `rowBuffer` points at alive. Must not be removed.
    private let mappedMatrix: Data
    /// Reused across searches to avoid reallocating a page of results.
    private var scoreScratch: [Float]

    var maxRows: Int { rowCount }

    /// The largest threadgroup this pipeline accepts. `threadsPerThreadgroup` is
    /// the *preferred* width chosen for Apple GPUs; the device may allow less,
    /// and dispatching more than the pipeline permits is not a request Metal is
    /// obliged to honour.
    var maxThreadsPerThreadgroup: Int { pipeline.maxTotalThreadsPerThreadgroup }

    /// - Parameter libraryURL: where to find a library when the app's default
    ///   one does not contain the kernel. The app uses the default library
    ///   (Xcode compiles `EmbeddingSimilarity.metal` into it); the test harness
    ///   passes a metallib built alongside the binary.
    init(matrixURL: URL, dimension: Int, rowCount: Int, libraryURL: URL? = nil) throws {
        guard dimension > 0, rowCount >= 0 else { throw EmbeddingSearchError.matrixTooSmall }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EmbeddingSearchError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw EmbeddingSearchError.metalUnavailable
        }

        let mapped = try Data(contentsOf: matrixURL, options: .mappedIfSafe)
        let required = EmbeddingHeader.pageSize + rowCount * dimension * MemoryLayout<Float16>.size
        guard mapped.count >= required else { throw EmbeddingSearchError.matrixTooSmall }

        // Load the kernel. The default library is what the app builds; a
        // separately compiled metallib is what the harness has.
        var library: MTLLibrary?
        if let defaultLibrary = try? device.makeDefaultLibrary(bundle: .main),
           defaultLibrary.functionNames.contains(Self.kernelName) {
            library = defaultLibrary
        } else if let libraryURL {
            library = try? device.makeLibrary(URL: libraryURL)
        } else if let defaultLibrary = device.makeDefaultLibrary(),
                  defaultLibrary.functionNames.contains(Self.kernelName) {
            library = defaultLibrary
        }
        guard let library else { throw EmbeddingSearchError.libraryUnavailable }
        guard let function = library.makeFunction(name: Self.kernelName) else {
            throw EmbeddingSearchError.kernelMissing(Self.kernelName)
        }

        self.device = device
        self.commandQueue = commandQueue
        self.mappedMatrix = mapped
        self.dimension = dimension
        self.rowCount = rowCount
        self.scoreScratch = [Float](repeating: 0, count: rowCount)
        self.pipeline = try device.makeComputePipelineState(function: function)

        // Zero-copy wrap of the mmap. `deallocator: nil` on purpose: the Data
        // owns the memory, so Metal must not free it.
        //
        // 🔴 Wrap the *whole* mapping and apply the header offset when binding,
        // rather than wrapping `base + pageSize`. `makeBuffer(bytesNoCopy:)`
        // requires a page-aligned pointer, and the header page is 4096 while the
        // hardware page size is 16384 on Apple silicon -- so `base + 4096` is
        // only 4096-aligned. macOS happened to tolerate that; iOS does not, and
        // the GPU read the wrong memory entirely (scores around -1428 where the
        // cosine must be within [-1, 1]). Binding with an offset keeps the
        // zero-copy property and satisfies the alignment rule.
        let base = (mapped as NSData).bytes
        guard let rowBuffer = device.makeBuffer(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
            length: mapped.count,
            options: .storageModeShared,
            deallocator: nil
        ) else {
            throw EmbeddingSearchError.bufferAllocationFailed
        }
        self.rowBuffer = rowBuffer

        let queryLength = max(1, dimension * MemoryLayout<Float>.size)
        guard let queryBuffer = device.makeBuffer(length: queryLength, options: .storageModeShared),
              let scoreBuffer = device.makeBuffer(
                  length: max(1, rowCount * MemoryLayout<Float>.size), options: .storageModeShared
              )
        else {
            throw EmbeddingSearchError.bufferAllocationFailed
        }
        self.queryBuffer = queryBuffer
        self.scoreBuffer = scoreBuffer
    }

    /// True when this machine can run the GPU path at all. Callers use it to
    /// decide between the Metal and Accelerate implementations.
    static func isAvailable() -> Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    /// Scores every row against `query`.
    ///
    /// `query` is expected to be unit length, matching what the text tower
    /// produces. It is not normalised here -- normalising twice is harmless but
    /// doing it implicitly would hide a caller that forgot.
    func scores(query: [Float]) throws -> [Float] {
        guard query.count == dimension else {
            throw EmbeddingSearchError.commandFailed(
                "query has \(query.count) dimensions, matrix has \(dimension)"
            )
        }
        guard rowCount > 0 else { return [] }

        query.withUnsafeBytes { raw in
            queryBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw EmbeddingSearchError.commandFailed("could not create a command buffer")
        }

        var dimensionValue = UInt32(dimension)
        var rowCountValue = UInt32(rowCount)

        encoder.setComputePipelineState(pipeline)
        // The rows start one header page into the mapping (see the note in `init`).
        encoder.setBuffer(rowBuffer, offset: EmbeddingHeader.pageSize, index: 0)
        encoder.setBuffer(queryBuffer, offset: 0, index: 1)
        encoder.setBuffer(scoreBuffer, offset: 0, index: 2)
        encoder.setBytes(&dimensionValue, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.setBytes(&rowCountValue, length: MemoryLayout<UInt32>.size, index: 4)

        // Clamp to what the pipeline actually allows rather than assuming the
        // preferred width is accepted everywhere.
        let width = max(1, min(Self.threadsPerThreadgroup, pipeline.maxTotalThreadsPerThreadgroup))
        let threadsPerGroup = MTLSize(width: width, height: 1, depth: 1)
        let groups = MTLSize(
            width: (rowCount + width - 1) / width,
            height: 1, depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw EmbeddingSearchError.commandFailed(error.localizedDescription)
        }

        let pointer = scoreBuffer.contents().bindMemory(to: Float.self, capacity: rowCount)
        return Array(UnsafeBufferPointer(start: pointer, count: rowCount))
    }

    /// Top-k by cosine similarity, ties broken by ascending slot.
    ///
    /// Exactly-equal scores break identically to the Accelerate path, since both
    /// call `selectTopK`. Two scores that differ by less than Float32
    /// accumulation error may still order differently between the two paths --
    /// the underlying floats genuinely differ. That is inherent to computing on
    /// different hardware, and a test asserts the disagreement never extends
    /// beyond scores that are indistinguishable at this precision.
    func topK(query: [Float], k: Int) throws -> [(slot: Int, score: Float)] {
        let all = try scores(query: query)
        return Self.selectTopK(all, k: k)
    }

    static func selectTopK(_ scores: [Float], k: Int) -> [(slot: Int, score: Float)] {
        guard k > 0 else { return [] }
        if k >= scores.count {
            return scores.enumerated()
                .sorted { $0.element == $1.element ? $0.offset < $1.offset : $0.element > $1.element }
                .map { (slot: $0.offset, score: $0.element) }
        }
        // Bounded worst-first buffer: one linear pass instead of a full sort.
        var heap: [(slot: Int, score: Float)] = []
        heap.reserveCapacity(k + 1)
        for (slot, score) in scores.enumerated() {
            if heap.count < k {
                heap.append((slot, score))
                if heap.count == k { heap.sort { $0.score < $1.score } }
            } else if score > heap[0].score {
                heap[0] = (slot, score)
                heap.sort { $0.score < $1.score }
            }
        }
        return heap.sorted { $0.score == $1.score ? $0.slot < $1.slot : $0.score > $1.score }
    }
}
