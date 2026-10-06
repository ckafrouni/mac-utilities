import AppKit
import Carbon.HIToolbox
import UtilityKit

// Calipers: measure anything on screen, like PixelSnap. ⌘⇧1 to start.

MainActor.assumeIsolated {
  let overlay = Overlay()

  UtilityApp.run(symbol: "ruler") {
    [UtilityApp.item("Measure", key: "1", modifiers: [.command, .shift]) { overlay.toggle() }]
  } onLaunch: {
    HotKey.register(keyCode: kVK_ANSI_1, modifiers: [.command, .shift]) { overlay.toggle() }
  }
}
