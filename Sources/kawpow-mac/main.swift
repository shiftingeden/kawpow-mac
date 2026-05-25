import Foundation

import Metal

setbuf(stdout, nil) // unbuffered output so logs flush in real time

runSelfTests()
_ = keccak800CrossCheck()

// CLI: `kawpow-mac dag-test [epoch] [dagBytesCap]`
// Builds the DAG to verify M4 end-to-end without entering the mining loop.
let args = CommandLine.arguments
if args.count >= 2 && args[1] == "dag-test" {
    let epoch = args.count >= 3 ? UInt64(args[2]) ?? 0 : 0
    // Default: cap DAG at 256 MB so a quick test fits in any Mac's RAM.
    let cap   = args.count >= 4 ? UInt64(args[3]) : 256 * 1024 * 1024
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("no Metal device"); exit(1)
    }
    print("[dag-test] device=\(device.name) epoch=\(epoch) dagBytesCap=\(cap)")
    do {
        let out = try buildDAG(device: device, epoch: epoch, dagBytesCap: cap)
        // Print first DAG item so a future test can compare against a reference value
        let dagPtr = out.dag.contents().assumingMemoryBound(to: UInt32.self)
        var dump = ""
        for k in 0..<16 { dump += String(format: "%08x ", dagPtr[k]) }
        print("[dag-test] DAG[0] = \(dump)")
        // Also DAG[1] and DAG[100] for confidence
        dump = ""
        for k in 0..<16 { dump += String(format: "%08x ", dagPtr[16 + k]) }
        print("[dag-test] DAG[1] = \(dump)")
        if out.dagNumItems > 100 {
            dump = ""
            for k in 0..<16 { dump += String(format: "%08x ", dagPtr[100*16 + k]) }
            print("[dag-test] DAG[100] = \(dump)")
        }
        print(String(format: "[dag-test] total time: %.2fs", out.elapsed))
    } catch {
        print("[dag-test] FAILED: \(error)")
        exit(2)
    }
    exit(0)
}

// Milestone 2: + target conversion + submit-harness.
// On the first job, we (a) compute the kernel target and print it, and (b) send a
// deliberately invalid mining.submit so the pool tells us whether our wire format is good.

// Load config.json from CWD when present (this is how Unmineable-Mac launches us).
// Fall back to dev-mode defaults if no config.json is found.
let cfg = ConfigLoader.loadFromCWD()
let host: String      = cfg?.host ?? "ethash.unmineable.com"
let port: UInt16      = cfg?.port ?? 3333
let workerUser: String = cfg?.user ?? "LTC:ltc1qw7ffr4hjqytukym0yvkrnsgxharjqs86z3c9wh.M5dev"
print("[kawpow-mac] host=\(host) port=\(port) user=\(workerUser)\(cfg == nil ? "  (no config.json — using dev defaults)" : "")")

let client = StratumClient(host: host, port: port)
guard let miner = Miner() else { print("no Metal device"); exit(1) }
// Throttle submits to avoid flooding the pool when running with
// KAWPOW_FORCED_TARGET (where shares appear faster than once per second).
var lastSubmitAt = Date(timeIntervalSince1970: 0)
let submitMinInterval: TimeInterval = 0.5
miner.onShare = { jobId, nonce, header, mix in
    let now = Date()
    if now.timeIntervalSince(lastSubmitAt) < submitMinInterval {
        print("[main] (throttled — last submit \(String(format: "%.2f", now.timeIntervalSince(lastSubmitAt)))s ago)")
        return
    }
    lastSubmitAt = now
    print("[main] submitting share jobId=\(jobId) nonce=\(nonce)")
    client.submitShare(workerName: workerUser, jobId: jobId, nonce: nonce, headerHash: header, mixHash: mix)
}
miner.startMiningLoop()

client.onConnected = {
    client.subscribe()
    client.authorize(user: workerUser)
}

client.onSetTarget = { target in
    let kt = Target.kernelTargetFromPoolTarget(target)
    print("[main] new share target: \(target)")
    print("[main]   → kernel uint64 = 0x\(String(kt, radix: 16, uppercase: false))")
}

client.onSetDifficulty = { d in
    print("[main] new difficulty: \(d)")
}

client.onNotify = { jobId, headerHash, seedHash, shareTarget, cleanJobs, blockHeight, bits in
    print("[main] JOB jobId=\(jobId) height=\(blockHeight) cleanJobs=\(cleanJobs)")
    let job = MiningJob(
        jobId: jobId,
        headerHashHex: headerHash,
        seedHashHex: seedHash,
        shareTargetHex: shareTarget,
        blockHeight: blockHeight,
        cleanJobs: cleanJobs
    )
    miner.updateJob(job)
}

client.onError = { err in
    print("[main] stratum error: \(err)")
}

client.connect()

RunLoop.main.run()
