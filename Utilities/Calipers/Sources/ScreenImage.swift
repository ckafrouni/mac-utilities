import AppKit
import ScreenCaptureKit

/// A frozen capture of one display, in its native pixels, and the measuring
/// done on it. Points are global AppKit coordinates (origin at the bottom left
/// of the main display, y up); pixel rows count down from the top.
final class ScreenImage {
  let frame: CGRect
  let width: Int
  let height: Int
  /// Pixels per point (the display's backing scale).
  let scale: CGFloat
  private let pixels: [UInt32]

  /// How far apart (per channel, 0–255) two colors may be and still count as the same.
  /// Captures are exact, so flat UI is one color; dark-mode borders can be 8 apart.
  static let tolerance: Int32 = 4

  init?(_ image: CGImage, frame: CGRect) {
    let width = image.width
    let height = image.height
    var pixels = [UInt32](repeating: 0, count: width * height)
    // The display's own color space, so colors aren't converted (and edges blurred) on the way.
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn, width > 0, height > 0 else { return nil }
    self.frame = frame
    self.width = width
    self.height = height
    self.scale = CGFloat(width) / frame.width
    self.pixels = pixels
  }

  /// The run of same-colored pixels through `point`, out to the first edge in
  /// each direction: its horizontal extent (minX…maxX) and vertical (minY…maxY).
  func span(at point: CGPoint) -> CGRect {
    let (x, y) = pixel(at: point)
    let color = self[x, y]
    var left = x, right = x, top = y, bottom = y
    while left > 0, same(self[left - 1, y], color) { left -= 1 }
    while right < width - 1, same(self[right + 1, y], color) { right += 1 }
    while top > 0, same(self[x, top - 1], color) { top -= 1 }
    while bottom < height - 1, same(self[x, bottom + 1], color) { bottom += 1 }
    return bounds(left: left, top: top, right: right + 1, bottom: bottom + 1)
  }

  /// `rect` shrunk to what's drawn inside it: the bounds of every pixel that
  /// differs from `background`'s color. Nil if it's all background.
  func snap(_ rect: CGRect, background: CGPoint) -> CGRect? {
    let x0 = clampX(Int(((rect.minX - frame.minX) * scale).rounded(.down)))
    let x1 = clampX(Int(((rect.maxX - frame.minX) * scale).rounded(.up)) - 1)
    let y0 = clampY(Int(((frame.maxY - rect.maxY) * scale).rounded(.down)))
    let y1 = clampY(Int(((frame.maxY - rect.minY) * scale).rounded(.up)) - 1)
    let (bx, by) = pixel(at: background)
    let color = self[bx, by]
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    pixels.withUnsafeBufferPointer { pixels in
      for y in y0...max(y0, y1) {
        let row = y * width
        for x in x0...max(x0, x1) where !same(pixels[row + x], color) {
          if x < minX { minX = x }
          if x > maxX { maxX = x }
          if y < minY { minY = y }
          if y > maxY { maxY = y }
        }
      }
    }
    guard maxX >= 0 else { return nil }
    return bounds(left: minX, top: minY, right: maxX + 1, bottom: maxY + 1)
  }

  private subscript(x: Int, y: Int) -> UInt32 { pixels[y * width + x] }

  private func same(_ a: UInt32, _ b: UInt32) -> Bool {
    let t = Self.tolerance
    return abs(Int32(a & 0xFF) - Int32(b & 0xFF)) <= t
      && abs(Int32((a >> 8) & 0xFF) - Int32((b >> 8) & 0xFF)) <= t
      && abs(Int32((a >> 16) & 0xFF) - Int32((b >> 16) & 0xFF)) <= t
  }

  private func pixel(at point: CGPoint) -> (Int, Int) {
    (
      clampX(Int(((point.x - frame.minX) * scale).rounded(.down))),
      clampY(Int(((frame.maxY - point.y) * scale).rounded(.down)))
    )
  }

  private func clampX(_ x: Int) -> Int { min(max(x, 0), width - 1) }
  private func clampY(_ y: Int) -> Int { min(max(y, 0), height - 1) }

  /// Pixel edges (exclusive right and bottom) to a rect in global points.
  private func bounds(left: Int, top: Int, right: Int, bottom: Int) -> CGRect {
    CGRect(
      x: frame.minX + CGFloat(left) / scale,
      y: frame.maxY - CGFloat(bottom) / scale,
      width: CGFloat(right - left) / scale,
      height: CGFloat(bottom - top) / scale)
  }
}

enum ScreenCapture {
  /// Captures every display at its native resolution, without this app's windows or the cursor.
  @MainActor
  static func captureAll() async throws -> [ScreenImage] {
    let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect, CGFloat)? in
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
      return (id, screen.frame, screen.backingScaleFactor)
    }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let me = content.applications.filter { $0.processID == getpid() }
    return try await withThrowingTaskGroup(of: ScreenImage?.self) { group in
      for (id, frame, scale) in screens {
        guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int((frame.width * scale).rounded())
        config.height = Int((frame.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        group.addTask {
          let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
          return ScreenImage(image, frame: frame)
        }
      }
      var images: [ScreenImage] = []
      for try await image in group { if let image { images.append(image) } }
      return images
    }
  }
}
