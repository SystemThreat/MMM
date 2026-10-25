// md_cpu.cpp: MetalDAG mining on the CPU (see md_cpu.h). Each nonce's 64 DAG reads depend on one another, so a
// thread hashing one nonce at a time spends nearly all of it waiting on memory (0.42 MH/s on a 12-core M3 Pro).
// hashimoto_lanes() hashes LANES nonces in step and prefetches every lane's next read before using any, so many reads
// are in flight per thread (5.99 MH/s on the same Mac; with MMM's GPU mining at the same time, 5.35 MH/s while the GPU
// went from 9.08 to 8.36). The result is the same hash as md::hashimoto_full, which xcoin-cuda-miner checks against
// the xCoin node on real mainnet blocks; md_cpu_selfcheck() and MMM's per-epoch GPU cross-check confirm it here.
#include "md_cpu.h"
#include "metaldag_core.h"

#include <algorithm>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace {

constexpr int LANES = 32;

void hashimoto_lanes(const uint32_t* dag, uint32_t n_entries, const uint32_t hh[8], uint32_t nonce0, uint32_t out[LANES][8])
{
    uint32_t s[LANES][16], mix[LANES][32];
    for (int l = 0; l < LANES; l++) {
        md::seed_hash(hh, (uint64_t)(uint32_t)(nonce0 + (uint32_t)l), s[l]);
        for (int k = 0; k < 32; k++) mix[l][k] = s[l][k % 16];
    }
    for (uint32_t i = 0; i < md::ACCESSES; i++) {
        const uint32_t* e[LANES];
        for (int l = 0; l < LANES; l++) {
            const uint32_t p = md::fnv(i ^ s[l][0], mix[l][i % 32]) % n_entries;
            e[l] = dag + (size_t)p * 32;
            __builtin_prefetch(e[l]);
            __builtin_prefetch(e[l] + 16);
        }
        for (int l = 0; l < LANES; l++)
            for (int k = 0; k < 32; k++) mix[l][k] = md::fnv(mix[l][k], e[l][k]);
    }
    for (int l = 0; l < LANES; l++) md::final_hash(s[l], mix[l], out[l]);
}

// The GPU kernel's comparison: below when the first differing word, most significant first, is smaller.
bool below(const uint32_t hash[8], const uint32_t target_msw[8])
{
    for (int k = 0; k < 8; k++) {
        const uint32_t h = hash[7 - k], t = target_msw[k];
        if (h != t) return h < t;
    }
    return false;
}

} // namespace

extern "C" int md_cpu_search(const uint32_t* dag, uint32_t n_entries, const uint32_t hh[8], const uint32_t target_msw[8],
                             uint32_t start, uint32_t count, int threads, md_cpu_found* found, int max_found)
{
    if (!dag || n_entries == 0 || count == 0 || max_found <= 0) return 0;
    threads = std::max(1, std::min(threads, 256));
    std::mutex m;
    int n_found = 0;
    auto hit = [&](uint32_t nonce, const uint32_t h[8]) {
        std::lock_guard<std::mutex> lk(m);
        if (n_found < max_found) { found[n_found].nonce = nonce; std::memcpy(found[n_found].hash, h, 32); n_found++; }
    };
    // Whole groups of LANES per thread; the plain path finishes each thread's tail.
    const uint64_t per = ((uint64_t)count + (uint64_t)threads - 1) / (uint64_t)threads;
    std::vector<std::thread> ts;
    for (int t = 0; t < threads; t++) {
        const uint64_t a = per * (uint64_t)t, b = std::min<uint64_t>(count, a + per);
        if (a >= b) break;
        ts.emplace_back([=, &hit] {
            uint64_t k = a;
            for (; k + LANES <= b; k += LANES) {
                uint32_t r[LANES][8];
                hashimoto_lanes(dag, n_entries, hh, start + (uint32_t)k, r);
                for (int l = 0; l < LANES; l++)
                    if (below(r[l], target_msw)) hit(start + (uint32_t)(k + (uint64_t)l), r[l]);
            }
            for (; k < b; k++) {
                uint32_t r[8];
                md::hashimoto_full(dag, n_entries, hh, (uint64_t)(uint32_t)(start + (uint32_t)k), r);
                if (below(r, target_msw)) hit(start + (uint32_t)k, r);
            }
        });
    }
    for (auto& t : ts) t.join();
    return n_found;
}

extern "C" void md_cpu_hash(const uint32_t* dag, uint32_t n_entries, const uint32_t hh[8], uint32_t nonce, uint32_t out[8])
{
    md::hashimoto_full(dag, n_entries, hh, (uint64_t)nonce, out);
}

extern "C" int md_cpu_selfcheck(const uint32_t* dag, uint32_t n_entries, const uint32_t hh[8])
{
    if (!dag || n_entries == 0) return 0;
    for (uint32_t base : {0x5eed0100u, 0xfffffff0u}) {
        for (uint32_t g = 0; g < 2; g++) {
            uint32_t lanes[LANES][8];
            const uint32_t b = base + g * LANES;
            hashimoto_lanes(dag, n_entries, hh, b, lanes);
            for (int l = 0; l < LANES; l++) {
                uint32_t r[8];
                md::hashimoto_full(dag, n_entries, hh, (uint64_t)(uint32_t)(b + (uint32_t)l), r);
                if (std::memcmp(r, lanes[l], sizeof r)) return 0;
            }
        }
    }
    return 1;
}

extern "C" int md_cpu_cores(void)
{
    const unsigned n = std::thread::hardware_concurrency();
    return n ? (int)n : 1;
}
