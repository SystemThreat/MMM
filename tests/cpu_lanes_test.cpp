// The CPU mining module on a synthetic DAG (any data will do: this checks the interleaved path against the plain
// one, the target comparison, nonce wrap-around and thread splitting, not the consensus hash, which
// xcoin-cuda-miner checks against the node and MMM checks against its own GPU on every new DAG).
#include "../Engine/cpu/md_cpu.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

int main()
{
    const uint32_t entries = 1u << 14;                       // 2 MiB of DAG
    std::vector<uint32_t> dag((size_t)entries * 32);
    uint32_t x = 0x9e3779b9u;
    for (auto& w : dag) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; w = x; }
    const uint32_t hh[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    assert(md_cpu_selfcheck(dag.data(), entries, hh) == 1);
    assert(md_cpu_cores() >= 1);

    // An all-ones target: every hash is below it, so the first max_found nonces come back, each with its own hash.
    uint32_t easy[8]; std::memset(easy, 0xff, sizeof easy);
    std::vector<md_cpu_found> f(64);
    for (int threads : {1, 3, 12}) {
        for (uint32_t start : {0u, 1000u, 0xffffffe0u}) {        // the last one wraps past 2^32
            const uint32_t count = 50;                           // not a multiple of the 32 lanes: the tail path too
            const int n = md_cpu_search(dag.data(), entries, hh, easy, start, count, threads, f.data(), 64);
            assert(n == (int)count);
            std::vector<bool> seen(count, false);
            for (int i = 0; i < n; i++) {
                const uint32_t k = f[i].nonce - start;
                assert(k < count && !seen[k]); seen[k] = true;
                uint32_t h[8]; md_cpu_hash(dag.data(), entries, hh, f[i].nonce, h);
                assert(std::memcmp(h, f[i].hash, sizeof h) == 0);
            }
        }
    }
    // A zero target: nothing is below it. max_found caps the output.
    uint32_t zero[8] = {0};
    assert(md_cpu_search(dag.data(), entries, hh, zero, 0, 500, 4, f.data(), 64) == 0);
    assert(md_cpu_search(dag.data(), entries, hh, easy, 0, 500, 4, f.data(), 10) == 10);
    // A target equal to a hash is not met (as in the GPU kernel); one just above it is.
    uint32_t h0[8]; md_cpu_hash(dag.data(), entries, hh, 7, h0);
    uint32_t eq[8]; for (int k = 0; k < 8; k++) eq[k] = h0[7 - k];
    assert(md_cpu_search(dag.data(), entries, hh, eq, 7, 1, 1, f.data(), 64) == 0);
    int k = 7; while (k >= 0 && eq[k] == 0xffffffffu) eq[k--] = 0; assert(k >= 0); eq[k]++;
    assert(md_cpu_search(dag.data(), entries, hh, eq, 7, 1, 1, f.data(), 64) == 1);
    std::puts("cpu lanes: interleaved = plain, targets, wrap-around and threads passed");
    return 0;
}
