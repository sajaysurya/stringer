import AppKit
import ServiceManagement
import StringerCore
import StringerKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let cards = Cards()
    let detector = MeetingDetector()
    let watcher: FolderWatcher
    var snapshot = Snapshot.take()
    var refreshTimer: Timer?
    var animTimer: Timer?
    var phase = 0.0

    /// Meetings we have seen unfinished, by ID. Each one gets a popup when it
    /// finishes, including one finishing while a newer recording runs and
    /// whose folder was renamed meanwhile.
    var watching: Set<String> = []
    /// The recording the icon is showing, and the stopping one (idle at once).
    var shownID: String?
    var stoppingIDs: Set<String> = []
    /// Recordings started from a detection card: these, and only these, stop
    /// on their own once no meeting app has used the mic for 30 s.
    var autoStopIDs: Set<String> = []
    var pending = false
    var setupProgress: (Double, String)?
    var setupFailed: String?

    override init() {
        var refresh: (() -> Void)?
        watcher = FolderWatcher { refresh?() }
        super.init()
        refresh = { [weak self] in self?.refresh() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.image = Icons.idle
        item.button?.imagePosition = .imageLeading
        menu.delegate = self
        item.menu = menu
        watching = Set(snapshot.active.map(\.id))
        watcher.watch(URL(fileURLWithPath: snapshot.home))
        refresh()
        detector.onStart = { [weak self] app in self?.meetingDetected(app) }
        detector.start()
        if !snapshot.models.ready && !snapshot.models.downloading { downloadModels() }
    }

    // MARK: refresh

    func scheduleRefresh() {
        refreshTimer?.invalidate()
        let busy = !snapshot.active.isEmpty
        refreshTimer = Timer.scheduledTimer(withTimeInterval: busy ? 1 : 3, repeats: false) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let previousHome = snapshot.home
        snapshot = Snapshot.take()
        if snapshot.home != previousHome { watcher.watch(URL(fileURLWithPath: snapshot.home)) }
        let activeIDs = Set(snapshot.active.map(\.id))
        // Announce every watched meeting that is no longer active.
        for id in watching.subtracting(activeIDs) {
            announce(id)
        }
        watching = watching.union(activeIDs).intersection(activeIDs)
        stoppingIDs = stoppingIDs.intersection(activeIDs)

        // Auto-stop only recordings started from the card.
        if let rec = recording, autoStopIDs.contains(rec.id), detector.ended {
            autoStopIDs.remove(rec.id)
            stop(rec.id)
        }
        updateIcon()
        scheduleRefresh()
    }

    /// The meeting holding the recording slot and actually recording.
    var recording: MeetingSummary? {
        snapshot.active.last { ($0.state == .recording || $0.state == .starting) && !stoppingIDs.contains($0.id) }
    }

    func announce(_ id: String) {
        guard let m = MeetingStore(home: URL(fileURLWithPath: snapshot.home)).find(id: id) else {
            trace?("announce: \(id) not found")
            return
        }
        trace?("announce \(m.state.rawValue) id=\(id) title=\(m.title) dir=\(m.dir.lastPathComponent)")
        autoStopIDs.remove(id)
        switch m.state {
        case .done:
            let transcript = m.file(MeetingFile.transcript)
            cards.show(title: "Transcript ready", message: m.title, buttons: [
                .init(title: "Dismiss") {},
                .init(title: "Open") { NSWorkspace.shared.open(transcript) },
            ], timeout: 30)
        case .failed:
            cards.show(title: "Recording failed", message: "\(m.title)\n\(m.owner?.error ?? m.info.error ?? "see worker.log")", buttons: [
                .init(title: "Dismiss") {},
                .init(title: "Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([m.dir]) },
            ], timeout: nil)
        case .interrupted:
            cards.show(title: "Recording interrupted", message: "\(m.title)\nRecover it with `stringer note`.", buttons: [
                .init(title: "Dismiss") {},
            ], timeout: 30)
        default:
            break
        }
    }

    // MARK: icon

    func updateIcon() {
        guard let button = item.button else { return }
        if let rec = recording, rec.state == .recording {
            if shownID != rec.id {
                shownID = rec.id
                trace?("icon recording id=\(rec.id) started_at=\(rec.startedAt ?? "?")")
            }
            if animTimer == nil {
                animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8, repeats: true) { [weak self] _ in self?.animate() }
            }
            animate()
        } else {
            if shownID != nil { trace?("icon idle") }
            shownID = nil
            animTimer?.invalidate()
            animTimer = nil
            button.image = Icons.idle
            button.title = ""
        }
    }

    func animate() {
        guard let rec = recording, rec.state == .recording, let button = item.button else { return updateIcon() }
        phase += 0.9
        // The timer is derived from this meeting's own started_at, never from
        // polled elapsed time, so it never jumps and restarts per meeting.
        let elapsed = Clock.parse(rec.startedAt).map { max(0, Date().timeIntervalSince($0)) } ?? 0
        if Int(phase / 0.9) % 8 == 0 { trace?("timer id=\(rec.id.prefix(8)) \(Clock.stamp(elapsed)) levels mic=\(rec.levels.mic) system=\(rec.levels.system)") }
        button.image = Icons.recording(mic: rec.levels.mic, system: rec.levels.system, phase: phase, timer: Clock.stamp(elapsed))
        button.title = ""
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let s = snapshot
        if let rec = recording {
            let elapsed = Clock.parse(rec.startedAt).map { Date().timeIntervalSince($0) } ?? 0
            menu.addItem(disabled(rec.state == .starting ? "Starting…" : "Recording — \(Clock.stamp(elapsed))"))
            menu.addItem(disabled(rec.title))
            menu.addItem(action("Rename…", #selector(renameCurrent), enabled: !pending))
            menu.addItem(action("Stop Recording", #selector(stopCurrent), key: "s", enabled: !pending))
            menu.addItem(action("Open Live Transcript", #selector(openLive)))
        } else {
            menu.addItem(action("Start Recording", #selector(startRecording), key: "r", enabled: !pending && s.models.ready))
            if let last = s.last {
                menu.addItem(action("Open Last Transcript", #selector(openLastTranscript), enabled: last.transcript != nil))
                menu.addItem(action("Open Last Live Transcript", #selector(openLastLive), enabled: last.live != nil))
                menu.addItem(action("Rename Last Meeting…", #selector(renameLast), enabled: !pending))
            }
        }
        for m in s.active where m.state == .transcribing || m.state == .stopping || stoppingIDs.contains(m.id) {
            menu.addItem(disabled("Transcribing “\(m.title)”…"))
        }
        if !s.models.ready {
            if let (f, label) = setupProgress {
                menu.addItem(disabled("Downloading speech models… \(Int(f * 100))%"))
                if !label.isEmpty { menu.addItem(disabled("  \(label)")) }
            } else if let err = setupFailed {
                menu.addItem(disabled("Model download failed: \(err.prefix(60))"))
                menu.addItem(action("Retry Download", #selector(retryDownload)))
            } else {
                menu.addItem(disabled("Speech models missing"))
                menu.addItem(action("Download Speech Models", #selector(retryDownload)))
            }
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Meetings Folder", #selector(openFolder)))
        menu.addItem(action("Save New Meetings To…", #selector(chooseFolder)))
        menu.addItem(disabled("  " + (s.home as NSString).abbreviatingWithTildeInPath))
        menu.addItem(.separator())
        menu.addItem(toggle("Ask to Record Detected Meetings", #selector(toggleDetect), on: s.settings.detect))
        menu.addItem(toggle("Debug Mode", #selector(toggleDebug), on: s.settings.debug))
        menu.addItem(toggle("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(action("Quit Stringer", #selector(quit), key: "q"))
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func action(_ title: String, _ sel: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: enabled ? sel : nil, keyEquivalent: key)
        i.target = self
        i.isEnabled = enabled
        return i
    }

    func toggle(_ title: String, _ sel: Selector, on: Bool) -> NSMenuItem {
        let i = action(title, sel)
        i.state = on ? .on : .off
        return i
    }

    // MARK: actions

    @objc func startRecording() { start(source: nil) }

    func start(source: String?) {
        guard !pending else { return }
        pending = true
        var args = ["start", "--json"]
        if let source { args += ["--source", source] }
        Backend.run(args) { [weak self] r in
            guard let self else { return }
            self.pending = false
            if let data = r.stdout.data(using: .utf8), let m = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
                self.watching.insert(m.id)
                if source != nil { self.autoStopIDs.insert(m.id) }
                if m.state.isTerminal { self.announce(m.id) }
            } else if r.status != 0 {
                self.cards.show(title: "Recording failed", message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines), buttons: [.init(title: "OK") {}], timeout: nil)
            }
            self.refresh()
        }
    }

    @objc func stopCurrent() {
        guard let rec = recording else { return }
        stop(rec.id)
    }

    func stop(_ id: String) {
        // The icon goes idle as soon as stopping begins.
        stoppingIDs.insert(id)
        updateIcon()
        pending = true
        Backend.run(["stop", id, "--no-wait", "--json"]) { [weak self] _ in
            self?.pending = false
            self?.refresh()
        }
    }

    @objc func renameCurrent() {
        guard let rec = recording else { return }
        rename(id: rec.id, current: rec.title)
    }

    @objc func renameLast() {
        guard let last = snapshot.last else { return }
        rename(id: last.id, current: last.title)
    }

    func rename(id: String, current: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename Meeting"
        alert.informativeText = "The meeting's folder and transcript follow the new name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != current else { return }
        pending = true
        Backend.run(["rename", id, title, "--json"]) { [weak self] r in
            self?.pending = false
            if r.status != 0 {
                self?.cards.show(title: "Rename failed", message: r.stderr, buttons: [.init(title: "OK") {}], timeout: 10)
            }
            self?.refresh()
        }
    }

    @objc func openLive() {
        if let p = recording?.live ?? recording.map({ $0.dir + "/" + MeetingFile.live }) { open(p) }
    }

    @objc func openLastTranscript() { snapshot.last?.transcript.map(open) }
    @objc func openLastLive() { snapshot.last?.live.map(open) }

    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    @objc func openFolder() {
        let url = URL(fileURLWithPath: snapshot.home)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "New meetings will be saved in this folder."
        panel.directoryURL = URL(fileURLWithPath: snapshot.home)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setting("home", url.path)
    }

    @objc func toggleDetect() { setting("detect", snapshot.settings.detect ? "false" : "true") }
    @objc func toggleDebug() { setting("debug", snapshot.settings.debug ? "false" : "true") }

    /// Settings change only through the CLI, so the CLI and the app agree.
    func setting(_ key: String, _ value: String) {
        Backend.run(["config", "set", key, value]) { [weak self] r in
            if r.status != 0 {
                self?.cards.show(title: "Could not change \(key)", message: r.stderr, buttons: [.init(title: "OK") {}], timeout: 10)
            }
            self?.refresh()
        }
    }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            cards.show(title: "Launch at Login", message: "\(error.localizedDescription)", buttons: [.init(title: "OK") {}], timeout: 10)
        }
        // The menu reads the real status next time it opens.
    }

    @objc func retryDownload() { downloadModels() }

    func downloadModels() {
        setupFailed = nil
        setupProgress = (0, "starting")
        cards.show(title: "Downloading speech models", message: "About 600 MB, once. After this Stringer works fully offline.",
                   buttons: [.init(title: "OK") {}], timeout: 10)
        Backend.setup(progress: { [weak self] f, label in
            self?.setupProgress = (f, label)
        }, done: { [weak self] ok, err in
            guard let self else { return }
            self.setupProgress = nil
            if ok {
                self.cards.show(title: "Ready to record", message: "Speech models are installed.", buttons: [.init(title: "OK") {}], timeout: 10)
            } else {
                self.setupFailed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.refresh()
        })
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: detection

    func meetingDetected(_ app: String) {
        guard snapshot.settings.detect, snapshot.models.ready else { return }
        // Already recording (started by hand): adopt the meeting, don't prompt.
        guard recording == nil, !pending else { return }
        cards.show(title: "\(app) is using the microphone", message: "Record this meeting? Stringer stops on its own when the call ends.",
                   buttons: [
                       .init(title: "Not Now") {},
                       .init(title: "Record") { [weak self] in self?.start(source: app) },
                   ], timeout: 30)
    }
}

/// Opt-in trace for tests (`STRINGER_APP_TRACE=/path/to/log`).
let trace: FileLog? = ProcessInfo.processInfo.environment["STRINGER_APP_TRACE"].map { FileLog(URL(fileURLWithPath: $0)) }

// `Stringer --render-icons DIR`: writes the menu-bar images as PNGs and exits.
if let i = CommandLine.arguments.firstIndex(of: "--render-icons"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func png(_ img: NSImage, _ name: String, scale: CGFloat = 4) {
        let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending("\(name).png"))
    }
    png(Icons.idle, "idle")
    png(Icons.recording(mic: 0.3, system: 0.05, phase: 1, timer: "12:34"), "recording-both")
    png(Icons.recording(mic: 0.0005, system: 0.2, phase: 2, timer: "1:02:03"), "recording-mic-silent")
    png(Icons.recording(mic: 0, system: 0, phase: 0, timer: "00:00"), "recording-silent")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
