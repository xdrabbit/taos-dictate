import SwiftUI

struct RootView: View {
    @ObservedObject var auth: AuthManager
    @StateObject private var speak: SpeakModel
    @State private var tab: String = Prefs.tab

    init(auth: AuthManager) {
        self.auth = auth
        let api = DictateAPI(tokens: auth.tokenProvider)
        _speak = StateObject(wrappedValue: SpeakModel(api: api, onSignedOut: { [weak auth] in auth?.sessionRejected() }))
    }

    var body: some View {
        TabView(selection: $tab) {
            SpeakView(model: speak)
                .tabItem { Label(L("tab.speak"), systemImage: "mic.fill") }
                .tag("speak")
            DecoderView(api: DictateAPI(tokens: auth.tokenProvider), onSignedOut: auth.sessionRejected)
                .tabItem { Label(L("tab.decoder"), systemImage: "text.magnifyingglass") }
                .tag("decode")
            SettingsView()
                .tabItem { Label(L("tab.settings"), systemImage: "gearshape") }
                .tag("settings")
        }
        .onChange(of: tab) { _, new in if new != "settings" { Prefs.tab = new } }
        // The keyboard's "open TAOS" button lands here.
        .onOpenURL { url in if url.host == "speak" { tab = "speak" } }
    }
}
