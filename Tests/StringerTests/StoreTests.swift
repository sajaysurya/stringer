import Foundation
import Testing
@testable import CaptureKit
@testable import StringerCore
@testable import StringerKit

@Suite(.serialized) struct StoreTests {
    init() { setenv("STRINGER_SUPPORT", tempDir().path, 1) }

    @Test func sameMinuteMeetingsAreDistinct() throws {
        let store = MeetingStore(home: tempDir())
        let a = try store.create(title: "Standup", source: nil, settings: Settings())
        let b = try store.create(title: "Standup", source: nil, settings: Settings())
        #expect(a.id != b.id)
        #expect(a.dir.path != b.dir.path)
        #expect(b.dir.lastPathComponent.hasSuffix("Standup (2)"))
        #expect(store.find(id: a.id)?.dir.path == a.dir.path && store.find(id: b.id)?.dir.path == b.dir.path)
    }

    @Test func automaticTitles() throws {
        let store = MeetingStore(home: tempDir())
        let z = try store.create(title: nil, source: "Zoom", settings: Settings())
        #expect(z.title == "Zoom meeting" && z.info.autoTitle)
        let m = try store.create(title: "  ", source: nil, settings: Settings())
        #expect(m.title == "Meeting" && m.info.autoTitle)
        let typed = try store.create(title: "Budget", source: "Zoom", settings: Settings())
        #expect(!typed.info.autoTitle)
    }

    func finished(_ store: MeetingStore, title: String) throws -> Meeting {
        var m = try store.create(title: title, source: nil, settings: Settings())
        let doc = TranscriptDoc(title: title, date: Date(), duration: 61, speakers: ["Me", "Them"], id: m.id, body: "[00:00] Me: Hi.")
        try doc.render().write(to: m.file(MeetingFile.transcript), atomically: true, encoding: .utf8)
        try AtomicFile.writeJSON(OwnerState(state: .done, pid: 1), to: m.file(MeetingFile.state))
        m = try store.update(m) { $0.outcome = "done" }
        return Meeting(dir: m.dir)!
    }

    @Test func renameFinishedMeetingMovesFolderAndHeader() throws {
        let store = MeetingStore(home: tempDir())
        let vault = tempDir()
        let m = try finished(store, title: "Meeting")
        let r = try Lifecycle.rename(m, to: "Quarry Permit Appeal", store: store, vault: vault)
        #expect(r.dir.lastPathComponent.hasSuffix(" - Quarry Permit Appeal"))
        #expect(!m.dir.exists)
        #expect(TranscriptDoc.read(r.file(MeetingFile.transcript))?.title == "Quarry Permit Appeal")
        #expect(!r.info.autoTitle)
        #expect(vault.appending(r.dir.lastPathComponent + ".md").exists)
    }

    @Test func renameWhileRecordingOnlyChangesTitle() throws {
        let store = MeetingStore(home: tempDir())
        let m = try store.create(title: nil, source: nil, settings: Settings())
        try AtomicFile.writeJSON(OwnerState(state: .recording, pid: getpid()), to: m.file(MeetingFile.state))
        let r = try Lifecycle.rename(m, to: "Hiring Loop", store: store, vault: nil)
        #expect(r.dir.path == m.dir.path)
        #expect(store.find(id: m.id)?.title == "Hiring Loop")
    }

    @Test func cleanupKeepsOnlyTranscriptsIdentityAndUserFiles() throws {
        let store = MeetingStore(home: tempDir())
        let m = try finished(store, title: "Cleanup")
        for name in MeetingFile.working + [MeetingFile.live] { FileManager.default.createFile(atPath: m.file(name).path, contents: Data("x".utf8)) }
        FileManager.default.createFile(atPath: m.file("my notes.md").path, contents: Data("mine".utf8))
        Lifecycle.cleanup(m)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: m.dir.path))
        #expect(left == ["live.txt", "transcript.txt", "meeting.json", "my notes.md"])  // L-9
        #expect(Meeting(dir: m.dir)?.state == .done)
    }

    @Test func deadOwnerIsInterrupted() throws {
        let store = MeetingStore(home: tempDir())
        let m = try store.create(title: "X", source: nil, settings: Settings())
        // A pid that can't exist.
        try AtomicFile.writeJSON(OwnerState(state: .recording, pid: 999_999), to: m.file(MeetingFile.state))
        #expect(Meeting(dir: m.dir)?.state == .interrupted)
        #expect(store.capturing() == nil)
        try AtomicFile.writeJSON(OwnerState(state: .recording, pid: getpid()), to: m.file(MeetingFile.state))
        #expect(store.capturing()?.id == m.id)
    }

    @Test func transcriptFrontMatterRoundTrip() {
        let doc = TranscriptDoc(title: "Leeds Lease", date: Date(timeIntervalSince1970: 1_800_000_000), duration: 3725,
                                speakers: ["Mic 1", "Speaker 1"], id: "abc", body: "[00:00] Mic 1: Hello.")
        let back = TranscriptDoc.parse(doc.render())
        #expect(back?.title == "Leeds Lease" && back?.duration == 3725 && back?.speakers == ["Mic 1", "Speaker 1"])
        #expect(back?.body == "[00:00] Mic 1: Hello.")
    }

    @Test func changingHomeNeverMovesAMeeting() throws {
        // S-3: a meeting finishing after "Save New Meetings To…" changed stays
        // where it started, and is still found by ID.
        let a = MeetingStore(home: tempDir()), b = MeetingStore(home: tempDir())
        let m = try finished(a, title: "Meeting")
        #expect(b.find(id: m.id)?.dir.path == m.dir.path)
        let r = try Lifecycle.rename(m, to: "Ferry Timetable", store: b, vault: nil)
        #expect(r.dir.deletingLastPathComponent().path == m.dir.deletingLastPathComponent().path)
        #expect(r.dir.lastPathComponent.hasSuffix("Ferry Timetable"))
    }
}
