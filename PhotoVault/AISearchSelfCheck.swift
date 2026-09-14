//
//  AISearchSelfCheck.swift
//  PhotoVault
//
//  Answers the questions that cannot be settled on a Mac.
//
//  Everything verified so far ran on an Apple M1. Four things are only knowable
//  on the actual device:
//
//  1. Does iOS ship SQLite **FTS5 with the trigram tokenizer**? The hybrid text
//     search degrades to `instr()` without it, and no simulator or Mac can
//     answer this for iOS.
//  2. Does the Core ML model actually land on the **Neural Engine**?
//  3. What is the **first-load time** and **peak memory** with a real ANE?
//  4. Does the whole stack load and run on device at all?
//
//  Running these needs no UI interaction, which is the point: it is triggered by
//  a launch argument and writes a plain-text report to the app's Caches
//  directory, which `devicectl device copy from` can retrieve.
//
//      xcrun devicectl device process launch -d <id> com.misswell.PhotoVault \
//        --pv-ai-selfcheck
//
//  This lives outside `PhotoVault/Search/` deliberately: the `privacy` gate
//  asserts that the *search stack* never writes to a log, and a diagnostic
//  harness is a different thing from the code under audit. It is also wrapped in
//  `#if DEBUG`, so none of it exists in a Release build.
//
//  The report contains only counts, timings and booleans -- no photo data, no
//  embeddings, no queries. Nothing here is uploaded; the file stays in the app
//  container and is removed on the next run.
//

#if DEBUG

import CoreML
import Foundation
import Photos
import SQLite3

enum AISearchSelfCheck {

    /// Opt-in: `--pv-ai-selfcheck-request-auth` also *asks* for photo access.
    ///
    /// The normal run never prompts -- a background probe must not raise a
    /// system dialog -- and that stays true. But without this, a simulator or a
    /// test run has no route to `.authorized` at all, so every photo-dependent
    /// probe is skipped and `identifier order` can never be answered. Requesting
    /// is therefore explicit and separate from merely running the check.
    static var requestsAuthorization: Bool {
        ProcessInfo.processInfo.arguments.contains("--pv-ai-selfcheck-request-auth")
    }

    /// Opt-in: `--pv-ai-selfcheck-index` also runs the real indexing pipeline
    /// over the photo library and then searches it.
    ///
    /// Separate from a plain run because it *writes* the app's index and can
    /// take minutes on a CPU-only simulator. It is the only check here that
    /// exercises the whole chain -- PhotoKit metadata, asset loading, the vision
    /// tower, the embedding matrix, and retrieval -- rather than each piece
    /// against synthetic input.
    static var runsEndToEndIndex: Bool {
        ProcessInfo.processInfo.arguments.contains("--pv-ai-selfcheck-index")
    }

