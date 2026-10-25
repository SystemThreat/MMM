// md_cpu.h: MetalDAG mining on the CPU, for MMM's GPU + CPU mode. A C interface (the Swift engine imports it as a
// bridging header) over md_cpu.cpp, which hashes with metaldag_core.h from xcoin-cuda-miner (MIT, the xCoin
// developers). The DAG is the one MMM's GPU built in shared memory: n_entries 128-byte entries of 32 words, so the
// CPU reads it in place, with no second copy and no second build.
#ifndef MD_CPU_H
#define MD_CPU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t nonce;
    uint32_t hash[8];   // as the GPU kernel returns it: word 7 is the most significant
} md_cpu_found;

/// Hash nonces start, start + 1, ... (count of them, 32-bit wrapping) on `threads` threads, 32 nonces in step per
/// thread, and write up to max_found of those whose hash is below target_msw (8 words, [0] most significant; equal
/// is not below, as in the GPU kernel). Returns how many were written.
int md_cpu_search(const uint32_t *dag, uint32_t n_entries, const uint32_t hh[8], const uint32_t target_msw[8],
                  uint32_t start, uint32_t count, int threads, md_cpu_found *found, int max_found);

/// The hash of one nonce on the plain path, for the cross-check against the GPU.
void md_cpu_hash(const uint32_t *dag, uint32_t n_entries, const uint32_t hh[8], uint32_t nonce, uint32_t out[8]);

/// 1 when the 32-in-step path equals the plain path for 64 nonces at two bases (one wrapping past 2^32), else 0.
int md_cpu_selfcheck(const uint32_t *dag, uint32_t n_entries, const uint32_t hh[8]);

/// Hardware threads (logical cores).
int md_cpu_cores(void);

#ifdef __cplusplus
}
#endif

#endif
