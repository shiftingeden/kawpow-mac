# Long-form (HackerNews "Show HN" body, blog post)

Suggested title:
> **Show HN: Five bugs between a closed-source crypto miner and a working one**

Or the simpler:
> **Show HN: An open-source KawPow miner for Apple Silicon Macs**

---

## Body

The macOS app *Unmineable-Mac* lets you mine cryptocurrency on a Mac via
the [unMineable](https://unmineable.com) pool. It ships a closed-source
GPU miner called `thinminerpro` for the KawPow algorithm (Ravencoin's
ProgPoW variant). On M3 and newer Apple Silicon chips that miner
*appears* to work — hashrate shows up, GPU usage is high — but the pool
rejects every share as `Invalid share`. No accepted shares means no
payouts. The source isn't public, so you can't patch it.

I spent a weekend disassembling the binary, extracting its Metal kernel,
and rewriting the host code from scratch in Swift to find out exactly
what was wrong. The result is
[`kawpow-mac`](https://github.com/shiftingeden/kawpow-mac), now the
first open-source KawPow miner verified accepted by unMineable on M3+
Apple Silicon.

It took finding **five separate algorithmic bugs** before the pool
accepted a single share. In order of discovery:

1. **Race condition** writing the result tuple from multiple GPU
   threads. Two threads could both pass the target check and interleave
   their writes, so the host ended up submitting one thread's nonce
   paired with another thread's mix-hash. Atomic guard on a results-
   index counter fixes it.

2. **Fisher-Yates shuffle order wrong** in the per-epoch PRNG code
   generation. The ProgPoW spec interleaves the `mix_seq_dst` and
   `mix_seq_cache` shuffles in one loop iterating `i = N-1 → 1`. We
   shuffled them sequentially. Same total number of `rnd()` calls, but
   consumed in the wrong order — every downstream math/merge op read a
   shifted slice of the kiss99 stream.

3. **Math op source generation used two `rnd()` calls** when the spec
   uses one. The reference computes `src_rnd = rnd() % (REGS *
   (REGS-1))` and derives `src1`, `src2` from that single value, with
   `if (src2 >= src1) ++src2` to guarantee they're distinct. We used
   two separate `rnd()` calls and skipped the distinctness check.
   Every extra `rnd()` shifts everything after it.

4. **`PROGPOW_DAG_ELEMENTS` was 4× too small.** The kernel computes
   `offset = offset * PROGPOW_LANES + (lane_id ^ loop) % PROGPOW_LANES`.
   With g_dag in 16-byte units this means the kernel can address
   `PROGPOW_DAG_ELEMENTS * 256` bytes — so the right value is
   `total_DAG_bytes / 256 = items / 4`. We were passing `items / 16`,
   so the kernel only accessed the first quarter of the DAG.

5. **The big one**: Ravencoin's KawPow uses `full_dataset_item_parents
   = 512`, not the standard ethash value of 256. Every single DAG item
   we computed had half the FNV folding rounds the pool expected. The
   CPU↔kernel cross-check passed because *both* used the wrong constant
   — they agreed on a wrong answer. Only the official Ravencoin test
   vectors exposed the spec drift.

After fix #5, the algorithm passes Ravencoin's official
`progpow_test_vectors.hpp` bitwise (block 0 + block 49, both mix_hash
and final_hash). The first share submitted to the live pool came back
accepted on the first try.

The full journey is documented in
[BUGS_AND_FIXES.md](https://github.com/shiftingeden/kawpow-mac/blob/main/BUGS_AND_FIXES.md),
with git history showing each bug found, the diagnostic that revealed
it, and the one-line code fix. There's also a CLI subcommand for each
diagnostic so anyone can reproduce:

- `kawpow-mac verify-vectors` — runs Ravencoin's official test vectors
  against the CPU light-eval impl. Passes.
- `kawpow-mac kernel-vs-cpu` — runs the Metal kernel and CPU light-eval
  on the same input, compares mix_hash bitwise.
- `kawpow-mac dag-crosscheck` — builds a small DAG with the GPU kernel,
  recomputes selected items on CPU, compares.
- `kawpow-mac dump-ops <progSeed>` — prints the generated
  RANDOM_MATH / DATA_LOADS source. Used to diff against the canonical
  kawpowminer reference.

Stack: Swift Package Manager + Metal, ~1500 LOC. Keccak-256, Keccak-512,
and Keccak-f[800] all written from scratch and cross-verified — Apple's
CryptoKit doesn't include Keccak (only NIST SHA-3, which has different
padding).

A side note on performance: KawPow is memory-bandwidth-limited rather
than compute-limited. Each inner-loop iteration does multiple reads
from a multi-GB DAG. M4 and M5 base configs have similar unified-memory
bandwidth (~120 GB/s) and consequently get similar hashrate (~2.7 MH/s
sustained on M5 MacBook Air, throttling down from a higher cold-start
peak). Optimizing further would mean overlapping multiple batches
in-flight, which has its own correctness implications with the
race-fix atomic — left as future work.

If you want to try it: the README has step-by-step instructions for
either the standalone miner binary or the full Unmineable-Mac app. As
always: mining on a Mac is not profitable. This is a "what can the
hardware actually do" exercise plus a salvage of a useful open-source
GUI for users who picked the wrong hardware to mine with.

---

## Things to anticipate / be ready to respond to on HN

- *"Mining on Apple Silicon is silly economically"* — yes, agree, that's
  not the point. Story is about reverse-engineering + spec compliance.
- *"Why didn't you just patch the binary?"* — closed-source, no symbols,
  not feasible. Easier to rewrite the host.
- *"Did you contribute this back to kawpowminer / Ravencoin?"* — could
  do; happy for someone to port it (the kawpow-mac Metal kernel is
  pretty self-contained).
- *"What's `full_dataset_item_parents=512` about?"* — Ravencoin changed
  it from ethash's 256, apparently to make the DAG more expensive to
  generate per share. Documented in their `src/crypto/ethash/lib/
  ethash/ethash.cpp`.
- *"How did you find bug #5?"* — kept getting "Invalid share" with all
  other bugs fixed; finally found Ravencoin's official test vector file
  and ran it against our impl. Failure pointed to DAG values, then a
  grep on `ravencoin_ethash.cpp` for "parents" surfaced the constant.
