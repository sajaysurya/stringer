import Darwin
import Foundation
import StringerCore
import StringerKit

/// The one process that owns a meeting: it launches the recorder, writes the
/// live transcript, then runs the final pass, the title and cleanup. It is
/// the only writer of `state.json`, which is what lets `stop` never
/// transcribe twice.
public final class Owner: @unchecked Sendable {
    let store: MeetingStore
    let id: String
    var meeting: Meeting
    let settings: Settings
    let log: FileLog
    let printLive: Bool
    var recorderPid: Int32?
    var childRecorder: pid_t?
    var state: OwnerState
    var recognizer: Recognizer?
    var stopRequested = false
    var signalSources: [DispatchSourceSignal] = []

    public init(meeting: Meeting, store: MeetingStore, printLive: Bool = false, echoLog: Bool = false) {
        self.store = store
        id = meeting.id
        self.meeting = meeting
        settings = JSON.read(Settings.self, from: meeting.file(MeetingFile.settings)) ?? .current()
        log = FileLog(meeting.file(MeetingFile.workerLog), echo: echoLog)
        self.printLive = printLive
        state = OwnerState(state: .starting, pid: getpid())
        Models.forbidDownloads()
    }

    // MARK: state

    func refresh() {
        if let m = store.find(id: id) { meeting = m }
    }

    func write(_ s: MeetingState, error: String? = nil) {
        state.state = s
        state.pid = getpid()
        state.recorderPid = recorderPid
        state.error = error ?? state.error
        state.updated = Clock.iso()
        refresh()
        try? AtomicFile.writeJSON(state, to: meeting.file(MeetingFile.state))
    }

    func fail(_ message: String) -> Int32 {
        log("failed: \(message)")
        try? MeetingLock.with(id) {
            refresh()
            meeting = (try? store.update(meeting) {
                $0.outcome = MeetingState.failed.rawValue
                $0.error = message
            }) ?? meeting
        }
        write(.failed, error: message)
        if printLive { FileHandle.standardError.write(Data("stringer: \(message)\n".utf8)) }
        return 1
    }

    // MARK: recording

