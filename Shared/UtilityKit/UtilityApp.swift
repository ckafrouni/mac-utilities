import AppKit

/// A menu bar app: an icon in the status bar whose menu holds the utility's
/// items, then the ones every utility has (updates, Open at Login, Quit).
/// Or, with `runInBackground`, no icon at all: a shortcut is the only way in.
@MainActor
public enum UtilityApp {
  private static var delegate: NSApplicationDelegate?

  /// Starts the app and never returns. `items` is called each time the menu opens.
  public static func run(
    symbol: String,
    items: @escaping @MainActor () -> [NSMenuItem],
    onLaunch: @escaping @MainActor () -> Void = {}
  ) -> Never {
    let app = NSApplication.shared
    let delegate = Delegate(symbol: symbol, items: items, onLaunch: onLaunch)
    self.delegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
  }

  /// Starts an app with no icon or menu, like the screenshot tool: it's reached
  /// by its shortcuts, and opening the app again (Finder, Spotlight) calls
  /// `onOpen`. It opens at login (added once, on its first launch) and installs
  /// updates by itself. ⌘Q in its own UI is how it quits.
  public static func runInBackground(
    onLaunch: @escaping @MainActor () -> Void,
    onOpen: @escaping @MainActor () -> Void
  ) -> Never {
    let app = NSApplication.shared
    let delegate = BackgroundDelegate(onLaunch: onLaunch, onOpen: onOpen)
    self.delegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
  }

  /// A menu item that runs `action`.
  public static func item(
    _ title: String,
    key: String = "",
    modifiers: NSEvent.ModifierFlags = .command,
    action: @escaping @MainActor () -> Void
  ) -> NSMenuItem {
    let item = ActionMenuItem(title: title, action: #selector(ActionMenuItem.fire), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = item
    item.handler = action
    return item
  }

  public static var name: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
  }

  public static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  /// Shows an alert in front of everything (the app has no windows of its own).
  @discardableResult
  public static func alert(_ title: String, _ message: String = "", buttons: [String] = ["OK"]) -> Int {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    for button in buttons { alert.addButton(withTitle: button) }
    return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
  }
}

@MainActor
private final class ActionMenuItem: NSMenuItem {
  var handler: (@MainActor () -> Void)?
  @objc func fire() { handler?() }
}

@MainActor
private final class BackgroundDelegate: NSObject, NSApplicationDelegate {
  let onLaunch: @MainActor () -> Void
  let onOpen: @MainActor () -> Void

  init(onLaunch: @escaping @MainActor () -> Void, onOpen: @escaping @MainActor () -> Void) {
    self.onLaunch = onLaunch
    self.onOpen = onOpen
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Released builds only: a dev build in build/ shouldn't become a login item.
    if Updater.shared.isEnabled, !UserDefaults.standard.bool(forKey: "addedLoginItem") {
      UserDefaults.standard.set(true, forKey: "addedLoginItem")
      if !LoginItem.isEnabled { LoginItem.toggle() }
    }
    Updater.shared.start(automatic: true)
    onLaunch()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    onOpen()
    return false
  }
}

@MainActor
private final class Delegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let symbol: String
  let items: @MainActor () -> [NSMenuItem]
  let onLaunch: @MainActor () -> Void
  var statusItem: NSStatusItem?

  init(symbol: String, items: @escaping @MainActor () -> [NSMenuItem], onLaunch: @escaping @MainActor () -> Void) {
    self.symbol = symbol
    self.items = items
    self.onLaunch = onLaunch
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: UtilityApp.name)
    image?.isTemplate = true
    statusItem.button?.image = image
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
    self.statusItem = statusItem
    Updater.shared.start()
    onLaunch()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    for item in items() { menu.addItem(item) }
    menu.addItem(.separator())
    if let update = Updater.shared.available {
      menu.addItem(UtilityApp.item("Update to \(update.version)…", key: "") { Updater.shared.install() })
    } else if Updater.shared.isEnabled {
      menu.addItem(UtilityApp.item("Check for Updates…", key: "") { Updater.shared.check(userInitiated: true) })
    }
    let login = UtilityApp.item("Open at Login", key: "") { LoginItem.toggle() }
    login.state = LoginItem.isEnabled ? .on : .off
    menu.addItem(login)
    menu.addItem(.separator())
    let version = NSMenuItem(title: "\(UtilityApp.name) \(UtilityApp.version)", action: nil, keyEquivalent: "")
    version.isEnabled = false
    menu.addItem(version)
    menu.addItem(UtilityApp.item("Quit \(UtilityApp.name)", key: "q") { NSApp.terminate(nil) })
  }
}
