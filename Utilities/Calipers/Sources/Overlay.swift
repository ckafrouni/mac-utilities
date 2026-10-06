import AppKit
import UtilityKit

/// Measuring mode: a see-through window over every display, measuring against
/// a capture of each taken as it opens.
///
/// - Move: the distance between the nearest edges around the cursor.
/// - Drag: a box, as drawn. Hold Option to snap it to what's inside it.
/// - Click: copy the measurement. ⌘C copies too; Delete removes the last box; Esc quits.
@MainActor
final class Overlay {
  private var views: [OverlayView] = []
  private var opening = false
  private var cursorHidden = false
  private var keyMonitor: Any?
  private var observers: [NSObjectProtocol] = []

  private(set) var mouse = CGPoint.zero
  private(set) var dragStart: CGPoint?
  private(set) var boxes: [CGRect] = []
  private(set) var flash: String?
  private var flashTask: Task<Void, Never>?

  var isOpen: Bool { !views.isEmpty }

  func toggle() {
    if isOpen { close() } else { Task { await open() } }
  }

  private func open() async {
    guard !opening, !isOpen else { return }
    guard hasScreenRecordingPermission() else { return }
    opening = true
    defer { opening = false }

    let images: [ScreenImage]
    do {
      images = try await ScreenCapture.captureAll()
    } catch {
      UtilityApp.alert("Couldn't capture the screen", error.localizedDescription)
      return
    }
    guard !images.isEmpty else { return }

    mouse = NSEvent.mouseLocation
    views = images.map { image in
      let window = OverlayWindow(frame: image.frame)
      let view = OverlayView(overlay: self, image: image)
      window.contentView = view
      window.orderFrontRegardless()
      return view
    }
    NSApp.activate(ignoringOtherApps: true)
    (views.first { $0.image.frame.contains(mouse) } ?? views[0]).window?.makeKey()

    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.keyDown(event) ? nil : event
    }
    let center = NotificationCenter.default
    for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      })
    }
    // The cursor only hides for the active app, which we become a moment later.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isOpen, !self.cursorHidden else { return }
      NSCursor.hide()
      self.cursorHidden = true
    }
    redraw()
  }

  func close() {
    guard isOpen else { return }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    for view in views { view.window?.orderOut(nil) }
    views = []
    boxes = []
    dragStart = nil
    flash = nil
    if cursorHidden {
      NSCursor.unhide()
      cursorHidden = false
    }
    NSApp.hide(nil)  // back to the app you were in
  }

  // MARK: Input

  func mouseMoved() {
    let old = mouse
    mouse = NSEvent.mouseLocation
    if dragStart != nil {
      redraw()
    } else {
      for view in views where view.image.frame.contains(old) || view.image.frame.contains(mouse) {
        view.needsDisplay = true
      }
    }
  }

  func mouseDown() {
    mouse = NSEvent.mouseLocation
    dragStart = mouse
  }

  func mouseUp(snap: Bool) {
    mouse = NSEvent.mouseLocation
    guard let start = dragStart else { return }
    dragStart = nil
    let rect = Self.rect(start, mouse)
    if rect.width < 2 && rect.height < 2 {
      copy()
    } else if snap {
      // Snap on the display that holds the box; one that spans two stays as drawn.
      let image = views.map(\.image).first { $0.frame.contains(rect) }
      boxes.append(image?.snap(rect, background: start) ?? rect)
    } else {
      boxes.append(rect)
    }
    redraw()
  }

  private func keyDown(_ event: NSEvent) -> Bool {
    let command = event.modifierFlags.contains(.command)
    switch (event.keyCode, command, event.charactersIgnoringModifiers) {
    case (53, _, _):  // Esc
      if dragStart != nil {
        dragStart = nil
        redraw()
      } else {
        close()
      }
    case (51, false, _), (117, false, _):  // Delete, Forward Delete
      if boxes.popLast() != nil { redraw() } else { NSSound.beep() }
    case (_, true, "c"):
      copy()
    case (_, true, "q"):
      NSApp.terminate(nil)
    default:
      return false
    }
    return true
  }

  private func copy() {
    let size = boxes.last?.size ?? image(at: mouse)?.span(at: mouse).size
    guard let size else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(Self.text(size), forType: .string)
    flash = "Copied \(Self.text(size))"
    flashTask?.cancel()
    flashTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.flash = nil
      self?.redraw()
    }
    redraw()
  }

  // MARK: Helpers

  func image(at point: CGPoint) -> ScreenImage? {
    views.map(\.image).first { $0.frame.contains(point) }
  }

  private func redraw() {
    for view in views { view.needsDisplay = true }
  }

  private func hasScreenRecordingPermission() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    // The first time, macOS asks on its own; after that, point the way to Settings.
    if !UserDefaults.standard.bool(forKey: "askedForScreenRecording") {
      UserDefaults.standard.set(true, forKey: "askedForScreenRecording")
      return CGRequestScreenCaptureAccess()
    }
    let choice = UtilityApp.alert(
      "Calipers needs to see your screen",
      "Allow Calipers in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. It measures what's on screen; nothing leaves your Mac.",
      buttons: ["Open System Settings", "Cancel"])
    if choice == 0 {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    return false
  }

  static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }

  static func text(_ size: CGSize) -> String {
    func number(_ v: CGFloat) -> String {
      abs(v - v.rounded()) < 0.01 ? "\(Int(v.rounded()))" : String(format: "%.1f", v)
    }
    return "\(number(size.width)) × \(number(size.height))"
  }
}

