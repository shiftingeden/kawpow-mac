import Foundation

import Metal

setbuf(stdout, nil) // unbuffered output so logs flush in real time

runSelfTests()
_ = keccak800CrossCheck()

// CLI: `kawpow-mac dag-crosscheck` — build a small DAG via the Metal kernel,
// then compute the same items on CPU via calcDatasetItemCPU and compare.
if CommandLine.arguments.contains("dag-crosscheck") {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no device"); exit(1) }
    print("[dag-crosscheck] device=\(device.name) — building epoch 0 DAG capped at 16 MB")
    // 16 MB / 64 = 262144 items — enough variation to catch bugs
    let out = try buildDAG(device: device, epoch: 0, dagBytesCap: 16 * 1024 * 1024)
    let cachePtr = out.cache.contents().assumingMemoryBound(to: UInt8.self)
    let dagPtr = out.dag.contents().assumingMemoryBound(to: UInt32.self)
    let indicesToCheck: [UInt32] = [0, 1, 7, 100, 1_000, 50_000, out.dagNumItems - 1]
    var allMatch = true
    for idx in indicesToCheck {
        let cpu = calcDatasetItemCPU(cache: cachePtr, cacheNumNodes: out.cacheNumNodes, index: idx)
        var gpu = [UInt32](repeating: 0, count: 16)
        for k in 0..<16 { gpu[k] = dagPtr[Int(idx) * 16 + k] }
        let ok = cpu == gpu
        let cpuHex = cpu.prefix(4).map { String(format: "%08x", $0) }.joined(separator: " ")
        let gpuHex = gpu.prefix(4).map { String(format: "%08x", $0) }.joined(separator: " ")
        print("[dag-crosscheck] idx=\(idx) \(ok ? "✓" : "✗")  cpu[0..4]=\(cpuHex)  gpu[0..4]=\(gpuHex)")
        if !ok {
            allMatch = false
            for k in 0..<16 where cpu[k] != gpu[k] {
                print("[dag-crosscheck]   word[\(k)] cpu=\(String(format: "%08x", cpu[k])) gpu=\(String(format: "%08x", gpu[k]))")
            }
        }
    }
    print(allMatch ? "[dag-crosscheck] ALL ITEMS MATCH ✓" : "[dag-crosscheck] DIVERGENCE — fill_dag.metal disagrees with CPU spec")
    exit(allMatch ? 0 : 2)
}

// CLI: `kawpow-mac kernel-vs-cpu` — runs the Metal search kernel and CPU
// progpowHashLight on the SAME input and compares mix_hash word-by-word.
// Uses a tiny synthetic epoch-0 DAG (already verified item-by-item via
// dag-crosscheck) so the only remaining variable is the inner-loop /
// fill_mix / aggregation logic. Disagreement = the algorithmic bug.
// CLI: `kawpow-mac verify-vectors` — runs the Ravencoin official ProgPoW
// test vectors (src/crypto/ethash/progpow_test_vectors.hpp). Each is a
// (block_number, header, nonce) → (expected_mix, expected_final). If our
// CPU light-eval matches the expected mix_hash, our algorithm is spec-
// compliant. If not, the diff tells us where we drifted.
if CommandLine.arguments.contains("verify-vectors") {
    struct TV { let block: UInt64; let header: String; let nonce: String; let mix: String; let final: String }
    let vectors: [TV] = [
        TV(block: 0,
           header: "0000000000000000000000000000000000000000000000000000000000000000",
           nonce: "0000000000000000",
           mix: "6e97b47b134fda0c7888802988e1a373affeb28bcd813b6e9a0fc669c935d03a",
           final: "e601a7257a70dc48fccc97a7330d704d776047623b92883d77111fb36870f3d1"),
        TV(block: 49,
           header: "63155f732f2bf556967f906155b510c917e48e99685ead76ea83f4eca03ab12b",
           nonce: "0000000007073c07",
           mix: "d36f7e815ee09e74eceb9c96993a3d681edf2bf0921fc7bb710364042db99777",
           final: "e7ced124598fd2500a55ad9f9f48e3569327fe50493c77a4ac9799b96efb9463"),
    ]
    func unhex(_ s: String) -> [UInt8] {
        let chars = Array(s); var out: [UInt8] = []; var i = 0
        while i + 1 < chars.count {
            out.append(UInt8(Int(String(chars[i]), radix: 16)! * 16 + Int(String(chars[i+1]), radix: 16)!))
            i += 2
        }
        return out
    }
    var lastEpoch: UInt64 = .max
    var cacheBytes: [UInt8] = []
    var cacheNumNodes: UInt32 = 0
    for v in vectors {
        let epoch = v.block / Ethash.KAWPOW_EPOCH_LENGTH
        if epoch != lastEpoch {
            print("[verify] building epoch \(epoch) cache…")
            cacheBytes = Ethash.makeCache(epoch: epoch)
            cacheNumNodes = UInt32(Ethash.cacheSize(epoch: epoch) / Ethash.HASH_BYTES)
            lastEpoch = epoch
        }
        let header = unhex(v.header)
        let nonceBytes = unhex(v.nonce)
        var nonce: UInt64 = 0
        for b in nonceBytes { nonce = (nonce << 8) | UInt64(b) }
        let progSeed = v.block / UInt64(KawPow.KAWPOW_PERIOD)
        let dsItems = UInt32(Ethash.datasetSize(epoch: epoch) / Ethash.HASH_BYTES)
        let result = cacheBytes.withUnsafeBufferPointer { ptr in
            progpowHashLight(
                headerHash: header, nonce: nonce, progSeed: progSeed,
                cache: ptr.baseAddress!, cacheNumNodes: cacheNumNodes,
                datasetNumItems: dsItems
            )
        }
        let mixHex = result.mixHash.map { String(format: "%02x", $0) }.joined()
        let finHex = result.finalHash.map { String(format: "%02x", $0) }.joined()
        let mixOK = mixHex == v.mix
        let finOK = finHex == v.final
        print("[verify] block=\(v.block) epoch=\(epoch) progSeed=\(progSeed)")
        print("[verify]   mix    expected: \(v.mix)")
        print("[verify]   mix    ours:     \(mixHex)  \(mixOK ? "✓" : "✗")")
        print("[verify]   final  expected: \(v.final)")
        print("[verify]   final  ours:     \(finHex)  \(finOK ? "✓" : "✗")")
    }
    exit(0)
}

