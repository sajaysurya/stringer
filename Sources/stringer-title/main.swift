import Foundation
import FoundationModels

// stringer-title: reads a transcript excerpt on stdin, prints a meeting title.
//   exit 0  a title was printed
//   exit 1  keep the automatic name (too little speech, declined, unusable)
//   exit 2  Apple Intelligence is unavailable (`--check` reports why)

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let model = SystemLanguageModel.default
switch model.availability {
case .available:
    if CommandLine.arguments.contains("--check") {
        print("available")
        exit(0)
    }
case .unavailable(let reason):
    switch reason {
    case .deviceNotEligible: fail(2, "this Mac is not eligible for Apple Intelligence")
    case .appleIntelligenceNotEnabled: fail(2, "Apple Intelligence is off (System Settings › Apple Intelligence & Siri)")
    case .modelNotReady: fail(2, "the Apple Intelligence model is not ready yet (still downloading; it cannot download while Siri is off)")
    @unknown default: fail(2, "Apple Intelligence is unavailable (\(reason))")
    }
}

let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
let wordCount = input.split { $0.isWhitespace }.count
// Below ~50 words the model just echoes a transcript line.
guard wordCount >= 50 else { fail(1, "only \(wordCount) words — too little to title") }

let banned = ["Meeting", "Discussion", "Overview", "Sync", "Call", "Update", "Session"]
// Made-up examples: real-looking ones get copied.
let instructions = """
You name meeting recordings. Given an excerpt of a meeting transcript, reply with a short title \
that names the specific subject discussed: 2 to 6 words, Title Case, no quotes, no punctuation at the end. \
Prefer concrete nouns from the conversation (projects, products, decisions, places). \
Never use these generic words: \(banned.joined(separator: ", ")). \
Never use speaker labels such as "Mic 1" or "Speaker 2". \
Examples of the style (invented): "Quarry Lake Permit Appeal", "Blue Heron Pricing Rollout", "Night Shift Staffing Plan".
Reply with the title only.
"""

let session = LanguageModelSession(instructions: instructions)
let prompt = "Transcript excerpt:\n\n\(input)\n\nTitle:"
do {
    // Greedy, so titles are deterministic. `sampling:` is the label the
    // macOS 26 SDK has (27 renames it `samplingMode:` and deprecates this).
    let response = try await session.respond(
        to: prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 32))
    var title = response.content.split(separator: "\n").first.map(String.init) ?? ""
    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#:."))
    if title.lowercased().hasPrefix("title") {
        title = String(title.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
    }
    // Strip filler words from either end.
    let filler: Set<String> = ["the", "a", "an", "and", "of", "on", "for", "about", "meeting", "discussion", "sync", "call", "update", "session", "overview"]
    var words = title.split(separator: " ").map(String.init)
    while let f = words.first, filler.contains(f.lowercased()) { words.removeFirst() }
    while let l = words.last, filler.contains(l.lowercased()) { words.removeLast() }
    title = words.joined(separator: " ")
    guard (2...6).contains(words.count) else { fail(1, "unusable reply: '\(response.content)'") }
    guard title.range(of: #"\b(Mic|Speaker) \d+\b"#, options: .regularExpression) == nil else {
        fail(1, "reply names a speaker label: '\(title)'")
    }
    print(title)
} catch {
    fail(1, "the model declined: \(error)")
}
