import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Development aid: runs the whole pipeline on an image (or the live display under the
/// pointer) and writes it with the translations drawn in place.
///
///   Babel --translate-image shot.png [-o out.png] [--target en] [--quality fast|best]
///   Babel --translate-image --screen [-o out.png]
@available(macOS 26.4, *)
@MainActor
enum TranslateImageCommand {
  static func run(_ arguments: [String]) async -> Int32 {
    var args = arguments
    func option(_ name: String) -> String? {
      guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
      let value = args[i + 1]
      args.removeSubrange(i...(i + 1))
      return value
    }
    let output = option("-o")
    let target = option("--target") ?? "en"
    let quality: TranslationQuality = option("--quality") == "best" ? .highFidelity : .fast
    let useScreen = args.contains("--screen")
    args.removeAll { $0 == "--screen" }

    let image: CGImage
    do {
      if useScreen {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
          print("No display")
          return 1
        }
        image = try await ScreenCapture.capture(screen)
      } else {
        guard let path = args.first,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
          print("usage: Babel --translate-image <image>|--screen [-o out.png] [--target en] [--quality fast|best]")
          return 2
        }
        image = loaded
      }

      let pipeline = TranslationPipeline(targetLanguage: target)
      pipeline.translator.quality = quality
      var layouts: [BlockLayout] = []
      let start = Date()
      let summary = try await pipeline.run(image: image) { event in
        if case let .layout(layout) = event { layouts.append(layout) }
      }
      print(
        String(format: "%dx%d, %.2fs: ", image.width, image.height, Date().timeIntervalSince(start))
          + summary.timings.map { String(format: "%@ %.2fs", $0.0, $0.1) }.joined(separator: ", "))
      for (language, error) in summary.failures { print("failed \(language): \(error.localizedDescription)") }
      for layout in layouts.sorted(by: { $0.fillRect.minY < $1.fillRect.minY }) {
        print("[\(layout.sourceLanguage)] \(layout.sourceText)\n   → \(layout.translatedText)")
      }
      if let output { try write(image, layouts, to: output) }
      return 0
    } catch {
      print("error: \(error.localizedDescription)")
      return 1
    }
  }

  private static func write(_ image: CGImage, _ layouts: [BlockLayout], to path: String) throws {
    let w = image.width, h = image.height
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    for layout in layouts { layout.draw(in: ctx) }
    guard let rendered = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, rendered, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(path)")
  }
}
