# Demo video scripts

Two scripts — one elevator pitch (~60s) and one walkthrough (~3 min).
Both meant for a screen recording with voiceover. Tools you could use:

- **QuickTime** (free, built into macOS) — Cmd+Shift+5 → record
- **OBS** (free) — more control, picture-in-picture
- **Screen Studio** ($) — auto-zoom on cursor, the standard for slick
  product demos
- **Descript** ($) — record screen + voice, AI-assisted editing,
  auto-captions

---

## A. 60-second elevator pitch

> **[0:00 - 0:05]** *(Screen: a typical Apple Silicon MacBook on a desk,
> or just the kawpow-mac README in a browser)*
>
> Voiceover: "If you've tried mining KawPow on a Mac with an M3, M4, or
> M5 chip, you've probably run into the same wall I did."
>
> **[0:05 - 0:15]** *(Screen: Unmineable-Mac app with the OLD setup —
> miner running, hashrate climbing, but no shares — show the dashboard
> on unmineable.com with zero balance)*
>
> Voiceover: "The bundled miner is closed-source and quietly broken on
> newer chips. Hashrate looks fine; the pool rejects every single share.
> No source, no fix."
>
> **[0:15 - 0:30]** *(Screen: terminal showing `git clone` of
> kawpow-mac, then `swift build -c release`, then
> `./kawpow-mac verify-vectors` showing the four ✓ lines)*
>
> Voiceover: "I rewrote the whole thing in Swift and Metal. It passes
> Ravencoin's official test vectors. And — most importantly —"
>
> **[0:30 - 0:45]** *(Screen: live mining session showing the
> `[main] submitting share` and then `result:true` line)*
>
> Voiceover: "— shares actually get accepted."
>
> **[0:45 - 0:60]** *(Screen: github.com/shiftingeden/kawpow-mac and
> github.com/shiftingeden/Unmineable-Mac repos side by side)*
>
> Voiceover: "Both the standalone miner and the integrated macOS app
> are open source. Links in the description. Mining on a Mac isn't
> profitable — this is for engineers who like figuring out what the
> hardware can really do."

---

## B. 3-minute walkthrough

### Scene 1 — The problem (0:00 - 0:30)

> *(Screen: Unmineable-Mac app running, hashrate ticking, unmineable
> dashboard showing zero shares accepted over many minutes)*
>
> "Here's what mining KawPow on a recent Apple Silicon Mac looks like
> with the default bundled miner. The hashrate is fine. GPU usage is
> high. But over twenty minutes of mining, zero shares have been
> accepted. Look at the pool dashboard — nothing.
>
> The bundled miner, called thinminerpro, is closed-source. The repo
> has only a README and a binary. So no patching."

### Scene 2 — The investigation (0:30 - 1:30)

> *(Screen: terminal showing `strings thinminerpro | head -30`, then
> `xxd default.metallib | head`, then the extracted kernel source)*
>
> "First I disassembled the binary and pulled out its Metal kernel.
> The kernel compiles cleanly on M5; pumping fake inputs through it
> produces shares. So the kernel works — the bug has to be in the
> closed-source Swift host that orchestrates it.
>
> So I rewrote the host from scratch in Swift, using the kernel as a
> reference."
>
> *(Screen: the kawpow-mac repo file tree)*

### Scene 3 — Finding the bugs (1:30 - 2:15)

> *(Screen: the BUGS_AND_FIXES.md page, scrolling through the five
> bullet points)*
>
> "It took five separate algorithmic bugs to get a share accepted by
> the pool. The first was a race condition writing the result tuple
> from multiple GPU threads. The second was a wrong shuffle order in
> the per-epoch PRNG. The third was using two random numbers where the
> spec uses one with a divide trick. The fourth was an off-by-four on
> the DAG element count.
>
> The fifth one was the killer: Ravencoin's KawPow uses 512 DAG-parent
> rounds, not the standard ethash 256. Every DAG item we computed had
> half the rounds the pool expected. Our own CPU-vs-GPU cross-check
> didn't catch it — both used 256 and agreed on a wrong answer. Only
> Ravencoin's official test vectors exposed it."

### Scene 4 — Verification (2:15 - 2:45)

> *(Screen: terminal running `kawpow-mac verify-vectors` — show the
> four ✓ lines; then `kawpow-mac` running live, the
> `[main] submitting share` line, then the
> `[stratum<<] {"id":3,"result":true,"error":null}` line)*
>
> "With all five fixes the algorithm passes Ravencoin's official test
> vectors bitwise. And the live pool accepts shares.
>
> Here's the first one coming back accepted — that 'result true' is
> what the pool says when the math matches."

### Scene 5 — Try it (2:45 - 3:00)

> *(Screen: the Unmineable-Mac README install steps, then `npm run
> fetch:miners`, then the app launching with shares-accepted counters
> ticking up)*
>
> "If you want to try it: both repos are on GitHub under
> shiftingeden. The macOS app builds itself from source — clone, npm
> install, npm run fetch:miners, npm run build:app. That last one
> clones and builds the new miner for you.
>
> Links in the description. Bug chronicle in BUGS_AND_FIXES.md if you
> want the full reverse-engineering story."

---

## Visual beats checklist

If you want to record this yourself, the screens to capture:

- [ ] Unmineable-Mac app showing hashrate climbing but zero shares on dashboard (the "before")
- [ ] Terminal: `git clone https://github.com/shiftingeden/kawpow-mac.git`
- [ ] Terminal: `swift build -c release`
- [ ] Terminal: `./kawpow-mac verify-vectors` showing four ✓ lines
- [ ] Terminal: live mining showing `[miner] N.NN MH/s` and `[main] submitting share` and `result:true`
- [ ] BUGS_AND_FIXES.md scrolling through the five bugs
- [ ] Unmineable-Mac app with both CPU and GPU mining, both share-counter chips showing non-zero
- [ ] Browser tabs: github.com/shiftingeden/kawpow-mac and github.com/shiftingeden/Unmineable-Mac

---

## Music / atmosphere

- Avoid trap / EDM beats — wrong vibe for "engineer figures out a
  problem" content. Try low-key chillhop or no music.
- If you do use music, leave a clear gap during the
  `result:true` reveal so the visual hit lands.

---

## Where to post the video

- **Embed in the README** — at the top of kawpow-mac and Unmineable-Mac
- **Twitter/X** — short version (60s) plays natively
- **YouTube** — long version, tag with `Apple Silicon`, `Ravencoin`,
  `KawPow`, `macOS development`
- **Reddit** — link the YouTube video from your Show HN / r/Ravencoin
  post body, not as a top-level post
