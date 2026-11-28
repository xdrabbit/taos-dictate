import SwiftUI
import AppKit

// TAOS for the Mac: a menu bar app. Hold Right Option, talk, let go — the text
// is typed into whatever has the cursor. All speech work happens on the TAOS
// backend (same /api/dictate as the phone); this app records and pastes.

@main
struct TaosMacApp: App {
    @StateObject private var auth: AuthManager
    @StateObject private var talk: HoldToTalk

    init() {
        let auth = AuthManager()
        _auth = StateObject(wrappedValue: auth)
        _talk = StateObject(wrappedValue: HoldToTalk(auth: auth))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(talk: talk, auth: auth)
        } label: {
            Image(systemName: talk.menuSymbol)
        }

        Window(L("mac.signin_title"), id: "signin") {
            MacSignInView(auth: auth)
        }
        .windowResizability(.contentSize)

        Settings {
            MacSettingsView()
        }
    }
}

/// The menu under the menu bar icon.
struct MenuContent: View {
    @ObservedObject var talk: HoldToTalk
    @ObservedObject var auth: AuthManager
    @Environment(\.openWindow) private var openWindow
    @State private var style = SharedPrefs.style
    @State private var target = SharedPrefs.target ?? ""

    var body: some View {
        Text(talk.statusLine)
        if let message = talk.message { Text(message) }

        if !talk.trusted {
            Button(L("mac.allow_typing")) { talk.askForTrust() }
        }

        Divider()

        Picker(L("mac.style"), selection: $style) {
            ForEach(DictateStyle.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .onChange(of: style) { _, v in SharedPrefs.style = v }

        Picker(L("speak.output"), selection: $target) {
            Text(L("speak.same")).tag("")
            ForEach(Language.all) { Text($0.label).tag($0.code) }
        }
        .onChange(of: target) { _, v in SharedPrefs.target = v.isEmpty ? nil : v }

        SettingsLink { Text(L("mac.settings")) }
            .keyboardShortcut(",")

        Divider()

        switch auth.state {
        case let .signedIn(email):
            Text(email)
            Button(L("settings.sign_out")) { Task { await auth.signOut() } }
        case .signedOut:
            Button(L("mac.sign_in")) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "signin")
            }
        case .loading:
            EmptyView()
        }

        Divider()
        Button(L("mac.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