// CLI: `kawpow-mac dump-ops <progSeed>` — emit our generated RANDOM_MATH +
// DATA_LOADS source for the given prog_seed. Used to diff against the
// canonical kawpowminer reference (test/kernel.cu).
if let idx = CommandLine.arguments.firstIndex(of: "dump-ops"),
   idx + 1 < CommandLine.arguments.count,
   let seed = UInt64(CommandLine.arguments[idx + 1]) {
    let gen = generateKernelSource(progSeed: seed)
    print("=== RANDOM_MATH(prog_seed=\(seed)) ===")
    print(gen.randomMath)
    print("=== DATA_LOADS(prog_seed=\(seed)) ===")
    print(gen.dataLoads)
    exit(0)
}

if CommandLine.arguments.contains("kernel-vs-cpu") {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no device"); exit(1) }
    print("[k-vs-c] device=\(device.name)")

    let epoch: UInt64 = 0
    let progSeed: UInt64 = 0
    // Cap DAG at 32 MB so it fits comfortably; we'll mod nonces to stay in range.
    let dagOut = try buildDAG(device: device, epoch: epoch, dagBytesCap: 32 * 1024 * 1024)
    let datasetNumItems = dagOut.dagNumItems

    // Fixed header + nonce so the test is reproducible.
    let header: [UInt8] = (0..<32).map { UInt8($0 + 1) }
    let nonce: UInt64 = 0xdeadbeef

    // ─── 1) CPU light-eval ────────────────────────────────────────────
    let cachePtr = dagOut.cache.contents().assumingMemoryBound(to: UInt8.self)
    let t0 = Date()
    let cpu = progpowHashLight(
        headerHash: header,
        nonce: nonce,
        progSeed: progSeed,
        cache: cachePtr,
        cacheNumNodes: dagOut.cacheNumNodes,
        datasetNumItems: datasetNumItems
    )
    print(String(format: "[k-vs-c] CPU computed in %.2fs", Date().timeIntervalSince(t0)))
    print("[k-vs-c] CPU mix u32:   " + cpu.mixUint32.map { String(format: "%08x", $0) }.joined(separator: " "))
    print("[k-vs-c] CPU final u32: " + cpu.finalUint32.map { String(format: "%08x", $0) }.joined(separator: " "))

    // ─── 2) Metal kernel — same input, forced target = max (always submits) ─
    var src = try String(contentsOf: Bundle.module.url(forResource: "kernel_template", withExtension: "metal")!, encoding: .utf8)
    src = src.replacingOccurrences(of: "TARGET_REPLACE", with: "0xFFFFFFFFFFFFFFFFUL;")
    src = src.replacingOccurrences(of: "PROGPOW_DAG_ELEMENTS_REPLACE", with: "\(datasetNumItems / 4)UL;")
    let gen = generateKernelSource(progSeed: progSeed)
    src = src.replacingOccurrences(of: "INCLUDE_PROGPOW_RANDOM_MATH", with: gen.randomMath)
    src = src.replacingOccurrences(of: "INCLUDE_PROGPOW_DATA_LOADS",  with: gen.dataLoads)
    let opts = MTLCompileOptions(); opts.languageVersion = .version2_4
    let lib = try device.makeLibrary(source: src, options: opts)
    let pso = try device.makeComputePipelineState(function: lib.makeFunction(name: "search")!)
    let queue = device.makeCommandQueue()!

    // job_blob = 8 header words + 0 + 0 (padding the kernel overwrites)
    let jobBlobBuf = device.makeBuffer(length: 40, options: .storageModeShared)!
    let jbPtr = jobBlobBuf.contents().assumingMemoryBound(to: UInt32.self)
    for i in 0..<8 {
        let off = i * 4
        jbPtr[i] =  UInt32(header[off]) |
                    UInt32(header[off + 1]) << 8 |
                    UInt32(header[off + 2]) << 16 |
                    UInt32(header[off + 3]) << 24
    }
    jbPtr[8] = 0
    jbPtr[9] = UInt32(truncatingIfNeeded: nonce >> 32)
    let resultsBuf = device.makeBuffer(length: 64 * 4, options: .storageModeShared)!
    memset(resultsBuf.contents(), 0, 64 * 4)
    let resultsIdxBuf = device.makeBuffer(length: 4, options: .storageModeShared)!
    memset(resultsIdxBuf.contents(), 0, 4)
    let stopBuf = device.makeBuffer(length: 4, options: .storageModeShared)!
    memset(stopBuf.contents(), 0, 4)
    // baseNonce = nonce.low32 - (lid_in_group); we want gid==nonce for laneId==0
    // The kernel sets gid = baseNonce + nonceOffset. To hit gid=nonce.low for
    // the broadcast lane we want, set baseNonce = nonce.low and dispatch 16
    // threads (one full group) — within that group lane 0 gets gid=nonce.low.
    var baseNonce = UInt32(truncatingIfNeeded: nonce)
    let baseNonceBuf = device.makeBuffer(bytes: &baseNonce, length: 4, options: .storageModeShared)!
    let dBuf  = device.makeBuffer(length: 32, options: .storageModeShared)!
    let jbBuf = device.makeBuffer(length: 32, options: .storageModeShared)!

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(dagOut.dag, offset: 0, index: 0)
    enc.setBuffer(jobBlobBuf, offset: 0, index: 1)
    enc.setBuffer(resultsBuf, offset: 0, index: 2)
    enc.setBuffer(resultsIdxBuf, offset: 0, index: 3)
    enc.setBuffer(stopBuf, offset: 0, index: 4)
    enc.setBuffer(baseNonceBuf, offset: 0, index: 5)
    enc.setBuffer(dBuf, offset: 0, index: 6)
    enc.setBuffer(jbBuf, offset: 0, index: 7)
    // One full threadgroup of 256 threads = 16 groups × 16 lanes
    enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    if let e = cb.error { print("[k-vs-c] dispatch err: \(e)"); exit(2) }

    let r = resultsBuf.contents().assumingMemoryBound(to: UInt32.self)
    let kernelGid = r[0]
    let kernelMixU32 = (1...8).map { r[$0] }
    print("[k-vs-c] Kernel won-nonce gid: 0x\(String(format: "%08x", kernelGid))")
    print("[k-vs-c] Kernel mix u32: " + kernelMixU32.map { String(format: "%08x", $0) }.joined(separator: " "))

    // For meaningful comparison the kernel-reported share must be for the
    // SAME nonce we just asked the CPU to evaluate. With baseNonce = nonce.low
    // and atomic-guarded results writes, the winning lane is whichever found
    // result <= target FIRST inside the dispatch — that's some lane in the
    // group, not necessarily lane 0. Compare CPU output for the nonce the
    // kernel actually reports.
    if UInt64(kernelGid) != nonce & 0xFFFFFFFF {
        print("[k-vs-c] kernel reported gid=\(String(format: "0x%llx", UInt64(kernelGid))); recomputing CPU for that nonce…")
        let recomputed = progpowHashLight(
            headerHash: header,
            nonce: UInt64(kernelGid) | (nonce & 0xFFFFFFFF00000000),
            progSeed: progSeed,
            cache: cachePtr,
            cacheNumNodes: dagOut.cacheNumNodes,
            datasetNumItems: datasetNumItems
        )
        let agree = recomputed.mixUint32 == kernelMixU32
        print("[k-vs-c] Recomputed CPU mix u32: " + recomputed.mixUint32.map { String(format: "%08x", $0) }.joined(separator: " "))
        print(agree ? "[k-vs-c] ✓ AGREE — CPU and kernel produce the same mix_hash" : "[k-vs-c] ✗ DISAGREE — bisect from here")
        exit(agree ? 0 : 3)
    } else {
        let agree = cpu.mixUint32 == kernelMixU32
        print(agree ? "[k-vs-c] ✓ AGREE — CPU and kernel produce the same mix_hash" : "[k-vs-c] ✗ DISAGREE — bisect from here")
        exit(agree ? 0 : 3)
    }
}

