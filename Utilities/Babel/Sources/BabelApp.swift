import AppKit
import UtilityKit

/// The menu bar app: the translate shortcut, the menu, Settings, and babel:// links.
@available(macOS 26.4, *)
@MainActor
final class BabelApp {
  private let controller = TranslateController()
  private let settingsModel = SettingsModel()
  private let settings = Settings.shared
  private var hotKey: HotKey.Registration?
  /// The app the user was in before Babel got activated (e.g. by a Raycast quicklink).
  private var previousApp: NSRunningApplication?

  func run() -> Never {
    UtilityApp.run(
      symbol: "translate",
      items: { [unowned self] in self.menuItems() },
      onLaunch: { [unowned self] in self.launch() },
      onOpen: { [unowned self] in self.showSettings() },
      onURL: { [unowned self] url in self.open(url) })
  }

  private func launch() {
    controller.onNeedsPermission = { [unowned self] in self.showSettings() }
    controller.onNeedsLanguageDownload = { source, target in
      WindowPresenter.show(
        id: "download", title: "Babel",
        view: LanguageDownloadView(source: source, target: target) { WindowPresenter.close("download") })
    }
    settingsModel.onShortcutChange = { [unowned self] in self.registerHotKey() }
    settingsModel.onRecording = { [unowned self] recording in
      if recording { self.unregisterHotKey() } else { self.registerHotKey() }
    }

    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
    ) { [unowned self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self.previousApp = app }
      }
    }

    registerHotKey()
    controller.warmUp()

    if !settings.hasShownWelcome || !ScreenCapture.hasPermission {
      settings.hasShownWelcome = true
      showSettings()
    }
  }

  private func menuItems() -> [NSMenuItem] {
    let translate: NSMenuItem
    if let shortcut = settings.shortcut, let key = shortcut.menuKey {
      // Shown for reference; the global shortcut is what fires.
      translate = UtilityApp.item("Translate Screen", key: key, modifiers: shortcut.modifiers) { [unowned self] in
        self.translateFromMenu()
      }
    } else {
      translate = UtilityApp.item("Translate Screen") { [unowned self] in self.translateFromMenu() }
    }
    return [
      translate,
      .separator(),
      UtilityApp.item("Settings…", key: ",") { [unowned self] in self.showSettings() },
    ]
  }

  private func translateFromMenu() {
    // Let the menu close before the screen is captured.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [unowned self] in self.controller.toggle() }
  }

  /// babel://translate: lets Raycast, Shortcuts or a Stream Deck trigger a translation.
  private func open(_ url: URL) {
    guard url.host == "translate" else { return }
    // Opening a URL activates Babel. Hand focus straight back to the app you were in, so the
    // capture shows it as you saw it and your keyboard focus stays put.
    if NSApp.isActive, let previousApp, !previousApp.isTerminated {
      previousApp.activate()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [unowned self] in self.controller.toggle() }
    } else {
      controller.toggle()
    }
  }

  private func registerHotKey() {
    unregisterHotKey()
    guard let shortcut = settings.shortcut else {
      settingsModel.shortcutProblem = nil
      return
    }
    hotKey = HotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [unowned self] in
      self.controller.toggle()
    }
    settingsModel.shortcutProblem = hotKey == nil ? "macOS wouldn't register \(shortcut.display). Try another." : nil
  }

  private func unregisterHotKey() {
    if let hotKey { HotKey.unregister(hotKey) }
    hotKey = nil
  }

  private func showSettings() {
    WindowPresenter.show(id: "settings", title: "Babel Settings", view: SettingsView(model: settingsModel))
  }
}
