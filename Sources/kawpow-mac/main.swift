import Foundation

setbuf(stdout, nil) // unbuffered output so logs flush in real time

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

    if !submitted {
        submitted = true
        // Send a deliberately invalid share — we just want the pool's response so we can
        // confirm our wire format. A valid submit is rejected with "invalid share" or similar.
        let fakeNonce  = "0xdeadbeefcafebabe"
        let fakeMixHash = String(repeating: "00", count: 32)
        print("[main] sending FAKE submit to probe wire format…")
        client.submitShare(workerName: workerUser,
                           jobId: jobId,
                           nonce: fakeNonce,
                           headerHash: "0x" + headerHash,
                           mixHash: "0x" + fakeMixHash)
    }
}

client.onError = { err in
    print("[main] stratum error: \(err)")
}

client.connect()

RunLoop.main.run()
