import Foundation

// CPU ("light") evaluation of KawPow progpow_hash. Mirrors the Metal search
// kernel exactly: same first keccak, same per-lane fill_mix, same inner-loop
// ops, same cross-lane FNV aggregation, same second keccak.
//
// Used as the ground-truth reference to bisect kernel divergence. If for a
// given (header, nonce, epoch) the kernel's mix_hash and this function's
// mix_hash agree, the two implementations are consistent. If they differ,
// we bisect within Swift code (which is far easier to instrument).
//
// Calls `calcDatasetItemCPU` on the fly for DAG accesses — no full DAG
// allocation required.

let kawpowRavencoinRndc: [UInt32] = [
    0x00000072, 0x00000041, 0x00000056, 0x00000045, 0x0000004E,
    0x00000043, 0x0000004F, 0x00000049, 0x0000004E, 0x0000004B,
    0x00000041, 0x00000057, 0x00000050, 0x0000004F, 0x00000057,
]

private let FNV_PRIME_KP: UInt32 = 0x01000193
private let FNV_OFFSET_BASIS_KP: UInt32 = 0x811c9dc5

@inline(__always) private func fnv1aKP(_ h: UInt32, _ d: UInt32) -> UInt32 {
    return (h ^ d) &* FNV_PRIME_KP
}

@inline(__always) private func rolKP(_ x: UInt32, _ n: UInt32) -> UInt32 {
    let s = n & 31
    if s == 0 { return x }
    return (x &<< s) | (x &>> (32 &- s))
}

@inline(__always) private func rorKP(_ x: UInt32, _ n: UInt32) -> UInt32 {
    return rolKP(x, 32 &- (n & 31))
}

// fill_mix: derive 32-uint32 mix vector for one lane.
// Matches the kernel's fill_mix exactly — kiss99 seeded from chained fnv1a
// of seed[0], seed[1], lane_id, lane_id.
func fillMixCPU(seed0: UInt32, seed1: UInt32, laneId: UInt32) -> [UInt32] {
    var fnvHash: UInt32 = FNV_OFFSET_BASIS_KP
    fnvHash = (fnvHash ^ seed0)  &* FNV_PRIME_KP; let z     = fnvHash
    fnvHash = (fnvHash ^ seed1)  &* FNV_PRIME_KP; let w     = fnvHash
    fnvHash = (fnvHash ^ laneId) &* FNV_PRIME_KP; let jsr   = fnvHash
    fnvHash = (fnvHash ^ laneId) &* FNV_PRIME_KP; let jcong = fnvHash
    var st = Kiss99(z: z, w: w, jsr: jsr, jcong: jcong)
    var mix = [UInt32](repeating: 0, count: 32)
    for i in 0..<32 { mix[i] = st.next() }
    return mix
}

private func progpowMath(_ a: UInt32, _ b: UInt32, _ r: UInt32) -> UInt32 {
    switch r % 11 {
    case 0:  return a &+ b
    case 1:  return a &* b
    case 2:  return UInt32(truncatingIfNeeded: (UInt64(a) &* UInt64(b)) >> 32)
    case 3:  return min(a, b)
    case 4:  return rolKP(a, b)
    case 5:  return rorKP(a, b)
    case 6:  return a & b
    case 7:  return a | b
    case 8:  return a ^ b
    case 9:  return UInt32(a.leadingZeroBitCount) &+ UInt32(b.leadingZeroBitCount)
    case 10: return UInt32(a.nonzeroBitCount) &+ UInt32(b.nonzeroBitCount)
    default: fatalError("unreachable")
    }
}

private func progpowMerge(_ a: UInt32, _ b: UInt32, _ r: UInt32) -> UInt32 {
    switch r % 4 {
    case 0: return (a &* 33) &+ b
    case 1: return (a ^ b) &* 33
    case 2:
        let n = ((r >> 16) % 31) + 1
        return rolKP(a, n) ^ b
    case 3:
        let n = ((r >> 16) % 31) + 1
        return rorKP(a, n) ^ b
    default: fatalError("unreachable")
    }
}

// Pre-baked operation sequences per progSeed. Mirrors Epoch.swift's codegen
// — same kiss99 PRNG, same shuffle (interleaved Fisher–Yates from N-1 → 1),
// same op ordering. Duplicated here intentionally so divergence between
// codegen and interpreter is detectable.
enum InnerOpKP {
    case cacheLoad(src: Int, dst: Int, r: UInt32)
    case math(src1: Int, src2: Int, dst: Int, rsel: UInt32, rmerge: UInt32)
}
struct DagLoadOpKP {
    let i: Int          // index into data_dag.s[0..3]
    let dst: Int
    let r: UInt32
}
struct EpochOpsKP {
    let math: [InnerOpKP]
    let dataLoads: [DagLoadOpKP]
}

