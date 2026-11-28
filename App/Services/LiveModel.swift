import Foundation
import UIKit

/// One subtitle: what was said, and its translation.
struct LiveLine: Codable, Identifiable, Equatable {
    var id: Int { seq }
    let seq: Int
    let at: Date
    let heard: String
    let heardLang: String
    let text: String
    let textLang: String
}

/// A finished Live session, kept on this iPhone.
struct LiveNote: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date
    let mine: String
    let theirs: String
    var lines: [LiveLine]
    var title: String
    var summary: String
    var points: [String]

    var translated: Bool { mine != theirs }

    /// The whole note as plain text, for Copy and Share.
    var plainText: String {
        var out = [title.isEmpty ? L("live.untitled") : title]
        out.append(startedAt.formatted(date: .abbreviated, time: .shortened))
        if !summary.isEmpty { out.append(""); out.append(summary) }
        if !points.isEmpty { out.append(""); out += points.map { "• " + $0 } }
        out.append("")
        out.append(L("live.transcript"))
        for l in lines {
            out.append(l.heard)
            if translated && l.text != l.heard { out.append("   → " + l.text) }
        }
        return out.joined(separator: "\n")
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q)
            || summary.localizedCaseInsensitiveContains(q)
            || points.contains { $0.localizedCaseInsensitiveContains(q) }
            || lines.contains { $0.heard.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q) }
    }
}