final class OverlayWindow: NSWindow {
  init(frame: CGRect) {
    // No `screen:` here: with it, AppKit reads the rect relative to that screen.
    super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    setFrame(frame, display: false)
    level = .screenSaver
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
  unowned let overlay: Overlay
  let image: ScreenImage

  private static let accent = NSColor(srgbRed: 1, green: 0.2, blue: 0.45, alpha: 1)

  init(overlay: Overlay, image: ScreenImage) {
    self.overlay = overlay
    self.image = image
    super.init(frame: CGRect(origin: .zero, size: image.frame.size))
    // Every display's view follows the mouse, key window or not.
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseMoved(with event: NSEvent) { overlay.mouseMoved() }
  override func mouseDown(with event: NSEvent) { overlay.mouseDown() }
  override func mouseDragged(with event: NSEvent) { overlay.mouseMoved() }
  override func mouseUp(with event: NSEvent) { overlay.mouseUp(snap: event.modifierFlags.contains(.option)) }
  override func rightMouseDown(with event: NSEvent) { overlay.close() }

  /// Global points to this view's.
  private func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -image.frame.minX, dy: -image.frame.minY) }
  private func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - image.frame.minX, y: point.y - image.frame.minY) }

  override func draw(_ dirtyRect: NSRect) {
    // Nearly clear, so the window takes the clicks.
    NSColor(white: 0, alpha: 0.004).setFill()
    bounds.fill()

    for box in overlay.boxes where box.intersects(image.frame) {
      drawBox(local(box), label: Overlay.text(box.size))
    }
    if let start = overlay.dragStart {
      let rect = Overlay.rect(start, overlay.mouse)
      if rect.intersects(image.frame) { drawBox(local(rect), label: Overlay.text(rect.size)) }
      return
    }
    guard image.frame.contains(overlay.mouse) else { return }
    let span = image.span(at: overlay.mouse)
    drawSpan(local(span), at: local(overlay.mouse))
    drawLabel(overlay.flash ?? Overlay.text(span.size), near: local(overlay.mouse))
  }

  /// A horizontal and a vertical line through the cursor, edge to edge, with end ticks.
  private func drawSpan(_ span: CGRect, at point: CGPoint) {
    let y = point.y.rounded(.down) + 0.5
    let x = point.x.rounded(.down) + 0.5
    let tick: CGFloat = 4
    let path = NSBezierPath()
    path.move(to: CGPoint(x: span.minX, y: y))
    path.line(to: CGPoint(x: span.maxX, y: y))
    path.move(to: CGPoint(x: x, y: span.minY))
    path.line(to: CGPoint(x: x, y: span.maxY))
    for edgeX in [span.minX, span.maxX] {
      path.move(to: CGPoint(x: edgeX, y: y - tick))
      path.line(to: CGPoint(x: edgeX, y: y + tick))
    }
    for edgeY in [span.minY, span.maxY] {
      path.move(to: CGPoint(x: x - tick, y: edgeY))
      path.line(to: CGPoint(x: x + tick, y: edgeY))
    }
    path.lineWidth = 1
    Self.accent.setStroke()
    path.stroke()
  }

  private func drawBox(_ rect: CGRect, label: String) {
    Self.accent.withAlphaComponent(0.12).setFill()
    rect.fill()
    let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
    outline.lineWidth = 1
    Self.accent.setStroke()
    outline.stroke()
    drawLabel(label, below: rect)
  }

  private static let labelAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
    .foregroundColor: NSColor.white,
  ]

  private func labelSize(_ text: String) -> CGSize {
    let size = (text as NSString).size(withAttributes: Self.labelAttributes)
    return CGSize(width: ceil(size.width) + 12, height: ceil(size.height) + 6)
  }

  /// Below and to the right of the cursor, flipped to stay on the display.
  private func drawLabel(_ text: String, near point: CGPoint) {
    let size = labelSize(text)
    var origin = CGPoint(x: point.x + 12, y: point.y - 12 - size.height)
    if origin.x + size.width > bounds.maxX - 4 { origin.x = point.x - 12 - size.width }
    if origin.y < bounds.minY + 4 { origin.y = point.y + 12 }
    drawLabel(text, in: CGRect(origin: origin, size: size))
  }

  /// Centered under the box, or inside its bottom edge at the bottom of the display.
  private func drawLabel(_ text: String, below rect: CGRect) {
    let size = labelSize(text)
    var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - 6 - size.height)
    if origin.y < bounds.minY + 4 { origin.y = rect.minY + 6 }
    origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - 4 - size.width)
    drawLabel(text, in: CGRect(origin: origin, size: size))
  }

  private func drawLabel(_ text: String, in rect: CGRect) {
    NSColor(white: 0.1, alpha: 0.88).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), withAttributes: Self.labelAttributes)
  }
}
