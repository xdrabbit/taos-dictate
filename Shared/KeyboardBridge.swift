import Foundation

// The keyboard and the app are separate processes. They talk through two channels:
//   1. App Group UserDefaults — state and data (who asked, what came back).
//   2. Darwin notifications — a nudge that something changed ("go read it now").
// iOS keyboards can't use the microphone, so the app records in the background
// while a "session" is live, and the keyboard drives it with start/stop nudges.
// The keyboard needs Full Access for both channels.

enum KeyboardBridge {
    enum Phase: String { case idle, listening, working, error }

    enum Note {
        static let start = "com.taoslite.dictate.kb.start"   // keyboard → app
        static let stop  = "com.taoslite.dictate.kb.stop"    // keyboard → app
        static let end   = "com.taoslite.dictate.kb.end"     // keyboard → app
        static let decode = "com.taoslite.dictate.kb.decode" // keyboard → app
        static let state = "com.taoslite.dictate.app.state"  // app → keyboard
    }

    private enum K {
        static let heartbeat = "kb.heartbeat"
        static let phase = "kb.phase"
        static let listenStart = "kb.listenStart"
        static let requestID = "kb.request.id"
        static let resultID = "kb.result.id"
        static let resultText = "kb.result.text"
        static let resultDate = "kb.result.date"
        static let consumedID = "kb.result.consumed"
        static let error = "kb.error"
        static let decodeReqID = "kb.decode.request.id"
        static let decodeReqText = "kb.decode.request.text"
        static let decodeResID = "kb.decode.result.id"
        static let decodeResJSON = "kb.decode.result.json"
        static let decodeAwaiting = "kb.decode.awaiting"
        static let decodeAwaitingAt = "kb.decode.awaiting.at"
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: TaosConfig.appGroup) }

    // MARK: Session liveness (app writes every second while the session is open)

    static func beat() { defaults?.set(Date().timeIntervalSince1970, forKey: K.heartbeat) }
    static func clearBeat() { defaults?.removeObject(forKey: K.heartbeat) }
    static var sessionAlive: Bool {
        guard let t = defaults?.object(forKey: K.heartbeat) as? Double else { return false }
        return Date().timeIntervalSince1970 - t < 3
    }

    // MARK: Phase

    static var phase: Phase {
        get { defaults?.string(forKey: K.phase).flatMap(Phase.init) ?? .idle }
        set { defaults?.set(newValue.rawValue, forKey: K.phase) }
    }
    static var listenStart: Date? {
        get { (defaults?.object(forKey: K.listenStart) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { defaults?.set(newValue?.timeIntervalSince1970, forKey: K.listenStart) }
    }
    static var error: String? {
        get { defaults?.string(forKey: K.error) }
        set { defaults?.set(newValue, forKey: K.error) }
    }

    // MARK: Request → result

    /// Set by the keyboard when it asks for a dictation.
    static var requestID: String? {
        get { defaults?.string(forKey: K.requestID) }
        set { defaults?.set(newValue, forKey: K.requestID) }
    }

    static func publishResult(id: String, text: String) {
        guard let d = defaults else { return }
        d.set(text, forKey: K.resultText)
        d.set(Date().timeIntervalSince1970, forKey: K.resultDate)
        d.set(id, forKey: K.resultID)
    }

    /// The result for the keyboard's current request, if it hasn't been typed yet and is fresh.
    static func takeResult() -> String? {
        guard let d = defaults,
              let req = d.string(forKey: K.requestID),
              d.string(forKey: K.resultID) == req,
              d.string(forKey: K.consumedID) != req,
              let text = d.string(forKey: K.resultText), !text.isEmpty,
              let at = d.object(forKey: K.resultDate) as? Double,
              Date().timeIntervalSince1970 - at < 600 else { return nil }
        d.set(req, forKey: K.consumedID)
        return text
    }
}

// MARK: Decoder (keyboard copies a message → app decodes it → keyboard shows it)

/// What the keyboard shows for a decoded message. Mirrors the API's decode reply.
struct DecodedMessage: Codable {
    let translation: String
    let cleaned: String
    let notes: [String]
    let sourceLanguage: String?
}

extension KeyboardBridge {
    /// Keyboard: ask the app to decode `text`. Returns the request id.
    static func requestDecode(_ text: String) -> String {
        let id = UUID().uuidString
        defaults?.set(text, forKey: K.decodeReqText)
        defaults?.set(id, forKey: K.decodeReqID)
        return id
    }

    /// App: the pending decode request, if any.
    static var pendingDecode: (id: String, text: String)? {
        guard let d = defaults, let id = d.string(forKey: K.decodeReqID),
              d.string(forKey: K.decodeResID) != id,
              let text = d.string(forKey: K.decodeReqText), !text.isEmpty else { return nil }
        return (id, text)
    }

    static func publishDecode(id: String, _ m: DecodedMessage) {
        guard let d = defaults, let data = try? JSONEncoder().encode(m) else { return }
        d.set(data, forKey: K.decodeResJSON)
        d.set(id, forKey: K.decodeResID)
    }

    /// Keyboard: the decode it is waiting to show. Stored in the App Group, not in memory,
    /// because iOS starts a fresh keyboard when the user comes back from the app.
    static var awaitingDecode: String? {
        get {
            guard let d = defaults, let id = d.string(forKey: K.decodeAwaiting),
                  let at = d.object(forKey: K.decodeAwaitingAt) as? Double,
                  Date().timeIntervalSince1970 - at < 600 else { return nil }
            return id
        }
        set {
            defaults?.set(newValue, forKey: K.decodeAwaiting)
            defaults?.set(newValue == nil ? nil : Date().timeIntervalSince1970, forKey: K.decodeAwaitingAt)
        }
    }

    /// Keyboard: the decoded message for request `id`, once it's there.
    static func decodeResult(for id: String) -> DecodedMessage? {
        guard let d = defaults, d.string(forKey: K.decodeResID) == id,
              let data = d.data(forKey: K.decodeResJSON) else { return nil }
        return try? JSONDecoder().decode(DecodedMessage.self, from: data)
    }
}

/// Cross-process notifications (CFNotificationCenter's Darwin center). No payload:
/// the receiver reads App Group defaults.
enum DarwinNotify {
    private static var handlers: [String: () -> Void] = [:]
    private static let token = NSObject()

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    static func observe(_ name: String, _ handler: @escaping () -> Void) {
        let first = handlers[name] == nil
        handlers[name] = handler
        guard first else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(token).toOpaque(),
            { _, _, cfName, _, _ in
                guard let n = cfName?.rawValue as String? else { return }
                DispatchQueue.main.async { DarwinNotify.handlers[n]?() }
            },
            name as CFString, nil, .deliverImmediately)
    }
}

