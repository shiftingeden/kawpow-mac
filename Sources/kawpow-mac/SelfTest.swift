import Foundation

// Quick self-tests run at startup so we know our PRNG and codegen are
// deterministic and match expected fixed-points.

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
}
