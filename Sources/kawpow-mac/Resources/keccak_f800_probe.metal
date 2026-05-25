#include <metal_stdlib>
using namespace metal;

// Standalone keccak-f[800] probe — used by Keccak800SelfTest.swift to cross-
// check the Swift CPU implementation against the same code path the search
// kernel uses. NOT linked into the production search kernel.

constant unsigned int keccakf_rndc[24] = {
    0x00000001, 0x00008082, 0x0000808a, 0x80008000,
    0x0000808b, 0x80000001, 0x80008081, 0x00008009,
    0x0000008a, 0x00000088, 0x80008009, 0x8000000a,
    0x8000808b, 0x0000008b, 0x00008089, 0x00008003,
    0x00008002, 0x00000080, 0x0000800a, 0x8000000a,
    0x80008081, 0x00008080, 0x80000001, 0x80008008
};

#define ROTL32(x, n) rotate((x), (unsigned int)(n))

static void keccak_f800_round_probe(thread unsigned int st[25], const int r) {
    const unsigned int keccakf_rotc[24] = {
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44
    };
    const unsigned int keccakf_piln[24] = {
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1
    };
    unsigned int t, bc[5];
    for (int i = 0; i < 5; i++)
        bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20];
    for (int i = 0; i < 5; i++) {
        t = bc[(i+4) % 5] ^ ROTL32(bc[(i+1) % 5], 1u);
        for (unsigned int j = 0; j < 25; j += 5)
            st[j+i] ^= t;
    }
    t = st[1];
    for (int i = 0; i < 24; i++) {
        unsigned int j = keccakf_piln[i];
        bc[0] = st[j];
        st[j] = ROTL32(t, keccakf_rotc[i]);
        t = bc[0];
    }
    for (unsigned int j = 0; j < 25; j += 5) {
        for (int i = 0; i < 5; i++) bc[i] = st[j+i];
        for (int i = 0; i < 5; i++) st[j+i] ^= (~bc[(i+1) % 5]) & bc[(i+2) % 5];
    }
    st[0] ^= keccakf_rndc[r];
}

// Read 25 uint32 from input, run keccak_f800 (22 rounds), write back to output.
kernel void keccak_f800_probe(
    constant uint* in_state    [[ buffer(0) ]],
    device   uint* out_state   [[ buffer(1) ]],
    uint tid                   [[ thread_position_in_grid ]]
) {
    if (tid != 0) return;
    unsigned int st[25];
    for (int i = 0; i < 25; i++) st[i] = in_state[i];
    for (int r = 0; r < 22; r++) keccak_f800_round_probe(st, r);
    for (int i = 0; i < 25; i++) out_state[i] = st[i];
}
