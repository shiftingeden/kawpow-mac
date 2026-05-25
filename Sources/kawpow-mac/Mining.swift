import Foundation
import Metal

// Mining loop. Owns the DAG for the current epoch and the per-epoch search pipeline.
// On a new stratum job: re-target, possibly rebuild DAG, recompile kernel.
// Dispatch loop: increment baseNonce by GRID_SIZE per batch, read results, submit any found.

struct MiningJob {
    let jobId: String
    let headerHashHex: String   // 64 hex chars
    let seedHashHex: String
    let shareTargetHex: String  // 64 hex chars
    let blockHeight: UInt64
    let cleanJobs: Bool
}

final class Miner {
    // Tunables
    private let GROUP_SIZE: UInt32 = 256
    private let BATCH_GROUPS: UInt32 = 4096   // 4096 * 256 = ~1M nonces per dispatch
    private var batchNonces: UInt32 { BATCH_GROUPS * GROUP_SIZE }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let dispatchQueue = DispatchQueue(label: "miner.dispatch")

    // Job state
    private var currentJob: MiningJob?
    private var jobLock = NSLock()

    // Epoch-scoped resources (rebuilt when epoch changes)
    private var currentEpoch: UInt64 = .max
    private var dagOut: DAGOutput?
    private var searchPSO: MTLComputePipelineState?
    private var lastTargetUInt64: UInt64 = 0
    private var lastDagElements: UInt32 = 0

    // Seed→epoch lookup cache (seed_hash_hex → epoch). The first time we see a
    // seed we walk keccak256 from zeros to find which iteration produces it
    // (≈1-2s for epoch ~800). Subsequent jobs with the same seed are O(1).
    private var seedEpochCache: [String: UInt64] = [:]

    // PSO cache keyed by prog_seed. Per-epoch the only thing that changes
    // between jobs is prog_seed (= blockHeight / KAWPOW_PERIOD) and that
    // bumps every ~3 jobs. Caching avoids re-compiling Metal source we
    // already have a pipeline for. Cleared on epoch change since target
    // and dagElements are baked into the compiled kernel.
    private var psoCache: [UInt64: MTLComputePipelineState] = [:]

    // Buffers re-used across dispatches
    private var jobBlobBuf: MTLBuffer?     // 10 uints
    private var resultsBuf: MTLBuffer?     // 64 uints
    private var resultsIdxBuf: MTLBuffer?  // 1 atomic uint
    private var stopBuf: MTLBuffer?        // 1 uint
    private var baseNonceBuf: MTLBuffer?   // 1 uint
    private var dBuf: MTLBuffer?           // 32 uchars (unused but expected by kernel)
    private var jbBuf: MTLBuffer?          // 32 uchars (ditto)

    // Counters
    private var baseNonce: UInt64 = 0
    private var hashesSinceTick: UInt64 = 0
    private var lastTick = Date()
    private var stopFlag = false

    // Stratum extranonce — used to seed the high bits of nonce space.
    var extranonce1: UInt32 = 0

