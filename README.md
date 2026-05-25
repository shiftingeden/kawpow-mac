# kawpow-mac

A native KawPow miner for Apple Silicon Macs (M1 through M5+), written in Swift + Metal.

## Why

`thinminerpro` — the closed-source binary used by Unmineable-Mac — does not submit shares on M3+
Apple Silicon. The Metal kernel works, but the closed Swift host orchestration is broken on
newer chips. This is a clean rewrite using the verified kernel + the public KawPow spec.

## Status

**✅ Working** — accepts shares against unMineable's KawPow pool on
modern Apple Silicon (verified on M5 MacBook Air, 2026-05-25). First
open-source KawPow miner known to do this on M3+ chips.

- [x] M0: kernel verified working on M5 (extracted + tested standalone)
- [x] M1: project skeleton + stratum client
- [x] M2: target conversion + submit wire format
- [x] M3: KawPow per-epoch RANDOM_MATH + DATA_LOADS generator
- [x] M4: DAG generation (light cache + 5.5 GB DAG GPU fill in ~30s on M5)
- [x] M5: mining loop integration (PSO cache, atomic results, ~2.7 MH/s)
- [x] M6: spec-compliant against Ravencoin's official progpow_hash test vectors
- [x] **M7: live on unmineable — first accepted share at jobId `3d56a`,
      pool replied `{"id":3,"result":true,"error":null}`** ✅

### Bugs found and fixed along the way

Full chronicle in [`BUGS_AND_FIXES.md`](BUGS_AND_FIXES.md). Five real
algorithm bugs were uncovered between M5 and M6:

1. Race condition writing `results[]` from multiple GPU threads (atomic guard added)
2. PROGPOW Fisher-Yates shuffle ordered sequentially instead of interleaved per spec
3. Math-op source generation used two `rnd()` calls when spec uses one (with distinct-source enforcement)
4. `PROGPOW_DAG_ELEMENTS` was 4× too small — kernel only addressed the first 1/4 of the DAG
5. **DAG generation used 256 parent-folding rounds; Ravencoin's KawPow spec uses 512** — every DAG item we computed differed from spec, which is why the pool always replied "Invalid share"

### Diagnostic harnesses available

| Command | Purpose |
|---|---|
| `kawpow-mac verify-vectors` | Run Ravencoin's official ProgPoW test vectors. Passes. |
| `kawpow-mac kernel-vs-cpu` | Bitwise compare Metal kernel and CPU light-eval |
| `kawpow-mac dag-crosscheck` | Cross-check GPU DAG fill against CPU spec |
| `kawpow-mac dump-ops <progSeed>` | Print our generated RANDOM_MATH/DATA_LOADS source |
| `KAWPOW_FORCED_TARGET=…` | Override kernel target to fast-find shares (for pool format diagnostics) |

## Build

```sh
swift build -c release
.build/release/kawpow-mac
```

Requires macOS 13+ and an Apple Silicon Mac.

## Testing it yourself

Two paths: just the miner binary (fast, explicit pool replies in the
terminal), or the full Unmineable-Mac app (slower, real end-user UX).

### A. Standalone miner — quickest end-to-end test

```sh
git clone https://github.com/shiftingeden/kawpow-mac.git
cd kawpow-mac
swift build -c release
```

Verify the spec-compliant algorithm against Ravencoin's official test
vectors (under 5s, no network needed):

```sh
./.build/release/kawpow-mac verify-vectors
```

You should see **all four `✓`** lines (mix + final for block 0 and
block 49). If any `✗`, something is broken in your toolchain — open
an issue.

Bitwise CPU↔Metal kernel cross-check (catches Metal driver oddities,
~10s including DAG build):

```sh
./.build/release/kawpow-mac kernel-vs-cpu
```

You should see `✓ AGREE — CPU and kernel produce the same mix_hash`.

Now actually mine for ~5 min. Drop a `config.json` next to the binary
with your own unMineable worker string (`COIN:ADDRESS.WORKER#REFERRAL`):

```sh
cat > config.json <<'EOF'
{
  "user": "LTC:YOUR_LTC_ADDRESS_HERE.yourworker",
  "chosenURL": "kp.unmineable.com",
  "chosenPort": 3333,
  "deviceNumber": 0,
  "intensity": 10371840
}
EOF
./.build/release/kawpow-mac
```

What you should see:

1. Self-tests pass (`kiss99`, `Keccak`, `keccak_f800` cross-check, etc.)
2. `[stratum] connected to kp.unmineable.com:3333` then both
   `mining.subscribe` and `mining.authorize` get `"result":true`
3. First `mining.notify` arrives — DAG build kicks off (light cache
   ~6s + GPU fill ~30-45s for the current epoch's ~5.5 GB DAG)
4. `[miner] N.NN MH/s` ticks start (expect ~2.5–3 MH/s on M5 Air)
5. Within a few minutes a `[main] submitting share jobId=…` line, then
   immediately:
   ```
   [stratum<<] {"id":N,"result":true,"error":null}
   ```
   **That's an accepted share.** It will also show up in your unMineable
   dashboard under the configured worker name within a minute or so.

Anything else from the pool (`Invalid share`, `Low difficulty share`,
`Stale`) means something is off — capture the log and open an issue.

To stop: `Ctrl-C` (or just close the terminal).

### B. Full Unmineable-Mac app (with UI)

```sh
git clone https://github.com/shiftingeden/Unmineable-Mac.git
cd Unmineable-Mac
npm install
npm run fetch:miners   # downloads XMRig + clones+builds this miner
npm run build:app
open out/Unmineable-Mac.app
```

In the app:
1. Pick a coin (LTC, RVN, anything unMineable supports)
2. Paste your payout address
3. Set a worker name
4. Toggle **GPU** on (and CPU too if you want both running)
5. Hit **Start**

Expect a ~30-45s DAG-build pause on the first GPU start. Then
the GPU hashrate panel should show ~2.5–3 MH/s and accepted shares
should accumulate on your unMineable dashboard for the worker name
you set.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| `swift: command not found` | Install Xcode Command Line Tools: `xcode-select --install` |
| Build fails with "Cannot find module" | Run from inside `kawpow-mac/` (Package.swift must be in CWD) |
| `verify-vectors` shows `✗` | Toolchain issue — check Swift version (`swift --version`, need 5.9+) |
| Hashrate is much lower than 2.5 MH/s | Other apps using GPU; or thermal throttling — Apple Silicon throttles aggressively when hot |
| Pool returns `Invalid share` | Something regressed since the verified spec-compliance — open an issue and include `/tmp/*.log` |
| `mining.subscribe` doesn't get `result:true` | Network/firewall blocking `kp.unmineable.com:3333` |

## License

GNU GPL v3 (derivative of Unmineable-Mac which is GPL v3).
