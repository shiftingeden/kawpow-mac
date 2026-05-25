# kawpow-mac — Bugs Found & Fixes (Working Log)

A record of every bug we found getting a clean KawPow miner working on Apple
Silicon (M3+), and how we fixed each one. Useful for anyone tracing why the
upstream Thinminerpro / similar closed-source miners don't submit accepted
shares on newer Macs.

## Background — the original problem

Unmineable-Mac shipped with [`rezahussain/thinminerpro`](https://github.com/rezahussain/thinminerpro)
for GPU (KawPow) mining. On M3 and newer Apple Silicon chips it displays
a hashrate but **never has a share accepted by the pool**. The repo has
no source (README + binaries only), so we couldn't just patch it.

We disassembled the binary, confirmed its kernel runs correctly on M5
(found a result, no Metal-level errors), then rebuilt the miner from
scratch in Swift + Metal so we'd own the code path. That's `kawpow-mac`.

## How the bugs surfaced

| Symptom | Pool says |
|---|---|
| Local kernel finds a share | (nothing, kernel-internal) |
| Submitted to pool | `[23, "Low difficulty share"]` initially |
| Then later | `[23, "Invalid share"]` |
| Mixed responses for similar inputs | (the race condition) |

"Invalid share" is the strongest signal: the pool ran progpow_hash on
`(header, nonce)` and got a different mix_hash than we sent. Algorithm
divergence somewhere.

## Bug list (chronological)

### 1. Race condition writing results from multiple GPU threads
**Symptom:** Pool gave a mix of `Invalid share` and `Low difficulty share`
for the same algorithm config — non-deterministic.
**Root cause:** The extracted thinminerpro kernel wrote `results[]` and
`stop[0]` non-atomically:
```c
if (result <= target) {
    results[1] = mix_hash_digest[0]; // ... 8 fields
    stop[0] = stop[0] + 1;             // not atomic
    results[0] = gid;
}
```
Two threads in the same dispatch could both pass the target check and
interleave their writes — host ends up submitting one thread's `gid`
paired with another thread's `mix_hash` (a "Frankenstein share").
**Fix:** Atomic CAS on `resultsIndex` — only the first winning thread
writes its full result tuple. (`kernel_template.metal`)

### 2. PROGPOW Fisher–Yates shuffle order was wrong
**Symptom:** Once the race was fixed, errors became consistently
`Invalid share`. CPU+kernel agreed on the wrong hash.
**Root cause:** The ProgPoW spec interleaves the dst-seq and cache-seq
shuffles in one loop iterating N-1 → 1. We shuffled them sequentially
(all dst first, then all cache), 1 → N-1. Same number of `rnd()` calls
total, but consumed in the wrong order, so every downstream math/merge
op read a shifted slice of the kiss99 stream. (`Epoch.swift`)
**Fix:** Match the spec exactly — `i = N-1 → 1`, two `rnd()` calls per
iteration, alternating dst/cache.

### 3. Math op source generation used two rnd() calls when spec uses one
**Symptom:** Even with shuffle fixed, all submits still `Invalid share`.
The diagnostic forced-target run made this clear (100% Invalid, never
Low-diff).
**Root cause:** The ProgPoW spec generates `src1` and `src2` from a
**single** `rnd()` call:
```cpp
src_rnd = rnd() % (PROGPOW_REGS * (PROGPOW_REGS - 1));
src1 = src_rnd % PROGPOW_REGS;
src2 = src_rnd / PROGPOW_REGS;
if (src2 >= src1) ++src2;   // enforce src1 != src2
```
We used two separate `rnd()` calls and didn't enforce distinctness.
That extra `rnd()` shifts everything after it. (`Epoch.swift` and
`ProgPowHashLight.swift`)
**Fix:** Match spec: one `rnd()` with the % / ÷ trick + the distinctness
adjustment.

### 4. PROGPOW_DAG_ELEMENTS was 4× too small
**Symptom:** Same — all submits Invalid.
**Root cause:** The kernel computes `offset = offset * PROGPOW_LANES +
(lane_id ^ loop) % PROGPOW_LANES`. With g_dag in `dag_t` units
(16 bytes each), this lets the kernel address `PROGPOW_DAG_ELEMENTS *
PROGPOW_LANES * 16 = PROGPOW_DAG_ELEMENTS * 256` bytes. So
`PROGPOW_DAG_ELEMENTS = total_DAG_bytes / 256 = items / 4`.
We were passing `dag.dagNumItems / 16`. The kernel only accessed the
first 1/4 of the DAG. (`Mining.swift`)
**Fix:** Use `items / 4`.

### 5. **(THE BIG ONE) DAG generation used 256 parents, Ravencoin spec uses 512**
**Symptom:** Even with all four prior fixes, Ravencoin's official
[`progpow_test_vectors.hpp`](https://github.com/RavenProject/Ravencoin/blob/master/src/crypto/ethash/progpow_test_vectors.hpp)
still failed. Test vector for block 0 (all-zero header, nonce 0):
- Expected mix: `6e97b47b134fda0c…`
- Ours:         `40ce8bf6046c09f9…`

**Root cause:** In `src/crypto/ethash/lib/ethash/ethash.cpp`:
```cpp
constexpr static int full_dataset_item_parents = 512;
```
Standard ethash uses **256** parent-folding rounds when computing a DAG
item from cache. Ravencoin's KawPow uses **512**. Every DAG item we
generated was hashed with half the rounds → every DAG value differed
from spec → every progpow_hash differed → pool rejected every share.

This is why our `kernel-vs-cpu` cross-check passed (both impls used
256 — they agreed on the wrong DAG) but the official test vectors
failed (spec uses 512).

**Fix:** One-line change in `fill_dag.metal` and `LightEval.swift`:
```c
for (uint j = 0; j < 512u; j++) {  // was 256u
```

### Verification after all five fixes

Ravencoin's official test vectors now pass bitwise:

```
block=0    mix ✓    final ✓
block=49   mix ✓    final ✓
```

```
[verify] block=0  expected mix:   6e97b47b134fda0c7888802988e1a373affeb28bcd813b6e9a0fc669c935d03a
                  ours:           6e97b47b134fda0c7888802988e1a373affeb28bcd813b6e9a0fc669c935d03a  ✓
                  expected final: e601a7257a70dc48fccc97a7330d704d776047623b92883d77111fb36870f3d1
                  ours:           e601a7257a70dc48fccc97a7330d704d776047623b92883d77111fb36870f3d1  ✓
```

## Other things found along the way (not bugs but surprises)

- **Pool URL**: unmineable's KawPow endpoint is `kp.unmineable.com:3333`
  — the same one older Thinminerpro releases use. We briefly switched
  to `ethash.unmineable.com:3333` mid-debug on a hunch, but that turned
  out to be unmineable's *ETHash* pool (Ethereum-Classic-style chain at
  height 24M+, 30000-block epochs). Switching back to `kp.unmineable.com`
  with all 5 fixes applied was what finally got an accepted share.

- **Two stratum dialects exist on unmineable's pools**, and our parser
  handles both:
  - `kp.unmineable.com` uses the **7-param ProgPoW notify**
    (`[jobId, headerHash, seedHash, shareTarget, cleanJobs, blockHeight, bits]`),
    no `0x` prefix on hex values, `blockHeight` in params.
  - `ethash.unmineable.com` uses the **5-param Ethereum-style notify**
    with `0x` prefix and `height` as a top-level message field. Used by
    pools mining ETHash chains, not KawPow.

- **Seed→epoch reverse derivation** (iterating `keccak256(0)` until the
  result matches the pool's seed_hash) is the authoritative way to get
  the real epoch when the pool's `height` field is a pool-internal
  counter rather than the on-chain block height. Belt-and-suspenders.

- **First letter of `ravencoin_rndc` is `0x72` ('r' lowercase)**, not
  `0x52` ('R'). The constant array spells "rAVENCOINKAWPOW" with the
  first letter lowercase — known quirk in the spec, present in
  kawpowminer and Ravencoin reference too.

- **DAG size**: at Ravencoin epoch 584 (current as of testing), the
  full ethash DAG is ~5.56 GB on disk/RAM. Tight on a 16 GB Mac
  but builds in ~30s on M5 with our optimized Keccak.

- **Race-fix combined with the algorithm fixes** is what made the
  diagnostic finally have signal. Before the race fix, error patterns
  were noisy mixes of Invalid + Low-diff; after, errors became
  consistent, which let us bisect.

## Cross-check tools committed to this repo

We built a few diagnostic harnesses while bisecting; all are committed:

| CLI subcommand | What it does |
|---|---|
| `kawpow-mac verify-vectors` | Run Ravencoin's official ProgPoW test vectors through CPU light-eval. PASSES. |
| `kawpow-mac kernel-vs-cpu` | Run Metal kernel + CPU light-eval on the same input, compare bitwise. Used to localize divergence. |
| `kawpow-mac dag-crosscheck` | Build a small DAG with the GPU kernel, recompute selected items on CPU, compare. Verifies fill_dag.metal. |
| `kawpow-mac dag-test [epoch]` | Build DAG end-to-end and print first items. |
| `kawpow-mac dump-ops <progSeed>` | Print our generated RANDOM_MATH + DATA_LOADS source for a given prog_seed. Used to diff against `kawpowminer/test/kernel.cu`. |
| (default) | Live mining against unmineable. |
| Env `KAWPOW_FORCED_TARGET=...` | Override kernel target to fast-find shares for pool-format diagnostics. |

## Open items (as of session pause)

- **M7 live-share verification still pending.** Spec-compliant code is
  committed and pushed (kawpow-mac [`941e207`](https://github.com/shiftingeden/kawpow-mac/commit/941e207)).
  A 25-min live mining run was scheduled but the session was paused at
  bedtime before the wakeup fired.
- Re-run tomorrow to confirm the pool accepts (we expect: `"result":true`
  or a single `Low difficulty share` if our hashrate hits a near-miss).
- Once accepted-share rate looks reasonable, M7 closes and kawpow-mac
  is officially the first open-source KawPow miner working on
  modern Apple Silicon via unmineable.