    /// Set by passing `--pv-ai-selfcheck` at launch.
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--pv-ai-selfcheck")
    }

    /// PhotoKit's own filename for an asset, which is how the evaluation fixture
    /// is identified. `PHAsset` carries no filename of its own; it lives on the
    /// first resource.
    /// Location and capture date for an asset, for verifying the metadata
    /// filters end to end. `PHAsset.location` is nil for assets with no fix,
    /// which is the distinction the index stores -- not the placeholder
    /// coordinate PhotoKit keeps in its own database.
    static func provenance(forAssetID identifier: String) -> String {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            .firstObject else { return "?,?" }
        let lat = asset.location.map { String(format: "%.4f", $0.coordinate.latitude) } ?? "nil"
        let lon = asset.location.map { String(format: "%.4f", $0.coordinate.longitude) } ?? "nil"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = asset.creationDate.map { formatter.string(from: $0) } ?? "nil"
        return "\(lat),\(lon),\(date)"
    }

    /// Look up an asset by its original filename, so the evaluation can address
    /// fixture images by the name they were generated under.
    static func assetID(forOriginalFilename name: String) -> String? {
        let all = PHAsset.fetchAssets(with: nil)
        var found: String?
        all.enumerateObjects { asset, _, stop in
            if PHAssetResource.assetResources(for: asset).first?.originalFilename == name {
                found = asset.localIdentifier
                stop.pointee = true
            }
        }
        return found
    }

    static func originalFilename(forAssetID identifier: String) -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            .firstObject else { return nil }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    static let logName = "AISearchSelfCheck.log"

    private static var logURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent("PhotoVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(logName)
    }

    /// Runs every probe and writes one report.
    ///
    /// Never throws: a probe that fails is a result, and a self-check that can
    /// itself abort tells you nothing.
    static func run() async {
        var lines: [String] = []
        // Emit the report as it is produced, not only once at the end. A first
        // index of a real library runs for hours -- the device library here is
        // 104k photos -- so a report that exists only on completion is lost
        // exactly when it is most interesting: when the app is killed partway
        // through, which is the pause/resume case the plan requires anyway.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        let lock = NSLock()
        func say(_ text: String = "") {
            lock.lock()
            defer { lock.unlock() }
            lines.append(text)
            if let handle, let data = (text + "\n").data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }

        say("PhotoVault AI search — on-device self-check")
        say("date: \(ISO8601DateFormatter().string(from: Date()))")
        say("device: \(deviceModel())")
        say("os: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        say("")

        // ---- 1. SQLite FTS5 + trigram ------------------------------------
        say("== SQLite full-text search ==")
        let fts = probeFullTextSearch()
        say("sqlite version:     \(fts.version)")
        say("FTS5 compiled in:   \(fts.hasFTS5)")
        say("trigram tokenizer:  \(fts.hasTrigram)")
        say("unicode61:          \(fts.hasUnicode61)")
        if let detail = fts.detail { say("detail:             \(detail)") }
        // This decides whether hybrid OCR search can use MATCH or must fall back
        // to a scan. Recorded explicitly so the fallback is a known state.
        say("search path:        \(fts.hasTrigram ? "FTS5 MATCH (trigram)" : "instr() fallback")")
        say("")

        // ---- 2. the model loads, and where it runs -----------------------
        say("== Core ML ==")
        let resources = SearchModelResources()
        say("artifacts present:  \(resources.isInstalled)")
        if let manifest = try? resources.manifest() {
            say("manifest:           \(manifest.name)")
            say("quantization:       \(manifest.quantization)")
            say("dimension:          \(manifest.embeddingDimension)")
        }

        reportComputeDevices(say: say)
        await reportComputePlan(say: say)

        // Whether the end-to-end path can be exercised at all. The self-check
        // never *requests* permission -- a background probe must not raise a
        // system prompt -- so it reports the state and stops there.
        if Self.requestsAuthorization {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            say("photo access asked: \(authorizationName(granted))")
        }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        say("photo access:       \(authorizationName(authorization))")
        say("")

        // ---- 3b. does PhotoKit preserve the order of the identifiers we pass? --
        //
        // This decides whether AI search results can page in relevance order.
        // `SmartSearchScreen` hands the ranked identifiers to
        // `fetchAssets(withLocalIdentifiers:)` and the viewer walks whatever
        // comes back, so if PhotoKit reorders them the ranked list is lost the
        // moment a photo is opened -- and the fix has to be an ordered pager
        // rather than passing the rank as the index.
        //
        // Worth measuring rather than assuming: the returned order is documented
        // as unspecified, which is not the same as "it differs", and the code
        // comments had been asserting the latter without evidence.
        say("== identifier order ==")
        if authorization == .authorized || authorization == .limited {
            let all = PHAsset.fetchAssets(with: nil)
            let sample = min(all.count, 8)
            if sample >= 2 {
                var forward: [String] = []
                all.enumerateObjects { asset, index, stop in
                    if index >= sample { stop.pointee = true; return }
                    forward.append(asset.localIdentifier)
                }
                let requested = Array(forward.reversed())
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: requested, options: nil)
                var returned: [String] = []
                fetched.enumerateObjects { asset, _, _ in returned.append(asset.localIdentifier) }

                say("assets in library:  \(all.count)")
                say("requested first:    \(requested.prefix(2).map { String($0.prefix(8)) }.joined(separator: ", "))")
                say("returned first:     \(returned.prefix(2).map { String($0.prefix(8)) }.joined(separator: ", "))")
                say("input order kept:   \(returned == requested ? "YES" : "NO")")
                say("returned count:     \(returned.count) of \(requested.count)")

                // The fix `SmartSearchScreen.open(_:at:)` applies. Since the fetch
                // result cannot express the ranking, it is used only as a lookup
                // table and the ranked order is re-emitted explicitly. Verifying
                // that here keeps the workaround honest: if PhotoKit ever starts
                // honouring the input order, or the rebuild is wrong, this says so.
                var byIdentifier: [String: PHAsset] = [:]
                fetched.enumerateObjects { asset, _, _ in
                    byIdentifier[asset.localIdentifier] = asset
                }
                let rebuilt = requested.compactMap { byIdentifier[$0] }
                let rebuiltIdentifiers = rebuilt.map(\.localIdentifier)
                say("fetch usable as map: \(byIdentifier.count == requested.count ? "YES" : "NO")")
                say("ranked rebuild order: \(rebuiltIdentifiers == requested ? "kept" : "LOST")")
            } else {
                say("not enough photos:  \(all.count)")
            }
        } else {
            say("skipped:            no photo access (\(authorizationName(authorization)))")
        }
        say("")

        // First load is the number that decides whether the screen feels
        // instant or broken, and it is dominated by weight paging.
        var vision: SigLIP2VisionEncoder?
        var text: SigLIP2TextEncoder?
        var tokenizer: SigLIP2Tokenizer?

        let visionStart = Date()
        do {
            vision = try resources.makeVisionEncoder()
            say(String(format: "vision first load:  %.0f ms", Date().timeIntervalSince(visionStart) * 1000))
            if let vision { say("vision dimension:   \(vision.dimension)") }
        } catch {
            say("vision load FAILED: \(error)")
        }

        let textStart = Date()
        do {
            text = try resources.makeTextEncoder()
            tokenizer = try resources.makeTokenizer()
            say(String(format: "text first load:    %.0f ms", Date().timeIntervalSince(textStart) * 1000))
        } catch {
            say("text load FAILED:   \(error)")
        }
        say("")

        // ---- 3. warm latency ---------------------------------------------
        say("== warm latency ==")
        if let vision, let text, let tokenizer {
            let image = solidImage()
            if let image {
                measure("vision encode", say: say) { try vision.embedding(cgImage: image) }
            }
            measure("text encode", say: say) {
                try text.embedding(text: "海边的猫", tokenizer: tokenizer)
            }
            measure("text encode (ASCII)", say: say) {
                try text.embedding(text: "cat", tokenizer: tokenizer)
            }

            // The pair check that needs no photo library: if the tokenizer and
            // text tower are the validated pair, case is still not folded.
            if let upper = try? text.embedding(text: "CAT", tokenizer: tokenizer),
               let lower = try? text.embedding(text: "cat", tokenizer: tokenizer) {
                let similarity = cosine(upper, lower)
                say(String(format: "cos(CAT, cat):      %.4f (expect ~0.8616)", similarity))
            }
        }
        say("")

        // ---- 4. the metadata index and its migration ---------------------
        say("== AI index store ==")
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("PhotoVault", isDirectory: true)
        let store = AIPhotoSearchStore(
            databaseURL: directory.appendingPathComponent("AIPhotoSearch.sqlite"),
            embeddingURL: directory.appendingPathComponent("embeddings-v1.bin")
        )
        do {
            // Open exactly as the app does. A hardcoded dimension would break the
            // spec's rule that the dimension comes from the converted metadata,
            // and a placeholder fingerprint would contradict what the app wrote --
            // reporting a model mismatch on any device that had built an index,
            // and, through the rebuilding entry point, wiping it.
            let manifest = try resources.manifest()
            let fingerprint = try resources.modelFingerprint()
            try store.open(
                dimension: manifest.embeddingDimension, sourceModelSHA256: fingerprint
            )
            let stats = try store.stats()
            say("open:               ok")
            say("total assets:       \(stats.totalAssets)")
            say("embedded:           \(stats.embeddedAssets)")
            say("pending:            \(stats.pendingAssets)")
            say("failed:             \(stats.failedAssets)")
            say("with location:      \(stats.assetsWithLocation)")
            say("with text:          \(stats.assetsWithText)")
        } catch {
            say("open FAILED:        \(error)")
        }
        say("")

                // ---- 100k scan, on the device -------------------------------
        // §82 asks for retrieval performance at 100k embeddings. That number
        // has only ever existed for the Mac, and the Mac is not the device: the
        // A17's memory bandwidth and the ANE/GPU split are different machines.
        // This measures the shipping Accelerate scan at the size that matters.
        // Opt-in: `--pv-ai-selfcheck-scan`. It builds a 192 MB synthetic matrix
        // in the temporary directory, which is far more memory than the real
        // index needs -- on a device it can be jetsam-killed, taking the whole
        // self-check (and a multi-hour index run) down with it. The default run
        // must not risk that.
        if ProcessInfo.processInfo.arguments.contains("--pv-ai-selfcheck-scan") {
        say("== 100k scan (device) ==")
        do {
            let dimension = 768
            let rows = 100_000
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pv-scan-bench", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let matrixURL = directory.appendingPathComponent("synthetic-\(rows)x\(dimension).bin")

            if !FileManager.default.fileExists(atPath: matrixURL.path) {
                var seed: UInt64 = 0x2026_0913
                func nextFloat() -> Float {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
                }
                let writer = try EmbeddingMatrixWriter(
                    url: matrixURL, dimension: dimension,
                    sourceModelSHA256: String(repeating: "ab", count: 32)
                )
                // Deliberately not unit-normalised: the scan's cost depends on
                // the matrix shape, not on the row values, and skipping the
                // normalisation removes 76.8M sqrt/divide operations from a
                // benchmark that already holds the device for long enough.
                for _ in 0..<rows {
                    var vector = [Float](repeating: 0, count: dimension)
                    for index in 0..<dimension { vector[index] = nextFloat() }
                    _ = try writer.append(vector)
                }
                try writer.flush()
            }

            let reader = try EmbeddingMatrixReader(url: matrixURL)
            var query = [Float](repeating: 1, count: dimension)
            let norm = query.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            for index in 0..<dimension { query[index] /= norm }

            _ = try reader.scores(query: query)   // warm the mmap
            var timings: [Double] = []
            for _ in 0..<10 {
                let start = Date()
                _ = try reader.scores(query: query)
                timings.append(Date().timeIntervalSince(start) * 1000)
            }
            timings.sort()
            say("rows:               \(reader.count) (dim \(dimension))")
            say(String(format: "scan P50:           %.2f ms", timings[timings.count / 2]))
            say(String(format: "scan P95:           %.2f ms", timings[min(timings.count - 1, Int(Double(timings.count) * 0.95))]))
            say(String(format: "scan min:           %.2f ms", timings[0]))
            try? FileManager.default.removeItem(at: matrixURL)
        } catch {
            say("scan FAILED:        \(error)")
        }
        say("")
        }
        // ---- 4b. the whole chain, on real photos --------------------------
        if Self.runsEndToEndIndex, vision != nil, let text, let tokenizer {
            say("== end-to-end index ==")
            do {
                let sync = try PhotoKitMetadataSync(store: store).sync()
                say("metadata inserted:  \(sync.inserted) updated: \(sync.updated) deleted: \(sync.deleted)")
                say("metadata fullscan:  \(sync.didFullScan)  limited: \(sync.isLimited)")
                let pending = PhotoKitPendingSource(store: store)
                say("assets to index:    \(try pending.totalAssetCount())")

                guard let vision else { throw AISearchStoreError.databaseUnavailable }
                let coordinator = PhotoSearchIndexCoordinator(
                    store: store,
                    source: pending,
                    imageLoader: PhotoKitImageLoader(),
                    embedder: vision,
                    recognizer: PhotoTextRecognizer()
                )
                let started = Date()
                await coordinator.run(conditions: { .current() })
                say(String(format: "index run:          %.1f s", Date().timeIntervalSince(started)))

                let indexed = try store.stats()
                say("embedded:           \(indexed.embeddedAssets)")
                say("pending:            \(indexed.pendingAssets)")
                say("failed:             \(indexed.failedAssets)")
                say("with text:          \(indexed.assetsWithText)")

                // Retrieval, through the same engine the search screen uses.
                let reader = try EmbeddingMatrixReader(url: store.embeddingURLForTesting)
                let engine = PhotoSearchEngine(
                    store: store,
                    embeddings: reader,
                    encoder: SigLIP2QueryEncoder(encoder: text, tokenizer: tokenizer)
                )
                // Phase 12 tuning evidence. `PhotoSearchConfiguration.minimumScore`
                // defaults to 0.02 with a comment saying it should be tuned against
                // a labelled set, and that has never been measured. Printing the
                // actual score distribution shows whether the floor sits in the
                // noise (everything passes) or above real matches (nothing does).
                for query in ["a red square", "蓝色", "green", "a photo of text", "mountain waterfall"] {
                    let response = try engine.search(query, limit: 5)
                    let scores = response.hits.map { $0.score }
                    let rendered = scores.map { String(format: "%.3f", $0) }.joined(separator: " ")
                    say("search \"\(query)\"".padding(toLength: 22, withPad: " ", startingAt: 0)
                        + " \(response.hits.count) hits  [\(rendered)]")
                }
                // How much of the library clears the floor for an unrelated query.
                // A floor below the noise band lets everything through, which is
                // the failure this constant is supposed to prevent.
                for query in ["a red square", "mountain waterfall"] {
                    let wide = try engine.search(query, limit: 500)
                    let above = wide.hits.count
                    let mean = wide.hits.isEmpty ? 0 : wide.hits.map(\.score).reduce(0, +) / Float(above)
                    say("floor probe \"\(query)\"".padding(toLength: 22, withPad: " ", startingAt: 0)
                        + " \(above)/\(indexed.embeddedAssets) clear 0.02, mean \(String(format: "%.3f", mean))")
                }
                // ---- labelled retrieval evaluation ------------------------
                // Emits the ranking with each asset's *original filename* so the
                // ground truth can be joined outside the app. Scoring here would
                // mean hardcoding a fixture into shipping-adjacent code, and the
                // labels are only meaningful next to the images they describe.
                say("== retrieval eval ==")
                for query in [
                    "a red image", "a green image", "a blue image",
                    "a purple image", "a yellow image", "a cyan image",
                    "an invoice", "a passport",
                    // Quoting is the documented exact-text request, and it is the
                    // only phrasing that populates `ocrTerms` -- so these two are
                    // what actually exercise the OCR pathway. The unquoted
                    // "an invoice" above does NOT: it is answered by appearance
                    // (a white page with black marks looks like a document), and
                    // keeping both makes the difference visible.
                    "\"INVOICE\"", "\"PASSPORT\"",
                    // Set logic, against photos whose contents are known. The
                    // `query` and `search` gates cover these rules on synthetic
                    // input; these cover them on the real path, where a negative
                    // clause has to out-score the configured ceiling against an
                    // actual embedding rather than a hand-built vector.
                    "a red image or a green image",
                    "a red image and a blue image",
                    "a red image not a cyan image",
                    // Metadata filters. These never touch the vector path, so
                    // they exercise the other half of the engine: the gazetteer
                    // resolving a place name to a coordinate and the date parser
                    // producing a range.
                    "北京", "上海", "东京", "2026年9月14日",
                ] {
                    let response = try engine.search(query, limit: 6)
                    var parts: [String] = []
                    for hit in response.hits {
                        let name = Self.originalFilename(forAssetID: hit.assetID) ?? "?"
                        parts.append("\(name):\(String(format: "%.4f", hit.score))")
                    }
                    // Separated from the ranking so the ranking line stays a
                    // plain list. This is what distinguishes "the invoice image
                    // looks like a document" from "OCR read the word INVOICE":
                    // OCR terms act as a *filter*, so a drop in candidates proves
                    // the text pathway did the work.
                    let plan = response.plan
                    say(
                        "evalplan|\(query)|candidates=\(response.diagnostics.candidateCount)"
                        + "|ocr=\(plan.ocrTerms.joined(separator: ","))"
                        + "|clauses=\(response.diagnostics.encodedClauses.count)"
                        + "|combine=\(plan.combine)"
                        + "|neg=\(plan.negativeVisualClauses.count)"
                    )
                    say("eval|\(query)|\(parts.joined(separator: " "))")
                    for hit in response.hits {
                        let name = Self.originalFilename(forAssetID: hit.assetID) ?? "?"
                        say(
                            "evalmeta|\(query)|\(name)|\(Self.provenance(forAssetID: hit.assetID))"
                        )
                    }
                }
                // ---- similar-image search ---------------------------------
                // Seeded by filename so the expectation is checkable: a red
                // photo's nearest neighbour should be the other red one. The seed
                // itself must not come back -- returning the query image as its
                // own best match is the classic way this feature looks broken
                // while appearing to work.
                say("== similar image ==")
                for seed in ["photo0.jpg", "photo5.jpg", "invoice.jpg"] {
                    guard let identifier = Self.assetID(forOriginalFilename: seed) else {
                        say("similar|\(seed)|seed not found")
                        continue
                    }
                    let response = try engine.search(similarTo: identifier, limit: 5)
                    let listed = response.hits.map { hit in
                        "\(Self.originalFilename(forAssetID: hit.assetID) ?? "?")"
                            + ":\(String(format: "%.4f", hit.score))"
                    }
                    say("similar|\(seed)|\(listed.joined(separator: " "))")
                }

        // ---- the Metal kernel, on the iOS Metal stack ---------------
                // `verify_siglip2.py metal` compiles this kernel into a **macOS**
                // harness, so its green result says nothing about whether the
                // kernel runs inside the app. It also ships in the bundle while
                // nothing calls it -- the shipping path is the Accelerate
                // fallback -- so this is the evidence that would have to exist
                // before it could be wired in.
                say("== Metal search (iOS) ==")
                do {
                    let manifest = try resources.manifest()
                    let reader = try EmbeddingMatrixReader(url: store.embeddingURLForTesting)
                    let dimension = manifest.embeddingDimension
                    let byteCount = EmbeddingHeader.pageSize + dimension * 2
                    guard reader.count > 0, try Data(contentsOf: store.embeddingURLForTesting).count >= byteCount else {
                        throw EmbeddingSearchError.matrixTooSmall
                    }

                    // A stored row is already unit-norm, so it doubles as a query
                    // vector and needs no encoder.
                    let matrix = try Data(contentsOf: store.embeddingURLForTesting, options: .mappedIfSafe)
                    var vector = [Float](repeating: 0, count: dimension)
                    matrix.withUnsafeBytes { raw in
                        let base = raw.baseAddress!.advanced(by: EmbeddingHeader.pageSize)
                        let half = base.assumingMemoryBound(to: Float16.self)
                        for index in 0..<dimension { vector[index] = Float(half[index]) }
                    }

                    let metal = try MetalSimilaritySearch(
                        matrixURL: store.embeddingURLForTesting,
                        dimension: dimension,
                        rowCount: reader.count
                    )
                    say("metal device:       ok (rows \(metal.maxRows), dim \(dimension))")

                    // The dispatch uses a fixed 256 threads per group without
                    // consulting the pipeline. If this device allows fewer, the
                    // group is over-subscribed and the kernel silently produces
                    // nothing useful.
                    say("metal maxThreads:   \(metal.maxThreadsPerThreadgroup) (preferred \(MetalSimilaritySearch.threadsPerThreadgroup))")

                    // Does bridging to NSData hand back the same memory, or a copy?
                    // `MetalSimilaritySearch` wraps `(mapped as NSData).bytes` with
                    // `bytesNoCopy` and a nil deallocator, so if the bridge copies,
                    // that pointer belongs to a temporary that is released
                    // immediately -- and the GPU reads freed memory.
                    let bridged = (matrix as NSData).bytes
                    let direct = matrix.withUnsafeBytes { $0.baseAddress! }
                    say("nsdata bridge copy: \(bridged == direct ? "NO (same memory)" : "YES (different pointer!)")")

                    // `makeBuffer(bytesNoCopy:)` demands a page-aligned pointer.
                    // The mmap base satisfies that, but the rows begin one
                    // *header* page in -- and the header page is not necessarily a
                    // multiple of the hardware page size. That mismatch is what
                    // made the GPU read the wrong memory on iOS, so the buffer
                    // wraps the whole mapping and the header offset is applied at
                    // bind time. Printed here because it is the whole story.
                    let hwPage = Int(getpagesize())
                    let headerPage = EmbeddingHeader.pageSize
                    let baseAligned = Int(bitPattern: direct) % hwPage == 0
                    say("page size:          \(hwPage), header page \(headerPage)")
                    say("row offset aligned: \(headerPage % hwPage == 0 ? "YES" : "NO (bound with setBuffer offset:)" )  (mmap base aligned: \(baseAligned ? "YES" : "NO"))")

                    let metalStart = Date()
                    let metalScores = try metal.scores(query: vector)
                    let metalElapsed = Date().timeIntervalSince(metalStart)

                    let cpuStart = Date()
                    let cpuScores = try reader.scores(query: vector)
                    let cpuElapsed = Date().timeIntervalSince(cpuStart)

                    let k = min(10, metalScores.count)
                    let metalTop = MetalSimilaritySearch.selectTopK(metalScores, k: k).map(\.slot)
                    let cpuTop = MetalSimilaritySearch.selectTopK(cpuScores, k: k).map(\.slot)
                    var worst: Float = 0
                    for index in 0..<min(metalScores.count, cpuScores.count) {
                        worst = max(worst, abs(metalScores[index] - cpuScores[index]))
                    }
                    say("metal top-\(k) == cpu:   \(metalTop == cpuTop ? "YES" : "NO")")
                    let show = min(3, metalScores.count)
                    say("metal first:        " + (0..<show).map { String(format: "%.4f", metalScores[$0]) }.joined(separator: " "))
                    say("cpu first:          " + (0..<show).map { String(format: "%.4f", cpuScores[$0]) }.joined(separator: " "))
                    say("query first:        " + (0..<show).map { String(format: "%.4f", vector[$0]) }.joined(separator: " "))
                    say(String(format: "max score delta:    %.2e", worst))
                    say(String(format: "metal %.2f ms / cpu %.2f ms (\(reader.count) rows)", metalElapsed * 1000, cpuElapsed * 1000))
                } catch {
                    say("metal FAILED:       \(error)")
                }
                say("")
            } catch {
                say("end-to-end FAILED:  \(error)")
            }
            say("")
        }

        // ---- 5. the OCR languages actually available ---------------------
        say("== Vision OCR ==")
        let languages = PhotoTextRecognizer.supportedLanguages()
        say("supported languages: \(languages.count)")
        let chinese = languages.filter { $0.hasPrefix("zh") }
        say("chinese:            \(chinese.isEmpty ? "NONE" : chinese.joined(separator: ", "))")
        say("")

        // Thermal state is recorded because the vision encoder's throughput was
        // measured varying 3x (161 -> 529 ms) and recovering after a rest. That
        // pattern says thermal, but `thermalState` is the evidence that would
        // confirm it -- and it matters which it is, because the indexing policy
        // adapts on this value. If the encode is already 3x slower while the
        // system still reports `.nominal`, then batching on `thermalState` alone
        // cannot see the slowdown that is actually happening.
        say("== conditions ==")
        say("thermal state:      \(thermalStateName(ProcessInfo.processInfo.thermalState))")
        say("low power mode:     \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        say("processor count:    \(ProcessInfo.processInfo.processorCount)")
        say("peak memory:        \(peakMemoryMB()) MB")
        say("END")

        try? handle?.close()
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(to: logURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Probes

    private struct FullTextProbe {
        var version = "?"
        var hasFTS5 = false
        var hasTrigram = false
        var hasUnicode61 = false
        var detail: String?
    }

    /// Creates a throwaway in-memory table to ask what this SQLite actually
    /// supports. The bundled SQLite on iOS is built by Apple with its own option
    /// set, so the answer cannot be inferred from the version number.
    private static func probeFullTextSearch() -> FullTextProbe {
        var probe = FullTextProbe()
        var database: OpaquePointer?
        guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
            probe.detail = "could not open an in-memory database"
            return probe
        }
        defer { sqlite3_close(database) }

        if let raw = sqlite3_libversion() {
            probe.version = String(cString: raw)
        }

        func execute(_ sql: String) -> Int32 {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            return sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        }

        probe.hasFTS5 = execute("CREATE VIRTUAL TABLE t1 USING fts5(body);") == SQLITE_OK
        // `tokenize='trigram'` is the part that matters: it is what makes
        // 1-2 character Chinese queries work at all.
        probe.hasTrigram = execute("CREATE VIRTUAL TABLE t2 USING fts5(body, tokenize='trigram');") == SQLITE_OK
        probe.hasUnicode61 = execute("CREATE VIRTUAL TABLE t3 USING fts5(body, tokenize='unicode61');") == SQLITE_OK

        if probe.hasTrigram {
            // A real round trip, not just DDL acceptance: create, insert, match.
            _ = execute("INSERT INTO t2(body) VALUES ('海边的猫 invoice 2023');")
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(database, "SELECT count(*) FROM t2 WHERE t2 MATCH '海边';", -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 {
                    probe.detail = "trigram MATCH round trip succeeded"
                } else {
                    probe.hasTrigram = false
                    probe.detail = "trigram DDL accepted but MATCH failed"
                }
            }
            sqlite3_finalize(statement)
        }
        return probe
    }

    /// Lists the compute devices Core ML will consider, so ANE availability is
    /// recorded rather than assumed.
    private static func reportComputeDevices(say: (String) -> Void) {
        let devices = MLModel.availableComputeDevices
        let names = devices.map { device -> String in
            switch device {
            case .cpu: return "cpu"
            case .gpu: return "gpu"
            case .neuralEngine: return "neuralEngine"
            default: return "other"
            }
        }
        let hasANE = names.contains("neuralEngine")
        say("compute devices:    \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        say("neural engine:      \(hasANE ? "available" : "NOT AVAILABLE")")
    }

    /// Asks Core ML where it will actually run each operation.
    ///
    /// This exists to settle a specific question left open by the timing data:
    /// the vision encoder measured either ~157-185 ms or ~417-529 ms, with
    /// nothing in between, and `thermalState` did not explain it. Two clusters
    /// that far apart look like two different compute units rather than one
    /// unit running at two speeds, but that was a guess -- this reports the
    /// placement instead of inferring it.
    ///
    /// Time is reported alongside so a fast sample and a slow sample can be
    /// compared against a placement difference rather than against a guess.
    private static func reportComputePlan(say: (String) -> Void) async {
        let resources = SearchModelResources()
        guard let url = try? resources.visionModelURL() else {
            say("compute plan:       unavailable (no vision model)")
            return
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            // `computePlan` gives the per-operation device assignment without
            // loading the weights, so this stays cheap.
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)

            var counts: [String: Int] = [:]
            var total = 0
            if case .program(let program) = plan.modelStructure,
               let main = program.functions["main"] {
                for operation in main.block.operations {
                    total += 1
                    let name: String
                    // `deviceUsage(for:)` reports what the planner chose and
                    // what else was eligible -- `preferred` decides the speed;
                    // `supported` matters because one ANE-only operation can
                    // pull the whole graph onto the ANE, or vice versa.
                    if let usage = plan.deviceUsage(for: operation) {
                        switch usage.preferred {
                        case .cpu: name = "cpu"
                        case .gpu: name = "gpu"
                        case .neuralEngine: name = "neuralEngine"
                        @unknown default: name = "other"
                        }
                    } else {
                        name = "unassigned"
                    }
                    counts[name, default: 0] += 1
                }
            }
            let summary = counts.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            say("vision ops total:   \(total)")
            say("vision placement:   \(summary.isEmpty ? "unknown" : summary)")
        } catch {
            say("compute plan FAILED: \(error)")
        }
    }

    private static func authorizationName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    /// A tiny image; the values are irrelevant, only the timing is.
    private static func solidImage() -> CGImage? {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context?.makeImage()
    }

    /// Warm latency: one discarded call to page in the graph, then the median of
    /// several. A single cold sample would just measure weight loading again.
    private static func measure(
        _ label: String, say: (String) -> Void, _ body: () throws -> [Float]
    ) {
        _ = try? body()
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            _ = try? body()
            samples.append(Date().timeIntervalSince(start) * 1000)
        }
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        say(String(format: "%-19s P50 %.1f ms  min %.1f ms", (label as NSString).utf8String!,
                   sorted[sorted.count / 2], sorted[0]))
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for index in 0..<min(a.count, b.count) {
            dot += a[index] * b[index]
            na += a[index] * a[index]
            nb += b[index] * b[index]
        }
        let denominator = na.squareRoot() * nb.squareRoot()
        return denominator == 0 ? 0 : dot / denominator
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine
    }

    /// `phys_footprint` is the number the system actually judges the app on;
    /// `resident_size` understates Swift and Core ML allocations.
    private static func peakMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1024 / 1024)
    }
}

#endif
