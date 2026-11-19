import AppKit

/// Runs one "translate the screen" pass: capture → OCR → detect → translate → overlay.
@available(macOS 26.4, *)
@MainActor
final class TranslateController {
  private let pipeline = TranslationPipeline()
  private var overlay: OverlayController?
  private var task: Task<Void, Never>?
  private(set) var recognitionReady = false
  var onNeedsLanguageDownload: ((_ source: String, _ target: String) -> Void)?
  var onNeedsPermission: (() -> Void)?

  func warmUp() {
    Task {
      await TextExtractor.warmUp()
      recognitionReady = true
    }
  }

  /// The hotkey: start a translation, or dismiss the one that's showing.
  func toggle() {
    if let overlay, !overlay.isClosed {
      overlay.close()
      return
    }
    start()
  }

  private func start() {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }

    let overlay = OverlayController(screen: screen)
    overlay.onClose = { [weak self] in
      self?.task?.cancel()
      self?.task = nil
    }
    self.overlay = overlay
    overlay.hud.state = .working(recognitionReady ? "Reading screen…" : "Preparing text recognition (first run only)…")
    overlay.show()

    task = Task { [weak self] in
      await self?.run(overlay: overlay)
    }
  }

  private func run(overlay: OverlayController) async {
    guard ScreenCapture.hasPermission || ScreenCapture.debugImagePath != nil else {
      overlay.hud.state = .message(
        "Babel needs Screen Recording access", symbol: "lock.fill",
        action: .init(title: "Set up…") { [weak self] in
          overlay.close()
          self?.onNeedsPermission?()
        })
      return
    }

    let settings = Settings.shared
    pipeline.targetLanguage = settings.targetLanguage
    pipeline.translator.quality = settings.quality
    let target = settings.targetLanguage

    do {
      let image = try await ScreenCapture.capture(overlay.screen)
      guard !overlay.isClosed else { return }
      overlay.setImagePixelWidth(image.width)

      let summary = try await pipeline.run(image: image) { event in
        guard !overlay.isClosed else { return }
        switch event {
        case let .translating(languages, _):
          let names = languages.map(Translator.displayName).joined(separator: ", ")
          overlay.hud.state = .working("Translating \(names)…")
        case let .layout(layout):
          overlay.add(layout)
        }
      }
      recognitionReady = true
      guard !overlay.isClosed else { return }
      NSLog("Babel: %@", summary.timings.map { "\($0.0) \(String(format: "%.2f", $0.1))s" }.joined(separator: ", "))

      for failure in summary.failures {
        NSLog("Babel: %@ failed: %@", failure.language, String(describing: failure.error))
      }
      // Only surface problems the user can act on; anything else is usually OCR noise.
      if let failure = summary.failures.first(where: { $0.error is TranslatorError }) {
        let message = failure.error.localizedDescription
        var action: HUDModel.Action?
        if case TranslatorError.notInstalled = failure.error {
          action = .init(title: "Download…") { [weak self] in
            overlay.close()
            self?.onNeedsLanguageDownload?(failure.language, target)
          }
        }
        if overlay.layoutCount == 0 {
          overlay.hud.state = .message(message, symbol: "exclamationmark.triangle.fill", action: action)
          return
        }
      }

      if overlay.layoutCount == 0 {
        overlay.hud.state = .message("No foreign text on screen", symbol: "checkmark.circle", action: nil)
        try? await Task.sleep(for: .seconds(1.3))
        overlay.close()
        return
      }
      let from = summary.languages.map(Translator.displayName).joined(separator: ", ")
      overlay.hud.state = .done(title: "\(from) → \(Translator.displayName(target))")
    } catch {
      guard !overlay.isClosed else { return }
      overlay.hud.state = .message(error.localizedDescription, symbol: "exclamationmark.triangle.fill", action: nil)
      try? await Task.sleep(for: .seconds(4))
      overlay.close()
    }
  }
}
