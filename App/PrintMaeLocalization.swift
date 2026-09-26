import Foundation

/// Japanese is the launch language; English is an optional in-app review language.
func L(_ key: String) -> String {
    let language = UserDefaults.standard.string(forKey: "uiLanguage") == "en" ? "en" : "ja"
    guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
          let bundle = Bundle(path: path) else { return key }
    return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
}