/// Choices shared by app and keyboard: languages, style, output language.
enum SharedPrefs {
    private static var d: UserDefaults { UserDefaults(suiteName: TaosConfig.appGroup) ?? .standard }

    static var style: String {
        get { d.string(forKey: "taos.dictate.style") ?? "professional" }
        set { d.set(newValue, forKey: "taos.dictate.style") }
    }
    static var myLanguage: String {
        get { d.string(forKey: "taos.dictate.mine") ?? deviceLanguage }
        set { d.set(newValue, forKey: "taos.dictate.mine") }
    }
    static var otherLanguage: String {
        get { d.string(forKey: "taos.dictate.other") ?? (myLanguage == "es" ? "en" : "es") }
        set { d.set(newValue, forKey: "taos.dictate.other") }
    }
    /// nil = same language as spoken.
    static var target: String? {
        get { d.string(forKey: "taos.dictate.target") }
        set { d.set(newValue, forKey: "taos.dictate.target") }
    }

    /// "Our words": names and words spelled the user's way ("Lu", not "Lou").
    /// Sent with every request; the server uses them as a spelling hint.
    static var words: [String] {
        get { d.stringArray(forKey: "taos.dictate.words") ?? [] }
        set { d.set(newValue, forKey: "taos.dictate.words") }
    }

    static let languageCodes = ["en", "es", "fr", "pt", "it", "de"]
    private static var deviceLanguage: String {
        let code = Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return languageCodes.contains(code) ? code : "en"
    }
}
