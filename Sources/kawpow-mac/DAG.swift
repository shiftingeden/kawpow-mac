import Foundation
import Metal

// GPU-side DAG construction.
//
// Strategy:
//   1) Generate the light cache on CPU (~16 MB for epoch 0, ~93 MB for epoch 584).
//   2) Upload to a Metal buffer (storageModeShared so no copy on Apple Silicon).
//   3) Allocate the DAG buffer (~1 GB for epoch 0, ~5.6 GB for epoch 584).
//   4) Dispatch fill_dag_at_index in chunks (millions of items per chunk).
//   5) On full epoch 584 expect ~90s build, matching what thinminerpro takes.

struct DAGOutput {
    let cache: MTLBuffer            // 16 MB at epoch 0
    let dag: MTLBuffer              // 1 GB at epoch 0
    let cacheNumNodes: UInt32       // cache_size / 64
    let dagNumItems: UInt32         // dataset_size / 64
    let elapsed: TimeInterval       // total build time
}

enum DAGError: Error {
    case kernelLoadFailed(String)
    case bufferAllocFailed(String)
}

func buildDAG(device: MTLDevice, epoch: UInt64, dagBytesCap: UInt64? = nil) throws -> DAGOutput {
    let cacheBytes  = Ethash.cacheSize(epoch: epoch)
    var dagBytes    = Ethash.datasetSize(epoch: epoch)
    if let cap = dagBytesCap, dagBytes > cap {
        // Round cap down to a multiple of 64 (one DAG item)
        dagBytes = (cap / Ethash.HASH_BYTES) * Ethash.HASH_BYTES
    }
    let cacheNodes = UInt32(cacheBytes / Ethash.HASH_BYTES)
    let dagItems   = UInt32(dagBytes / Ethash.HASH_BYTES)
    print("[dag] epoch=\(epoch)  cache=\(cacheBytes) bytes (\(cacheNodes) nodes)  dag=\(dagBytes) bytes (\(dagItems) items)")

    // ─── 1) CPU light cache ────────────────────────────────────────────────
    let tCache = Date()
    print("[dag] building light cache on CPU…")
    let cacheBytesArray = Ethash.makeCache(epoch: epoch)
    print(String(format: "[dag] light cache done in %.1fs", Date().timeIntervalSince(tCache)))

    // ─── 2) Upload cache to Metal buffer (shared = zero-copy on Apple Silicon) ─
    guard let cacheBuf = device.makeBuffer(bytes: cacheBytesArray,
                                            length: cacheBytesArray.count,
                                            options: .storageModeShared) else {
        throw DAGError.bufferAllocFailed("light cache (\(cacheBytesArray.count) bytes)")
    }

    // ─── 3) Allocate DAG buffer ────────────────────────────────────────────
    guard let dagBuf = device.makeBuffer(length: Int(dagBytes), options: .storageModeShared) else {
        throw DAGError.bufferAllocFailed("DAG (\(dagBytes) bytes)")
    }
    memset(dagBuf.contents(), 0, Int(dagBytes))

    // ─── 4) Compile + create pipeline ──────────────────────────────────────
    guard let kernelURL = Bundle.module.url(forResource: "fill_dag", withExtension: "metal"),
          let src = try? String(contentsOf: kernelURL, encoding: .utf8) else {
        throw DAGError.kernelLoadFailed("Resources/fill_dag.metal not found in bundle")
    }
    let opts = MTLCompileOptions()
    opts.languageVersion = .version2_4
    let lib: MTLLibrary
    do {
        lib = try device.makeLibrary(source: src, options: opts)
    } catch {
        throw DAGError.kernelLoadFailed("compile error: \(error)")
    }
    guard let fn = lib.makeFunction(name: "fill_dag_at_index") else {
        throw DAGError.kernelLoadFailed("fill_dag_at_index not in library")
    }
    let pso = try device.makeComputePipelineState(function: fn)
    let queue = device.makeCommandQueue()!

    // ─── 5) Dispatch in chunks ─────────────────────────────────────────────
    let tFill = Date()
    let chunkItems: UInt32 = 1 << 20  // ~1M items per chunk
    var dagOffset: UInt32 = 0
    while dagOffset < dagItems {
        let thisChunk = min(chunkItems, dagItems - dagOffset)
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBuffer(cacheBuf, offset: 0, index: 0)
        enc.setBuffer(dagBuf,   offset: 0, index: 1)
        var dagNumItemsLocal = dagItems
        var cacheNumNodesLocal = cacheNodes
        var offsetLocal = dagOffset
        enc.setBytes(&dagNumItemsLocal,   length: 4, index: 2)
        enc.setBytes(&cacheNumNodesLocal, length: 4, index: 3)
        enc.setBytes(&offsetLocal,        length: 4, index: 4)

        let tgWidth = min(pso.maxTotalThreadsPerThreadgroup, 256)
        let groups = (Int(thisChunk) + tgWidth - 1) / tgWidth
        enc.dispatchThreadgroups(
            MTLSize(width: groups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgWidth, height: 1, depth: 1)
        )
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error {
            print("[dag] command buffer error at offset \(dagOffset): \(e)")
            throw DAGError.kernelLoadFailed("dispatch failed: \(e)")
        }
        dagOffset += thisChunk
        if dagOffset % (chunkItems * 8) == 0 || dagOffset >= dagItems {
            let pct = Double(dagOffset) / Double(dagItems) * 100
            print(String(format: "[dag] %u / %u items (%.1f%%)", dagOffset, dagItems, pct))
        }
    }
    let fillTime = Date().timeIntervalSince(tFill)
    print(String(format: "[dag] GPU fill done in %.1fs", fillTime))

    return DAGOutput(
        cache: cacheBuf,
        dag: dagBuf,
        cacheNumNodes: cacheNodes,
        dagNumItems: dagItems,
        elapsed: fillTime + Date().timeIntervalSince(tCache)
    )
}
