# Short-form (Twitter / X / Mastodon / Bluesky)

Three variants — pick whichever fits your tone. Each is ≤ 280 chars.

---

## A. Engineering-pitch tone

🛠️ kawpow-mac — first open-source KawPow miner that works on Apple Silicon M3+ via @unMineable. Drop-in replacement for closed-source Thinminerpro. Five algorithm bugs uncovered + fixed along the way; spec-compliant against Ravencoin's official test vectors.

https://github.com/shiftingeden/kawpow-mac

---

## B. User-pitch tone

macOS unMineable app now mines on M3, M4, M5 Macs 🎉
100% in-repo Swift + Metal GPU miner — no closed-source binaries that silently fail. Hashrate + accepted-share counters, both CPU & GPU.

https://github.com/shiftingeden/Unmineable-Mac

---

## C. Bug-story hook tone

A weekend reverse-engineering a closed-source crypto miner found 5 separate algorithmic bugs. The last one: KawPow doubles the standard ethash `full_dataset_item_parents` from 256 to 512 — and our previous DAG-item cross-check missed it because both impls used 256.

Full chronicle: https://github.com/shiftingeden/kawpow-mac/blob/main/BUGS_AND_FIXES.md
