import SwiftUI

/// Shown when the TAOS keyboard's mic opened the app: we're already listening;
/// the user goes back to their chat (◀ in the status bar) and keeps talking.
struct SessionGuideView: View {
    @ObservedObject var session: KeyboardSession

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Image(systemName: "arrow.up.left").font(.title2.bold())
                Text(L("session.go_back_hint")).font(.headline)
                Spacer()
            }
            .foregroundStyle(Color.taosAccent)
            .padding(.top, 8)

            Spacer()

            ZStack {
                Circle()
                    .fill(session.phase == .listening ? Color.red : Color.taosAccent)
                    .frame(width: 150, height: 150)
                    .shadow(color: .red.opacity(session.phase == .listening ? 0.5 : 0), radius: 24)
                if session.phase == .working {
                    ProgressView().tint(.white).scaleEffect(1.6)
                } else {
                    Image(systemName: session.guideIsDecode ? "text.magnifyingglass" : "mic.fill").font(.system(size: 56, weight: .bold)).foregroundStyle(.white)
                }
            }

            Text(L(session.guideIsDecode
                   ? (session.phase == .working ? "session.decoding" : "session.decoded")
                   : (session.phase == .listening ? "session.listening" : "session.ready")))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(L(session.guideIsDecode ? "session.explain_decode" : "session.explain"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let err = session.lastError {
                Text(err).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }

            Spacer()

            if session.phase == .listening {
                Button(L("session.stop_here")) { session.stopListening() }
                    .buttonStyle(BigButton())
            }
            Button(L("session.end"), role: .destructive) {
                session.end()
                session.showGuide = false
            }
            .font(.footnote)
            Button(L("session.stay")) { session.showGuide = false }
                .font(.footnote)
        }
        .padding(24)
        .onChange(of: session.isOpen) { _, open in if !open { session.showGuide = false } }
    }
}

/// A thin strip at the top of the app while a keyboard session holds the mic.
struct SessionBanner: View {
    @ObservedObject var session: KeyboardSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.phase == .listening ? "waveform" : "keyboard")
            Text(L(session.phase == .listening ? "session.banner_listening" : "session.banner_ready"))
                .font(.footnote.weight(.medium))
            Spacer()
            Button(L("session.end")) { session.end() }
                .font(.footnote.bold())
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(session.phase == .listening ? Color.red : Color.taosAccent)
    }
}