// CLI: `kawpow-mac dag-test [epoch] [dagBytesCap]`
// Builds the DAG to verify M4 end-to-end without entering the mining loop.
let args = CommandLine.arguments
if args.count >= 2 && args[1] == "dag-test" {
    let epoch = args.count >= 3 ? UInt64(args[2]) ?? 0 : 0
    // Default: cap DAG at 256 MB so a quick test fits in any Mac's RAM.
    let cap   = args.count >= 4 ? UInt64(args[3]) : 256 * 1024 * 1024
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("no Metal device"); exit(1)
    }
    print("[dag-test] device=\(device.name) epoch=\(epoch) dagBytesCap=\(cap)")
    do {
        let out = try buildDAG(device: device, epoch: epoch, dagBytesCap: cap)
        // Print first DAG item so a future test can compare against a reference value
        let dagPtr = out.dag.contents().assumingMemoryBound(to: UInt32.self)
        var dump = ""
        for k in 0..<16 { dump += String(format: "%08x ", dagPtr[k]) }
        print("[dag-test] DAG[0] = \(dump)")
        // Also DAG[1] and DAG[100] for confidence
        dump = ""
        for k in 0..<16 { dump += String(format: "%08x ", dagPtr[16 + k]) }
        print("[dag-test] DAG[1] = \(dump)")
        if out.dagNumItems > 100 {
            dump = ""
            for k in 0..<16 { dump += String(format: "%08x ", dagPtr[100*16 + k]) }
            print("[dag-test] DAG[100] = \(dump)")
        }
        print(String(format: "[dag-test] total time: %.2fs", out.elapsed))
    } catch {
        print("[dag-test] FAILED: \(error)")
        exit(2)
    }
    exit(0)
}