    // Callback to submit a found share
    var onShare: ((_ jobId: String, _ nonceHex: String, _ headerHashHex: String, _ mixHashHex: String) -> Void)?

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.queue = q
    }

    // MARK: - Job switching

    func updateJob(_ job: MiningJob) {
        jobLock.lock()
        defer { jobLock.unlock() }
        currentJob = job

        // The pool's authoritative epoch comes from its seed hash, not the
        // height field (which on ethash.unmineable.com is a pool-internal
        // counter, not the on-chain block number we'd expect).
        let epoch: UInt64
        if let cached = seedEpochCache[job.seedHashHex] {
            epoch = cached
        } else if !job.seedHashHex.isEmpty,
                  case let seedBytes = hexToBytes(job.seedHashHex),
                  seedBytes.count == 32,
                  let derived = Ethash.epochFromSeed(seedBytes, maxSearch: 2000) {
            epoch = derived
            seedEpochCache[job.seedHashHex] = derived
            print("[miner] seed-derived epoch=\(epoch) (pool's height field was \(job.blockHeight))")
        } else {
            epoch = Ethash.epoch(forBlockHeight: job.blockHeight)
            print("[miner] could not recover epoch from seed within 2000; fallback height/epoch_length = \(epoch)")
        }

        if epoch != currentEpoch {
            let dagBytes = Ethash.datasetSize(epoch: epoch)
            // Soft cap: refuse DAGs that won't fit comfortably on a 16 GB Mac.
            // 10 GB allows epoch ~870 ethash DAG (~7.9 GB) plus other allocations.
            print("[miner] epoch change: \(currentEpoch) → \(epoch); DAG = \(dagBytes) bytes (\(String(format: "%.2f", Double(dagBytes) / 1_073_741_824)) GB)")
            if dagBytes > 10 * 1024 * 1024 * 1024 {
                print("[miner] ABORT: DAG > 10 GB — won't fit. Pool likely mines a chain too big for this machine.")
                dagOut = nil
                return
            }
            currentEpoch = epoch
            psoCache.removeAll(keepingCapacity: false)  // PSO bakes in dagElements
            do {
                dagOut = try buildDAG(device: device, epoch: epoch, dagBytesCap: nil)
            } catch {
                print("[miner] DAG build failed: \(error)")
                dagOut = nil
                return
            }
        }
        guard let dag = dagOut else { return }
        // PROGPOW_DAG_ELEMENTS = DAG_BYTES / (PROGPOW_LANES * sizeof(dag_t))
        //                      = DAG_BYTES / (16 * 16)
        //                      = DAG_BYTES / 256
        // and DAG_BYTES = dagNumItems * 64, so dagElements = dagNumItems / 4.
        // (Previously divided by 16 here, which caused the kernel to address only
        // the first 1/4 of the DAG — so our hashes used the wrong DAG values and
        // every share came back "Invalid share" from the pool.)
        let dagElements = dag.dagNumItems / 4
        lastDagElements = dagElements
        // Debug-only override: if KAWPOW_FORCED_TARGET is set in the environment
        // (hex, with or without "0x"), use that uint64 as the kernel-side
        // share-difficulty target. The pool will reject everything as
        // "Low difficulty share" — that's the point: we just want fast
        // pool-response signal to verify our submit wire format and the
        // mix_hash matching path.
        let envOverride = ProcessInfo.processInfo.environment["KAWPOW_FORCED_TARGET"].flatMap { raw -> UInt64? in
            let s = raw.lowercased().hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
            return UInt64(s, radix: 16)
        }
        let newTarget = envOverride ?? Target.kernelTargetFromPoolTarget(job.shareTargetHex)
        if envOverride != nil && lastTargetUInt64 == 0 {
            print("[miner] DEBUG: forcing kernel target to 0x\(String(newTarget, radix: 16)) (KAWPOW_FORCED_TARGET) — pool will reject all shares")
        }
        if newTarget != lastTargetUInt64 && lastTargetUInt64 != 0 {
            // Target bakes into the kernel — invalidate cache on change.
            print("[miner] target changed 0x\(String(lastTargetUInt64, radix: 16)) → 0x\(String(newTarget, radix: 16)); flushing PSO cache")
            psoCache.removeAll(keepingCapacity: true)
        }
        lastTargetUInt64 = newTarget

        let progSeed = KawPow.progSeed(forBlockHeight: job.blockHeight)
        if let cached = psoCache[progSeed] {
            searchPSO = cached
        } else {
            do {
                let pso = try compileSearchKernel(
                    progSeed: progSeed,
                    target: lastTargetUInt64,
                    dagElements: dagElements
                )
                psoCache[progSeed] = pso
                searchPSO = pso
                print("[miner] kernel compiled for prog_seed=\(progSeed) targetUL=0x\(String(lastTargetUInt64, radix: 16)) dagElements=\(dagElements) (cache size \(psoCache.count))")
            } catch {
                print("[miner] kernel compile failed: \(error)")
                searchPSO = nil
            }
        }
        allocBuffersIfNeeded()
        loadJobBlob(headerHashHex: job.headerHashHex)
        // Reset nonce space at the start of each new clean job.
        if job.cleanJobs { baseNonce = UInt64(extranonce1) << 32 }
    }

    // MARK: - Buffers + job blob

    private func allocBuffersIfNeeded() {
        if jobBlobBuf  == nil { jobBlobBuf  = device.makeBuffer(length: 10 * 4, options: .storageModeShared) }
        if resultsBuf  == nil { resultsBuf  = device.makeBuffer(length: 64 * 4, options: .storageModeShared) }
        if resultsIdxBuf == nil { resultsIdxBuf = device.makeBuffer(length: 4, options: .storageModeShared) }
        if stopBuf     == nil { stopBuf     = device.makeBuffer(length: 4, options: .storageModeShared) }
        if baseNonceBuf == nil { baseNonceBuf = device.makeBuffer(length: 4, options: .storageModeShared) }
        if dBuf        == nil { dBuf        = device.makeBuffer(length: 32, options: .storageModeShared) }
        if jbBuf       == nil { jbBuf       = device.makeBuffer(length: 32, options: .storageModeShared) }
    }

    private func loadJobBlob(headerHashHex: String) {
        // The kernel's "job_blob" is the keccak_f800 input — header hash bytes as 8 uints,
        // plus 2 padding uints (the kernel writes gid into state_a[8] itself).
        guard let buf = jobBlobBuf else { return }
        let bytes = hexToBytes(headerHashHex)
        precondition(bytes.count >= 32, "header hash hex too short: \(headerHashHex)")
        let p = buf.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<8 {
            let off = i * 4
            let w =  UInt32(bytes[off + 0])
                  | UInt32(bytes[off + 1]) << 8
                  | UInt32(bytes[off + 2]) << 16
                  | UInt32(bytes[off + 3]) << 24
            p[i] = w
        }
        p[8] = 0  // overwritten with gid per-thread
        p[9] = 0
    }

    // MARK: - Per-epoch kernel compile

    private func compileSearchKernel(progSeed: UInt64, target: UInt64, dagElements: UInt32) throws -> MTLComputePipelineState {
        guard let url = Bundle.module.url(forResource: "kernel_template", withExtension: "metal"),
              var src = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "miner", code: 1, userInfo: [NSLocalizedDescriptionKey: "kernel_template.metal missing from bundle"])
        }
        src = src.replacingOccurrences(of: "TARGET_REPLACE",
                                       with: String(format: "0x%016llxUL;", target))
        src = src.replacingOccurrences(of: "PROGPOW_DAG_ELEMENTS_REPLACE",
                                       with: "\(dagElements)UL;")
        let gen = generateKernelSource(progSeed: progSeed)
        src = src.replacingOccurrences(of: "INCLUDE_PROGPOW_RANDOM_MATH", with: gen.randomMath)
        src = src.replacingOccurrences(of: "INCLUDE_PROGPOW_DATA_LOADS",  with: gen.dataLoads)

        let opts = MTLCompileOptions()
        opts.languageVersion = .version2_4
        let lib = try device.makeLibrary(source: src, options: opts)
        guard let fn = lib.makeFunction(name: "search") else {
            throw NSError(domain: "miner", code: 2, userInfo: [NSLocalizedDescriptionKey: "search function missing"])
        }
        return try device.makeComputePipelineState(function: fn)
    }

    // MARK: - Mining loop

    func startMiningLoop() {
        dispatchQueue.async { [weak self] in
            self?.mineLoop()
        }
    }

    func stop() { stopFlag = true }

    private func mineLoop() {
        while !stopFlag {
            jobLock.lock()
            let job = currentJob
            let pso = searchPSO
            let dag = dagOut
            jobLock.unlock()

            guard let job, let pso, let dag else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            dispatchOneBatch(job: job, pso: pso, dag: dag)
        }
    }

    private func dispatchOneBatch(job: MiningJob, pso: MTLComputePipelineState, dag: DAGOutput) {
        guard let resultsBuf, let stopBuf, let baseNonceBuf, let jobBlobBuf,
              let dBuf, let jbBuf, let resultsIdxBuf else { return }
        // Zero results + stop
        memset(resultsBuf.contents(), 0, 64 * 4)
        memset(stopBuf.contents(), 0, 4)
        memset(resultsIdxBuf.contents(), 0, 4)

        // Take the low 32 bits of baseNonce for the kernel; the high 32 bits we set per dispatch
        // by also mixing them into the header (via state_a[8]=gid the kernel mixes the low 32).
        let baseLow = UInt32(baseNonce & 0xFFFFFFFF)
        baseNonceBuf.contents().assumingMemoryBound(to: UInt32.self).pointee = baseLow

        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBuffer(dag.dag, offset: 0, index: 0)
        enc.setBuffer(jobBlobBuf, offset: 0, index: 1)
        enc.setBuffer(resultsBuf, offset: 0, index: 2)
        enc.setBuffer(resultsIdxBuf, offset: 0, index: 3)
        enc.setBuffer(stopBuf, offset: 0, index: 4)
        enc.setBuffer(baseNonceBuf, offset: 0, index: 5)
        enc.setBuffer(dBuf, offset: 0, index: 6)
        enc.setBuffer(jbBuf, offset: 0, index: 7)

        let tg = MTLSize(width: Int(GROUP_SIZE), height: 1, depth: 1)
        let grid = MTLSize(width: Int(BATCH_GROUPS), height: 1, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()

        // Emit thinminerpro-compatible batch line so Unmineable-Mac's frontend
        // hashrate parser (client/src/util/mining.js) picks up the GPU rate.
        // Format: "Computing <N> nonces starting at <X> <YYYY-MM-DD HH:MM:SS> +0000"
        let tsFmt = DateFormatter()
        tsFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        tsFmt.timeZone = TimeZone(identifier: "UTC")
        print("Computing \(batchNonces) nonces starting at \(baseNonce) \(tsFmt.string(from: Date())) +0000")

        let t0 = Date()
        cb.commit()
        cb.waitUntilCompleted()
        let dt = Date().timeIntervalSince(t0)

        if let e = cb.error {
            print("[miner] dispatch error: \(e)")
            return
        }

        hashesSinceTick += UInt64(batchNonces)
        baseNonce &+= UInt64(batchNonces)

        // Inspect results
        let r = resultsBuf.contents().assumingMemoryBound(to: UInt32.self)
        let stop = stopBuf.contents().assumingMemoryBound(to: UInt32.self).pointee
        if stop > 0 {
            // Found a share!
            let nonce32 = r[0]
            // Reconstruct the full 64-bit nonce: high32 = (baseNonce >> 32), low32 = nonce32
            let fullNonce = (baseNonce & 0xFFFFFFFF00000000) | UInt64(nonce32)
            // Submit mix_hash with bytes per-uint32 in LITTLE-endian order — KawPow's
            // standard wire format on most pools matches the in-memory layout where
            // each uint32 word is laid out LSB-first. (We previously tried BE here;
            // every submit came back "Invalid share" on ethash.unmineable.com.)
            var mixBytes = [UInt8](repeating: 0, count: 32)
            for i in 0..<8 {
                let w = r[1 + i]
                mixBytes[i*4 + 0] = UInt8(w & 0xFF)
                mixBytes[i*4 + 1] = UInt8((w >> 8) & 0xFF)
                mixBytes[i*4 + 2] = UInt8((w >> 16) & 0xFF)
                mixBytes[i*4 + 3] = UInt8((w >> 24) & 0xFF)
            }
            let mixHex = mixBytes.map { String(format: "%02x", $0) }.joined()
            let nonceHex = String(format: "%016llx", fullNonce)
            // Also log the raw kernel uint32s for postmortem diagnosis if pool keeps rejecting.
            let rawU32 = (0..<9).map { String(format: "%08x", r[$0]) }.joined(separator: " ")
            print("[miner] *** SHARE FOUND *** nonce=\(nonceHex) mix=\(mixHex)")
            print("[miner]     raw kernel results[0..8]: \(rawU32)")
            onShare?(job.jobId, "0x" + nonceHex, "0x" + job.headerHashHex, "0x" + mixHex)
        }

        // Hashrate tick
        let elapsed = Date().timeIntervalSince(lastTick)
        if elapsed > 5 {
            let rate = Double(hashesSinceTick) / elapsed / 1_000_000
            print(String(format: "[miner] %.2f MH/s  baseNonce=0x%016llx  lastBatch=%.3fs",
                         rate, baseNonce, dt))
            hashesSinceTick = 0
            lastTick = Date()
        }
    }
}

// Helpers
fileprivate func hexToBytes(_ s: String) -> [UInt8] {
    var s = s
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    let chars = Array(s)
    var out = [UInt8](); out.reserveCapacity(chars.count / 2)
    var i = 0
    while i + 1 < chars.count {
        let hi = Int(String(chars[i]), radix: 16) ?? 0
        let lo = Int(String(chars[i+1]), radix: 16) ?? 0
        out.append(UInt8(hi * 16 + lo))
        i += 2
    }
    return out
}
