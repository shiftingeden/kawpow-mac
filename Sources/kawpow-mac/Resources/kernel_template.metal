#include <metal_stdlib>
using namespace metal;
#define GROUP_SIZE 256
#define GROUP_SHARE (GROUP_SIZE / 16)
#define PROGPOW_LANES 16
#define PROGPOW_REGS 32
#define PROGPOW_DAG_LOADS 4
#define PROGPOW_CACHE_WORDS 4096
#define PROGPOW_CNT_DAG 64
#define PROGPOW_CNT_MATH 18
#define MAX_OUTPUTS 63U
#define HASHES_PER_GROUP (GROUP_SIZE / PROGPOW_LANES)
#define FNV_PRIME 0x1000193
#define FNV_OFFSET_BASIS 0x811c9dc5
typedef struct {unsigned int s[PROGPOW_DAG_LOADS];} dag_t;
//-------------------------------------------------------------------------------------
//covered under apache license
//https://github.com/ifdefelse/proghash/blob/master/lib/ethash/keccakf800.c
constant unsigned int ravencoin_rndc[15]={
        0x00000072,
        0x00000041,
        0x00000056,
        0x00000045,
        0x0000004E,
        0x00000043,
        0x0000004F,
        0x00000049,
        0x0000004E,
        0x0000004B,
        0x00000041,
        0x00000057,
        0x00000050,
        0x0000004F,
        0x00000057,
};
constant unsigned int keccakf_rndc[24]={0x00000001,0x00008082,0x0000808a,0x80008000,
    0x0000808b,0x80000001,0x80008081,0x00008009,0x0000008a,0x00000088,0x80008009,0x8000000a,
    0x8000808b,0x0000008b,0x00008089,0x00008003,0x00008002,0x00000080,0x0000800a,0x8000000a,
    0x80008081,0x00008080,0x80000001,0x80008008};
