import Foundation

/// Last style, languages and tab, remembered on this device.
enum Prefs {
    private static let d = UserDefaults.standard

    static var style: DictateStyle {
        get { d.string(forKey: "taos.dictate.style").flatMap(DictateStyle.init) ?? .professional }
        set { d.set(newValue.rawValue, forKey: "taos.dictate.style") }
    }

    /// The phone owner's language: what they speak and read. Defaults to the device language.
    static var myLanguage: String {
        get { d.string(forKey: "taos.dictate.mine") ?? deviceLanguage }
        set { d.set(newValue, forKey: "taos.dictate.mine") }
    }

    /// The other side of the pair (Decoder translates to/from it).
    static var otherLanguage: String {
        get { d.string(forKey: "taos.dictate.other") ?? (myLanguage == "es" ? "en" : "es") }
        set { d.set(newValue, forKey: "taos.dictate.other") }
    }

    /// Output language of a dictation: nil = same as spoken.
    static var target: String? {
        get { d.string(forKey: "taos.dictate.target") }
        set { d.set(newValue, forKey: "taos.dictate.target") }
    }

    static var tab: String {
        get { d.string(forKey: "taos.dictate.mode") ?? "speak" }
        set { d.set(newValue, forKey: "taos.dictate.mode") }
    }

    private static var deviceLanguage: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Language.all.contains { $0.code == code } ? code : "en"
    }
}
