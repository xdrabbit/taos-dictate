import SwiftUI

struct SpeakView: View {
    @ObservedObject var model: SpeakModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    languageRow
                    stylePills
                    micButton
                    if let error = model.error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    if let r = model.result {
                        ResultCard(
                            text: r.styled,
                            busy: model.phase == .restyling,
                            secondary: model.showOriginal ? r.raw : nil,
                            secondaryTitle: L("speak.original")
                        )
                        HStack {
                            Button(L(model.showOriginal ? "speak.hide_original" : "speak.show_original")) {
                                model.showOriginal.toggle()
                            }
                            Spacer()
                            Button(L("speak.clear"), role: .destructive) { model.clear() }
                        }
                        .font(.footnote)
                    }
                }
                .padding()
            }
            .navigationTitle(L("tab.speak"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var languageRow: some View {
        HStack {
            Menu {
                Picker(L("speak.i_speak"), selection: $model.source) {
                    ForEach(Language.all) { Text($0.label).tag($0.code) }
                }
            } label: {
                pill(L("speak.i_speak") + ": " + Language.named(model.source).label, on: false)
            }
            .disabled(model.phase == .recording)
            Spacer()
            Menu {
                Picker(L("speak.output"), selection: $model.target) {
                    Text(L("speak.same")).tag(String?.none)
                    ForEach(Language.all.filter { $0.code != model.source }) { Text($0.label).tag(Optional($0.code)) }
                }
            } label: {
                pill(L("speak.output") + ": " + (model.target.map { Language.named($0).label } ?? L("speak.same")),
                     on: model.target != nil)
            }
        }
    }

    private var stylePills: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(DictateStyle.allCases) { s in
                Button { model.style = s } label: {
                    Text(s.label)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(model.style == s ? Color.taosAccent : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(model.style == s ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pill(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(on ? Color.taosAccent : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(on ? .white : .primary)
    }

    private var micButton: some View {
        VStack(spacing: 12) {
            Button(action: model.toggle) {
                ZStack {
                    Circle()
                        .fill(model.phase == .recording ? Color.red : Color.taosAccent)
                        .frame(width: 168, height: 168)
                        .shadow(color: (model.phase == .recording ? Color.red : .clear).opacity(0.5), radius: 24)
                    if model.phase == .working {
                        ProgressView().tint(.white).scaleEffect(1.8)
                    } else {
                        Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 64, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .working)
            .accessibilityLabel(L(model.phase == .recording ? "speak.stop" : "speak.start"))

            if let start = model.startedAt {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(start)
                    let remaining = max(0, ChunkedRecorder.maxSeconds - elapsed)
                    VStack(spacing: 4) {
                        Text(clock(elapsed)).font(.title.monospacedDigit().bold())
                        Text(String(format: L("speak.remaining"), clock(remaining)))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(remaining <= 30 ? .red : .secondary)
                    }
                }
            } else {
                Text(L(model.phase == .working ? "speak.working" : "speak.tap_to_start"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Styled text plus big Copy and Share.
struct ResultCard: View {
    let text: String
    var busy = false
    var secondary: String? = nil
    var secondaryTitle = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(busy ? 0.4 : 1)
                if busy { ProgressView() }
            }
            if let secondary {
                Divider()
                Text(secondaryTitle).font(.caption.bold()).foregroundStyle(.secondary)
                Text(secondary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(L(copied ? "result.copied" : "result.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(BigButton())
                ShareLink(item: text) {
                    Label(L("result.share"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(BigButton(color: .secondary))
            }
            .disabled(busy)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}
