import SwiftUI

struct RootView: View {
    @ObservedObject var auth: AuthManager
    @StateObject private var speak: SpeakModel
    @StateObject private var live: LiveModel
    @State private var tab: String = Prefs.tab
    @ObservedObject private var session = KeyboardSession.shared

    init(auth: AuthManager) {
        self.auth = auth
        let api = DictateAPI(tokens: auth.tokenProvider)
        _speak = StateObject(wrappedValue: SpeakModel(api: api, onSignedOut: { [weak auth] in auth?.sessionRejected() }))
        _live = StateObject(wrappedValue: LiveModel(api: api, onSignedOut: { [weak auth] in auth?.sessionRejected() }))
        KeyboardSession.shared.api = api
    }

    var body: some View {
        TabView(selection: $tab) {
            SpeakView(model: speak)
                .tabItem { Label(L("tab.speak"), systemImage: "mic.fill") }
                .tag("speak")
            LiveView(model: live)
                .tabItem { Label(L("tab.live"), systemImage: "waveform") }
                .tag("live")
            DecoderView(api: DictateAPI(tokens: auth.tokenProvider), onSignedOut: auth.sessionRejected)
                .tabItem { Label(L("tab.decoder"), systemImage: "text.magnifyingglass") }
                .tag("decode")
            SettingsView()
                .tabItem { Label(L("tab.settings"), systemImage: "gearshape") }
                .tag("settings")
        }
        .onChange(of: tab) { _, new in if new != "settings" { Prefs.tab = new } }
        .onOpenURL { url in if url.host == "speak" { tab = "speak" } }
        .safeAreaInset(edge: .top) { if session.isOpen { SessionBanner(session: session) } }
        .fullScreenCover(isPresented: $session.showGuide) { SessionGuideView(session: session) }
    }
}
