import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var mine = Prefs.myLanguage
    @State private var other = Prefs.otherLanguage
    @State private var wordCount = SharedPrefs.words.count
    @State private var dialects = SharedPrefs.dialects

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("settings.my_language"), selection: $mine) {
                        ForEach(Language.all) { Text($0.label).tag($0.code) }
                    }
                    dialectPicker(for: mine)
                    Picker(L("settings.other_language"), selection: $other) {
                        ForEach(Language.all.filter { $0.code != mine }) { Text($0.label).tag($0.code) }
                    }
                    dialectPicker(for: other)
                } header: { Text(L("settings.languages")) } footer: { Text(L("settings.dialect_help")) }
                Section {
                    NavigationLink {
                        OurWordsView()
                    } label: {
                        LabeledContent(L("words.title"), value: String(wordCount))
                    }
                } footer: { Text(L("words.footer")) }
                Section {
                    Text(L("settings.keyboard_help")).font(.footnote)
                    Button(L("settings.open_settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: { Text(L("settings.keyboard")) }
                Section {
                    if case let .signedIn(email) = auth.state { Text(email).foregroundStyle(.secondary) }
                    Button(L("settings.sign_out"), role: .destructive) { Task { await auth.signOut() } }
                }
            }
            .navigationTitle(L("tab.settings"))
            .onAppear { wordCount = SharedPrefs.words.count }
            .onChange(of: mine) { _, v in
                Prefs.myLanguage = v
                if other == v { other = v == "es" ? "en" : "es" }
            }
            .onChange(of: other) { _, v in Prefs.otherLanguage = v }
            .onChange(of: dialects) { _, v in SharedPrefs.dialects = v }
        }
    }

    /// "Dialect" under a language, when the server knows regions for it.
    @ViewBuilder private func dialectPicker(for language: String) -> some View {
        if let regions = SharedPrefs.dialectRegions[language] {
            Picker(L("settings.dialect"), selection: Binding(
                get: { dialects[language] ?? "" },
                set: { dialects[language] = $0.isEmpty ? nil : $0 }
            )) {
                Text(L("settings.dialect_none")).tag("")
                ForEach(regions, id: \.self) { region in
                    Text(Locale.current.localizedString(forRegionCode: region) ?? region).tag(region)
                }
            }
            .padding(.leading, 16)
        }
    }
}

/// Names and words spelled the user's way. Kept on the phone (App Group, so the
/// keyboard's dictations use them too) and sent with every request.
struct OurWordsView: View {
    @State private var words = SharedPrefs.words
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(L("words.placeholder"), text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($typing)
                        .onSubmit(add)
                    Button(L("words.add"), action: add)
                        .disabled(clean(draft).isEmpty)
                }
            } footer: { Text(L("words.help")) }
            if !words.isEmpty {
                Section {
                    ForEach(words, id: \.self) { Text($0) }
                        .onDelete { words.remove(atOffsets: $0); save() }
                }
            }
        }
        .navigationTitle(L("words.title"))
        .onAppear { typing = words.isEmpty }
    }

    private func clean(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    private func add() {
        let word = clean(draft)
        guard !word.isEmpty else { return }
        draft = ""
        guard !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }), words.count < 50 else { return }
        words.insert(word, at: 0)
        save()
    }

    private func save() { SharedPrefs.words = words }
}
