# kawpow-mac

A native KawPow miner for Apple Silicon Macs (M1 through M5+), written in Swift + Metal.

## Why

`thinminerpro` — the closed-source binary used by Unmineable-Mac — does not submit shares on M3+
Apple Silicon. The Metal kernel works, but the closed Swift host orchestration is broken on
newer chips. This is a clean rewrite using the verified kernel + the public KawPow spec.

## Status

Work in progress. Milestones:

- [x] M0: kernel verified working on M5 (extracted + tested standalone)
- [x] M1: project skeleton + stratum client (connects to `ethash.unmineable.com:3333`, subscribes, authorizes, parses jobs)
- [x] M2: target conversion + submit wire format (pool processes submits; wire format confirmed)
- [x] M3: KawPow per-epoch RANDOM_MATH + DATA_LOADS generator (kiss99 PRNG + interleaved Fisher-Yates per spec)
- [x] M4: DAG generation (light cache on CPU in ~6s for epoch 810, GPU fill of 7.3 GB DAG in ~42s)
- [x] M5: mining loop integration (per-epoch kernel compile cached by `prog_seed`, atomic results write to fix race condition, ~2.7 MH/s steady on M5 MacBook Air)
- [ ] M6: verify against known KawPow test vector — *partial: seed→epoch derivation validated against pool's seed; full hash validation against a reference vector still pending*
- [ ] M7: live on unmineable — *in progress: long runs underway, pool's `mining.submit` response still being characterised*

### Recent fixes (latest commit)

- Stratum 5-param ethash-style notify (the actual unMineable pool dialect)
- Seed→epoch lookup (pool's `height` field is a pool-internal counter, not on-chain block height — seed is authoritative)
- Race-condition fix on the kernel's results write (atomic guard so two threads in the same dispatch can't interleave `gid` + `mix_hash`)
- Shuffle-order fix in the per-epoch codegen (interleaved Fisher-Yates per the ProgPoW spec; was sequential before)
- PSO cache keyed by `prog_seed` (was recompiling Metal on every job)

## Build

```sh
swift build -c release
.build/release/kawpow-mac
```

Requires macOS 13+ and an Apple Silicon Mac.

## License

GNU GPL v3 (derivative of Unmineable-Mac which is GPL v3).
