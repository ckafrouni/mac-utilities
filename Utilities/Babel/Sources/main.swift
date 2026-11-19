import AppKit
import UtilityKit

// Babel: ⇧⌘2 translates everything foreign on screen into English, drawn in place over
// the original. Text recognition and translation run on the Mac.

MainActor.assumeIsolated {
  _ = NSApplication.shared
  guard #available(macOS 26.4, *) else {
    UtilityApp.alert("Babel needs macOS 26.4 or later", "It uses Apple's newest on-device text recognition and translation.")
    exit(1)
  }

  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.first == "--translate-image" {
    Task { exit(await TranslateImageCommand.run(Array(arguments.dropFirst()))) }
    dispatchMain()
  }

  BabelApp().run()
}
