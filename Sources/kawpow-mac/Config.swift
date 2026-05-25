import Foundation

// Runtime config loaded from a config.json sitting in the current working directory.
// Matches the thinminerpro config.json schema so Unmineable-Mac's existing wrapper
// (which patches user / chosenURL / chosenPort) works unchanged.

struct RuntimeConfig: Decodable {
    let user: String
    let chosenURL: String?
    let chosenPort: Int?
    let deviceNumber: Int?
    let intensity: Int?

    var host: String { chosenURL ?? "ethash.unmineable.com" }
    var port: UInt16 { UInt16(chosenPort ?? 3333) }
}

enum ConfigLoader {
    static func loadFromCWD() -> RuntimeConfig? {
        let p = FileManager.default.currentDirectoryPath + "/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
        return try? JSONDecoder().decode(RuntimeConfig.self, from: data)
    }
}
