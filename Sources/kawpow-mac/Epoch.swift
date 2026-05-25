import Foundation

// KawPow / ProgPoW per-epoch source generator.
//
// Reference: https://github.com/RavenProject/Ravencoin/wiki/KAWPOW-Algorithm
//            https://github.com/ifdefelse/ProgPOW
//
// The kernel template has two placeholders that are filled in fresh for each
// progpow seed (= block_number / KAWPOW_PERIOD):
//
//   INCLUDE_PROGPOW_RANDOM_MATH  — interleaved random math + c_dag cache loads
//   INCLUDE_PROGPOW_DATA_LOADS   — final merge of data_dag.s[0..3] into the mix
//
// Determinism: every miner generating from the same prog_seed must produce
// identical code; otherwise miners and pool disagree on what hash they computed.

enum KawPow {
    // ProgPoW / KawPow algorithm parameters — must match kernel #defines
    static let PROGPOW_LANES        = 16
    static let PROGPOW_REGS         = 32
    static let PROGPOW_DAG_LOADS    = 4
    static let PROGPOW_CACHE_WORDS  = 4096
    static let PROGPOW_CNT_DAG      = 64
    static let PROGPOW_CNT_MATH     = 18
    static let PROGPOW_CNT_CACHE    = 11   // ProgPoW spec value, matches KawPow
    static let KAWPOW_PERIOD        = 3    // KawPow re-rolls math every 3 blocks

    static func progSeed(forBlockHeight height: UInt64) -> UInt64 {
        return height / UInt64(KAWPOW_PERIOD)
    }
}

// --------------------------------------------------------------------------
// kiss99 PRNG — must match the Metal-side kiss99() exactly so we generate
// deterministic source code that matches what every other miner generates.
// --------------------------------------------------------------------------

struct Kiss99 {
    var z: UInt32
    var w: UInt32
    var jsr: UInt32
    var jcong: UInt32

    mutating func next() -> UInt32 {
        z = 36969 &* (z & 0xFFFF) &+ (z >> 16)
        w = 18000 &* (w & 0xFFFF) &+ (w >> 16)
        let MWC = (z << 16) &+ w
        jsr ^= jsr << 17
        jsr ^= jsr >> 13
        jsr ^= jsr << 5
        jcong = 69069 &* jcong &+ 1234567
        return (MWC ^ jcong) &+ jsr
    }
}

// fnv1a hash used by ProgPoW to derive kiss99 state from prog_seed
private let FNV_PRIME: UInt32 = 0x1000193
private let FNV_OFFSET_BASIS: UInt32 = 0x811c9dc5

private func fnv1a(_ h: inout UInt32, _ d: UInt32) -> UInt32 {
    h = (h ^ d) &* FNV_PRIME
    return h
}

// Initialise kiss99 from a 64-bit prog_seed — matches the reference Python
// rnd_state() from the ProgPoW spec.
func initKiss99(progSeed: UInt64) -> Kiss99 {
    var fnvHash: UInt32 = FNV_OFFSET_BASIS
    let lo = UInt32(truncatingIfNeeded: progSeed)
    let hi = UInt32(truncatingIfNeeded: progSeed >> 32)
    var st = Kiss99(z: 0, w: 0, jsr: 0, jcong: 0)
    st.z     = fnv1a(&fnvHash, lo)
    st.w     = fnv1a(&fnvHash, hi)
    st.jsr   = fnv1a(&fnvHash, lo)
    st.jcong = fnv1a(&fnvHash, hi)
    return st
}

// --------------------------------------------------------------------------
// Generated-source helpers
// --------------------------------------------------------------------------

// `progPowMath(a, b, r)` — selects one of 11 math operations on r % 11.
// We emit the corresponding Metal expression as a string.
private func mathExpr(a: String, b: String, r: UInt32) -> String {
    switch r % 11 {
    case 0:  return "(\(a) + \(b))"
    case 1:  return "(\(a) * \(b))"
    case 2:  return "(uint)(((ulong)(\(a)) * (ulong)(\(b))) >> 32)"  // mul_hi
    case 3:  return "min(\(a), \(b))"
    case 4:  return "rotate(\(a), (uint)(\(b)))"                      // ROTL32
    case 5:  return "rotate(\(a), (uint)(32u - (\(b) & 31u)))"        // ROTR32
    case 6:  return "(\(a) & \(b))"
    case 7:  return "(\(a) | \(b))"
    case 8:  return "(\(a) ^ \(b))"
    case 9:  return "(clz(\(a)) + clz(\(b)))"
    case 10: return "(popcount(\(a)) + popcount(\(b)))"
    default: fatalError("unreachable")
    }
}

