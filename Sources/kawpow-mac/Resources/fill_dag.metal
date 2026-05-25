#include <metal_stdlib>
using namespace metal;

// Keccak-f[1600] permutation. Operates on a 25-lane ulong state in thread memory.
constant ulong KECCAK_RC[24] = {
    0x0000000000000001UL, 0x0000000000008082UL, 0x800000000000808AUL, 0x8000000080008000UL,
    0x000000000000808BUL, 0x0000000080000001UL, 0x8000000080008081UL, 0x8000000000008009UL,
    0x000000000000008AUL, 0x0000000000000088UL, 0x0000000080008009UL, 0x000000008000000AUL,
    0x000000008000808BUL, 0x800000000000008BUL, 0x8000000000008089UL, 0x8000000000008003UL,
    0x8000000000008002UL, 0x8000000000000080UL, 0x000000000000800AUL, 0x800000008000000AUL,
    0x8000000080008081UL, 0x8000000000008080UL, 0x0000000080000001UL, 0x8000000080008008UL
};

constant int KECCAK_ROTC[24] = {
     1,  3,  6, 10, 15, 21, 28, 36, 45, 55,  2, 14,
    27, 41, 56,  8, 25, 43, 62, 18, 39, 61, 20, 44
};

constant int KECCAK_PIL[24] = {
    10,  7, 11, 17, 18,  3,  5, 16,  8, 21, 24,  4,
    15, 23, 19, 13, 12,  2, 20, 14, 22,  9,  6,  1
};

inline ulong rol64(ulong x, int n) {
    int s = n & 63;
    return (x << s) | (x >> (64 - s));
}

static void keccakf(thread ulong st[25]) {
    ulong bc[5];
    for (int r = 0; r < 24; r++) {
        // Theta
        for (int i = 0; i < 5; i++)
            bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20];
        for (int i = 0; i < 5; i++) {
            ulong t = bc[(i+4) % 5] ^ rol64(bc[(i+1) % 5], 1);
            for (int j = 0; j < 25; j += 5)
                st[j+i] ^= t;
        }
        // Rho + Pi
        ulong t = st[1];
        for (int i = 0; i < 24; i++) {
            int j = KECCAK_PIL[i];
            ulong tmp = st[j];
            st[j] = rol64(t, KECCAK_ROTC[i]);
            t = tmp;
        }
        // Chi
        for (int j = 0; j < 25; j += 5) {
            for (int i = 0; i < 5; i++) bc[i] = st[j+i];
            for (int i = 0; i < 5; i++) st[j+i] ^= (~bc[(i+1) % 5]) & bc[(i+2) % 5];
        }
        // Iota
        st[0] ^= KECCAK_RC[r];
    }
}

// Keccak-512 on a 64-byte input (16 uint32). Output: 64 bytes (16 uint32) in place.
// Block size = 72 bytes (rate = 576 bits, capacity = 1024 bits).
// Padding: input(64) | 0x01 | zeros... | 0x80  → 72 bytes total → 1 absorb block.
static void keccak512_64(thread uint mix[16]) {
    ulong st[25];
    for (int i = 0; i < 25; i++) st[i] = 0;
    // Lanes 0..7 = bytes 0..63 (the 64-byte input)
    for (int i = 0; i < 8; i++) {
        ulong lo = (ulong)mix[i*2 + 0];
        ulong hi = (ulong)mix[i*2 + 1];
        st[i] = lo | (hi << 32);
    }
    // Lane 8: 0x01 at byte 64, 0x80 at byte 71 → little-endian = 0x8000000000000001
    st[8] = 0x8000000000000001UL;
    keccakf(st);
    // Squeeze 64 bytes from lanes 0..7
    for (int i = 0; i < 8; i++) {
        mix[i*2 + 0] = (uint)(st[i] & 0xFFFFFFFFUL);
        mix[i*2 + 1] = (uint)(st[i] >> 32);
    }
}

// FNV-1 hash (NOT fnv1a) — ethash uses plain FNV.
inline uint fnv1(uint a, uint b) {
    return (a * 0x01000193u) ^ b;
}

// fill_dag_at_index — each thread computes one 64-byte DAG item from the light cache.
//
// Algorithm (ethash spec):
//   mix = cache[i mod n]   (16 uint32)
//   mix[0] ^= i
//   mix = keccak512(mix)
//   for j in 0..256:
//       parent_idx = fnv1(i ^ j, mix[j % 16]) mod n
//       mix = fnv1_pairwise(mix, cache[parent_idx])
//   mix = keccak512(mix)
//   dag[i] = mix
kernel void fill_dag_at_index(
    constant uint* light_cache       [[ buffer(0) ]],
    device   uint* dag_buffer        [[ buffer(1) ]],
    constant uint& dag_num_items     [[ buffer(2) ]],
    constant uint& cache_num_nodes   [[ buffer(3) ]],
    constant uint& dag_item_offset   [[ buffer(4) ]],
    uint tid                         [[ thread_position_in_grid ]]
) {
    uint i = tid + dag_item_offset;
    if (i >= dag_num_items) return;

    uint mix[16];
    uint cache_idx = i % cache_num_nodes;
    for (int k = 0; k < 16; k++)
        mix[k] = light_cache[cache_idx * 16 + k];

    mix[0] ^= i;
    keccak512_64(mix);

    // 512 parent-folding rounds (Ravencoin KawPow spec — full_dataset_item_parents=512).
    // Standard ethash uses 256; Ravencoin doubled it. This is what controls whether the
    // pool's reference hash agrees with ours.
    for (uint j = 0; j < 512u; j++) {
        uint h = fnv1(i ^ j, mix[j & 15]);
        uint parent_idx = h % cache_num_nodes;
        for (int k = 0; k < 16; k++)
            mix[k] = fnv1(mix[k], light_cache[parent_idx * 16 + k]);
    }

    keccak512_64(mix);

    for (int k = 0; k < 16; k++)
        dag_buffer[i * 16 + k] = mix[k];
}
