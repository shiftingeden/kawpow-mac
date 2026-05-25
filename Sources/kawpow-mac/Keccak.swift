import Foundation

// Keccak (not NIST SHA-3) — used by ethash/KawPow for cache+DAG generation.
// Difference from SHA-3: padding byte is 0x01, not 0x06.

enum Keccak {
    // Round constants for the 24 rounds of Keccak-f[1600].
    private static let RC: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ]

    // Sequence-indexed rotation offsets for the rho-pi step (24 iterations).
    private static let ROTC: [Int] = [
         1,  3,  6, 10, 15, 21, 28, 36, 45, 55,  2, 14,
        27, 41, 56,  8, 25, 43, 62, 18, 39, 61, 20, 44
    ]

    private static let PI: [Int] = [
        10,  7, 11, 17, 18,  3,  5, 16,  8, 21, 24,  4,
        15, 23, 19, 13, 12,  2, 20, 14, 22,  9,  6,  1
    ]

    private static func rol(_ x: UInt64, _ n: Int) -> UInt64 {
        let s = UInt64(n & 63)
        return (x &<< s) | (x &>> (64 &- s))
    }

    @inline(__always)
    private static func keccakF(_ st: inout [UInt64]) {
        var bc = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            // Theta
            for i in 0..<5 { bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20] }
            for i in 0..<5 {
                let t = bc[(i+4) % 5] ^ rol(bc[(i+1) % 5], 1)
                var j = 0
                while j < 25 { st[j+i] ^= t; j += 5 }
            }
            // Rho + Pi
            var t = st[1]
            for i in 0..<24 {
                let j = PI[i]
                bc[0] = st[j]
                st[j] = rol(t, ROTC[i])
                t = bc[0]
            }
            // Chi
            var j = 0
            while j < 25 {
                for i in 0..<5 { bc[i] = st[j+i] }
                for i in 0..<5 { st[j+i] ^= (~bc[(i+1) % 5]) & bc[(i+2) % 5] }
                j += 5
            }
            // Iota
            st[0] ^= RC[round]
        }
    }

    // ─── Fast specialization: keccak-512 of a 64-byte input ──────────────
    // Used by cache + DAG generation. No allocations on the hot path.
    // Padding for 64-byte input fitting one 72-byte block: lane 8 = 0x80…01.
    @inline(__always)
    static func keccak512_64(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 25) { state in
            for i in 0..<25 { state[i] = 0 }
            // Absorb 8 lanes from the 64-byte input (little-endian)
            input.withMemoryRebound(to: UInt64.self, capacity: 8) { p64 in
                for i in 0..<8 { state[i] = p64[i] }
            }
            // Padding lane: 0x01 at byte 0 (relative to lane), 0x80 at byte 7
            state[8] = 0x8000000000000001
            keccakF_ptr(state.baseAddress!)
            // Squeeze 64 bytes from lanes 0..7
            output.withMemoryRebound(to: UInt64.self, capacity: 8) { p64 in
                for i in 0..<8 { p64[i] = state[i] }
            }
        }
    }

    // keccakF on a pointer state — same algorithm, no bounds checks.
    @inline(__always)
    private static func keccakF_ptr(_ st: UnsafeMutablePointer<UInt64>) {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 5) { bc in
            for round in 0..<24 {
                for i in 0..<5 {
                    bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20]
                }
                for i in 0..<5 {
                    let t = bc[(i+4) % 5] ^ rol(bc[(i+1) % 5], 1)
                    var j = 0
                    while j < 25 { st[j+i] ^= t; j += 5 }
                }
                var t = st[1]
                for i in 0..<24 {
                    let j = PI[i]
                    let tmp = st[j]
                    st[j] = rol(t, ROTC[i])
                    t = tmp
                }
                var j = 0
                while j < 25 {
                    for i in 0..<5 { bc[i] = st[j+i] }
                    for i in 0..<5 { st[j+i] ^= (~bc[(i+1) % 5]) & bc[(i+2) % 5] }
                    j += 5
                }
                st[0] ^= RC[round]
            }
        }
    }

    // Generic sponge absorb+squeeze for fixed-output Keccak hashes used by ethash.
    static func hash(_ input: [UInt8], outputBytes: Int, blockBytes: Int) -> [UInt8] {
        precondition(blockBytes % 8 == 0)
        precondition(outputBytes <= blockBytes)
        var state = [UInt64](repeating: 0, count: 25)
        // Absorb
        var inputPadded = input
        // Keccak (not SHA-3) padding: 0x01 ... 0x80
        let padLen = blockBytes - (input.count % blockBytes)
        var pad = [UInt8](repeating: 0, count: padLen)
        pad[0] = 0x01
        pad[padLen - 1] |= 0x80
        inputPadded.append(contentsOf: pad)

        var off = 0
        while off < inputPadded.count {
            let lanes = blockBytes / 8
            for i in 0..<lanes {
                var w: UInt64 = 0
                for b in 0..<8 {
                    w |= UInt64(inputPadded[off + i*8 + b]) << (UInt64(b) * 8)
                }
                state[i] ^= w
            }
            keccakF(&state)
            off += blockBytes
        }
        // Squeeze (single block — output <= blockBytes)
        var out = [UInt8](repeating: 0, count: outputBytes)
        for i in 0..<outputBytes {
            let lane = state[i / 8]
            out[i] = UInt8((lane >> UInt64((i % 8) * 8)) & 0xFF)
        }
        return out
    }

    static func keccak256(_ input: [UInt8]) -> [UInt8] {
        // capacity = 512 bits, rate = 1088 bits = 136 bytes
        return hash(input, outputBytes: 32, blockBytes: 136)
    }

    static func keccak512(_ input: [UInt8]) -> [UInt8] {
        // capacity = 1024 bits, rate = 576 bits = 72 bytes
        return hash(input, outputBytes: 64, blockBytes: 72)
    }
}
