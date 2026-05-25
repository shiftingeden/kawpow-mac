import Foundation

// Keccak-f[800] permutation — 25 uint32 lanes, 22 rounds. This is the
// permutation ProgPoW/KawPow uses (NOT keccak-f[1600], which we already
// have in Keccak.swift for ethash cache+DAG generation).
//
// Difference from f[1600]:
//   - lane width 32 bits (vs 64), so rotation offsets are taken mod 32
//   - 22 rounds (vs 24)
//   - same Theta / Rho-Pi / Chi / Iota structure
//
// Round constants are the keccak-f[1600] RC truncated to 32 bits.
// Rotation offsets are the keccak-f[1600] offsets mod 32.

enum Keccak800 {

    // Round constants — keccak-f[1600] RC, low 32 bits, first 24 entries.
    // We use the first 22 (one per round).
    static let RNDC: [UInt32] = [
        0x00000001, 0x00008082, 0x0000808a, 0x80008000,
        0x0000808b, 0x80000001, 0x80008081, 0x00008009,
        0x0000008a, 0x00000088, 0x80008009, 0x8000000a,
        0x8000808b, 0x0000008b, 0x00008089, 0x00008003,
        0x00008002, 0x00000080, 0x0000800a, 0x8000000a,
        0x80008081, 0x00008080, 0x80000001, 0x80008008
    ]

    // Rho-pi step uses sequence-indexed rotation offsets (24 values).
    // f[1600] amounts: 1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44
    // For f[800] (32-bit lanes), each is taken mod 32:
    static let ROTC: [Int] = [
         1,  3,  6, 10, 15, 21, 28,  4, 13, 23,  2, 14,
        27,  9, 24,  8, 25, 11, 30, 18,  7, 29, 20, 12
    ]

    static let PILN: [Int] = [
        10,  7, 11, 17, 18,  3,  5, 16,  8, 21, 24,  4,
        15, 23, 19, 13, 12,  2, 20, 14, 22,  9,  6,  1
    ]

    @inline(__always)
    private static func rol32(_ x: UInt32, _ n: Int) -> UInt32 {
        let s = UInt32(n & 31)
        if s == 0 { return x }
        return (x &<< s) | (x &>> (32 &- s))
    }

    /// In-place keccak-f[800] permutation on a 25-uint32 state.
    /// Mirrors the Metal kernel's `keccak_f800` (22 rounds).
    static func permute(_ st: inout [UInt32]) {
        precondition(st.count == 25)
        var bc = [UInt32](repeating: 0, count: 5)
        for r in 0..<22 {
            // Theta
            for i in 0..<5 {
                bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20]
            }
            for i in 0..<5 {
                let t = bc[(i+4) % 5] ^ rol32(bc[(i+1) % 5], 1)
                var j = 0
                while j < 25 { st[j+i] ^= t; j += 5 }
            }
            // Rho + Pi
            var t = st[1]
            for i in 0..<24 {
                let j = PILN[i]
                let tmp = st[j]
                st[j] = rol32(t, ROTC[i])
                t = tmp
            }
            // Chi
            var j = 0
            while j < 25 {
                for i in 0..<5 { bc[i] = st[j+i] }
                for i in 0..<5 { st[j+i] ^= (~bc[(i+1) % 5]) & bc[(i+2) % 5] }
                j += 5
            }
            // Iota
            st[0] ^= RNDC[r]
        }
    }
}
