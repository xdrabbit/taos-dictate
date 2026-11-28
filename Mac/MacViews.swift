import SwiftUI
import Auth

/// Email code sign-in, same TAOS account as the phone.
struct MacSignInView: View {
    @ObservedObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TAOS").font(.largeTitle.bold())
            Text(L(sent ? "signin.code_sent" : "signin.subtitle")).foregroundStyle(.secondary)
            if !sent {
                TextField(L("signin.email"), text: $email)
                    .textContentType(.emailAddress)
                    .onSubmit(send)
                Button(L("signin.send_code"), action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !email.contains("@"))
            } else {
                TextField(L("signin.code"), text: $code)
                    .textContentType(.oneTimeCode)
                    .onSubmit(verify)
                HStack {
                    Button(L("signin.verify"), action: verify)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || code.count < 6)
                    Button(L("signin.change_email")) { sent = false; code = ""; error = nil }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 340)
        .onChange(of: auth.state) { _, s in if case .signedIn = s { dismiss() } }
    }

    private func send() {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await auth.sendCode(to: address); email = address; sent = true }
            catch { self.error = Self.message(for: error, fallback: "signin.send_failed") }
        }
    }

    private func verify() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await auth.verify(email: email, code: code.trimmingCharacters(in: .whitespaces)) }
            catch { self.error = Self.message(for: error, fallback: "signin.bad_code") }
        }
    }

    private static func message(for error: Error, fallback: String) -> String {
        guard let auth = error as? AuthError else { return L(fallback) }
        switch auth.errorCode {
        case .overEmailSendRateLimit: return L("signin.rate_limited")
        case .otpDisabled, .signupDisabled: return L("signin.no_account")
        case .otpExpired: return L("signin.expired")
        default: return L(fallback)
        }
    }
}

/// Languages, dialects and "Our words" for the Mac (kept on this Mac).
struct MacSettingsView: View {
    @State private var mine = SharedPrefs.myLanguage
    @State private var dialects = SharedPrefs.dialects
    @State private var words = SharedPrefs.words
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                Picker(L("speak.i_speak"), selection: $mine) {
                    ForEach(Language.all) { Text($0.label).tag($0.code) }
                }
                ForEach(SharedPrefs.languageCodes.filter { SharedPrefs.dialectRegions[$0] != nil }, id: \.self) { lang in
                    Picker("\(Language.named(lang).label) — \(L("settings.dialect"))", selection: Binding(
                        get: { dialects[lang] ?? "" },
                        set: { dialects[lang] = $0.isEmpty ? nil : $0 }
                    )) {
                        Text(L("settings.dialect_none")).tag("")
                        ForEach(SharedPrefs.dialectRegions[lang] ?? [], id: \.self) { r in
                            Text(Locale.current.localizedString(forRegionCode: r) ?? r).tag(r)
                        }
                    }
                }
            } header: { Text(L("settings.languages")) } footer: { Text(L("settings.dialect_help")).font(.footnote) }

            Section {
                HStack {
                    TextField(L("words.placeholder"), text: $draft).onSubmit(addWord)
                    Button(L("words.add"), action: addWord).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(words, id: \.self) { w in
                    HStack {
                        Text(w)
                        Spacer()
                        Button(role: .destructive) { words.removeAll { $0 == w } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: { Text(L("words.title")) } footer: { Text(L("words.footer")).font(.footnote) }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 520)
        .onChange(of: mine) { _, v in SharedPrefs.myLanguage = v }
        .onChange(of: dialects) { _, v in SharedPrefs.dialects = v }
        .onChange(of: words) { _, v in SharedPrefs.words = v }
    }

    private func addWord() {
        let w = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        draft = ""
        guard !w.isEmpty, words.count < 50,
              !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        words.insert(w, at: 0)
    }
}
