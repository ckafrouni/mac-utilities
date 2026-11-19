import CoreGraphics
import Foundation

struct RGB: Sendable, Hashable {
  var r: Double, g: Double, b: Double

  var cgColor: CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
  }

  var luminance: Double {
    func lin(_ c: Double) -> Double {
      let v = c / 255
      return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
  }

  func distance(_ o: RGB) -> Double {
    let dr = r - o.r, dg = g - o.g, db = b - o.b
    return (dr * dr + dg * dg + db * db).squareRoot()
  }

  static func contrast(_ a: RGB, _ b: RGB) -> Double {
    let la = a.luminance, lb = b.luminance
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }

  static let black = RGB(r: 0, g: 0, b: 0)
  static let white = RGB(r: 255, g: 255, b: 255)
}

struct BlockColors: Sendable, Hashable {
  var background: RGB
  var text: RGB
  /// How much of the area around the text is close to `background` (0...1).
  /// Low values mean a photo or gradient behind the text.
  var backgroundUniformity: Double
}

/// RGBA8 copy of a captured image in sRGB, for estimating the colours around text.
final class PixelSampler: @unchecked Sendable {
  let width: Int
  let height: Int
  private let data: [UInt8]

  init?(image: CGImage) {
    let width = image.width, height = image.height
    self.width = width
    self.height = height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard ok else { return nil }
    data = buffer
  }

  @inline(__always) private func pixel(_ x: Int, _ y: Int) -> RGB {
    // Bitmap contexts store rows top-down in memory, matching our top-left coordinates.
    let i = (y * width + x) * 4
    return RGB(r: Double(data[i]), g: Double(data[i + 1]), b: Double(data[i + 2]))
  }

  private func pixels(in rect: CGRect, excluding holes: [CGRect] = [], budget: Int = 6000) -> [RGB] {
    let r = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
    guard !r.isNull, r.width >= 1, r.height >= 1 else { return [] }
    let area = Int(r.width * r.height)
    let step = max(1, Int((Double(area) / Double(budget)).squareRoot()))
    var result: [RGB] = []
    result.reserveCapacity(min(area, budget * 2))
    var y = Int(r.minY)
    while y < Int(r.maxY) {
      var x = Int(r.minX)
      while x < Int(r.maxX) {
        let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
        if !holes.contains(where: { $0.contains(p) }) {
          result.append(pixel(x, y))
        }
        x += step
      }
      y += step
    }
    return result
  }

  /// Most common colour (quantised to 5 bits/channel), averaged within its bucket.
  private static func dominant(_ pixels: [RGB]) -> (RGB, count: Int)? {
    guard !pixels.isEmpty else { return nil }
    var buckets: [Int: (n: Int, r: Double, g: Double, b: Double)] = [:]
    for p in pixels {
      let key = (Int(p.r) >> 3) << 10 | (Int(p.g) >> 3) << 5 | (Int(p.b) >> 3)
      var e = buckets[key] ?? (0, 0, 0, 0)
      e.n += 1; e.r += p.r; e.g += p.g; e.b += p.b
      buckets[key] = e
    }
    guard let best = buckets.values.max(by: { $0.n < $1.n }) else { return nil }
    let n = Double(best.n)
    return (RGB(r: best.r / n, g: best.g / n, b: best.b / n), best.n)
  }

  /// How far the plain background extends left, right and below a block, up to `limit` px.
  func room(around block: TextBlock, background: RGB, limit: CGFloat) -> BlockLayout.Room {
    let rect = block.rect.integral
    let lim = Int(limit)
    func isBackground(_ x: Int, _ y: Int) -> Bool {
      guard x >= 0, y >= 0, x < width, y < height else { return false }
      return pixel(x, y).distance(background) < 30
    }
    func columnFree(_ x: Int) -> Bool {
      stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2).allSatisfy { isBackground(x, $0) }
    }
    func rowFree(_ y: Int) -> Bool {
      stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2).allSatisfy { isBackground($0, y) }
    }
    // Start a couple of pixels out: OCR boxes are tight and anti-aliasing spills past them.
    let skip = 2
    var right = skip
    while right < lim, columnFree(Int(rect.maxX) + right) { right += 1 }
    var left = skip
    while left < lim, columnFree(Int(rect.minX) - 1 - left) { left += 1 }
    var below = skip
    while below < lim, rowFree(Int(rect.maxY) + below) { below += 1 }
    return BlockLayout.Room(left: CGFloat(left), right: CGFloat(right), below: CGFloat(below))
  }

  func colors(for block: TextBlock) -> BlockColors {
    let lineHeight = block.lines.map(\.rect.height).sorted()[block.lines.count / 2]
    let pad = max(3, lineHeight * 0.35)
    let outer = block.rect.insetBy(dx: -pad, dy: -pad)
    let lineRects = block.lines.map(\.rect)

    // Background: the area around and between the lines, not the glyphs themselves.
    var ring = pixels(in: outer, excluding: lineRects.map { $0.insetBy(dx: -1, dy: -1) })
    if ring.count < 40 { ring = pixels(in: outer) }
    let background = Self.dominant(ring)?.0 ?? .white
    let uniform = ring.isEmpty ? 0 : Double(ring.filter { $0.distance(background) < 24 }.count) / Double(ring.count)

    // Text: among pixels inside the line boxes, the most common colour far from the background.
    let inside = lineRects.flatMap { pixels(in: $0, budget: 3000) }
    let distances = inside.map { $0.distance(background) }
    let maxDistance = distances.max() ?? 0
    var text: RGB
    if maxDistance < 40 {
      text = background.luminance > 0.4 ? .black : .white
    } else {
      let far = zip(inside, distances).filter { $0.1 >= maxDistance * 0.6 }.map(\.0)
      text = Self.dominant(far)?.0 ?? (background.luminance > 0.4 ? .black : .white)
    }
    // Keep the translation readable even if the estimate is off.
    if RGB.contrast(text, background) < 3 {
      text = background.luminance > 0.4 ? RGB(r: 20, g: 20, b: 20) : RGB(r: 240, g: 240, b: 240)
    }
    return BlockColors(background: background, text: text, backgroundUniformity: uniform)
  }
}
