import SwiftUI

/// Paste a messy message → cleaned original + faithful translation + ambiguity notes.
struct DecoderView: View {
    let api: DictateAPI
    let onSignedOut: () -> Void

    @State private var input = ""
    @State private var result: DecodeResult?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TextEditor(text: $input)
                        .focused($focused)
                        .frame(minHeight: 140)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topLeading) {
                            if input.isEmpty {
                                Text(L("decoder.placeholder")).foregroundStyle(.tertiary).padding(16).allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: 12) {
                        // PasteButton reads the clipboard without the "Allow Paste" prompt.
                        PasteButton(payloadType: String.self) { strings in
                            if let s = strings.first { input = s }
                        }
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        Spacer()
                        if !input.isEmpty {
                            Button(L("speak.clear"), role: .destructive) { input = ""; result = nil; error = nil }
                        }
                    }

                    Button {
                        Task { await decode() }
                    } label: {
                        if busy { ProgressView().tint(.white) } else { Text(L("decoder.decode")) }
                    }
                    .buttonStyle(BigButton())
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    if let r = result {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("decoder.translation")).font(.caption.bold()).foregroundStyle(.secondary)
                            ResultCard(text: r.translation)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("decoder.cleaned") + (r.sourceLanguage.map { " · \($0)" } ?? ""))
                                .font(.caption.bold()).foregroundStyle(.secondary)
                            ResultCard(text: r.cleaned)
                        }
                        if !r.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(L("decoder.notes"), systemImage: "questionmark.bubble")
                                    .font(.subheadline.bold())
                                ForEach(r.notes, id: \.self) { Text("• " + $0).font(.callout) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L("tab.decoder"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func decode() async {
        focused = false
        busy = true; error = nil
        defer { busy = false }
        let reader = Prefs.myLanguage
        var other = Prefs.otherLanguage
        if other == reader { other = reader == "es" ? "en" : "es" }
        do {
            result = try await api.decode(raw: input, reader: reader, other: other)
        } catch let e as DictateError {
            if e == .signedOut { onSignedOut() }
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
