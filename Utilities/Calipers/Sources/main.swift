import AppKit
import Carbon.HIToolbox
import UtilityKit

// Calipers: measure anything on screen, like PixelSnap. ⌘⇧6 to start, like
// the screenshot tool: no icon, opening the app measures too.

MainActor.assumeIsolated {
  let overlay = Overlay()

  UtilityApp.runInBackground {
    HotKey.register(keyCode: kVK_ANSI_6, modifiers: [.command, .shift]) { overlay.toggle() }
    // With no icon, say once that it's there.
    if !UserDefaults.standard.bool(forKey: "welcomed") {
      UserDefaults.standard.set(true, forKey: "welcomed")
      UtilityApp.alert(
        "Calipers is ready",
        "Press ⌘⇧6 to measure anything on screen, on any display. It stays out of sight until then and opens at login. Press ⌘Q while measuring to quit it.")
    }
  } onOpen: {
    overlay.toggle()
  }
}