func epochOpsCPU(progSeed: UInt64) -> EpochOpsKP {
    var rnd = initKiss99(progSeed: progSeed)
    var mixSeqDst   = Array(0..<KawPow.PROGPOW_REGS)
    var mixSeqCache = Array(0..<KawPow.PROGPOW_REGS)
    var i = KawPow.PROGPOW_REGS - 1
    while i > 0 {
        let jDst   = Int(rnd.next() % UInt32(i + 1)); mixSeqDst.swapAt(i, jDst)
        let jCache = Int(rnd.next() % UInt32(i + 1)); mixSeqCache.swapAt(i, jCache)
        i -= 1
    }
    var dstIdx = 0
    var cacheIdx = 0
    var math: [InnerOpKP] = []
    let maxIter = max(KawPow.PROGPOW_CNT_CACHE, KawPow.PROGPOW_CNT_MATH)
    for k in 0..<maxIter {
        if k < KawPow.PROGPOW_CNT_CACHE {
            let src = mixSeqCache[cacheIdx % KawPow.PROGPOW_REGS]; cacheIdx += 1
            let r   = rnd.next()
            let dst = mixSeqDst[dstIdx % KawPow.PROGPOW_REGS]; dstIdx += 1
            math.append(.cacheLoad(src: src, dst: dst, r: r))
        }
        if k < KawPow.PROGPOW_CNT_MATH {
            // Spec: one rnd() generates both src indices, enforced distinct.
            let modulus = UInt32((KawPow.PROGPOW_REGS - 1) * KawPow.PROGPOW_REGS)
            let srcRnd = Int(rnd.next() % modulus)
            let s1 = srcRnd % KawPow.PROGPOW_REGS
            var s2 = srcRnd / KawPow.PROGPOW_REGS
            if s2 >= s1 { s2 += 1 }
            let rs = rnd.next()
            let dst = mixSeqDst[dstIdx % KawPow.PROGPOW_REGS]; dstIdx += 1
            let rm = rnd.next()
            math.append(.math(src1: s1, src2: s2, dst: dst, rsel: rs, rmerge: rm))
        }
    }
    var dataLoads: [DagLoadOpKP] = []
    for k in 0..<KawPow.PROGPOW_DAG_LOADS {
        let r = rnd.next()
        let dst: Int
        if k == 0 { dst = 0 }
        else { dst = mixSeqDst[dstIdx % KawPow.PROGPOW_REGS]; dstIdx += 1 }
        dataLoads.append(DagLoadOpKP(i: k, dst: dst, r: r))
    }
    return EpochOpsKP(math: math, dataLoads: dataLoads)
}

// Compute the c_dag (first 4096 uint32 of the DAG) from cache. Mirrors the
// kernel's preload loop. 4096 uints = 256 items × 16 uints each.
private func buildCDag(cache: UnsafePointer<UInt8>, cacheNumNodes: UInt32) -> [UInt32] {
    var cDag = [UInt32](repeating: 0, count: 4096)
    for itemIdx in 0..<256 {
        let item = calcDatasetItemCPU(cache: cache, cacheNumNodes: cacheNumNodes, index: UInt32(itemIdx))
        for k in 0..<16 { cDag[itemIdx * 16 + k] = item[k] }
    }
    return cDag
}

struct ProgPowHashResult {
    let mixHash: [UInt8]     // 32 bytes — what we'd submit as mix_hash
    let finalHash: [UInt8]   // 32 bytes — what gets compared to share target
    let mixUint32: [UInt32]  // 8-word raw representation (LE-equivalent of mixHash)
    let finalUint32: [UInt32]
}