    /// Records, then finishes. Returns an exit code.
    public func run() async -> Int32 {
        installSignals()
        write(.starting)
        log("owner pid \(getpid()), meeting \(id), mic \(settings.mic)")
        do {
            try launchRecorder()
        } catch {
            return fail("\(error)")
        }
        guard let hello = await waitForRecorder() else {
            return fail("the recorder did not start within 15 s — run `stringer doctor` (see capture.log)")
        }
        recorderPid = hello.pid
        try? MeetingLock.with(id) {
            refresh()
            meeting = try store.update(meeting) { $0.startedAt = Clock.iso(hello.t0) }
        }
        write(.recording)
        log("recording; recorder pid \(hello.pid)")

        let live = await makeLive()
        var crashed = false
        var lastUpdate = Date.distantPast
        while true {
            if meeting.file(MeetingFile.captureJSON).exists { break }
            if !stopRequested && meeting.file(MeetingFile.stop).exists {
                stopRequested = true
            }
            if stopRequested && state.state == .recording {
                write(.stopping)
                log("stopping")
            }
            if !recorderRunning() {
                // Give it a moment to write capture.json.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if meeting.file(MeetingFile.captureJSON).exists { break }
                crashed = true
                log("recorder exited without capture.json — repairing WAV headers")
                break
            }
            // Status about once a second; STOP and capture.json every 250 ms.
            if Date().timeIntervalSince(lastUpdate) >= 1 {
                lastUpdate = Date()
                refresh()
                state.elapsed = Date().timeIntervalSince(hello.t0)
                state.levels = levels()
                if state.state == .recording || state.state == .stopping { write(state.state) }
                if let live, state.state == .recording { await live.step() }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if crashed { repairAudio() }
        if let cap = JSON.read(CaptureReport.self, from: meeting.file(MeetingFile.captureJSON)) {
            log(String(format: "capture: system %.1fs peak %.3f%@ (stop: %@)", cap.system.seconds, cap.system.peak,
                       cap.mic.map { String(format: ", mic %.1fs peak %.3f", $0.seconds, $0.peak) } ?? "", cap.stopReason))
            if cap.system.silent { log("warning: the system track is exact zeros (permission problem if audio played)") }
        }
        return await finish(live: live)
    }

    func installSignals() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                guard let self else { return }
                if !self.stopRequested {
                    self.stopRequested = true
                    touch(self.meeting.file(MeetingFile.stop))
                    if self.printLive { FileHandle.standardError.write(Data("\nstopping — transcribing…\n".utf8)) }
                }
            }
            s.resume()
            signalSources.append(s)
        }
    }

    func launchRecorder() throws {
        let rec = Binaries.recorder
        var args = ["--dir", meeting.dir.path, "--mic", settings.mic]
        let env = ProcessInfo.processInfo.environment
        if let s = env["STRINGER_REPLAY_SYSTEM"] { args += ["--replay-system", s] }
        if let s = env["STRINGER_REPLAY_MIC"] { args += ["--replay-mic", s] }
        if let s = env["STRINGER_REPLAY_SPEED"] { args += ["--replay-speed", s] }
        if let s = env["STRINGER_MAX_SECONDS"] { args += ["--max-seconds", s] }
        if let s = env["STRINGER_TEST_HANG_MIC"] { args += ["--test-hang-mic", s] }
        guard rec.exists else { throw StoreError("recorder not found at \(rec.path) — run ./build.sh") }
        if rec.pathExtension == "app" {
            // LaunchServices, so the permission grants are the bundle's (or
            // its containing app's), never the terminal's. `-n`: a new
            // instance (plain `open` reuses one and drops --args).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", "-g", "-j", rec.path, "--args"] + args
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw StoreError("`open` could not launch the recorder (\(p.terminationStatus))") }
            log("launched recorder via LaunchServices: \(rec.path)")
        } else {
            // A bare executable (tests with replay): no permissions involved.
            childRecorder = try spawnDetached(rec, args, log: nil)
            log("spawned recorder executable \(rec.path) (pid \(childRecorder!))")
        }
    }

    func waitForRecorder() async -> RecorderHello? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let h = RecorderHello.parse(meeting.file(MeetingFile.captureLog)) { return h }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    func recorderRunning() -> Bool {
        if let child = childRecorder {
            var status: Int32 = 0
            if waitpid(child, &status, WNOHANG) == child { childRecorder = nil; return false }
            return true
        }
        return recorderPid.map(processIsAlive) ?? false
    }

    func levels() -> OwnerState.Levels {
        func tail(_ name: String) -> Float {
            let url = meeting.file(name)
            guard let n = WavReader.info(url)?.sampleCount, n > 0 else { return 0 }
            return WavReader.peak(url, from: max(0, n - 16_000), count: 16_000)
        }
        return .init(mic: settings.mic == "none" ? 0 : tail(MeetingFile.mic), system: tail(MeetingFile.system))
    }

    func repairAudio() {
        for name in [MeetingFile.mic, MeetingFile.system] where meeting.file(name).exists {
            if let n = Wav.repair(meeting.file(name)) { log("repaired \(name): \(String(format: "%.1f", Double(n) / 16_000))s") }
        }
    }

    func loadRecognizer() async throws -> Recognizer {
        if let recognizer { return recognizer }
        let r: Recognizer
        if settings.asr == "apple" {
            r = try await AppleSpeech.load()
        } else {
            r = try await ParakeetRecognizer.load(vocabulary: settings.vocabURL) { self.log($0) }
        }
        recognizer = r
        return r
    }

    func makeLive() async -> LiveTranscriber? {
        guard settings.live else { return nil }
        do {
            let r = try await loadRecognizer()
            return LiveTranscriber(dir: meeting.dir, recognizer: r, chunkSeconds: settings.chunk, hasMic: settings.mic != "none",
                                   log: { self.log($0) }, onLine: { line in
                                       if self.printLive { print(line); fflush(stdout) }
                                   })
        } catch {
            log("live transcript off: \(error)")
            return nil
        }
    }

    // MARK: finishing

    /// The final pass, title, naming, cleanup. Also used by `stop` when the
    /// owner died, and by `note` to recover an interrupted meeting.
    public func finish(live: LiveTranscriber? = nil) async -> Int32 {
        write(.transcribing)
        refresh()
        if let live {
            await live.step(final: true)
            log("live: \(live.lines) lines")
        }
        Models.waitForSetup { log($0) }
        let started = Date()
        let output: FinalPass.Output
        do {
            let r = try await loadRecognizer()
            output = try await FinalPass(dir: meeting.dir, settings: settings, recognizer: r) { self.log($0) }.run()
        } catch {
            return fail("transcription failed: \(error)")
        }
        try? AtomicFile.writeJSON(output, to: meeting.file(MeetingFile.finalJSON))
        log(String(format: "final pass: %d words, %d turns, speakers %@ in %.1fs", output.words, output.segments.count,
                   output.speakers.joined(separator: ", "), Date().timeIntervalSince(started)))

        // The title comes before the transcript is written, so it is written
        // once, under its final name.
        var proposed: String?
        if settings.aiTitle, meeting.info.autoTitle {
            proposed = Titler.propose(output.segments, helper: Binaries.title) { self.log($0) }
        }

        let duration = durationSeconds()
        do {
            try MeetingLock.with(id) {
                refresh()
                if let proposed, meeting.info.autoTitle {
                    meeting = try store.update(meeting) { $0.title = proposed }
                    log("title: \(proposed)")
                }
                meeting = try Lifecycle.applyName(meeting, store: store, vault: nil)
                let doc = TranscriptDoc(title: meeting.title, date: meeting.startedAt ?? meeting.created, duration: duration,
                                        speakers: output.speakers, id: id,
                                        body: output.segments.isEmpty ? "(no speech)" : Transcript.render(output.segments))
                try AtomicFile.write(doc.render(), to: meeting.file(MeetingFile.transcript))
                if let vault = settings.vaultURL {
                    do { try Lifecycle.copyToVault(meeting.file(MeetingFile.transcript), vault: vault, name: meeting.dir.lastPathComponent) }
                    catch { log("vault copy failed: \(error)") }
                }
                meeting = try store.update(meeting) {
                    $0.endedAt = Clock.iso()
                    $0.duration = duration
                    $0.speakers = output.speakers
                    $0.outcome = MeetingState.done.rawValue
                    $0.error = nil
                }
            }
        } catch {
            return fail("could not write the transcript: \(error)")
        }
        write(.done)
        log("done: \(meeting.dir.lastPathComponent)")
        if !settings.debug { Lifecycle.cleanup(meeting) }
        if printLive { print("\ntranscript: \(meeting.file(MeetingFile.transcript).path)") }
        return 0
    }

    func durationSeconds() -> Double {
        if let cap = JSON.read(CaptureReport.self, from: meeting.file(MeetingFile.captureJSON)) {
            return max(cap.system.seconds, cap.mic?.seconds ?? 0)
        }
        let a = WavReader.info(meeting.file(MeetingFile.system))?.seconds ?? 0
        let b = WavReader.info(meeting.file(MeetingFile.mic))?.seconds ?? 0
        return max(a, b)
    }

    /// Takes over a meeting whose owner died: stops the recorder (STOP, then
    /// SIGTERM, then SIGKILL), repairs the WAV headers, and finishes.
    public func takeOver() async -> Int32 {
        recorderPid = meeting.owner?.recorderPid
        write(.stopping)
        log("taking over meeting \(id) (owner \(meeting.owner?.pid ?? 0) is gone)")
        touch(meeting.file(MeetingFile.stop))
        if let pid = recorderPid, processIsAlive(pid) {
            for (sig, wait) in [(Int32(0), 10.0), (SIGTERM, 5.0), (SIGKILL, 2.0)] {
                if sig != 0 {
                    kill(pid, sig)
                    log("sent signal \(sig) to recorder \(pid)")
                }
                let deadline = Date().addingTimeInterval(wait)
                while processIsAlive(pid), Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
                if !processIsAlive(pid) { break }
            }
        }
        try? FileManager.default.removeItem(at: meeting.file(MeetingFile.stop))
        if !meeting.file(MeetingFile.captureJSON).exists { repairAudio() }
        return await finish()
    }

    /// Re-transcribes an interrupted (or any) meeting from its audio.
    public func recover() async -> Int32 {
        guard meeting.file(MeetingFile.system).exists || meeting.file(MeetingFile.mic).exists else {
            return fail("no audio left to transcribe (the folder was already cleaned up)")
        }
        repairAudio()
        return await finish()
    }
}
