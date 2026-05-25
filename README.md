# kawpow-mac

A native KawPow miner for Apple Silicon Macs (M1 through M5+), written in Swift + Metal.

## Why

`thinminerpro` — the closed-source binary used by Unmineable-Mac — does not submit shares on M3+
Apple Silicon. The Metal kernel works, but the closed Swift host orchestration is broken on
newer chips. This is a clean rewrite using the verified kernel + the public KawPow spec.

## Status

Work in progress. Milestones:

- [x] M0: kernel verified working on M5 (extracted + tested standalone)
- [ ] M1: project skeleton + stratum client
- [ ] M2: target conversion + submit wire format
- [ ] M3: KawPow per-epoch RANDOM_MATH + DATA_LOADS generator
- [ ] M4: DAG generation (light cache + GPU fill)
- [ ] M5: mining loop integration
- [ ] M6: verify against known KawPow test vector
- [ ] M7: live on unmineable

## Build

```sh
swift build -c release
.build/release/kawpow-mac
```

Requires macOS 13+ and an Apple Silicon Mac.

## License

GNU GPL v3 (derivative of Unmineable-Mac which is GPL v3).
