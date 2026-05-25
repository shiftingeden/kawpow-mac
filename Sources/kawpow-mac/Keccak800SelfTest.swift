import Foundation
import Metal

// Cross-check: run keccak-f[800] in both Swift CPU (Keccak800.permute) and a
// standalone Metal probe kernel (Resources/keccak_f800_probe.metal). For any
// input state the two outputs must be bitwise identical. If they diverge, we
// have a bug in our keccak_f800 implementation — and since both keccaks in
// ProgPoW use this permutation, that would explain every "Invalid share".
//
// Returns true on agreement.
@discardableResult
func keccak800CrossCheck() -> Bool {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        print("[keccak800] no Metal device"); return false
    }

    // Compile the probe kernel from the bundled resource.
    guard let url = Bundle.module.url(forResource: "keccak_f800_probe", withExtension: "metal"),
          let src = try? String(contentsOf: url, encoding: .utf8) else {
        print("[keccak800] probe metal source missing from bundle"); return false
    }
    let opts = MTLCompileOptions()
    opts.languageVersion = .version2_4
    let lib: MTLLibrary
    do { lib = try device.makeLibrary(source: src, options: opts) }
    catch { print("[keccak800] probe compile failed: \(error)"); return false }
    guard let fn = lib.makeFunction(name: "keccak_f800_probe"),
          let pso = try? device.makeComputePipelineState(function: fn) else {
        print("[keccak800] probe pipeline failed"); return false
    }

    // Try several inputs: all-zero, a "ProgPoW first keccak" shape, and a
    // random-ish pattern. If any one diverges, we have a bug.
    let cases: [[UInt32]] = [
        Array(repeating: 0, count: 25),
        {
            var s = [UInt32](repeating: 0, count: 25)
            s[0] = 1                          // minimal non-zero
            return s
        }(),
        {
            // Matches what the search kernel actually feeds keccak_f800 on
            // the first call: 8 header words + lo32(nonce) at [8], hi32 at [9],
            // ravencoin_rndc at [10..24].
            var s = [UInt32](repeating: 0, count: 25)
            // arbitrary "header" — repeating pattern
            for i in 0..<8 { s[i] = 0x11111111 &* UInt32(i + 1) }
            s[8] = 0xdeadbeef
            s[9] = 0
            let ravencoin_rndc: [UInt32] = [
                0x00000072, 0x00000041, 0x00000056, 0x00000045, 0x0000004E,
                0x00000043, 0x0000004F, 0x00000049, 0x0000004E, 0x0000004B,
                0x00000041, 0x00000057, 0x00000050, 0x0000004F, 0x00000057,
            ]
            for i in 0..<15 { s[10 + i] = ravencoin_rndc[i] }
            return s
        }()
    ]

    let inBuf = device.makeBuffer(length: 25 * 4, options: .storageModeShared)!
    let outBuf = device.makeBuffer(length: 25 * 4, options: .storageModeShared)!

    for (idx, input) in cases.enumerated() {
        // Swift CPU
        var swiftState = input
        Keccak800.permute(&swiftState)

        // Metal probe
        let inPtr = inBuf.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<25 { inPtr[i] = input[i] }
        memset(outBuf.contents(), 0, 25 * 4)
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBuffer(inBuf, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { print("[keccak800] dispatch err: \(e)"); return false }
        let outPtr = outBuf.contents().assumingMemoryBound(to: UInt32.self)
        let metalState = (0..<25).map { outPtr[$0] }

        // Compare
        let agree = swiftState == metalState
        let summary = "case \(idx): swift[0..4]=" + swiftState.prefix(4).map { String(format: "%08x", $0) }.joined(separator: " ")
                    + " metal[0..4]=" + metalState.prefix(4).map { String(format: "%08x", $0) }.joined(separator: " ")
                    + (agree ? " ✓" : " ✗")
        print("[keccak800] \(summary)")
        if !agree {
            // Dump full divergence
            for i in 0..<25 {
                if swiftState[i] != metalState[i] {
                    print("[keccak800]   lane[\(i)] swift=\(String(format: "%08x", swiftState[i])) metal=\(String(format: "%08x", metalState[i]))")
                }
            }
            return false
        }
    }
    print("[keccak800] CPU keccak_f800 matches Metal kernel keccak_f800 ✓")
    return true
}
