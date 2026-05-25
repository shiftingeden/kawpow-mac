import Foundation

// CPU implementation of ethash dataset-item derivation ("light evaluation").
// One DAG item = 64 bytes = 16 uint32. Algorithm mirrors fill_dag.metal exactly:
//
//   mix = cache[i mod n]            // 16 uint32
//   mix[0] ^= i
//   mix = keccak512(mix)
//   for j in 0..256:
//       parent = fnv1(i^j, mix[j%16]) % n
//       mix = fnv1_pairwise(mix, cache[parent])
//   mix = keccak512(mix)
//   return mix
//
// Used to validate that fill_dag.metal produces the same bytes the spec
// requires. Cache is laid out as 16 uint32 per node, little-endian.

private let FNV1_PRIME: UInt32 = 0x01000193

@inline(__always)
private func fnv1(_ a: UInt32, _ b: UInt32) -> UInt32 {
    return (a &* FNV1_PRIME) ^ b
}

/// Compute one 64-byte DAG item from the light cache.
/// `cache` is the raw little-endian byte buffer; `cacheNumNodes` = bytes / 64.
/// Returns 16 uint32 values (= 64 bytes).
func calcDatasetItemCPU(cache: UnsafePointer<UInt8>, cacheNumNodes: UInt32, index: UInt32) -> [UInt32] {
    var mix = [UInt32](repeating: 0, count: 16)
    let cacheIdx = index % cacheNumNodes
    let base = Int(cacheIdx) * 64
    // Load cache node (16 uint32, little-endian from bytes)
    for k in 0..<16 {
        let off = base + k * 4
        mix[k] =  UInt32(cache[off + 0])
              | UInt32(cache[off + 1]) << 8
              | UInt32(cache[off + 2]) << 16
              | UInt32(cache[off + 3]) << 24
    }
    mix[0] ^= index

    // keccak_512 on 64 bytes
    do {
        var inBytes = [UInt8](repeating: 0, count: 64)
        for k in 0..<16 {
            let w = mix[k]
            inBytes[k*4 + 0] = UInt8(w & 0xFF)
            inBytes[k*4 + 1] = UInt8((w >> 8) & 0xFF)
            inBytes[k*4 + 2] = UInt8((w >> 16) & 0xFF)
            inBytes[k*4 + 3] = UInt8((w >> 24) & 0xFF)
        }
        var outBytes = [UInt8](repeating: 0, count: 64)
        inBytes.withUnsafeBufferPointer { ip in
            outBytes.withUnsafeMutableBufferPointer { op in
                Keccak.keccak512_64(ip.baseAddress!, op.baseAddress!)
            }
        }
        for k in 0..<16 {
            let off = k * 4
            mix[k] =  UInt32(outBytes[off + 0])
                  | UInt32(outBytes[off + 1]) << 8
                  | UInt32(outBytes[off + 2]) << 16
                  | UInt32(outBytes[off + 3]) << 24
        }
    }

    // FNV1 rounds with cache parents. Ravencoin's KawPow uses
    // full_dataset_item_parents=512 (NOT the standard ethash 256).
    for j: UInt32 in 0..<512 {
        let h = fnv1(index ^ j, mix[Int(j & 15)])
        let parent = Int(h % cacheNumNodes)
        let pbase = parent * 64
        for k in 0..<16 {
            let off = pbase + k * 4
            let w =  UInt32(cache[off + 0])
                  | UInt32(cache[off + 1]) << 8
                  | UInt32(cache[off + 2]) << 16
                  | UInt32(cache[off + 3]) << 24
            mix[k] = fnv1(mix[k], w)
        }
    }

    // Final keccak_512
    do {
        var inBytes = [UInt8](repeating: 0, count: 64)
        for k in 0..<16 {
            let w = mix[k]
            inBytes[k*4 + 0] = UInt8(w & 0xFF)
            inBytes[k*4 + 1] = UInt8((w >> 8) & 0xFF)
            inBytes[k*4 + 2] = UInt8((w >> 16) & 0xFF)
            inBytes[k*4 + 3] = UInt8((w >> 24) & 0xFF)
        }
        var outBytes = [UInt8](repeating: 0, count: 64)
        inBytes.withUnsafeBufferPointer { ip in
            outBytes.withUnsafeMutableBufferPointer { op in
                Keccak.keccak512_64(ip.baseAddress!, op.baseAddress!)
            }
        }
        for k in 0..<16 {
            let off = k * 4
            mix[k] =  UInt32(outBytes[off + 0])
                  | UInt32(outBytes[off + 1]) << 8
                  | UInt32(outBytes[off + 2]) << 16
                  | UInt32(outBytes[off + 3]) << 24
        }
    }

    return mix
}
