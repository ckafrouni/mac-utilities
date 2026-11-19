import AppKit
import Carbon.HIToolbox

/// The user's translate shortcut: a virtual key code and its modifiers.
struct Shortcut: Codable, Equatable {
  var keyCode: Int
  var modifierFlags: UInt
  var display: String

  static let `default` = Shortcut(keyCode: kVK_ANSI_2, modifiers: [.command, .shift], display: "⇧⌘2")

  var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

  init(keyCode: Int, modifiers: NSEvent.ModifierFlags, display: String) {
    self.keyCode = keyCode
    self.modifierFlags = modifiers.rawValue
    self.display = display
  }

  /// From a key press, or nil without ⌘, ⌥ or ⌃ (a shortcut needs one).
  init?(event: NSEvent) {
    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
    var symbols = ""
    if flags.contains(.control) { symbols += "⌃" }
    if flags.contains(.option) { symbols += "⌥" }
    if flags.contains(.shift) { symbols += "⇧" }
    if flags.contains(.command) { symbols += "⌘" }
    self.init(keyCode: Int(event.keyCode), modifiers: flags, display: symbols + Self.keyName(event))
  }

  private static func keyName(_ event: NSEvent) -> String {
    let special: [Int: String] = [
      kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
      kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    if let name = special[Int(event.keyCode)] { return name }
    // Not charactersIgnoringModifiers: that still applies ⇧, turning ⇧⌘2 into "⇧⌘@".
    return (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?").uppercased()
  }

  /// One keycap per key: ["⇧", "⌘", "2"].
  var keys: [String] {
    let modifierSymbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
    let mods = display.prefix { modifierSymbols.contains($0) }.map(String.init)
    let key = String(display.dropFirst(mods.count))
    return mods + (key.isEmpty ? [] : [key])
  }

  /// The key to show beside a menu item, when it's a single character.
  var menuKey: String? {
    guard let key = keys.last, key.count == 1 else { return nil }
    return key.lowercased()
  }
}
