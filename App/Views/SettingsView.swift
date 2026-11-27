import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var mine = Prefs.myLanguage
    @State private var other = Prefs.otherLanguage

    var body: some View {
        NavigationStack {
            Form {
                Section(L("settings.languages")) {
                    Picker(L("settings.my_language"), selection: $mine) {
                        ForEach(Language.all) { Text($0.label).tag($0.code) }
                    }
                    Picker(L("settings.other_language"), selection: $other) {
                        ForEach(Language.all.filter { $0.code != mine }) { Text($0.label).tag($0.code) }
                    }
                }
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
            .onChange(of: mine) { _, v in
                Prefs.myLanguage = v
                if other == v { other = v == "es" ? "en" : "es" }
            }
            .onChange(of: other) { _, v in Prefs.otherLanguage = v }
        }
    }
}
