import Foundation
import StringerCore
import StringerKit

/// `stringer doctor`: binaries, signing, permissions, models, Apple
/// Intelligence, settings, devices. Each check is independent and reports
/// rather than throws, so doctor never crashes.
public enum Doctor {
    public struct Check: Codable {
        public var name: String
        public var ok: Bool
        public var detail: String
        public var hint: String?
    }

    public static func run(json: Bool) async -> Int32 {
        var checks: [Check] = []
        func add(_ name: String, _ ok: Bool, _ detail: String, _ hint: String? = nil) {
            checks.append(Check(name: name, ok: ok, detail: detail, hint: hint))
            if !json {
                print("\(ok ? "✓" : "✗") \(name): \(detail)")
                if let hint, !ok { print("    → \(hint)") }
            }
        }

        // Binaries.
        let cli = Binaries.cli, rec = Binaries.recorder, title = Binaries.title
        add("cli", cli.exists, cli.path)
        let recPlist = rec.appending("Contents/Info.plist")
        let plist = NSDictionary(contentsOf: recPlist) as? [String: Any]
        add("recorder", rec.exists && plist != nil, rec.path, "run ./build.sh")
        let strings = ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription"]
        if let plist {
            let missing = strings.filter { plist[$0] == nil }
            add("recorder usage strings", missing.isEmpty, missing.isEmpty ? "microphone and system audio" : "missing \(missing.joined(separator: ", "))")
        }
        // A nested recorder is attributed to its outer app, which must carry them too.
        let outer = rec.deletingLastPathComponent().deletingLastPathComponent()
        if outer.lastPathComponent == "Contents", let op = NSDictionary(contentsOf: outer.appending("Info.plist")) as? [String: Any] {
            let missing = strings.filter { op[$0] == nil }
            add("app usage strings", missing.isEmpty, missing.isEmpty ? "present in \(outer.deletingLastPathComponent().lastPathComponent)" : "missing \(missing.joined(separator: ", ")) — the nested recorder will record zeros")
        }
        add("title helper", title.exists, title.path)

        // Signing.
        let sign = shell("/usr/bin/codesign", ["-d", "-r-", rec.path])
        let req = sign.output
        let certBased = req.contains("certificate root") || req.contains("certificate leaf")
        if certBased {
            add("signing", true, "certificate-based requirement (permission grants survive rebuilds)")
        } else if req.contains("cdhash") {
            add("signing", false, "ad-hoc (permissions will be asked again after every rebuild)", "run ./setup-signing.sh, then ./build.sh")
        } else {
            add("signing", false, "unsigned or unreadable: \(req.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))", "run ./build.sh")
        }
        let keychain = ProcessInfo.processInfo.environment["STRINGER_KEYCHAIN"].map(Paths.expand)
            ?? FileManager.default.homeDirectoryForCurrentUser.appending("Library/Keychains/stringer-signing.keychain-db").path
        let ident = shell("/usr/bin/security", ["find-certificate", "-c", "Stringer Local Signing", keychain])
        add("signing identity", ident.status == 0 || certBased,
            ident.status == 0 ? "Stringer Local Signing in \((keychain as NSString).abbreviatingWithTildeInPath)"
                : certBased ? "not on this Mac (only needed to build; this install is already signed)" : "not created yet",
            "run ./setup-signing.sh (needed only to build; a DMG install is already signed)")

        // Permissions, asked of the recorder itself (its grant, not the terminal's).
        if rec.exists, rec.pathExtension == "app" {
            let tmp = FileManager.default.temporaryDirectory.appending("stringer-perm-\(UUID().uuidString).json")
            _ = shell("/usr/bin/open", ["-n", "-g", "-j", rec.path, "--args", "--permissions", tmp.path])
            let deadline = Date().addingTimeInterval(8)
            while !tmp.exists, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let info = JSON.read([String: String].self, from: tmp) {
                let mic = info["microphone"] ?? "unknown"
                add("microphone permission", mic == "granted", mic, "allow Stringer in System Settings › Privacy & Security › Microphone (it is asked on the first recording)")
                try? FileManager.default.removeItem(at: tmp)
            } else {
                add("microphone permission", false, "the recorder did not answer", "check the recorder launches: open -n \"\(rec.path)\"")
            }
        }
        let store = MeetingStore()
        if let last = store.all().reversed().first(where: { $0.file(MeetingFile.captureJSON).exists }),
           let cap = JSON.read(CaptureReport.self, from: last.file(MeetingFile.captureJSON))
        {
            add("system audio permission", !cap.system.silent,
                cap.system.silent ? "the last kept recording's system track was exact zeros" : String(format: "last kept recording had system audio (peak %.3f)", cap.system.peak),
                "allow Stringer in System Settings › Privacy & Security › Screen & System Audio Recording")
        } else {
            add("system audio permission", true, "not checked yet — asked on the first recording; verified from capture.json in debug mode")
        }

        // Models.
        let status = ModelStatus.check()
        add("speech models", status.ready, status.ready ? "Parakeet TDT v3 + Pyannote diarizer, offline" : "missing: \(status.missing.joined(separator: ", "))\(status.downloading ? " (downloading now)" : "")", "run stringer setup")
        add("vocabulary model", Models.ctcPresent(), Models.ctcPresent() ? "CTC 110M" : "missing (only needed with a vocab file)", "run stringer setup")

        // Apple Intelligence.
        if title.exists {
            let r = shell(title.path, ["--check"])
            add("Apple Intelligence", r.status == 0, r.status == 0 ? "available for meeting titles" : r.output.trimmingCharacters(in: .whitespacesAndNewlines),
                "titles stay automatic; enable Apple Intelligence (and Siri) in System Settings")
        }

        // Settings and storage.
        do {
            let r = try Settings.resolve()
            add("settings", r.problems.isEmpty, r.problems.isEmpty ? Paths.configURL.path : r.problems.joined(separator: "; "))
            let home = r.settings.homeURL
            if home.exists {
                add("meetings folder", FileManager.default.isWritableFile(atPath: home.path), home.path)
            } else {
                var parent = home.deletingLastPathComponent()
                while !parent.exists, parent.path != "/" { parent = parent.deletingLastPathComponent() }
                add("meetings folder", FileManager.default.isWritableFile(atPath: parent.path), "\(home.path) (created on the first recording)")
            }
        } catch {
            add("settings", false, "\(error)")
        }

        // Devices.
        let clock = CA.clockDevice()
        add("tap clock", clock != nil, clock?.description ?? "no real output device")
        let input = CA.defaultInput().flatMap(CA.device)
        add("default input", input != nil, input.map { "\($0)\($0.isVirtual ? " — virtual, a real mic will be used instead" : "")" } ?? "none")

        add("version", true, "stringer \(stringerVersion)")
        if json {
            try? FileHandle.standardOutput.write(JSON.encode(checks))
        }
        return checks.allSatisfy(\.ok) ? 0 : 1
    }

    static func shell(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
