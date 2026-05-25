import Foundation

// ethash/KawPow sizing + cache generation.
//
// Constants from the ethash spec; KawPow uses the same DAG/cache machinery with
// a different epoch length (Ravencoin = 7500 blocks/epoch vs ETH's 30000).
//
// Cache size grows linearly with epoch, rounded down to a multiple of HASH_BYTES
// such that (size / HASH_BYTES) is prime. Same for the DAG.

enum Ethash {
    static let DATASET_BYTES_INIT:   UInt64 = 1 << 30   // 1 GB
    static let DATASET_BYTES_GROWTH: UInt64 = 1 << 23   // 8 MB per epoch
    static let CACHE_BYTES_INIT:     UInt64 = 1 << 24   // 16 MB
    static let CACHE_BYTES_GROWTH:   UInt64 = 1 << 17   // 128 KB per epoch
    static let HASH_BYTES:           UInt64 = 64        // one keccak-512 output
    static let MIX_BYTES:            UInt64 = 128
    static let DATASET_PARENTS:      UInt64 = 256
    static let CACHE_ROUNDS:         UInt64 = 3

    static let KAWPOW_EPOCH_LENGTH:  UInt64 = 7500

    static func epoch(forBlockHeight h: UInt64) -> UInt64 {
        return h / KAWPOW_EPOCH_LENGTH
    }

    static func cacheSize(epoch: UInt64) -> UInt64 {
        var sz = CACHE_BYTES_INIT + CACHE_BYTES_GROWTH * epoch
        sz -= HASH_BYTES
        while !isPrime(sz / HASH_BYTES) {
            sz -= 2 * HASH_BYTES
        }
        return sz
    }

    static func datasetSize(epoch: UInt64) -> UInt64 {
        var sz = DATASET_BYTES_INIT + DATASET_BYTES_GROWTH * epoch
        sz -= MIX_BYTES
        while !isPrime(sz / MIX_BYTES) {
            sz -= 2 * MIX_BYTES
        }
        return sz
    }

    // seed = keccak256 iterated `epoch` times starting from 0...0
    static func seedHash(epoch: UInt64) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: 32)
        for _ in 0..<epoch {
            s = Keccak.keccak256(s)
        }
        return s
    }

    // ─── Light cache generation ────────────────────────────────────────────
    // cache[0] = keccak_512(seed); cache[i] = keccak_512(cache[i-1]).
    // Then CACHE_ROUNDS of RandMemoHash mixing.
    static func makeCache(epoch: UInt64) -> [UInt8] {
        let size = cacheSize(epoch: epoch)
        let nodeCount = Int(size / HASH_BYTES)
        let seed = seedHash(epoch: epoch)

        var cache = [UInt8](repeating: 0, count: Int(size))
        // First node
        let firstNode = Keccak.keccak512(seed)
        for i in 0..<64 { cache[i] = firstNode[i] }

        // Subsequent nodes — chain keccak_512
        var prev = firstNode
        for i in 1..<nodeCount {
            prev = Keccak.keccak512(prev)
            let off = i * 64
            for b in 0..<64 { cache[off + b] = prev[b] }
        }

        // RandMemoHash rounds
        for _ in 0..<Int(CACHE_ROUNDS) {
            for i in 0..<nodeCount {
                // v = cache[i][0] mod nodeCount, indexed as little-endian uint32 at byte 0
                let off = i * 64
                let lo: UInt32 =
                      UInt32(cache[off + 0])
                    | UInt32(cache[off + 1]) << 8
                    | UInt32(cache[off + 2]) << 16
                    | UInt32(cache[off + 3]) << 24
                let v = Int(lo) % nodeCount
                let leftIdx  = (i + nodeCount - 1) % nodeCount
                let rightIdx = v

                var tmp = [UInt8](repeating: 0, count: 64)
                let lOff = leftIdx * 64
                let rOff = rightIdx * 64
                for b in 0..<64 {
                    tmp[b] = cache[lOff + b] ^ cache[rOff + b]
                }
                let h = Keccak.keccak512(tmp)
                for b in 0..<64 { cache[off + b] = h[b] }
            }
        }

        return cache
    }
}

// Miller–Rabin would be overkill for the modest sizes we test here (~1.5M-25M);
// trial division up to sqrt(n) is fine. Cache sizing only ever runs once.
func isPrime(_ n: UInt64) -> Bool {
    if n < 2 { return false }
    if n < 4 { return true }
    if n % 2 == 0 { return false }
    if n % 3 == 0 { return false }
    var i: UInt64 = 5
    while i * i <= n {
        if n % i == 0 { return false }
        if n % (i + 2) == 0 { return false }
        i += 6
    }
    return true
}
