import Foundation

@available(macOS 26.4, *)
@MainActor
final class Settings {
  static let shared = Settings()
  private let defaults = UserDefaults.standard

  /// Languages offered as translation targets.
  static let targetLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("de", "German"), ("nl", "Dutch"), ("fr", "French"), ("es", "Spanish"),
    ("it", "Italian"), ("pt", "Portuguese"), ("pl", "Polish"), ("tr", "Turkish"), ("uk", "Ukrainian"),
    ("ru", "Russian"), ("ar", "Arabic"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
  ]

  var targetLanguage: String {
    get { defaults.string(forKey: "targetLanguage") ?? "en" }
    set { defaults.set(newValue, forKey: "targetLanguage") }
  }

  var quality: TranslationQuality {
    get { TranslationQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .fast }
    set { defaults.set(newValue.rawValue, forKey: "quality") }
  }

  /// nil when the user removed the shortcut (to trigger Babel some other way).
  var shortcut: Shortcut? {
    get {
      if defaults.bool(forKey: "shortcutDisabled") { return nil }
      guard let data = defaults.data(forKey: "shortcut"),
        let value = try? JSONDecoder().decode(Shortcut.self, from: data)
      else { return .default }
      return value
    }
    set {
      defaults.set(newValue == nil, forKey: "shortcutDisabled")
      if let newValue { defaults.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }
  }

  var hasShownWelcome: Bool {
    get { defaults.bool(forKey: "hasShownWelcome") }
    set { defaults.set(newValue, forKey: "hasShownWelcome") }
  }
}
