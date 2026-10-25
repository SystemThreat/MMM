// Copyright (c) 2026 The xCoin developers
// Distributed under the MIT software license, see the accompanying file LICENSE.
//
// MetalDAG hashing core, shared by the CPU (tests, share re-verification, the CPU test
// backend) and the CUDA kernels. Every function here compiles as plain C++ and as CUDA
// __host__ __device__ code, so the code the GPU runs is the code the tests check against
// the xCoin node (src/metaldag/metaldag.cpp in the node source).
//
// Data is handled as little-endian 32-bit words, as the node reads it (ReadLE32):
//   cache   : n_cache items of 16 words (64 bytes)
//   DAG     : n_entries entries of 32 words (128 bytes) = 2 * n_entries items of 64 bytes
//   hashes  : 8 words; word 7 is the most significant when the hash is read as a number
#ifndef XCOIN_METALDAG_CORE_H
#define XCOIN_METALDAG_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __CUDACC__
#define MD_HD __host__ __device__ __forceinline__
#else
#define MD_HD inline
#endif

// Fully unroll a fixed-length loop in GPU code, so arrays it indexes stay in registers.
#ifdef __CUDA_ARCH__
#define MD_UNROLL _Pragma("unroll")
#else
#define MD_UNROLL
#endif

namespace md {

// Ethash-family constants, identical to the node's.
static constexpr uint32_t DATASET_PARENTS = 256;
static constexpr uint32_t ACCESSES = 64;

MD_HD uint64_t rol64(uint64_t x, int n) { return (x << n) | (x >> (64 - n)); }

MD_HD uint32_t fnv(uint32_t a, uint32_t b) { return (a * 0x01000193u) ^ b; }

// ───────────── Keccak-f[1600], original Keccak (0x01 padding, as Ethash) ─────────────
// Written out with constant indices so a GPU keeps the whole state in registers.

#define MD_KECCAK_RC_VALUES \
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL, \
    0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL, \
    0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL, \
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL, \
    0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL, \
    0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
// One table for the host, one in GPU constant memory. Both are declared in both CUDA
// compilation passes (a device variable must not depend on __CUDA_ARCH__); the HD code
// below picks the one for the side it runs on.
static const uint64_t MD_KECCAK_RC_HOST[24] = {MD_KECCAK_RC_VALUES};
#ifdef __CUDACC__
__constant__ uint64_t MD_KECCAK_RC_DEV[24] = {MD_KECCAK_RC_VALUES};
#endif
#ifdef __CUDA_ARCH__
#define MD_KECCAK_RC MD_KECCAK_RC_DEV
#else
#define MD_KECCAK_RC MD_KECCAK_RC_HOST
#endif

MD_HD void keccakf(uint64_t s[25])
{
#ifdef __CUDA_ARCH__
#pragma unroll 2
#endif
    for (int r = 0; r < 24; r++) {
        // theta
        const uint64_t c0 = s[0] ^ s[5] ^ s[10] ^ s[15] ^ s[20];
        const uint64_t c1 = s[1] ^ s[6] ^ s[11] ^ s[16] ^ s[21];
        const uint64_t c2 = s[2] ^ s[7] ^ s[12] ^ s[17] ^ s[22];
        const uint64_t c3 = s[3] ^ s[8] ^ s[13] ^ s[18] ^ s[23];
        const uint64_t c4 = s[4] ^ s[9] ^ s[14] ^ s[19] ^ s[24];
        const uint64_t d0 = c4 ^ rol64(c1, 1);
        const uint64_t d1 = c0 ^ rol64(c2, 1);
        const uint64_t d2 = c1 ^ rol64(c3, 1);
        const uint64_t d3 = c2 ^ rol64(c4, 1);
        const uint64_t d4 = c3 ^ rol64(c0, 1);
        s[0] ^= d0; s[5] ^= d0; s[10] ^= d0; s[15] ^= d0; s[20] ^= d0;
        s[1] ^= d1; s[6] ^= d1; s[11] ^= d1; s[16] ^= d1; s[21] ^= d1;
        s[2] ^= d2; s[7] ^= d2; s[12] ^= d2; s[17] ^= d2; s[22] ^= d2;
        s[3] ^= d3; s[8] ^= d3; s[13] ^= d3; s[18] ^= d3; s[23] ^= d3;
        s[4] ^= d4; s[9] ^= d4; s[14] ^= d4; s[19] ^= d4; s[24] ^= d4;
        // rho + pi (the node's KECCAK_PI / KECCAK_ROT loop, unrolled)
        uint64_t b[25];
        b[0] = s[0];
        b[10] = rol64(s[1], 1);   b[7] = rol64(s[10], 3);   b[11] = rol64(s[7], 6);
        b[17] = rol64(s[11], 10); b[18] = rol64(s[17], 15); b[3] = rol64(s[18], 21);
        b[5] = rol64(s[3], 28);   b[16] = rol64(s[5], 36);  b[8] = rol64(s[16], 45);
        b[21] = rol64(s[8], 55);  b[24] = rol64(s[21], 2);  b[4] = rol64(s[24], 14);
        b[15] = rol64(s[4], 27);  b[23] = rol64(s[15], 41); b[19] = rol64(s[23], 56);
        b[13] = rol64(s[19], 8);  b[12] = rol64(s[13], 25); b[2] = rol64(s[12], 43);
        b[20] = rol64(s[2], 62);  b[14] = rol64(s[20], 18); b[22] = rol64(s[14], 39);
        b[9] = rol64(s[22], 61);  b[6] = rol64(s[9], 20);   b[1] = rol64(s[6], 44);
        // chi
#define MD_CHI_ROW(j)                                     \
        s[j + 0] = b[j + 0] ^ (~b[j + 1] & b[j + 2]);     \
        s[j + 1] = b[j + 1] ^ (~b[j + 2] & b[j + 3]);     \
        s[j + 2] = b[j + 2] ^ (~b[j + 3] & b[j + 4]);     \
        s[j + 3] = b[j + 3] ^ (~b[j + 4] & b[j + 0]);     \
        s[j + 4] = b[j + 4] ^ (~b[j + 0] & b[j + 1]);
        MD_CHI_ROW(0) MD_CHI_ROW(5) MD_CHI_ROW(10) MD_CHI_ROW(15) MD_CHI_ROW(20)
#undef MD_CHI_ROW
        // iota
        s[0] ^= MD_KECCAK_RC[r];
    }
}

MD_HD uint64_t md_lane(const uint32_t* w, int k) { return (uint64_t)w[2 * k] | ((uint64_t)w[2 * k + 1] << 32); }

// keccak512 of exactly 64 bytes (16 words). in and out may be the same array.
MD_HD void keccak512_64w(const uint32_t in[16], uint32_t out[16])
{
    uint64_t s[25];
    MD_UNROLL
    for (int k = 0; k < 8; k++) s[k] = md_lane(in, k);
    s[8] = 0x8000000000000001ULL; // 0x01 pad at byte 64, 0x80 at byte 71 (rate 72)
    MD_UNROLL
    for (int k = 9; k < 25; k++) s[k] = 0;
    keccakf(s);
    MD_UNROLL
    for (int k = 0; k < 8; k++) { out[2 * k] = (uint32_t)s[k]; out[2 * k + 1] = (uint32_t)(s[k] >> 32); }
}

// keccak512 of exactly 40 bytes (10 words): header hash (32 bytes) + nonce (8 bytes LE).
MD_HD void keccak512_40w(const uint32_t in[10], uint32_t out[16])
{
    uint64_t s[25];
    MD_UNROLL
    for (int k = 0; k < 5; k++) s[k] = md_lane(in, k);
    s[5] = 0x01ULL;                // pad at byte 40
    s[6] = 0; s[7] = 0;
    s[8] = 0x8000000000000000ULL;  // 0x80 at byte 71
    MD_UNROLL
    for (int k = 9; k < 25; k++) s[k] = 0;
    keccakf(s);
    MD_UNROLL
    for (int k = 0; k < 8; k++) { out[2 * k] = (uint32_t)s[k]; out[2 * k + 1] = (uint32_t)(s[k] >> 32); }
}

// keccak256 of exactly 96 bytes (24 words): s (64 bytes) + cmix (32 bytes).
MD_HD void keccak256_96w(const uint32_t in[24], uint32_t out[8])
{
    uint64_t s[25];
    MD_UNROLL
    for (int k = 0; k < 12; k++) s[k] = md_lane(in, k);
    s[12] = 0x01ULL;               // pad at byte 96
    MD_UNROLL
    for (int k = 13; k < 16; k++) s[k] = 0;
    s[16] = 0x8000000000000000ULL; // 0x80 at byte 135 (rate 136)
    MD_UNROLL
    for (int k = 17; k < 25; k++) s[k] = 0;
    keccakf(s);
    MD_UNROLL
    for (int k = 0; k < 4; k++) { out[2 * k] = (uint32_t)s[k]; out[2 * k + 1] = (uint32_t)(s[k] >> 32); }
}

// ───────────── DAG item (calc_dataset_item) ─────────────
// Item i (64-bit index, its low 32 bits in the mixing, as the node) from the cache.
MD_HD void dag_item(const uint32_t* cache, uint32_t n_cache, uint64_t i, uint32_t out[16])
{
    const uint32_t i32 = (uint32_t)i;
    const uint32_t* c0 = cache + (size_t)(i % n_cache) * 16;
    uint32_t mix[16];
    MD_UNROLL
    for (int k = 0; k < 16; k++) mix[k] = c0[k];
    mix[0] ^= i32;
    keccak512_64w(mix, mix);
    for (uint32_t j0 = 0; j0 < DATASET_PARENTS; j0 += 16) {
#ifdef __CUDA_ARCH__
#pragma unroll
#endif
        for (uint32_t jj = 0; jj < 16; jj++) {   // mix[j % 16] with a constant index
            const uint32_t ci = fnv(i32 ^ (j0 + jj), mix[jj]) % n_cache;
            const uint32_t* c = cache + (size_t)ci * 16;
#ifdef __CUDA_ARCH__
            const uint4* c4 = reinterpret_cast<const uint4*>(c);
#pragma unroll
            for (int q = 0; q < 4; q++) {
                const uint4 d = c4[q];
                mix[4 * q] = fnv(mix[4 * q], d.x);
                mix[4 * q + 1] = fnv(mix[4 * q + 1], d.y);
                mix[4 * q + 2] = fnv(mix[4 * q + 2], d.z);
                mix[4 * q + 3] = fnv(mix[4 * q + 3], d.w);
            }
#else
            MD_UNROLL
            for (int k = 0; k < 16; k++) mix[k] = fnv(mix[k], c[k]);
#endif
        }
    }
    keccak512_64w(mix, out);
}

// ───────────── hashimoto ─────────────
// s = keccak512(header hash || nonce LE). Returns s as 16 words.
MD_HD void seed_hash(const uint32_t hh[8], uint64_t nonce, uint32_t s[16])
{
    uint32_t in10[10];
    MD_UNROLL
    for (int k = 0; k < 8; k++) in10[k] = hh[k];
    in10[8] = (uint32_t)nonce;
    in10[9] = (uint32_t)(nonce >> 32);
    keccak512_40w(in10, s);
}

// keccak256(s || cmix), where cmix compresses the 32-word mix.
MD_HD void final_hash(const uint32_t s[16], const uint32_t mix[32], uint32_t out[8])
{
    uint32_t fin[24];
    MD_UNROLL
    for (int k = 0; k < 16; k++) fin[k] = s[k];
    MD_UNROLL
    for (int k = 0; k < 8; k++)
        fin[16 + k] = fnv(fnv(fnv(mix[4 * k], mix[4 * k + 1]), mix[4 * k + 2]), mix[4 * k + 3]);
    keccak256_96w(fin, out);
}

// Full-DAG hashimoto (the mining path): dag holds n_entries 128-byte entries.
MD_HD void hashimoto_full(const uint32_t* dag, uint32_t n_entries, const uint32_t hh[8], uint64_t nonce, uint32_t out[8])
{
    uint32_t s[16];
    seed_hash(hh, nonce, s);
    uint32_t mix[32];
    MD_UNROLL
    for (int k = 0; k < 32; k++) mix[k] = s[k % 16];
    MD_UNROLL
    for (uint32_t i0 = 0; i0 < ACCESSES; i0 += 32) {
        MD_UNROLL
        for (uint32_t ii = 0; ii < 32; ii++) {   // mix[i % 32] with a constant index
            const uint32_t p = fnv((i0 + ii) ^ s[0], mix[ii]) % n_entries;
            const uint32_t* e = dag + (size_t)p * 32;
#ifdef __CUDA_ARCH__
            const uint4* e4 = reinterpret_cast<const uint4*>(e);
#pragma unroll
            for (int q = 0; q < 8; q++) {
                const uint4 d = e4[q];
                mix[4 * q] = fnv(mix[4 * q], d.x);
                mix[4 * q + 1] = fnv(mix[4 * q + 1], d.y);
                mix[4 * q + 2] = fnv(mix[4 * q + 2], d.z);
                mix[4 * q + 3] = fnv(mix[4 * q + 3], d.w);
            }
#else
            MD_UNROLL
            for (int k = 0; k < 32; k++) mix[k] = fnv(mix[k], e[k]);
#endif
        }
    }
    final_hash(s, mix, out);
}

// Light hashimoto (verification): derives the 128 DAG items it touches from the cache.
// n_entries = full DAG bytes / 128. Slow (milliseconds); used to re-check GPU results.
MD_HD void hashimoto_light(const uint32_t* cache, uint32_t n_cache, uint32_t n_entries, const uint32_t hh[8], uint64_t nonce, uint32_t out[8])
{
    uint32_t s[16];
    seed_hash(hh, nonce, s);
    uint32_t mix[32];
    MD_UNROLL
    for (int k = 0; k < 32; k++) mix[k] = s[k % 16];
    for (uint32_t i = 0; i < ACCESSES; i++) {
        const uint64_t p = (uint64_t)(fnv(i ^ s[0], mix[i % 32]) % n_entries) * 2;
        uint32_t item[16];
        dag_item(cache, n_cache, p, item);
        MD_UNROLL
        for (int k = 0; k < 16; k++) mix[k] = fnv(mix[k], item[k]);
        dag_item(cache, n_cache, p + 1, item);
        MD_UNROLL
        for (int k = 0; k < 16; k++) mix[16 + k] = fnv(mix[16 + k], item[k]);
    }
    final_hash(s, mix, out);
}

// hash <= target. hash: 8 words, [7] most significant. target: 8 words, [0] most significant
// (the order the Metal miner uses). Equal counts as meeting it, as in the node and the pool.
MD_HD bool meets_target(const uint32_t hash[8], const uint32_t target_msw_first[8])
{
    MD_UNROLL
    for (int k = 0; k < 8; k++) {
        const uint32_t h = hash[7 - k], t = target_msw_first[k];
        if (h != t) return h < t;
    }
    return true;
}

} // namespace md

#endif // XCOIN_METALDAG_CORE_H
