import Foundation

/// Last style, languages and tab. Style and languages live in the App Group
/// (SharedPrefs) so the keyboard uses the same choices; the tab is app-only.
enum Prefs {
    static var style: DictateStyle {
        get { DictateStyle(rawValue: SharedPrefs.style) ?? .professional }
        set { SharedPrefs.style = newValue.rawValue }
    }
    static var myLanguage: String {
        get { SharedPrefs.myLanguage }
        set { SharedPrefs.myLanguage = newValue }
    }
    static var otherLanguage: String {
        get { SharedPrefs.otherLanguage }
        set { SharedPrefs.otherLanguage = newValue }
    }
    static var target: String? {
        get { SharedPrefs.target }
        set { SharedPrefs.target = newValue }
    }
    static var tab: String {
        get { UserDefaults.standard.string(forKey: "taos.dictate.mode") ?? "speak" }
        set { UserDefaults.standard.set(newValue, forKey: "taos.dictate.mode") }
    }
}
