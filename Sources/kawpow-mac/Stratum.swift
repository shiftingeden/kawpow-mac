import Foundation
import Network

// Minimal Stratum (Mining v1) client over plain TCP.
// Used against unmineable's kp.unmineable.com:3333 (KawPow / ProgPoW pool).
// Messages are newline-terminated JSON-RPC blobs.

struct StratumMessage: Decodable {
    var id: Int?
    var result: AnyCodable?
    var error: AnyCodable?
    var method: String?
    var params: AnyCodable?
}

struct AnyCodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)        { value = v }
        else if let v = try? c.decode(Int.self)    { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value } }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value } }
        else if c.decodeNil() { value = NSNull() }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON") }
    }
}

final class StratumClient {
    typealias NotifyHandler = (_ jobId: String, _ headerHash: String, _ seedHash: String, _ shareTarget: String, _ cleanJobs: Bool, _ blockHeight: UInt64, _ bits: String) -> Void

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "stratum")
    private var conn: NWConnection?
    private var buffer = Data()
    private var nextId = 1

    var onNotify: NotifyHandler?
    var onSetTarget: ((String) -> Void)?
    var onSetDifficulty: ((Double) -> Void)?
    var onConnected: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect() {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        let c = NWConnection(to: endpoint, using: .tcp)
        self.conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[stratum] connected to \(self.host):\(self.port)")
                self.startReceive()
                self.onConnected?()
            case .failed(let e):
                print("[stratum] failed: \(e)")
                self.onError?(e)
            case .waiting(let e):
                print("[stratum] waiting: \(e)")
            case .cancelled:
                print("[stratum] cancelled")
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func startReceive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if let error {
                print("[stratum] recv error: \(error)")
                self.onError?(error)
                return
            }
            if isComplete {
                print("[stratum] connection closed by peer")
                return
            }
            self.startReceive()
        }
    }

    private func drainBuffer() {
        while let nlIdx = buffer.firstIndex(of: 0x0A) {  // '\n'
            let line = buffer.subdata(in: buffer.startIndex..<nlIdx)
            buffer.removeSubrange(buffer.startIndex...nlIdx)
            if line.isEmpty { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ data: Data) {
        if let s = String(data: data, encoding: .utf8) {
            print("[stratum<<] \(s)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[stratum] could not parse JSON")
            return
        }
        if let method = json["method"] as? String {
            handleNotification(method: method, params: json["params"], topLevel: json)
        } else if let id = json["id"] as? Int {
            handleResponse(id: id, json: json)
        }
    }

    // Strip an optional "0x"/"0X" prefix from a hex string.
    private func stripHexPrefix(_ s: String) -> String {
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return String(s.dropFirst(2)) }
        return s
    }

    private func handleNotification(method: String, params: Any?, topLevel: [String: Any]) {
        switch method {
        case "mining.notify":
            // unMineable's kp.unmineable.com pool uses an ethash-style notify:
            //   params: ["0x<jobId>", "0x<headerHash>", "0x<seedHash>", "0x<target>", cleanJobs]
            //   AND a top-level "height" field on the message itself.
            // Older kp.unmineable.com used a 7-param ProgPoW notify (kept for backward
            // compatibility, even though we no longer connect there by default).
            guard let arr = params as? [Any], arr.count >= 5 else {
                print("[stratum] mining.notify malformed (params count)"); return
            }

            // Ethash-style: 5 params, no jobId/bits, height at top level.
            if arr.count >= 5 && arr.count < 7,
               let jobIdRaw     = arr[0] as? String,
               let headerRaw    = arr[1] as? String,
               let seedRaw      = arr[2] as? String,
               let targetRaw    = arr[3] as? String,
               let cleanJobs    = arr[4] as? Bool {
                let jobId      = stripHexPrefix(jobIdRaw)
                let headerHash = stripHexPrefix(headerRaw)
                let seedHash   = stripHexPrefix(seedRaw)
                let shareTarget = stripHexPrefix(targetRaw)
                let blockHeight: UInt64 = {
                    if let n = topLevel["height"] as? UInt64 { return n }
                    if let n = topLevel["height"] as? Int    { return UInt64(n) }
                    return 0
                }()
                onNotify?(jobId, headerHash, seedHash, shareTarget, cleanJobs, blockHeight, "")
                return
            }

            // ProgPoW-style legacy fallback: 7 params, blockHeight in params[5].
            if let jobId       = arr[0] as? String,
               let headerHash  = arr[1] as? String,
               let seedHash    = arr[2] as? String,
               let shareTarget = arr[3] as? String,
               let cleanJobs   = arr[4] as? Bool,
               let bits        = arr[6] as? String {
                let blockHeight: UInt64
                if let n = arr[5] as? UInt64 { blockHeight = n }
                else if let n = arr[5] as? Int { blockHeight = UInt64(n) }
                else { blockHeight = 0 }
                onNotify?(jobId, stripHexPrefix(headerHash), stripHexPrefix(seedHash),
                          stripHexPrefix(shareTarget), cleanJobs, blockHeight, bits)
                return
            }

            print("[stratum] mining.notify malformed (param types)")
        case "mining.set_target":
            if let arr = params as? [Any], let t = arr.first as? String {
                onSetTarget?(t)
            }
        case "mining.set_difficulty":
            if let arr = params as? [Any], let d = arr.first as? Double {
                onSetDifficulty?(d)
            }
        default:
            print("[stratum] unhandled notification: \(method)")
        }
    }

    private func handleResponse(id: Int, json: [String: Any]) {
        // For v1 we just log responses; submit/subscribe/authorize callers can match by id later.
        if let err = json["error"], !(err is NSNull) {
            print("[stratum] response id=\(id) ERROR: \(err)")
        } else {
            print("[stratum] response id=\(id) OK: result=\(json["result"] ?? "nil")")
        }
    }

    // MARK: - Outgoing

    @discardableResult
    func send(method: String, params: [Any]) -> Int {
        let id = nextId
        nextId += 1
        let payload: [String: Any] = [
            "id": id,
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: payload, options: [])
            data.append(0x0A) // newline
            if let s = String(data: data, encoding: .utf8) {
                print("[stratum>>] \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            conn?.send(content: data, completion: .contentProcessed { err in
                if let err { print("[stratum] send err: \(err)") }
            })
        } catch {
            print("[stratum] encode err: \(error)")
        }
        return id
    }

    func subscribe(userAgent: String = "kawpow-mac/0.1") {
        send(method: "mining.subscribe", params: [userAgent])
    }

    func authorize(user: String, password: String = "x") {
        send(method: "mining.authorize", params: [user, password])
    }

    func submitShare(workerName: String, jobId: String, nonce: String, headerHash: String, mixHash: String) {
        // Standard ProgPoW/KawPow submit: [worker, jobId, nonceHex, headerHashHex, mixHashHex]
        send(method: "mining.submit", params: [workerName, jobId, nonce, headerHash, mixHash])
    }
}
