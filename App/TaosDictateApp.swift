import SwiftUI

@main
struct TaosDictateApp: App {
    @StateObject private var auth = AuthManager()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // Layout check in the Simulator without signing in: launch with -uiPreview.
                let preview = ProcessInfo.processInfo.arguments.contains("-uiPreview")
                #else
                let preview = false
                #endif
                if preview { RootView(auth: auth) } else {
                switch auth.state {
                case .loading:
                    ProgressView()
                case .signedOut:
                    SignInView()
                case .signedIn:
                    RootView(auth: auth)
                }
                }
            }
            .environmentObject(auth)
            .tint(Color.taosAccent)
            // The TAOS keyboard's mic opens taosdictate://session. Handled here, not in
            // RootView, so a cold launch (still restoring sign-in) isn't lost.
            .onOpenURL { url in
                if url.host == "session" { KeyboardSession.shared.handleOpenFromKeyboard() }
            }
        }
    }
}

extension Color {
    static let taosAccent = Color(red: 0.86, green: 0.38, blue: 0.20)
}
