import AppKit
import AVFoundation
import ApplicationServices

/// Hold the key → record. Let go → send to TAOS → type the result where the cursor is.
@MainActor
final class HoldToTalk: ObservableObject {
    enum Phase: Equatable { case idle, listening, working }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message: String?
    @Published private(set) var trusted = AXIsProcessTrusted()

    /// One request is one chunk on the server: stop and send at 4:30.
    private static let maxSeconds: TimeInterval = 270
    /// Shorter than this is a stray tap of the key, not a dictation.
    private static let minMs = 350

    private let auth: AuthManager
    private let recorder = MacRecorder()
    private var hotkey: HotkeyMonitor?
    private var held = false
    private var capTimer: Timer?
    private var trustTimer: Timer?

    init(auth: AuthManager) {
        self.auth = auth
        installHotkey()
        if !trusted { watchTrust() }
    }

    var menuSymbol: String {
        switch phase {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .working: return "ellipsis.circle"
        }
    }

    var statusLine: String {
        switch phase {
        case .idle: return L("mac.hold_hint")
        case .listening: return L("mac.listening")
        case .working: return L("speak.working")
        }
    }

    // MARK: Permissions

    /// Accessibility lets TAOS see the key from any app and paste for you.
    func askForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        watchTrust()
    }

    private func watchTrust() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, AXIsProcessTrusted() else { return }
                self.trusted = true
                self.trustTimer?.invalidate()
                self.installHotkey() // global monitors start delivering once trusted
            }
        }
    }

    private func installHotkey() {
        hotkey = HotkeyMonitor(
            onDown: { [weak self] in self?.keyDown() },
            onUp: { [weak self] in self?.keyUp() },
            onCancel: { [weak self] in self?.cancel() }
        )
    }

    // MARK: Hold to talk

    private func keyDown() {
        held = true
        guard phase == .idle else { return }
        guard case .signedIn = auth.state else {
            message = L("mac.sign_in_first")
            return
        }
        message = nil
        Task {
            guard await MacRecorder.permission() else {
                message = L("error.mic_denied")
                return
            }
            guard held, phase == .idle else { return } // let go before the mic was ready
            do {
                try recorder.start()
            } catch {
                message = L("error.mic_failed")
                return
            }
            phase = .listening
            Feedback.start()
            HUD.shared.show(.listening)
            capTimer = Timer.scheduledTimer(withTimeInterval: Self.maxSeconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
        }
    }

    private func keyUp() {
        held = false
        if phase == .listening { finish() }
    }

    /// Another key pressed while holding (e.g. ⌥E for an accent): not a dictation.
    private func cancel() {
        guard phase == .listening else { return }
        capTimer?.invalidate()
        recorder.cancel()
        phase = .idle
        HUD.shared.hide()
    }

    private func finish() {
        capTimer?.invalidate()
        guard phase == .listening, let take = recorder.stop() else { return }
        Feedback.stop()
        guard take.ms >= Self.minMs else {
            try? FileManager.default.removeItem(at: take.url)
            phase = .idle
            HUD.shared.hide()
            return
        }
        phase = .working
        HUD.shared.show(.working)
        let api = DictateAPI(tokens: auth.tokenProvider)
        Task {
            defer {
                try? FileManager.default.removeItem(at: take.url)
                phase = .idle
                HUD.shared.hide()
            }
            do {
                let result = try await api.speak(
                    audio: take.url,
                    source: SharedPrefs.myLanguage,
                    style: DictateStyle(rawValue: SharedPrefs.style) ?? .professional,
                    target: SharedPrefs.target
                )
                if !Inserter.insert(result.styled) { message = L("mac.copied_instead") }
            } catch DictateError.signedOut {
                message = L("error.signed_out")
                auth.sessionRejected()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// The recording: AAC, 16 kHz mono, like the phone.
final class MacRecorder {
    private var recorder: AVAudioRecorder?
    private var started: Date?

    static func permission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taos-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        guard r.record() else { throw CocoaError(.fileWriteUnknown) }
        recorder = r
        started = Date()
    }

    func stop() -> (url: URL, ms: Int)? {
        guard let r = recorder, let s = started else { return nil }
        r.stop()
        recorder = nil
        started = nil
        return (r.url, Int(Date().timeIntervalSince(s) * 1000))
    }

    func cancel() {
        if let take = stop() { try? FileManager.default.removeItem(at: take.url) }
    }
}

/// Short system sounds so you know it heard the key without looking.
enum Feedback {
    static func start() { NSSound(named: "Tink")?.play() }
    static func stop() { NSSound(named: "Pop")?.play() }
}
