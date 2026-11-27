import Foundation

/// Values shared by the app and the keyboard extension.
enum TaosConfig {
    /// Set once in project.yml (TAOS_APP_GROUP) and read from Info.plist, so the
    /// entitlements and the code can't disagree.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "TaosAppGroup") as? String
        ?? "group.com.taoslite.dictate"
    /// From project.yml (TAOS_DICTATE_URL) via Info.plist, so a test build can use a preview deployment.
    static let dictateURL = (Bundle.main.object(forInfoDictionaryKey: "TaosDictateURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? URL(string: "https://taoslite.com/api/dictate")!
    /// Public by design (same project as taoslite.com, lib/authServer.ts in taos-lite).
    static let supabaseURL = URL(string: "https://duqkmuaceklnfgvoufrz.supabase.co")!
    static let supabaseKey = "sb_publishable_LBhw7XTAhPWjNhbmjcf3uA_r_tbaALD"
    /// URL the keyboard opens to bring the user to the Speak screen.
    static let speakURL = URL(string: "taosdictate://speak")!
}

/// The latest result, written by the app and read by the keyboard's Insert key.
/// Lives in the App Group's UserDefaults; the keyboard needs Full Access to read it.
enum SharedResult {
    private static let textKey = "taos.lastResult.text"
    private static let dateKey = "taos.lastResult.date"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: TaosConfig.appGroup) }

    static func save(_ text: String) {
        guard let d = defaults else { return }
        d.set(text, forKey: textKey)
        d.set(Date(), forKey: dateKey)
    }

    static func load() -> (text: String, date: Date)? {
        guard let d = defaults,
              let text = d.string(forKey: textKey), !text.isEmpty else { return nil }
        return (text, d.object(forKey: dateKey) as? Date ?? .distantPast)
    }
}

/// Short helper so call sites read `L("speak.title")`.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