#define ROTL32(x, n) rotate((x), (unsigned int)(n))
#define ROTR32(x, n) rotate((x), (unsigned int)(32-n))
void keccak_f800_round(unsigned int st[25],const int r)
{
    const unsigned int keccakf_rotc[24]={
        1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
        const unsigned int keccakf_piln[24]={
            10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};
            unsigned int t,bc[5];
            for (int i=0; i<5; i++)
                bc[i]=st[i]^st[i+5]^st[i+10]^st[i+15]^st[i+20];
            for (int i=0; i<5; i++)
            {
                t=bc[(i+4) % 5] ^ ROTL32(bc[(i+1) % 5],1u);
                for (unsigned int j=0; j<25; j+=5)
                    st[j+i] ^= t;
            }
            t=st[1];
            for (int i=0; i<24; i++)
            {
                unsigned int j=keccakf_piln[i];
                bc[0]=st[j];
                st[j]= ROTL32(t,keccakf_rotc[i]);
                t=bc[0];
            }
            for (unsigned int j=0; j<25; j+=5)
            {
                for (int i=0; i<5; i++)
                    bc[i]=st[j+i];
                for (int i=0; i<5; i++)
                    st[j+i] ^= (~bc[(i+1) % 5])&bc[(i+2) % 5];
            }
            st[0] ^= keccakf_rndc[r];
}
//-------------------------------------------------------------------------------------
void keccak_f800(thread unsigned int* st)
{
    for (int r=0; r<22; r++) {
        keccak_f800_round(st,r);
    }
}
#define fnv1a(h, d) (h = (h ^ d) * FNV_PRIME)
//-------------------------------------------------------------------------------------
typedef struct
{
    unsigned int z,w,jsr,jcong;
} kiss99_t;
unsigned int kiss99(thread kiss99_t* st)
{
    st->z=36969*(st->z&65535)+(st->z>>16);
    st->w=18000*(st->w&65535)+(st->w>>16);
    unsigned int MWC=((st->z<<16)+st->w);
    st->jsr ^= (st->jsr<<17);
    st->jsr ^= (st->jsr>>13);
    st->jsr ^= (st->jsr<<5);
    st->jcong=69069*st->jcong+1234567;
    return ((MWC^st->jcong)+st->jsr);
}
void fill_mix(threadgroup unsigned int* seed,unsigned int lane_id, thread unsigned int* a_mix)
{
    unsigned int fnv_hash=FNV_OFFSET_BASIS;
    kiss99_t st;
    st.z=fnv1a(fnv_hash,seed[0]);
    st.w=fnv1a(fnv_hash,seed[1]);
    st.jsr=fnv1a(fnv_hash,lane_id);
    st.jcong=fnv1a(fnv_hash,lane_id);
    for (int i=0; i<PROGPOW_REGS; i++)
        a_mix[i]=kiss99(&st);
}
//-------------------------------------------------------------------------------------
typedef struct
{
    unsigned int uint32s[PROGPOW_LANES];
} shuffle_t;
typedef struct
{
    unsigned int uint32s[32/sizeof(unsigned int)];
} hash32_t;
kernel void search(
                   constant dag_t * g_dag,
                   constant uint *job_blob,
                   device uint *results,
                   device atomic_uint *resultsIndex,
                   device uint *stop,
                   constant uint &baseNonce,
                   constant uchar *d,
                   constant uchar *jb,
                   uint nonceOffset [[thread_position_in_grid]],
                   uint position_in_threadgroup [[thread_position_in_threadgroup]]
                )
{
    const unsigned int lid = position_in_threadgroup;
    const unsigned int gid =  baseNonce + nonceOffset;
    unsigned long target = TARGET_REPLACE
    unsigned long PROGPOW_DAG_ELEMENTS = PROGPOW_DAG_ELEMENTS_REPLACE

    if(stop[0]) {
        return;
    }

    threadgroup shuffle_t share[HASHES_PER_GROUP];
    threadgroup unsigned int c_dag[PROGPOW_CACHE_WORDS];
    const unsigned int lane_id = lid & (PROGPOW_LANES-1);
    const unsigned int group_id = lid / PROGPOW_LANES;
    for (unsigned int word = lid * PROGPOW_DAG_LOADS; word<PROGPOW_CACHE_WORDS; word+=GROUP_SIZE*PROGPOW_DAG_LOADS)
    {
        dag_t load=g_dag[word/PROGPOW_DAG_LOADS];
        for (int i=0; i<PROGPOW_DAG_LOADS; i++)
            c_dag[word+i]=load.s[i];
    }

    hash32_t digest;
    unsigned int state2[8];
    unsigned int state_a[25];
    for (int i=0; i<10; i++)
        state_a[i]=job_blob[i];
    state_a[8]=gid;
    for (int i=10; i<25; i++)
        state_a[i]=ravencoin_rndc[i-10];
    keccak_f800(state_a);
    for (int i=0; i<8; i++)
        state2[i]=state_a[i];

    for (unsigned int h=0; h<PROGPOW_LANES; h++)
    {
        unsigned int the_mix[PROGPOW_REGS];
        if(lane_id==h) {
            share[group_id].uint32s[0]=state2[0];
            share[group_id].uint32s[1]=state2[1];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        fill_mix(share[group_id].uint32s,lane_id,the_mix);
        for (unsigned int loop=0; loop<PROGPOW_CNT_DAG; ++loop)
        {
            if(lane_id==(loop % PROGPOW_LANES))
                share[0].uint32s[group_id]=the_mix[0];
            threadgroup_barrier(mem_flags::mem_threadgroup);
            unsigned int offset=share[0].uint32s[group_id];
            offset %= PROGPOW_DAG_ELEMENTS;
            offset=offset*PROGPOW_LANES+(lane_id^loop) % PROGPOW_LANES;
            dag_t data_dag=g_dag[offset];
            threadgroup_barrier(mem_flags::mem_threadgroup);
            unsigned int data;
                  INCLUDE_PROGPOW_RANDOM_MATH
            threadgroup_barrier(mem_flags::mem_threadgroup);
                INCLUDE_PROGPOW_DATA_LOADS
        }
        unsigned int mix_hash=FNV_OFFSET_BASIS;
        for (int i=0; i<PROGPOW_REGS; i++)
            fnv1a(mix_hash,the_mix[i]);
        hash32_t digest_temp;
        for (int i=0; i<8; i++)
            digest_temp.uint32s[i]=FNV_OFFSET_BASIS;
        share[group_id].uint32s[lane_id]=mix_hash;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (int i=0; i<PROGPOW_LANES; i++)
        {
            fnv1a(digest_temp.uint32s[i % 8],share[group_id].uint32s[i]);
        }
        if(h==lane_id)
        {
            digest=digest_temp;
        }
    }

    unsigned int mix_hash_digest[8];
    unsigned long result;

    unsigned int state_b[25]={0x0};
    for (int i=0; i<8; i++)
        state_b[i]=state2[i];
    for (int i=8; i<16; i++)
    {
        state_b[i]=digest.uint32s[i-8];
        mix_hash_digest[i-8] = digest.uint32s[i-8];
    }
    for (int i=16; i<25; i++)
        state_b[i]=ravencoin_rndc[i-16];
    keccak_f800(state_b);
    unsigned long res=(unsigned long)state_b[1]<<32|state_b[0];

    unsigned long x = res;
    x = (x & 0x00000000FFFFFFFF) << 32 | (x & 0xFFFFFFFF00000000) >> 32;
    x = (x & 0x0000FFFF0000FFFF) << 16 | (x & 0xFFFF0000FFFF0000) >> 16;
    x = (x & 0x00FF00FF00FF00FF) << 8  | (x & 0xFF00FF00FF00FF00) >> 8;
    result = x;

    if(result <= target)
    {
        // Only the FIRST winning thread in this dispatch writes its result.
        // Without this guard two threads can both reach the result-write block
        // and interleave: thread A's gid ends up paired with thread B's
        // mix_hash bytes → host submits a Frankenstein share → pool replies
        // "Invalid share" because its computed mix_hash for our nonce does
        // not match the one we sent. The atomic counter (resultsIndex) is
        // already supplied as a kernel argument; host code zeroes it per
        // dispatch.
        uint claimed = atomic_fetch_add_explicit(resultsIndex, 1u, memory_order_relaxed);
        if (claimed == 0u) {
            results[0] = gid;
            results[1] = mix_hash_digest[0];
            results[2] = mix_hash_digest[1];
            results[3] = mix_hash_digest[2];
            results[4] = mix_hash_digest[3];
            results[5] = mix_hash_digest[4];
            results[6] = mix_hash_digest[5];
            results[7] = mix_hash_digest[6];
            results[8] = mix_hash_digest[7];
            stop[0] = 1u;
        }
    }
}
