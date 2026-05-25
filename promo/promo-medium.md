# Medium-form (Reddit body, Discord long-message, forum post)

Two variants — one user-focused (r/Unmineable, r/Ravencoin, r/MacMining),
one engineering-focused (r/programming, r/swift, r/AppleSilicon).

Suggested title for either:
> **kawpow-mac: a clean-room Swift+Metal KawPow miner that finally works on M3 / M4 / M5 Macs**

---

## A. User-focused body

If you've tried mining KawPow (Ravencoin payout) on a recent Apple Silicon
Mac via unMineable, you may have noticed: the GUI shows a hashrate but
**zero shares ever get accepted**. The bundled miner (`thinminerpro`) is
a closed-source binary from 2022 that connects, computes, submits — and
the pool says `Invalid share` every time. No source means no fix.

Over a weekend I disassembled it, extracted the kernel, and rewrote the
whole thing in Swift + Metal as a drop-in replacement:
[shiftingeden/kawpow-mac](https://github.com/shiftingeden/kawpow-mac).

It took **five separate algorithmic bug hunts** to get shares accepted —
the big one was that Ravencoin's KawPow doubles the standard ethash
`full_dataset_item_parents` from 256 to 512, so every DAG item generated
by ethash-derived miners (including ours, until we found it) ends up
different from what the pool computes. Full chronicle:
[BUGS_AND_FIXES.md](https://github.com/shiftingeden/kawpow-mac/blob/main/BUGS_AND_FIXES.md).

Verified bitwise against Ravencoin's official `progpow_test_vectors.hpp`.
Pool accepts shares cleanly on M3, M4, M5 (no upstream miner does this).

Also updated the macOS GUI ([Unmineable-Mac](https://github.com/shiftingeden/Unmineable-Mac))
to use it — `npm run fetch:miners` clones + builds it automatically. CPU
mining via XMRig is unchanged. The mining page now shows per-miner
accepted-share counts alongside the hashrate.

If you want to try it: instructions in the README. Performance note —
KawPow is memory-bandwidth-limited, so expect similar hashrate across
Apple Silicon generations (M4 base ≈ M5 base because the memory
subsystems are similar). Mining on a Mac is not profitable; this is a
"what hardware can do" exercise.

---

## B. Engineering-focused body

The Unmineable-Mac project shipped a closed-source GPU miner
(`thinminerpro`) for the KawPow (Ravencoin) algorithm. On M3 and newer
Apple Silicon, it appears to work — hashrate climbs, GPU is busy — but
the pool rejects every share. No source means no patch.

I disassembled the binary, extracted its Metal kernel, and rewrote the
host in Swift to find out exactly what was wrong:
[shiftingeden/kawpow-mac](https://github.com/shiftingeden/kawpow-mac).

Took **five separate algorithmic bugs** before the pool accepted a share:

1. **Race condition** on the kernel's `results[]` write — two GPU threads
   could both pass the target check and interleave writes, so the host
   submitted one thread's nonce paired with another thread's mix-hash.
2. **Fisher-Yates shuffle order** in the per-epoch PRNG codegen — `dst`
   and `src` permutations need to be **interleaved** in one loop per
   spec; we did them sequentially.
3. **Math source generation** used two `rnd()` calls when the spec uses
   one (with a `%/÷ REGS` trick to derive both indices, plus a distinctness
   adjustment). Every extra `rnd()` shifts every downstream selector.
4. **`PROGPOW_DAG_ELEMENTS` was 4× too small** — kernel only addressed
   the first quarter of the DAG buffer.
5. **The big one**: Ravencoin's KawPow uses `full_dataset_item_parents
   = 512`, not the standard ethash value of 256. Every DAG item computed
   had half the FNV folding rounds. Our CPU↔kernel cross-check passed
   because *both* used 256 — only the official Ravencoin test vectors
   exposed the spec drift.

After fix #5, the algorithm passes Ravencoin's official test vectors
bitwise (block 0 + block 49, mix_hash + final_hash). First live share
submitted came back accepted.

Each bug, its symptom, the diagnostic that revealed it, and the one-line
fix is in
[BUGS_AND_FIXES.md](https://github.com/shiftingeden/kawpow-mac/blob/main/BUGS_AND_FIXES.md).
Five CLI subcommands for reproducible diagnostics:
`verify-vectors`, `kernel-vs-cpu`, `dag-crosscheck`, `dump-ops <seed>`,
plus a `KAWPOW_FORCED_TARGET` env var to make shares appear faster
while testing pool wire format.

Stack: Swift Package Manager + Metal + ~1500 LOC. No external crypto
dependencies — Keccak-256 / 512 / f[800] all written from scratch and
cross-verified.
