import Foundation
import Testing
@testable import CaptureKit
@testable import StringerCore
@testable import StringerKit

@Suite(.serialized) struct SettingsTests {
    @Test func precedenceForEveryKey() throws {
        let dir = tempDir()
        let config = dir.appending("config.toml")
        let values: [String: (file: String, env: String, flag: String)] = [
            "home": ("~/A", "~/B", "~/C"), "vault": ("~/V1", "~/V2", "~/V3"), "mic": ("all", "none", "default"),
            "asr": ("apple", "parakeet", "apple"), "diarize": ("false", "true", "false"), "speakers": ("2", "3", "4"),
            "cluster_threshold": ("0.5", "0.6", "0.7"), "chunk": ("5", "6", "7"), "live": ("false", "true", "false"),
            "vocab": ("/a", "/b", "/c"), "debug": ("true", "false", "true"), "ai_title": ("false", "true", "false"),
            "detect": ("false", "true", "false"),
        ]
        #expect(Set(values.keys) == Set(Settings.keys))
        try values.map { "\($0.key) = \"\($0.value.file)\"" }.joined(separator: "\n").write(to: config, atomically: true, encoding: .utf8)
        let env = Dictionary(uniqueKeysWithValues: values.map { ("STRINGER_" + $0.key.uppercased(), $0.value.env) })
        let flags = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value.flag) })
        for k in Settings.keys {
            let d = Settings().value(k)
            #expect(try Settings.resolve(flags: [:], env: [:], configURL: dir.appending("none")).settings.value(k) == d)
            var probe = Settings()
            try probe.set(k, values[k]!.file)
            #expect(try Settings.resolve(flags: [:], env: [:], configURL: config).settings.value(k) == probe.value(k), "\(k) file")
            try probe.set(k, values[k]!.env)
            #expect(try Settings.resolve(flags: [:], env: env, configURL: config).settings.value(k) == probe.value(k), "\(k) env")
            try probe.set(k, values[k]!.flag)
            #expect(try Settings.resolve(flags: flags, env: env, configURL: config).settings.value(k) == probe.value(k), "\(k) flag")
        }
    }

    @Test func validation() {
        var s = Settings()
        #expect(throws: Settings.Invalid.self) { try s.set("mic", "loud") }
        #expect(throws: Settings.Invalid.self) { try s.set("speakers", "-1") }
        #expect(throws: Settings.Invalid.self) { try s.set("nope", "1") }
        try? s.set("mic", "aec")
        #expect(s.mic == "default")  // old name accepted
    }

    @Test func configSetKeepsOtherLines() throws {
        let url = tempDir().appending("c.toml")
        try "# my settings\nhome = \"~/Notes\"  # here\ndebug = false\n".write(to: url, atomically: true, encoding: .utf8)
        try ConfigFile.set("debug", "true", in: url)
        try ConfigFile.set("speakers", "2", in: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "# my settings\nhome = \"~/Notes\"  # here\ndebug = true\nspeakers = 2\n")
        #expect(ConfigFile.read(url).first { $0.0 == "home" }?.1 == "~/Notes")
    }
}
