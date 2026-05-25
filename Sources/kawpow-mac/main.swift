import Foundation

import Metal

setbuf(stdout, nil) // unbuffered output so logs flush in real time

runSelfTests()

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

let host = "kp.unmineable.com"
let port: UInt16 = 3333
let workerUser = "LTC:ltc1qw7ffr4hjqytukym0yvkrnsgxharjqs86z3c9wh.M5dev"

let client = StratumClient(host: host, port: port)
var submitted = false

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
    print("[main] JOB jobId=\(jobId) height=\(blockHeight) cleanJobs=\(cleanJobs) bits=\(bits)")
    print("[main]   header=\(headerHash)")
    print("[main]   seed  =\(seedHash)")
    print("[main]   target=\(shareTarget)")
    print("[main]   kernel target literal=\(Target.metalLiteral(for: shareTarget))")

    let seed = KawPow.progSeed(forBlockHeight: blockHeight)
    print("[main]   prog_seed = \(seed) (KAWPOW_PERIOD=\(KawPow.KAWPOW_PERIOD))")
    let gen = generateKernelSource(progSeed: seed)
    print("[main]   RANDOM_MATH first lines:")
    gen.randomMath.split(separator: "\n").prefix(6).forEach { print("[main]     \($0)") }
    print("[main]   DATA_LOADS:")
    gen.dataLoads.split(separator: "\n").forEach { print("[main]     \($0)") }
}

client.onError = { err in
    print("[main] stratum error: \(err)")
}

client.connect()

RunLoop.main.run()
