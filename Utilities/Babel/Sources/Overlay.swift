import AppKit
import Carbon.HIToolbox
import SwiftUI
import UtilityKit

/// Full-screen transparent panel above everything (menu bar included). It never becomes
/// key or activates Babel, so the app underneath keeps focus.
final class OverlayPanel: NSPanel {
  init(screen: NSScreen) {
    super.init(
      contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    level = .screenSaver
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    ignoresMouseEvents = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    setFrame(screen.frame, display: false)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Draws translated paragraphs over the spots where the originals are.
final class OverlayCanvas: NSView {
  var layouts: [BlockLayout] = [] { didSet { needsDisplay = true } }
  /// Captured-image pixels per view point.
  var pixelScale: CGFloat = 2
  var hoveredID: Int? { didSet { if hoveredID != oldValue { needsDisplay = true } } }
  var showingOriginal = false { didSet { if showingOriginal != oldValue { needsDisplay = true } } }
  var onClickLayout: ((BlockLayout) -> Void)?

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard !showingOriginal, let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.scaleBy(x: 1 / pixelScale, y: 1 / pixelScale)
    for layout in layouts {
      layout.draw(in: ctx, highlighted: layout.blockID == hoveredID)
    }
    ctx.restoreGState()
  }

  func layout(at point: NSPoint) -> BlockLayout? {
    guard !showingOriginal else { return nil }
    let p = CGPoint(x: point.x * pixelScale, y: point.y * pixelScale)
    return layouts.last { $0.fillRect.contains(p) }
  }

  override func mouseDown(with event: NSEvent) {
    if let hit = layout(at: convert(event.locationInWindow, from: nil)) {
      onClickLayout?(hit)
    }
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// NSHostingView that responds to the first click even though its window is never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns one overlay on one screen: drawing, hover, copy, ⌥-to-peek and every way of dismissing it.
@MainActor
final class OverlayController {
  let screen: NSScreen
  let hud = HUDModel()
  private let panel: OverlayPanel
  private let container: FlippedView
  private let canvas: OverlayCanvas
  private let hudView: NSView
  private var timer: Timer?
  private var monitors: [Any] = []
  private var observers: [NSObjectProtocol] = []
  private var escapeKey: HotKey.Registration?
  private let shownAt = Date()
  private(set) var isClosed = false
  var onClose: (() -> Void)?

  init(screen: NSScreen) {
    self.screen = screen
    panel = OverlayPanel(screen: screen)
    let bounds = NSRect(origin: .zero, size: screen.frame.size)
    container = FlippedView(frame: bounds)
    panel.contentView = container
    // Translations and the HUD are siblings so the translations can fade in on their own.
    canvas = OverlayCanvas(frame: bounds)
    canvas.autoresizingMask = [.width, .height]
    canvas.pixelScale = screen.backingScaleFactor
    canvas.wantsLayer = true
    container.addSubview(canvas)

    let host = FirstClickHostingView(rootView: HUDView(model: hud))
    host.sizingOptions = [.intrinsicContentSize]
    host.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(host)
    // Bottom-centre, clear of the Dock.
    let bottomInset = max(28, screen.visibleFrame.minY - screen.frame.minY + 24)
    NSLayoutConstraint.activate([
      host.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      host.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottomInset),
    ])
    hudView = host

    canvas.onClickLayout = { [weak self] layout in
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(layout.translatedText, forType: .string)
      self?.hud.flash("Copied translation")
    }
    hud.onCopyAll = { [weak self] in self?.copyAll() }
    hud.onToggleOriginal = { [weak self] in
      guard let self else { return }
      self.hud.pinnedOriginal.toggle()
    }
  }

  func show() {
    panel.orderFrontRegardless()
    startTracking()
  }

  func setImagePixelWidth(_ width: Int) {
    canvas.pixelScale = CGFloat(width) / screen.frame.width
  }

  func add(_ layout: BlockLayout) {
    guard !isClosed else { return }
    if canvas.layouts.isEmpty {
      canvas.alphaValue = 0
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        canvas.animator().alphaValue = 1
      }
    }
    canvas.layouts.append(layout)
  }

  var layoutCount: Int { canvas.layouts.count }

  private func copyAll() {
    let text = canvas.layouts
      .sorted {
        abs($0.fillRect.minY - $1.fillRect.minY) > 6 ? $0.fillRect.minY < $1.fillRect.minY : $0.fillRect.minX < $1.fillRect.minX
      }
      .map(\.translatedText)
      .joined(separator: "\n\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    hud.flash("Copied all translations")
  }

  // MARK: Interaction

  private func startTracking() {
    // Poll the pointer and ⌥: works without Accessibility permission, and lets clicks
    // fall through to the app underneath everywhere except on translations and the HUD.
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.track() }
    }

    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      } as Any)
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
        MainActor.assumeIsolated {
          guard let self, Date().timeIntervalSince(self.shownAt) > 0.4, event.momentumPhase.isEmpty else { return }
          self.close()
        }
      } as Any)

    // Switching apps or Spaces means the screen underneath has changed.
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        MainActor.assumeIsolated {
          // Ignore the hand-back of focus right after a babel://translate trigger.
          guard let self, Date().timeIntervalSince(self.shownAt) > 0.5 else { return }
          self.close()
        }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      })

    escapeKey = HotKey.register(keyCode: kVK_Escape, modifiers: []) { [weak self] in self?.close() }
  }

  private func track() {
    let point = container.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    let optionHeld = NSEvent.modifierFlags.contains(.option)
    canvas.showingOriginal = optionHeld || hud.pinnedOriginal
    let overHUD = hudView.frame.contains(point)
    let hit = canvas.layout(at: point)
    canvas.hoveredID = hit?.blockID
    panel.ignoresMouseEvents = !(overHUD || hit != nil)
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    timer?.invalidate()
    monitors.forEach { NSEvent.removeMonitor($0) }
    observers.forEach {
      NSWorkspace.shared.notificationCenter.removeObserver($0)
      NotificationCenter.default.removeObserver($0)
    }
    if let escapeKey { HotKey.unregister(escapeKey) }
    let panel = self.panel
    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = 0.12
        panel.animator().alphaValue = 0
      },
      completionHandler: {
        panel.orderOut(nil)
      })
    onClose?()
  }
}
