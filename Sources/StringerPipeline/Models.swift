import CoreML
import FluidAudio
import Foundation
import Speech
import StringerCore
import StringerKit

public struct ModelsMissing: Error, CustomStringConvertible {
    public var description: String
}

/// Model management. The network is touched only by `stringer setup`; every
/// other path loads from the cache, and the model registry is pointed at an
/// unreachable address so nothing can download by accident.
public enum Models {
    public static func forbidDownloads() {
        ModelRegistry.baseURL = "http://127.0.0.1:9"
    }

    static var asrDir: URL { AsrModels.defaultCacheDirectory(for: .v3) }
    static var diarizerDir: URL { OfflineDiarizerModels.defaultModelsDirectory() }

    public static func asrPresent() -> Bool { AsrModels.modelsExist(at: asrDir, version: .v3) }

    public static func diarizerPresent() -> Bool {
        let repo = ModelStatus.fluidModels.appending("speaker-diarization")
        return ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"]
            .allSatisfy { repo.appending($0).exists }
    }

    public static func ctcPresent() -> Bool { CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m)) }

    public static func loadASR() async throws -> AsrModels {
        guard asrPresent() else {
            throw ModelsMissing(description: "speech models are not downloaded — run `stringer setup` (the audio is kept)")
        }
        return try await AsrModels.loadFromCache(version: .v3)
    }

    public static func loadDiarizer() async throws -> OfflineDiarizerModels {
        guard diarizerPresent() else {
            throw ModelsMissing(description: "diarization models are not downloaded — run `stringer setup`")
        }
        return try await OfflineDiarizerModels.load()
    }

    public static func loadCTC() async throws -> CtcModels {
        guard ctcPresent() else { throw ModelsMissing(description: "vocabulary model is not downloaded — run `stringer setup`") }
        return try await CtcModels.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }

    /// If `stringer setup` is downloading, waits for it (up to `timeout`).
    public static func waitForSetup(timeout: Double = 1800, log: (String) -> Void) {
        guard ModelStatus.setupRunning() else { return }
        log("models are downloading (stringer setup) — waiting")
        let deadline = Date().addingTimeInterval(timeout)
        while ModelStatus.setupRunning(), Date() < deadline { Thread.sleep(forTimeInterval: 2) }
    }

    /// Downloads every model once. Progress lines go to `progress` as
    /// `(fraction 0–1, label)`. A second run is a no-op.
    public static func setup(force: Bool = false, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if ModelStatus.setupRunning() {
            throw ModelsMissing(description: "another `stringer setup` is already running")
        }
        try AtomicFile.write("\(getpid())\n", to: ModelStatus.setupLock)
        defer { try? FileManager.default.removeItem(at: ModelStatus.setupLock) }

        if !force, asrPresent(), diarizerPresent(), ctcPresent(), ModelStatus.marker.exists {
            progress(1, "models already present")
            return
        }
        try? FileManager.default.removeItem(at: ModelStatus.marker)

        // Weights: speech ~60 %, diarization ~25 %, vocabulary ~15 %.
        progress(0, "speech recognition (Parakeet TDT v3)")
        _ = try await AsrModels.download(version: .v3, progressHandler: { p in
            progress(0.6 * p.fractionCompleted, "speech recognition (Parakeet TDT v3)")
        })
        progress(0.6, "speaker diarization (Pyannote Community-1)")
        _ = try await OfflineDiarizerModels.load(progressHandler: { p in
            progress(0.6 + 0.25 * p.fractionCompleted, "speaker diarization (Pyannote Community-1)")
        })
        progress(0.85, "vocabulary rescoring (CTC 110M)")
        _ = try await CtcModels.download(variant: .ctc110m)

        progress(0.95, "verifying")
        _ = try await AsrModels.loadFromCache(version: .v3)
        guard asrPresent(), diarizerPresent(), ctcPresent() else {
            throw ModelsMissing(description: "download finished but some models are missing")
        }
        try AtomicFile.write(Clock.iso() + "\n", to: ModelStatus.marker)
        await AppleSpeech.installAssets()
        progress(1, "done")
    }
}

// MARK: - recognisers

public protocol Recognizer: Sendable {
    /// Tokens with times relative to the start of `samples` (16 kHz mono).
    func tokens(_ samples: [Float]) async throws -> [Token]
    /// Tokens for a whole file, absolute times.
    func tokens(file: URL) async throws -> [Token]
    /// Rescores a word run against its audio with the vocabulary, if any.
    func rescore(_ words: [Word], tokens: [Token], audio: [Float], offset: Double) async -> [Word]
}

/// Parakeet TDT v3 via FluidAudio, on the Neural Engine.
public final class ParakeetRecognizer: Recognizer, @unchecked Sendable {
    let manager: AsrManager
    let vocab: VocabularyBoostingSession?
    let layers: Int

