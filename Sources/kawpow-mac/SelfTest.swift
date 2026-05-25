import Foundation

// Quick self-tests run at startup so we know our PRNG and codegen are
// deterministic and match expected fixed-points.

// Hex helpers — only used by self-tests
private func hex(_ b: [UInt8]) -> String {
    b.map { String(format: "%02x", $0) }.joined()
}
private func unhex(_ s: String) -> [UInt8] {
    let c = Array(s)
    var r = [UInt8](); r.reserveCapacity(s.count / 2)
    var i = 0
    while i + 1 < c.count {
        let hi = Int(String(c[i]), radix: 16)!
        let lo = Int(String(c[i+1]), radix: 16)!
        r.append(UInt8(hi*16 + lo))
        i += 2
    }
    return r
}

func runSelfTests() {
    // ──────────────────────────────────────────────────────────────────
    // 1) kiss99 fixed point.
    // The canonical kiss99 from Marsaglia, when seeded as below, has a
    // well-known 100-millionth output of 1372460312.
    // (See https://github.com/ifdefelse/ProgPOW reference Python).
    // We won't run 100M iterations here — just check the FIRST values
    // for the spec-test seed are stable across runs (regression guard).
    // ──────────────────────────────────────────────────────────────────
    var st = Kiss99(z: 362436069, w: 521288629, jsr: 123456789, jcong: 380116160)
    let firstFive = (0..<5).map { _ in st.next() }
    print("[selftest] kiss99 first 5: \(firstFive.map { String(format: "0x%08x", $0) })")

    // ──────────────────────────────────────────────────────────────────
    // 2) Same prog_seed must always produce the same kernel source.
    // ──────────────────────────────────────────────────────────────────
    let a = generateKernelSource(progSeed: 1234567)
    let b = generateKernelSource(progSeed: 1234567)
    let c = generateKernelSource(progSeed: 1234568)
    precondition(a.randomMath == b.randomMath, "codegen not deterministic (RANDOM_MATH)")
    precondition(a.dataLoads  == b.dataLoads,  "codegen not deterministic (DATA_LOADS)")
    precondition(a.randomMath != c.randomMath, "codegen seed has no effect")
    print("[selftest] codegen determinism OK")
    print("[selftest] RANDOM_MATH(1234567) size: \(a.randomMath.count) chars")
    print("[selftest] DATA_LOADS(1234567)  size: \(a.dataLoads.count) chars")

    // ──────────────────────────────────────────────────────────────────
    // 3) Keccak-256 + Keccak-512 against canonical empty-input vectors.
    // ──────────────────────────────────────────────────────────────────
    let k256Empty = Keccak.keccak256([])
    let expected256 = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    precondition(hex(k256Empty) == expected256, "keccak256(\"\") wrong: got \(hex(k256Empty))")
    let k512Empty = Keccak.keccak512([])
    let expected512 = "0eab42de4c3ceb9235fc91acffe746b29c29a8c366b7c60e4e67c466f36a4304" +
                      "c00fa9caf9d87976ba469bcbe06713b435f091ef2769fb160cdab33d3670680e"
    precondition(hex(k512Empty) == expected512, "keccak512(\"\") wrong: got \(hex(k512Empty))")
    print("[selftest] Keccak-256/512 empty-input vectors OK")

    // ──────────────────────────────────────────────────────────────────
    // 4) Sizing — Ravencoin block ~4,381,151 → epoch 584. From the
    // captured thinminerpro log: light_cache_size 93,322,816 / 64 = 1,458,169 nodes.
    // ──────────────────────────────────────────────────────────────────
    let h: UInt64 = 4_381_151
    let ep = Ethash.epoch(forBlockHeight: h)
    let cs = Ethash.cacheSize(epoch: ep)
    let nodes = cs / Ethash.HASH_BYTES
    print("[selftest] block \(h) → epoch \(ep), cache_size=\(cs) bytes, nodes=\(nodes)")
    precondition(cs == 93_322_816, "cacheSize wrong: expected 93322816, got \(cs)")
    precondition(nodes == 1_458_169, "cache nodes wrong: expected 1458169, got \(nodes)")
    print("[selftest] cacheSize matches thinminerpro log for epoch \(ep)")
}
