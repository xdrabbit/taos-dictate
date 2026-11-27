import SwiftUI
import Auth

struct SignInView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("TAOS Dictate").font(.largeTitle.bold())
            Text(L(codeSent ? "signin.code_sent" : "signin.subtitle"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if !codeSent {
                TextField(L("signin.email"), text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Button(L("signin.send_code")) { Task { await send() } }
                    .buttonStyle(BigButton())
                    .disabled(busy || !email.contains("@"))
            } else {
                TextField(L("signin.code"), text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.title2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Button(L("signin.verify")) { Task { await verify() } }
                    .buttonStyle(BigButton())
                    .disabled(busy || code.count < 6)
                Button(L("signin.change_email")) { codeSent = false; code = ""; error = nil }
                    .font(.footnote)
            }

            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).font(.footnote).multilineTextAlignment(.center) }
            Spacer(); Spacer()
        }
        .padding(24)
    }

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespaces).lowercased() }

    private func send() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await auth.sendCode(to: cleanEmail)
            codeSent = true
        } catch {
            self.error = Self.message(for: error, fallback: "signin.send_failed")
        }
    }

    private func verify() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await auth.verify(email: cleanEmail, code: code.trimmingCharacters(in: .whitespaces))
        } catch {
            self.error = Self.message(for: error, fallback: "signin.bad_code")
        }
    }

    /// Supabase's error codes, turned into something the user can act on.
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

struct BigButton: ButtonStyle {
    var color: Color = .taosAccent
    func makeBody(configuration: Configuration) -> some View {
        BigButtonBody(configuration: configuration, color: color)
    }

    private struct BigButtonBody: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.45)
        }
    }
}
