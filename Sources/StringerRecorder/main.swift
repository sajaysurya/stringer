import AVFoundation
import CaptureKit
import Foundation
import StringerCore

// Stringer Recorder: capture only. Launched through LaunchServices
// (`open -n`) so macOS attributes the microphone and system-audio grants to
// this signed bundle (or to the app it is nested in), never to a terminal.
//
//   StringerRecorder --dir <meeting folder> [--mic default|all|none]
//                    [--max-seconds N] [--no-aec]
//                    [--replay-system F [--replay-mic F] [--replay-speed X]]
//   StringerRecorder --permissions <out.json>

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: StringerRecorder --dir DIR [--mic default|all|none] [--max-seconds N]\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let out = value("--permissions") {
    // For `stringer doctor`: report this bundle's microphone grant.
    let status: String
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: status = "granted"
    case .denied: status = "denied"
    case .restricted: status = "restricted"
    case .notDetermined: status = "not determined"
    @unknown default: status = "unknown"
    }
    let info = ["microphone": status, "bundle": Bundle.main.bundleIdentifier ?? "", "pid": "\(getpid())"]
    try? AtomicFile.writeJSON(info, to: URL(fileURLWithPath: out))
    exit(0)
}

guard let dir = value("--dir") else { usage() }
var options = Recorder.Options(dir: URL(fileURLWithPath: dir), mic: MicMode(setting: value("--mic") ?? "default"))
if let s = value("--max-seconds"), let v = Double(s) { options.maxSeconds = v }
if args.contains("--no-aec") { options.aec = false }
options.replaySystem = value("--replay-system").map { URL(fileURLWithPath: $0) }
options.replayMic = value("--replay-mic").map { URL(fileURLWithPath: $0) }
if let s = value("--replay-speed"), let v = Double(s) { options.replaySpeed = v }
// Test hook (C-7): this mic's start hangs. Passed as an argument because
// LaunchServices does not hand the environment on.
if let name = value("--test-hang-mic") { setenv("STRINGER_TEST_HANG_MIC", name, 1) }

let recorder = Recorder(options)
exit(recorder.run())
