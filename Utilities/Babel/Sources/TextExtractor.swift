import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Vision

/// Finds paragraphs of text in an image using Vision's document recogniser, which groups
/// lines into paragraphs (and list items) far better than line-level OCR.
@available(macOS 26.4, *)
enum TextExtractor {
  /// Above roughly this many pixels the document recogniser downsamples so much that small
  /// UI text turns to garbage (a 6K display is 20 MP), so big captures are read in bands.
  static let maxPixelsPerPass = 8_000_000

  static func paragraphs(in image: CGImage) async throws -> [TextBlock] {
    let width = image.width, height = image.height

    // Vision reliably misses light text on dark areas of a mostly light screen (and vice
    // versa), so read the inverted image too and keep the more complete reading.
    var variants = [image]
    if let inverted = inverted(image) { variants.append(inverted) }

    // Full-width horizontal bands that overlap by 40%, so every paragraph shorter than
    // the overlap lies whole inside at least one band. Paragraphs cut by a band edge are
    // dropped; the neighbouring band has them intact.
    var bands: [(top: Int, bottom: Int)] = []
    if width * height <= maxPixelsPerPass * 11 / 10 {
      bands = [(0, height)]
    } else {
      let bandHeight = max(900, maxPixelsPerPass / width)
      let step = bandHeight * 6 / 10
      var top = 0
      while true {
        let bottom = min(height, top + bandHeight)
        bands.append((top, bottom))
        if bottom >= height { break }
        top += step
      }
    }

    var found = try await withThrowingTaskGroup(of: [TextBlock].self) { group in
      for (pass, variant) in variants.enumerated() {
        for (top, bottom) in bands {
          let region = CGRect(x: 0, y: top, width: width, height: bottom - top)
          guard let band = bands.count == 1 ? variant : variant.cropping(to: region) else { continue }
          group.addTask {
            let margin: CGFloat = 3
            return try await recognize(band, offsetY: top, pass: pass).filter { block in
              let r = block.rect
              let cutAtTop = top > 0 && r.minY <= CGFloat(top) + margin
              let cutAtBottom = bottom < height && r.maxY >= CGFloat(bottom) - margin
              return !cutAtTop && !cutAtBottom
            }
          }
        }
      }
      var all: [TextBlock] = []
      for try await blocks in group { all += blocks }
      return all
    }
    found = mergedSoftWraps(deduplicated(found))

    return found.sorted { a, b in
      let ra = a.rect, rb = b.rect
      return abs(ra.minY - rb.minY) > 4 ? ra.minY < rb.minY : ra.minX < rb.minX
    }.enumerated().map { index, block in
      TextBlock(id: index, lines: block.lines, alignment: block.alignment)
    }
  }

  private static func recognize(_ image: CGImage, offsetY: Int, pass: Int = 0) async throws -> [TextBlock] {
    var request = RecognizeDocumentsRequest()
    request.textRecognitionOptions.automaticallyDetectLanguage = true
    request.textRecognitionOptions.useLanguageCorrection = true
    request.barcodeDetectionOptions.enabled = false

    let size = CGSize(width: image.width, height: image.height)
    let documents = try await request.perform(on: image)

    var blocks: [TextBlock] = []
    var seen = Set<[CGRect]>()
    for document in documents {
      for paragraph in allParagraphs(in: document.document) {
        let lines: [TextLine] = paragraph.lines.compactMap { line in
          let text = line.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { return nil }
          let rect = line.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            .offsetBy(dx: 0, dy: CGFloat(offsetY)).integral
          return TextLine(text: text, rect: rect)
        }
        guard !lines.isEmpty else { continue }
        // Table cells can also show up as top-level paragraphs; don't draw them twice.
        guard seen.insert(lines.map(\.rect)).inserted else { continue }

        let alignment: BlockAlignment
        switch paragraph.textAlignment {
        case .center?: alignment = .center
        case .trailing?: alignment = .trailing
        default: alignment = .leading
        }
        var block = TextBlock(id: 0, lines: lines, alignment: alignment)
        block.pass = pass
        blocks.append(block)
      }
    }
    return blocks
  }

  private static let ciContext = CIContext(options: [.cacheIntermediates: false])