/// Notes as one JSON file each in Application Support/LiveNotes. Never in the
/// App Group: the keyboard has no business reading them.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    @Published private(set) var notes: [LiveNote] = []

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("LiveNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() { load() }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        notes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(LiveNote.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ note: LiveNote) {
        guard let data = try? Self.encoder.encode(note) else { return }
        try? data.write(to: file(note.id), options: [.atomic, .completeFileProtection])
        notes.removeAll { $0.id == note.id }
        notes.insert(note, at: 0)
        notes.sort { $0.startedAt > $1.startedAt }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        notes.removeAll { $0.id == id }
    }

    private func file(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// Live notes: listen, subtitle each piece, keep it as a note.
@MainActor
final class LiveModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [LiveLine] = []
    @Published private(set) var pending = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var level: Float = 0
    @Published var error: String?
    /// The note just finished, to open it.
    @Published var finished: LiveNote?

    @Published var mine: String = Prefs.myLanguage { didSet { Prefs.myLanguage = mine } }
    @Published var theirs: String = Prefs.otherLanguage { didSet { if theirs != mine { Prefs.otherLanguage = theirs } } }
    /// Also keep the lines at taoslite.com/live/saved.
    @Published var saveOnline: Bool = UserDefaults.standard.object(forKey: "taos.live.saveOnline") as? Bool ?? true {
        didSet { UserDefaults.standard.set(saveOnline, forKey: "taos.live.saveOnline") }
    }

    /// A long dinner, not a whole day.
    static let maxSeconds: TimeInterval = 2 * 60 * 60

    private let api: DictateAPI
    private let onSignedOut: () -> Void
    private let recorder = LiveRecorder()
    private var queue: [LiveRecorder.Piece] = []
    private var working = false
    private var seq = 0
    private var sessionID = UUID()
    private var onlineOK = true
    private var saveChain: Task<Void, Never>?
    private var meter: Timer?
    private var sessionMine = "en"
    private var sessionTheirs = "es"

    init(api: DictateAPI, onSignedOut: @escaping () -> Void) {
        self.api = api
        self.onSignedOut = onSignedOut
        recorder.onPiece = { [weak self] p in self?.enqueue(p) }
        recorder.onInterrupted = { [weak self] in self?.stop() }
    }

    func toggle() {
        switch phase {
        case .idle: Task { await start() }
        case .listening: stop()
        case .finishing: break
        }
    }

    private func start() async {
        error = nil
        guard await ChunkedRecorder.requestPermission() else { error = L("error.mic_denied"); return }
        if KeyboardSession.shared.isOpen { KeyboardSession.shared.end() }
        do { try recorder.start() } catch { self.error = L("error.mic_failed"); return }
        lines = []
        seq = 0
        sessionID = UUID()
        onlineOK = saveOnline
        sessionMine = mine
        sessionTheirs = theirs
        startedAt = Date()
        phase = .listening
        UIApplication.shared.isIdleTimerDisabled = true
        meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = self.recorder.level
                if let s = self.startedAt, Date().timeIntervalSince(s) >= Self.maxSeconds { self.stop() }
            }
        }
    }

    func stop() {
        guard phase == .listening else { return }
        meter?.invalidate(); meter = nil
        level = 0
        recorder.stop()            // the last piece joins the queue
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .finishing
        Task { await finish() }
    }

    // MARK: Pieces, one at a time and in order (each uses the last lines as context)

    private func enqueue(_ piece: LiveRecorder.Piece) {
        queue.append(piece)
        pending = queue.count + (working ? 1 : 0)
        if !working { Task { await drain() } }
    }

    private func drain() async {
        working = true
        while !queue.isEmpty {
            let piece = queue.removeFirst()
            pending = queue.count + 1
            await subtitle(piece)
            try? FileManager.default.removeItem(at: piece.url)
        }
        working = false
        pending = 0
    }

    private func subtitle(_ piece: LiveRecorder.Piece) async {
        let context = lines.suffix(2).map(\.heard).joined(separator: "\n")
        do {
            let r = try await api.live(audio: piece.url, mine: sessionMine, theirs: sessionTheirs, context: context)
            let line = LiveLine(seq: seq, at: Date(), heard: r.heard, heardLang: r.heardLang,
                                text: r.text, textLang: r.textLang)
            seq += 1
            lines.append(line)
            keepOnline(line)
        } catch DictateError.nothingHeard {
            // a cough, a door: nothing to show
        } catch DictateError.signedOut {
            error = L("error.signed_out")
            onSignedOut()
        } catch {
            self.error = L("live.piece_failed")
        }
    }

    /// Text only, one line at a time, never blocking the subtitles. A 404 means
    /// this account cannot save online: stop trying for this session.
    private func keepOnline(_ line: LiveLine) {
        guard onlineOK else { return }
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = [
            "session": ["id": sessionID.uuidString.lowercased(), "mine": sessionMine, "theirs": sessionTheirs,
                        "style": "verbatim", "auto": sessionMine != sessionTheirs,
                        "startedAt": iso.string(from: startedAt ?? Date())],
            "line": ["seq": line.seq, "heard": line.heard, "heardLang": line.heardLang,
                     "text": line.text, "textLang": line.textLang, "detect": "hit"],
        ]
        let previous = saveChain
        saveChain = Task { [api] in
            await previous?.value
            do { try await api.saveLiveLine(body) }
            catch DictateError.notAvailable { await MainActor.run { self.onlineOK = false } }
            catch { /* the note on the phone still has it */ }
        }
    }

    // MARK: Finish: wait for the last subtitles, summarize, keep

    private func finish() async {
        while working || !queue.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        let started = startedAt ?? Date()
        startedAt = nil
        guard !lines.isEmpty else { phase = .idle; return }
        var note = LiveNote(id: sessionID, startedAt: started, endedAt: Date(), mine: sessionMine,
                            theirs: sessionTheirs, lines: lines, title: "", summary: "", points: [])
        NotesStore.shared.save(note)   // kept even if the summary fails
        let transcript = lines.map { $0.heard + ($0.text != $0.heard ? " (\($0.text))" : "") }
            .joined(separator: "\n")
        do {
            let s = try await api.summarize(transcript: transcript, reader: sessionMine)
            note.title = s.title
            note.summary = s.summary
            note.points = s.points
            NotesStore.shared.save(note)
        } catch DictateError.signedOut {
            onSignedOut()
        } catch {
            self.error = L("live.summary_failed")
        }
        phase = .idle
        finished = note
    }

    /// For a note whose summary failed: try again.
    func summarizeAgain(_ note: LiveNote) async -> LiveNote {
        var note = note
        let transcript = note.lines.map { $0.heard + ($0.text != $0.heard ? " (\($0.text))" : "") }
            .joined(separator: "\n")
        do {
            let s = try await api.summarize(transcript: transcript, reader: note.mine)
            note.title = s.title
            note.summary = s.summary
            note.points = s.points
            NotesStore.shared.save(note)
        } catch DictateError.signedOut {
            onSignedOut()
        } catch {
            self.error = L("live.summary_failed")
        }
        return note
    }
}