// Milestone 2: + target conversion + submit-harness.
// On the first job, we (a) compute the kernel target and print it, and (b) send a
// deliberately invalid mining.submit so the pool tells us whether our wire format is good.

// Load config.json from CWD when present (this is how Unmineable-Mac launches us).
// Fall back to dev-mode defaults if no config.json is found.
let cfg = ConfigLoader.loadFromCWD()
let host: String      = cfg?.host ?? "kp.unmineable.com"
let port: UInt16      = cfg?.port ?? 3333
let workerUser: String = cfg?.user ?? "LTC:ltc1qw7ffr4hjqytukym0yvkrnsgxharjqs86z3c9wh.M5dev"
print("[kawpow-mac] host=\(host) port=\(port) user=\(workerUser)\(cfg == nil ? "  (no config.json — using dev defaults)" : "")")

let client = StratumClient(host: host, port: port)
guard let miner = Miner() else { print("no Metal device"); exit(1) }
// Throttle submits to avoid flooding the pool when running with
// KAWPOW_FORCED_TARGET (where shares appear faster than once per second).
var lastSubmitAt = Date(timeIntervalSince1970: 0)
let submitMinInterval: TimeInterval = 0.5
miner.onShare = { jobId, nonce, header, mix in
    let now = Date()
    if now.timeIntervalSince(lastSubmitAt) < submitMinInterval {
        print("[main] (throttled — last submit \(String(format: "%.2f", now.timeIntervalSince(lastSubmitAt)))s ago)")
        return
    }
    lastSubmitAt = now
    print("[main] submitting share jobId=\(jobId) nonce=\(nonce)")
    client.submitShare(workerName: workerUser, jobId: jobId, nonce: nonce, headerHash: header, mixHash: mix)
}
miner.startMiningLoop()

client.onConnected = {
    client.subscribe()
    client.authorize(user: workerUser)
}

client.onSetTarget = { target in
    let kt = Target.kernelTargetFromPoolTarget(target)
    print("[main] new share target: \(target)")
    print("[main]   → kernel uint64 = 0x\(String(kt, radix: 16, uppercase: false))")
}

client.onSetDifficulty = { d in
    print("[main] new difficulty: \(d)")
}

client.onNotify = { jobId, headerHash, seedHash, shareTarget, cleanJobs, blockHeight, bits in
    print("[main] JOB jobId=\(jobId) height=\(blockHeight) cleanJobs=\(cleanJobs)")
    let job = MiningJob(
        jobId: jobId,
        headerHashHex: headerHash,
        seedHashHex: seedHash,
        shareTargetHex: shareTarget,
        blockHeight: blockHeight,
        cleanJobs: cleanJobs
    )
    miner.updateJob(job)
}

client.onError = { err in
    print("[main] stratum error: \(err)")
}

client.connect()

RunLoop.main.run()