  private static func inverted(_ image: CGImage) -> CGImage? {
    let input = CIImage(cgImage: image)
    let output = input.applyingFilter("CIColorInvert")
    return ciContext.createCGImage(output, from: input.extent)
  }

  /// The same paragraph read twice (two bands, or normal + inverted): keep the most complete
  /// reading, which also repairs paragraphs one pass split into separate lines.
  private static func deduplicated(_ blocks: [TextBlock]) -> [TextBlock] {
    // Most lines first (most complete), then the original image over the inverted one,
    // then the longer transcript.
    let ordered = blocks.sorted { a, b in
      if a.lines.count != b.lines.count { return a.lines.count > b.lines.count }
      if a.pass != b.pass { return a.pass < b.pass }
      return a.sourceText.count > b.sourceText.count
    }
    var kept: [TextBlock] = []
    for block in ordered {
      let r = block.rect
      let duplicate = kept.contains { other in
        let overlap = r.intersection(other.rect)
        guard !overlap.isNull else { return false }
        return overlap.width * overlap.height >= 0.5 * r.width * r.height
      }
      if !duplicate { kept.append(block) }
    }
    return kept
  }

  /// Vision occasionally reports each line of a widely spaced paragraph as its own
  /// paragraph, and translating line by line garbles sentences. Re-join two blocks when the
  /// second continues the first: same column, close below it, same text size, the first
  /// doesn't end a sentence, and both lines are long prose (so lists, addresses and menus,
  /// which are short lines, are left alone).
  static func mergedSoftWraps(_ input: [TextBlock]) -> [TextBlock] {
    func isProse(_ line: TextLine) -> Bool {
      line.text.count >= 40 && line.text.split(separator: " ").count >= 5
    }
    var blocks = input.sorted { $0.rect.minY < $1.rect.minY }
    var merged = true
    while merged {
      merged = false
      outer: for i in blocks.indices {
        guard let last = blocks[i].lines.last, isProse(last),
          let end = last.text.last, !".!?:;…".contains(end)
        else { continue }
        let lh = last.rect.height
        for j in blocks.indices where j != i {
          guard let first = blocks[j].lines.first, isProse(first) else { continue }
          let gap = first.rect.minY - last.rect.maxY
          guard gap >= -lh * 0.2, gap <= lh * 0.75,
            abs(first.rect.minX - last.rect.minX) <= lh * 0.6,
            first.rect.height / lh > 0.8, first.rect.height / lh < 1.25
          else { continue }
          var combined = TextBlock(id: 0, lines: blocks[i].lines + blocks[j].lines, alignment: blocks[i].alignment)
          combined.pass = blocks[i].pass
          blocks[i] = combined
          blocks.remove(at: j)
          merged = true
          break outer
        }
      }
    }
    return blocks
  }

  /// Paragraphs of a container plus those nested in its tables.
  private static func allParagraphs(in container: DocumentObservation.Container) -> [DocumentObservation.Container.Text] {
    var result = container.paragraphs
    for table in container.tables {
      for row in table.rows {
        for cell in row {
          result += allParagraphs(in: cell.content)
        }
      }
    }
    return result
  }

  /// Recognises a synthetic page so Vision compiles its models before the first real use.
  /// (The first document request in a freshly installed app can take a minute.)
  static func warmUp() async {
    let width = 1800, height = 900
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let text = [
      "Hallo zusammen,",
      "das Treffen am Donnerstag verschiebt sich auf zehn Uhr. Passt euch das noch?",
      "• Bitte bringt die Unterlagen für das neue Projekt mit, insbesondere die Zahlen.",
      "Goedemorgen, kunnen jullie de factuur van vorige maand nog een keer sturen?",
      "Thanks, I will get back to you tomorrow with the numbers.",
      "Viele Grüße, Anna",
    ]
    let font = CTFontCreateUIFontForLanguage(.system, 30, nil)!
    for (i, line) in text.enumerated() {
      let attributed = NSAttributedString(
        string: line,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ])
      ctx.textPosition = CGPoint(x: 60, y: height - 100 - i * 110)
      CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
    }
    guard let image = ctx.makeImage() else { return }
    _ = try? await recognize(image, offsetY: 0)
  }
}