// `merge(a, b, r)` — folds `b` into `a` four different ways, on r % 4.
// We mutate `a` in place. Returns the Metal statement string ending with ';'.
private func mergeStmt(dst: String, src: String, r: UInt32) -> String {
    switch r % 4 {
    case 0: return "\(dst) = (\(dst) * 33u) + \(src);"
    case 1: return "\(dst) = (\(dst) ^ \(src)) * 33u;"
    case 2:
        let n = ((r >> 16) % 31) + 1
        return "\(dst) = rotate(\(dst), \(n)u) ^ \(src);"
    case 3:
        let n = ((r >> 16) % 31) + 1
        return "\(dst) = rotate(\(dst), (uint)(32u - \(n)u)) ^ \(src);"
    default: fatalError("unreachable")
    }
}

// --------------------------------------------------------------------------
// Build the two source blocks for a given prog_seed.
// --------------------------------------------------------------------------

struct GeneratedKernel {
    let randomMath: String
    let dataLoads: String
}

func generateKernelSource(progSeed: UInt64) -> GeneratedKernel {
    var rnd = initKiss99(progSeed: progSeed)

    // ProgPoW spec: mix_seq_dst and mix_seq_cache are shuffled INTERLEAVED,
    // walking i from N-1 down to 1, two rnd() calls per i. (Doing dst fully
    // then cache fully would consume the same number of rnd() calls but in
    // the wrong order, leaving every downstream math/merge op reading a
    // shifted slice of the kiss99 stream → divergent hashes vs. the pool.)
    var mixSeqDst   = Array(0..<KawPow.PROGPOW_REGS)
    var mixSeqCache = Array(0..<KawPow.PROGPOW_REGS)
    var i = KawPow.PROGPOW_REGS - 1
    while i > 0 {
        let jDst   = Int(rnd.next() % UInt32(i + 1))
        mixSeqDst.swapAt(i, jDst)
        let jCache = Int(rnd.next() % UInt32(i + 1))
        mixSeqCache.swapAt(i, jCache)
        i -= 1
    }
    var dstIdx = 0
    var cacheIdx = 0

    // ─── RANDOM_MATH block ────────────────────────────────────────────────
    // Interleaves cache reads (PROGPOW_CNT_CACHE) with math ops (PROGPOW_CNT_MATH).
    // Reference ProgPoW does up to max(CNT_CACHE, CNT_MATH) iterations.
    var randomMath = "{\n"
    let maxIter = max(KawPow.PROGPOW_CNT_CACHE, KawPow.PROGPOW_CNT_MATH)
    for i in 0..<maxIter {
        if i < KawPow.PROGPOW_CNT_CACHE {
            let src = mixSeqCache[cacheIdx % KawPow.PROGPOW_REGS]; cacheIdx += 1
            let r   = rnd.next()
            let dst = mixSeqDst[dstIdx % KawPow.PROGPOW_REGS]; dstIdx += 1
            randomMath += "  // cache load \(i)\n"
            randomMath += "  data = c_dag[the_mix[\(src)] % PROGPOW_CACHE_WORDS];\n"
            randomMath += "  " + mergeStmt(dst: "the_mix[\(dst)]", src: "data", r: r) + "\n"
        }
        if i < KawPow.PROGPOW_CNT_MATH {
            let src1 = Int(rnd.next() % UInt32(KawPow.PROGPOW_REGS))
            let src2 = Int(rnd.next() % UInt32(KawPow.PROGPOW_REGS))
            let rsel = rnd.next()
            let rmerge = rnd.next()
            let dst = mixSeqDst[dstIdx % KawPow.PROGPOW_REGS]; dstIdx += 1
            let expr = mathExpr(a: "the_mix[\(src1)]", b: "the_mix[\(src2)]", r: rsel)
            randomMath += "  // math \(i)\n"
            randomMath += "  data = \(expr);\n"
            randomMath += "  " + mergeStmt(dst: "the_mix[\(dst)]", src: "data", r: rmerge) + "\n"
        }
    }
    randomMath += "}\n"

    // ─── DATA_LOADS block ─────────────────────────────────────────────────
    // Consume data_dag.s[0..PROGPOW_DAG_LOADS-1] into mix registers.
    // ProgPoW spec: index 0 always merges into mix[0], the rest follow mix_seq_dst.
    var dataLoads = "{\n"
    for i in 0..<KawPow.PROGPOW_DAG_LOADS {
        let r = rnd.next()
        let dst: Int
        if i == 0 {
            dst = 0
        } else {
            dst = mixSeqDst[dstIdx % KawPow.PROGPOW_REGS]
            dstIdx += 1
        }
        dataLoads += "  data = data_dag.s[\(i)];\n"
        dataLoads += "  " + mergeStmt(dst: "the_mix[\(dst)]", src: "data", r: r) + "\n"
    }
    dataLoads += "}\n"

    return GeneratedKernel(randomMath: randomMath, dataLoads: dataLoads)
}
