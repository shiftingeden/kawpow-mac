import Foundation

// Pool sends a 256-bit target as 64 hex chars, big-endian.
// The kernel compares only the first 8 bytes of the keccak_f800 output (interpreted big-endian)
// against a uint64 target. So our job is: take the first 16 hex chars of the pool target,
// parse big-endian → UInt64. That value goes into the kernel as TARGET_REPLACE.
//
// The likely-bug surface in thinminerpro: getting this conversion wrong (endianness,
// using last 8 bytes instead of first 8, etc.) would either make the kernel reject every
// share or accept hashes that the pool then rejects.

enum Target {
    /// Parse the first 8 bytes of a 256-bit target hex string as a big-endian UInt64.
    static func kernelTargetFromPoolTarget(_ hex: String) -> UInt64 {
        let cleaned = hex.lowercased().hasPrefix("0x")
            ? String(hex.dropFirst(2))
            : hex
        // Pad to 64 chars if pool returns short form
        let padded = String(repeating: "0", count: max(0, 64 - cleaned.count)) + cleaned
        let first16 = String(padded.prefix(16))
        return UInt64(first16, radix: 16) ?? 0
    }

    /// Returns the kernel target as Metal source: a literal "0xNNN...UL;" string suitable
    /// for substituting in place of TARGET_REPLACE.
    static func metalLiteral(for poolTarget: String) -> String {
        let v = kernelTargetFromPoolTarget(poolTarget)
        return String(format: "0x%016llxUL;", v)
    }
}