    public static func load(vocabulary: URL?, log: (String) -> Void) async throws -> ParakeetRecognizer {
        let models = try await Models.loadASR()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var session: VocabularyBoostingSession?
        if let vocabulary, let terms = try? String(contentsOf: vocabulary, encoding: .utf8) {
            let list = terms.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if !list.isEmpty {
                do {
                    let ctc = try await Models.loadCTC()
                    // Spotter rescue over-fires ("published before" → "Postgres"): off.
                    session = try await VocabularyBoostingSession(
                        vocabulary: CustomVocabularyContext(terms: list.map { CustomVocabularyTerm(text: $0) }),
                        ctcModels: ctc,
                        config: VocabularyRescorer.Config(spotterRescueEnabled: false))
                    log("vocabulary: \(list.count) terms")
                } catch {
                    log("vocabulary disabled: \(error)")
                }
            }
        }
        return ParakeetRecognizer(manager: manager, vocab: session, layers: await manager.decoderLayerCount)
    }

    init(manager: AsrManager, vocab: VocabularyBoostingSession?, layers: Int) {
        self.manager = manager
        self.vocab = vocab
        self.layers = layers
    }

    public func tokens(_ samples: [Float]) async throws -> [Token] {
        // FluidAudio needs at least ~1 s; pad short slices with silence.
        var x = samples
        if x.count < 16_000 { x += [Float](repeating: 0, count: 16_000 - x.count) }
        var state = TdtDecoderState.make(decoderLayers: layers)
        let r = try await manager.transcribe(x, decoderState: &state)
        return (r.tokenTimings ?? []).map { Token(text: $0.token, start: $0.startTime, end: $0.endTime) }
    }

    public func tokens(file: URL) async throws -> [Token] {
        var state = TdtDecoderState.make(decoderLayers: layers)
        let r = try await manager.transcribe(file, decoderState: &state)
        return (r.tokenTimings ?? []).map { Token(text: $0.token, start: $0.startTime, end: $0.endTime) }
    }

    public func rescore(_ words: [Word], tokens: [Token], audio: [Float], offset: Double) async -> [Word] {
        guard let vocab, !words.isEmpty, !tokens.isEmpty else { return words }
        let timings = tokens.map {
            TokenTiming(token: $0.text, tokenId: 0, startTime: $0.start - offset, endTime: $0.end - offset, confidence: 1)
        }
        let text = Text.join(words.map(\.text))
        guard let out = await vocab.rescore(text: text, tokenTimings: timings, audioSamples: audio), out.wasModified else {
            return words
        }
        // Put corrected words back on the timed words; if the counts disagree
        // keep the original rather than risk a bad alignment.
        let fixed = out.text.split(separator: " ").map(String.init)
        guard fixed.count == words.count else { return words }
        return zip(words, fixed).map { w, t in
            var w = w
            w.text = t
            return w
        }
    }
}

/// Apple SpeechAnalyzer, the zero-dependency fallback (`asr = apple`). No
/// vocabulary support: `contextualStrings` was inert when tested.
public final class AppleSpeech: Recognizer, @unchecked Sendable {
    let locale: Locale

    public static func load() async throws -> AppleSpeech {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw ModelsMissing(description: "Apple speech recognition does not support \(Locale.current.identifier)")
        }
        return AppleSpeech(locale: locale)
    }

    init(locale: Locale) { self.locale = locale }

    static func installAssets() async {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return }
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await req.downloadAndInstall()
        }
    }

    public func tokens(_ samples: [Float]) async throws -> [Token] {
        let tmp = FileManager.default.temporaryDirectory.appending("stringer-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let w = try WavWriter(url: tmp)
        w.write(samples)
        w.close()
        return try await tokens(file: tmp)
    }

    public func tokens(file: URL) async throws -> [Token] {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [t])
        let audio = try AVAudioFile(forReading: file)
        let collect = Task { () -> [Token] in
            var out: [Token] = []
            for try await r in t.results {
                for run in r.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(r.text[run.range].characters)
                    let parts = piece.split(separator: " ")
                    guard !parts.isEmpty else { continue }
                    // Spread the run's time over its words.
                    let s = range.start.seconds, e = range.end.seconds
                    let step = (e - s) / Double(parts.count)
                    for (i, p) in parts.enumerated() {
                        out.append(Token(text: " " + p, start: s + Double(i) * step, end: s + Double(i + 1) * step))
                    }
                }
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }

    public func rescore(_ words: [Word], tokens: [Token], audio: [Float], offset: Double) async -> [Word] { words }
}

// MARK: - diarization

/// Pyannote Community-1 segmentation and embeddings with VBx clustering,
/// one track at a time.
public final class Diarizer: @unchecked Sendable {
    let models: OfflineDiarizerModels
    let speakers: Int
    let threshold: Double

    public init(models: OfflineDiarizerModels, speakers: Int, threshold: Double) {
        self.models = models
        self.speakers = speakers
        self.threshold = threshold
    }

    public struct Result {
        public var turns: [Transcript.Turn]
        public var embeddings: [String: [Float]]
    }

    public func run(_ file: URL) async throws -> Result {
        var config = OfflineDiarizerConfig()
        if threshold > 0 { config.clustering.threshold = threshold }
        if speakers > 0 { config.clustering.numSpeakers = speakers }
        // Keep short turns ("Yeah.") eligible for their own embedding.
        config.embedding.minSegmentDurationSeconds = 0.5
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let r = try await manager.process(file)
        let turns = r.segments.map { Transcript.Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        return Result(turns: turns, embeddings: r.speakerDatabase ?? [:])
    }
}
