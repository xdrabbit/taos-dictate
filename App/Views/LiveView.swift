import SwiftUI

/// Live notes: let it listen to the room. Each pause brings a subtitle (what was
/// said + its translation); Stop keeps it all as a note with a summary.
struct LiveView: View {
    @ObservedObject var model: LiveModel
    @ObservedObject private var store = NotesStore.shared
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if model.phase == .idle && model.lines.isEmpty {
                    idleIntro
                } else {
                    subtitles
                }
                controls
            }
            .navigationTitle(L("tab.live"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { NotesListView(model: model) } label: {
                        Label(L("live.notes"), systemImage: "list.bullet.rectangle")
                    }
                    .disabled(model.phase != .idle)
                }
            }
            .navigationDestination(for: UUID.self) { NoteDetailView(model: model, id: $0) }
            .onChange(of: model.finished) { _, note in
                if let note { path = [note.id]; model.finished = nil }
            }
        }
    }

    // MARK: Before starting

    private var idleIntro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("live.intro")).font(.body)
                languageRow
                Toggle(L("live.save_online"), isOn: $model.saveOnline)
                Text(L("live.save_online_help")).font(.footnote).foregroundStyle(.secondary)
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
                if let last = store.notes.first {
                    Divider()
                    Text(L("live.last_note")).font(.caption.bold()).foregroundStyle(.secondary)
                    NavigationLink(value: last.id) { NoteRow(note: last) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .frame(maxHeight: .infinity)
    }

    private var languageRow: some View {
        HStack {
            Menu {
                Picker(L("speak.i_speak"), selection: $model.mine) {
                    ForEach(Language.all) { Text($0.label).tag($0.code) }
                }
            } label: { pill(L("live.me") + ": " + Language.named(model.mine).label) }
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            Menu {
                Picker(L("live.them"), selection: $model.theirs) {
                    Text(L("live.same_language")).tag(model.mine)
                    ForEach(Language.all.filter { $0.code != model.mine }) { Text($0.label).tag($0.code) }
                }
            } label: {
                pill(L("live.them") + ": " + (model.theirs == model.mine ? L("live.same_language")
                                                                          : Language.named(model.theirs).label))
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.primary)
    }

    // MARK: Listening

    private var subtitles: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.lines) { line in
                        SubtitleRow(line: line, translated: line.text != line.heard).id(line.id)
                    }
                    if model.pending > 0 {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("live.catching_up")).font(.footnote).foregroundStyle(.secondary)
                        }
                        .id(-1)
                    }
                    if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                .padding()
            }
            .onChange(of: model.lines.count) { _, _ in
                withAnimation { proxy.scrollTo(model.lines.last?.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Start / stop

    private var controls: some View {
        VStack(spacing: 8) {
            Button(action: model.toggle) {
                ZStack {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 6)
                        .frame(width: 96 + CGFloat(model.level) * 28, height: 96 + CGFloat(model.level) * 28)
                        .opacity(model.phase == .listening ? 1 : 0)
                        .animation(.easeOut(duration: 0.1), value: model.level)
                    Circle()
                        .fill(model.phase == .listening ? Color.red : Color.taosAccent)
                        .frame(width: 96, height: 96)
                    if model.phase == .finishing {
                        ProgressView().tint(.white).scaleEffect(1.4)
                    } else {
                        Image(systemName: model.phase == .listening ? "stop.fill" : "waveform")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 128)
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .finishing)
            .accessibilityLabel(L(model.phase == .listening ? "live.stop" : "live.start"))

            Group {
                switch model.phase {
                case .idle: Text(L("live.tap_to_start"))
                case .listening:
                    if let start = model.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(String(format: L("live.listening_for"), clock(ctx.date.timeIntervalSince(start))))
                                .monospacedDigit()
                        }
                    }
                case .finishing: Text(L("live.writing_notes"))
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The translation big, what was said small underneath.
private struct SubtitleRow: View {
    let line: LiveLine
    let translated: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.text).font(.title3.weight(.semibold)).textSelection(.enabled)
            if translated {
                Text(line.heard).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoteRow: View {
    let note: LiveNote
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title.isEmpty ? L("live.untitled") : note.title).font(.headline)
            Text(note.startedAt.formatted(date: .abbreviated, time: .shortened) + " · "
                 + String(format: L("live.line_count"), note.lines.count))
                .font(.caption).foregroundStyle(.secondary)
            if !note.summary.isEmpty {
                Text(note.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Every note, newest first, searchable across titles, summaries and lines.
struct NotesListView: View {
    @ObservedObject var model: LiveModel
    @ObservedObject private var store = NotesStore.shared
    @State private var query = ""

    var body: some View {
        let shown = store.notes.filter { $0.matches(query) }
        List {
            ForEach(shown) { note in
                NavigationLink(value: note.id) { NoteRow(note: note) }
            }
            .onDelete { idx in idx.map { shown[$0].id }.forEach(store.delete) }
        }
        .overlay {
            if store.notes.isEmpty {
                ContentUnavailableView(L("live.no_notes"), systemImage: "waveform",
                                       description: Text(L("live.no_notes_help")))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: L("live.search"))
        .navigationTitle(L("live.notes"))
    }
}

/// One note: summary, key points, the whole transcript, Copy and Share.
struct NoteDetailView: View {
    @ObservedObject var model: LiveModel
    let id: UUID
    @ObservedObject private var store = NotesStore.shared
    @State private var retrying = false
    @State private var copied = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let note = store.notes.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(note.startedAt.formatted(date: .complete, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if note.summary.isEmpty {
                        Button {
                            retrying = true
                            Task { _ = await model.summarizeAgain(note); retrying = false }
                        } label: {
                            Label(L("live.summarize_again"), systemImage: "sparkles")
                        }
                        .buttonStyle(BigButton())
                        .disabled(retrying)
                    } else {
                        Text(note.summary)
                        if !note.points.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(note.points, id: \.self) { p in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•"); Text(p)
                                    }
                                }
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = note.plainText
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        } label: {
                            Label(L(copied ? "result.copied" : "result.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(BigButton())
                        ShareLink(item: note.plainText) {
                            Label(L("result.share"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(BigButton(color: .secondary))
                    }
                    Divider()
                    Text(L("live.transcript")).font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(note.lines) { line in
                        SubtitleRow(line: line, translated: line.text != line.heard)
                    }
                }
                .padding()
            }
            .navigationTitle(note.title.isEmpty ? L("live.untitled") : note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                }
            }
            .confirmationDialog(L("live.delete_confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("live.delete"), role: .destructive) { store.delete(id); dismiss() }
            }
        } else {
            ContentUnavailableView(L("live.no_notes"), systemImage: "waveform")
        }
    }
}
