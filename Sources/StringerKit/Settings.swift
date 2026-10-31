import Foundation
import StringerCore

/// Every setting, resolved once: flags > `STRINGER_*` environment >
/// `~/.config/stringer/config.toml` > defaults. A meeting snapshots its
/// resolved settings into `settings.json`, so changing them mid-meeting does
/// not alter that meeting's pipeline.
public struct Settings: Codable, Equatable, Sendable {
    public var home = "~/Meetings"
    public var vault = ""
    public var mic = "default"
    public var asr = "parakeet"
    public var diarize = true
    /// Exact speaker count per track; 0 = decide automatically.
    public var speakers = 0
    /// Diarization clustering distance; 0 = the model default. Lower finds more speakers.
    public var clusterThreshold = 0.0
    /// Live-transcript slice length, seconds.
    public var chunk = 10.0
    public var live = true
    public var vocab = ""
    public var debug = false
    public var aiTitle = true
    /// Menu-bar app: ask to record when a meeting app starts using the mic.
    public var detect = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case home, vault, mic, asr, diarize, speakers, chunk, live, vocab, debug, detect
        case clusterThreshold = "cluster_threshold", aiTitle = "ai_title"
    }

    public static let keys = ["home", "vault", "mic", "asr", "diarize", "speakers", "cluster_threshold",
                              "chunk", "live", "vocab", "debug", "ai_title", "detect"]

    public var homeURL: URL { URL(fileURLWithPath: Paths.expand(home)) }
    public var vaultURL: URL? { vault.isEmpty ? nil : URL(fileURLWithPath: Paths.expand(vault)) }
    public var vocabURL: URL? { vocab.isEmpty ? nil : URL(fileURLWithPath: Paths.expand(vocab)) }

    public struct Invalid: Error, CustomStringConvertible {
        public var description: String
    }

    /// Sets one key from text, validating it.
    public mutating func set(_ key: String, _ raw: String) throws {
        let v = raw.trimmingCharacters(in: .whitespaces)
        func bool() throws -> Bool {
            switch v.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: throw Invalid(description: "\(key) must be true or false, not '\(v)'")
            }
        }
        func number() throws -> Double {
            guard let d = Double(v), d.isFinite else { throw Invalid(description: "\(key) must be a number, not '\(v)'") }
            return d
        }
        switch key.replacingOccurrences(of: "-", with: "_").lowercased() {
        case "home":
            guard !v.isEmpty else { throw Invalid(description: "home cannot be empty") }
            home = v
        case "vault": vault = v
        case "mic":
            let m = v.lowercased() == "aec" ? "default" : v.lowercased()
            guard ["default", "all", "none"].contains(m) else {
                throw Invalid(description: "mic must be default, all or none, not '\(v)'")
            }
            mic = m
        case "asr":
            guard ["parakeet", "apple"].contains(v.lowercased()) else {
                throw Invalid(description: "asr must be parakeet or apple, not '\(v)'")
            }
            asr = v.lowercased()
        case "diarize": diarize = try bool()
        case "speakers":
            let n = try number()
            guard n >= 0, n <= 20, n == n.rounded() else { throw Invalid(description: "speakers must be 0 (auto) to 20") }
            speakers = Int(n)
        case "cluster_threshold":
            let t = try number()
            guard t == 0 || (t > 0 && t < 2) else { throw Invalid(description: "cluster_threshold must be 0 (default) or in (0, 2)") }
            clusterThreshold = t
        case "chunk":
            let c = try number()
            guard c >= 3, c <= 60 else { throw Invalid(description: "chunk must be 3–60 seconds") }
            chunk = c
        case "live": live = try bool()
        case "vocab": vocab = v
        case "debug": debug = try bool()
        case "ai_title": aiTitle = try bool()
        case "detect": detect = try bool()
        default:
            throw Invalid(description: "unknown setting '\(key)' (keys: \(Self.keys.joined(separator: ", ")))")
        }
    }

    public func value(_ key: String) -> String {
        switch key {
        case "home": return home
        case "vault": return vault
        case "mic": return mic
        case "asr": return asr
        case "diarize": return "\(diarize)"
        case "speakers": return "\(speakers)"
        case "cluster_threshold": return clusterThreshold == 0 ? "0" : "\(clusterThreshold)"
        case "chunk": return chunk == chunk.rounded() ? "\(Int(chunk))" : "\(chunk)"
        case "live": return "\(live)"
        case "vocab": return vocab
        case "debug": return "\(debug)"
        case "ai_title": return "\(aiTitle)"
        case "detect": return "\(detect)"
        default: return ""
        }
    }

    /// Where each key's value came from, for `stringer config`.
    public enum Origin: String { case `default`, file, env, flag }

    public struct Resolved {
        public var settings: Settings
        public var origins: [String: Origin]
        public var problems: [String]
    }

    /// Resolves defaults < config file < environment < flags. Invalid values
    /// in the file or environment are reported and skipped; invalid flags throw.
    public static func resolve(flags: [String: String] = [:],
                               env: [String: String] = ProcessInfo.processInfo.environment,
                               configURL: URL = Paths.configURL) throws -> Resolved
    {
        var s = Settings()
        var origins = Dictionary(uniqueKeysWithValues: keys.map { ($0, Origin.default) })
        var problems: [String] = []
        for (k, v) in ConfigFile.read(configURL) {
            do {
                try s.set(k, v)
                origins[k] = .file
            } catch {
                problems.append("config.toml: \(error)")
            }
        }
        for k in keys {
            guard let v = env["STRINGER_" + k.uppercased()] else { continue }
            do {
                try s.set(k, v)
                origins[k] = .env
            } catch {
                problems.append("STRINGER_\(k.uppercased()): \(error)")
            }
        }
        for (k, v) in flags {
            try s.set(k, v)
            origins[k.replacingOccurrences(of: "-", with: "_")] = .flag
        }
        return Resolved(settings: s, origins: origins, problems: problems)
    }

    public static func current() -> Settings {
        (try? resolve().settings) ?? Settings()
    }
}

