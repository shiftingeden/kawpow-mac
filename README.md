# kawpow-mac

A native KawPow miner for Apple Silicon Macs (M1 through M5+), written in Swift + Metal.

## Why

`thinminerpro` — the closed-source binary used by Unmineable-Mac — does not submit shares on M3+
Apple Silicon. The Metal kernel works, but the closed Swift host orchestration is broken on
newer chips. This is a clean rewrite using the verified kernel + the public KawPow spec.

## Status

Algorithm spec-compliant; live-pool acceptance pending verification.

- [x] M0: kernel verified working on M5 (extracted + tested standalone)
- [x] M1: project skeleton + stratum client (connects to `ethash.unmineable.com:3333`)
- [x] M2: target conversion + submit wire format (pool processes submits)
- [x] M3: KawPow per-epoch RANDOM_MATH + DATA_LOADS generator
- [x] M4: DAG generation (light cache + 7.3 GB DAG GPU fill in ~42s)
- [x] M5: mining loop integration (PSO cache, atomic results, ~2.7 MH/s on M5 Air)
- [x] **M6: spec-compliant against Ravencoin's official progpow_hash test vectors** — block 0 and block 49 match mix_hash + final_hash bitwise
- [ ] M7: live on unmineable — verification pending (run scheduled; awaiting first accepted share)

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

## License

GNU GPL v3 (derivative of Unmineable-Mac which is GPL v3).