/// Compute progpow_hash for one (header, nonce, prog_seed) using light cache.
/// `datasetNumItems` = total DAG items in 64-byte units (matches Ethash.datasetSize / 64).
func progpowHashLight(
    headerHash: [UInt8],
    nonce: UInt64,
    progSeed: UInt64,
    cache: UnsafePointer<UInt8>,
    cacheNumNodes: UInt32,
    datasetNumItems: UInt32
) -> ProgPowHashResult {
    precondition(headerHash.count == 32, "header must be 32 bytes")

    // First Keccak: state_a[0..7] = header words (LE uint32), state_a[8/9] =
    // nonce low/high, state_a[10..24] = ravencoin_rndc constants.
    var state_a = [UInt32](repeating: 0, count: 25)
    for i in 0..<8 {
        let off = i * 4
        state_a[i] =  UInt32(headerHash[off + 0])
                   | UInt32(headerHash[off + 1]) << 8
                   | UInt32(headerHash[off + 2]) << 16
                   | UInt32(headerHash[off + 3]) << 24
    }
    state_a[8] = UInt32(truncatingIfNeeded: nonce)
    state_a[9] = UInt32(truncatingIfNeeded: nonce >> 32)
    for i in 10..<25 { state_a[i] = kawpowRavencoinRndc[i - 10] }
    Keccak800.permute(&state_a)
    let state2: [UInt32] = Array(state_a[0..<8])

    // Build the in-threadgroup c_dag (first 4096 DAG uints).
    let cDag = buildCDag(cache: cache, cacheNumNodes: cacheNumNodes)

    // Per-lane mix init via fill_mix(state2[0..1], lane_id).
    var mixes = [[UInt32]](repeating: [UInt32](), count: 16)
    for laneId in 0..<16 {
        mixes[laneId] = fillMixCPU(seed0: state2[0], seed1: state2[1], laneId: UInt32(laneId))
    }

    let ops = epochOpsCPU(progSeed: progSeed)
    // PROGPOW_DAG_ELEMENTS = DAG_BYTES / 256 = items / 4
    let progpowDagElements: UInt32 = datasetNumItems / 4

    // Inner loop. The broadcast lane (loop % 16) reveals its mix[0] to all
    // lanes; each lane then DAG-fetches a 4-uint32 dag_t at a unique offset.
    // All lanes mutate their mix via the same ops sequence.
    var lastItemIdx: UInt32 = .max
    var lastItem: [UInt32] = []
    for loop in 0..<KawPow.PROGPOW_CNT_DAG {
        let broadcastLane = loop & 15
        let broadcastMix0 = mixes[broadcastLane][0]
        let baseOffset    = broadcastMix0 % progpowDagElements

        for laneId in 0..<16 {
            let laneOff = UInt32((laneId ^ loop) & 15)
            let dagIdx  = baseOffset &* 16 &+ laneOff      // index in dag_t units
            // Each dag_t = 4 uint32 within a 64-byte item.
            let itemIdx = dagIdx / 4
            let sub     = Int(dagIdx % 4) * 4
            if itemIdx != lastItemIdx {
                lastItem = calcDatasetItemCPU(cache: cache, cacheNumNodes: cacheNumNodes, index: itemIdx)
                lastItemIdx = itemIdx
            }
            let dataDag = [lastItem[sub], lastItem[sub + 1], lastItem[sub + 2], lastItem[sub + 3]]

            for op in ops.math {
                switch op {
                case .cacheLoad(let src, let dst, let r):
                    let offset = Int(mixes[laneId][src] % UInt32(KawPow.PROGPOW_CACHE_WORDS))
                    let data = cDag[offset]
                    mixes[laneId][dst] = progpowMerge(mixes[laneId][dst], data, r)
                case .math(let s1, let s2, let dst, let rsel, let rmerge):
                    let d = progpowMath(mixes[laneId][s1], mixes[laneId][s2], rsel)
                    mixes[laneId][dst] = progpowMerge(mixes[laneId][dst], d, rmerge)
                }
            }
            for op in ops.dataLoads {
                let data = dataDag[op.i]
                mixes[laneId][op.dst] = progpowMerge(mixes[laneId][op.dst], data, op.r)
            }
        }
    }

    // Per-lane FNV1A reduction over 32 mix words → one uint32.
    var mixHashes = [UInt32](repeating: 0, count: 16)
    for laneId in 0..<16 {
        var h: UInt32 = FNV_OFFSET_BASIS_KP
        for i in 0..<32 { h = fnv1aKP(h, mixes[laneId][i]) }
        mixHashes[laneId] = h
    }

    // Cross-lane: 16 mix_hashes into 8 digest slots via FNV1A chain.
    var digest = [UInt32](repeating: FNV_OFFSET_BASIS_KP, count: 8)
    for i in 0..<16 {
        digest[i % 8] = fnv1aKP(digest[i % 8], mixHashes[i])
    }

    // Second Keccak: state2 (8) + digest (8) + ravencoin_rndc[0..8] (9) = 25.
    var state_b = [UInt32](repeating: 0, count: 25)
    for i in 0..<8 { state_b[i] = state2[i] }
    for i in 0..<8 { state_b[8 + i] = digest[i] }
    for i in 0..<9 { state_b[16 + i] = kawpowRavencoinRndc[i] }
    Keccak800.permute(&state_b)

    // Serialize the 8-uint32 mix_hash and final_hash as little-endian-per-word
    // bytes. (Wire endianness is a separate concern handled by the submit path.)
    var mixBytes   = [UInt8](repeating: 0, count: 32)
    var finalBytes = [UInt8](repeating: 0, count: 32)
    for i in 0..<8 {
        let m = digest[i]
        mixBytes[i*4 + 0] = UInt8(m         & 0xFF)
        mixBytes[i*4 + 1] = UInt8((m >> 8)  & 0xFF)
        mixBytes[i*4 + 2] = UInt8((m >> 16) & 0xFF)
        mixBytes[i*4 + 3] = UInt8((m >> 24) & 0xFF)
        let f = state_b[i]
        finalBytes[i*4 + 0] = UInt8(f         & 0xFF)
        finalBytes[i*4 + 1] = UInt8((f >> 8)  & 0xFF)
        finalBytes[i*4 + 2] = UInt8((f >> 16) & 0xFF)
        finalBytes[i*4 + 3] = UInt8((f >> 24) & 0xFF)
    }
    return ProgPowHashResult(
        mixHash: mixBytes,
        finalHash: finalBytes,
        mixUint32: digest,
        finalUint32: Array(state_b[0..<8])
    )
}