/// A minimal TOML reader/writer for flat `key = value` files.
public enum ConfigFile {
    public static func read(_ url: URL) -> [(String, String)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("["), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            out.append((key, unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))))
        }
        return out
    }

    /// Sets one key, keeping every other line (and comments) as they were.
    public static func set(_ key: String, _ value: String, in url: URL) throws {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let rendered = "\(key) = \(render(key, value))"
        if let i = lines.firstIndex(where: { line in
            let l = stripComment(line).trimmingCharacters(in: .whitespaces)
            guard let eq = l.firstIndex(of: "=") else { return false }
            return l[..<eq].trimmingCharacters(in: .whitespaces) == key
        }) {
            lines[i] = rendered
        } else {
            lines.append(rendered)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(lines.joined(separator: "\n") + "\n", to: url)
    }

    static func render(_ key: String, _ value: String) -> String {
        let bare = ["true", "false"].contains(value.lowercased()) || Double(value) != nil
        let stringKeys: Set<String> = ["home", "vault", "mic", "asr", "vocab"]
        if bare && !stringKeys.contains(key) { return value.lowercased() == value ? value : value.lowercased() }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func stripComment(_ line: String) -> String {
        var inString = false
        var prev: Character = " "
        for (i, c) in line.enumerated() {
            if c == "\"" && prev != "\\" { inString.toggle() }
            if c == "#" && !inString { return String(line.prefix(i)) }
            prev = c
        }
        return line
    }

    static func unquote(_ v: String) -> String {
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            let inner = String(v.dropFirst().dropLast())
            return v.hasPrefix("'") ? inner : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return v
    }
}

public enum Paths {
    public static var configURL: URL {
        if let p = ProcessInfo.processInfo.environment["STRINGER_CONFIG"] { return URL(fileURLWithPath: expand(p)) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(".config/stringer/config.toml")
    }

    /// Locks and the setup lock. Never deleted by cleanup.
    public static var support: URL {
        if let p = ProcessInfo.processInfo.environment["STRINGER_SUPPORT"] { return URL(fileURLWithPath: expand(p)) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending("Stringer")
    }

    public static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
}
