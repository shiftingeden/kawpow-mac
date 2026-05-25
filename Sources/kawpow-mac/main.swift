import Foundation

setbuf(stdout, nil) // unbuffered output so logs flush in real time

// Milestone 1: project skeleton + minimal stratum client.
// Connects to kp.unmineable.com:3333, subscribes, authorizes, prints incoming jobs.

let host = "kp.unmineable.com"
let port: UInt16 = 3333
let user = "LTC:ltc1qw7ffr4hjqytukym0yvkrnsgxharjqs86z3c9wh.M5dev"

let client = StratumClient(host: host, port: port)

client.onConnected = {
    client.subscribe()
    client.authorize(user: user)
}

client.onSetTarget = { target in
    print("[main] new share target: \(target)")
}

client.onSetDifficulty = { d in
    print("[main] new difficulty: \(d)")
}

client.onNotify = { jobId, headerHash, seedHash, shareTarget, cleanJobs, blockHeight, bits in
    print("[main] JOB jobId=\(jobId) height=\(blockHeight) cleanJobs=\(cleanJobs) bits=\(bits)")
    print("[main]   header=\(headerHash)")
    print("[main]   seed  =\(seedHash)")
    print("[main]   target=\(shareTarget)")
}

client.onError = { err in
    print("[main] stratum error: \(err)")
}

client.connect()

// Keep alive — stratum runs on a background queue
RunLoop.main.run()
