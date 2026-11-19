import CoreGraphics
import CoreText
import Foundation

/// A translated paragraph laid out to sit exactly where the original was.
/// All geometry is in image pixel coordinates with a top-left origin.
final class BlockLayout {
  let blockID: Int
  let sourceText: String
  let translatedText: String
  let sourceLanguage: String
  let colors: BlockColors
  /// Area painted over the original text.
  let fillRect: CGRect
  let cornerRadius: CGFloat
  let fontSize: CGFloat
  let lines: [(line: CTLine, origin: CGPoint)]

  init(
    block: TextBlock, translation: String, colors: BlockColors, fillRect: CGRect,
    fontSize: CGFloat, lines: [(CTLine, CGPoint)]
  ) {
    blockID = block.id
    sourceText = block.sourceText
    translatedText = translation
    sourceLanguage = block.sourceLanguage ?? ""
    self.colors = colors
    self.fillRect = fillRect
    cornerRadius = max(2, fontSize * 0.22)
    self.fontSize = fontSize
    self.lines = lines.map { (line: $0.0, origin: $0.1) }
  }

  // MARK: Drawing

  /// Draws into a context whose user space is image pixels with a top-left origin
  /// (i.e. y grows downwards, as in a flipped NSView).
  func draw(in ctx: CGContext, highlighted: Bool = false) {
    ctx.saveGState()
    let path = CGPath(roundedRect: fillRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    if colors.backgroundUniformity < 0.55 {
      // Busy background (photo, gradient): a soft shadow keeps the label legible.
      ctx.setShadow(offset: .zero, blur: fontSize * 0.5, color: CGColor(gray: 0, alpha: 0.35))
    }
    ctx.setFillColor(colors.background.cgColor)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    if highlighted {
      let accent = CGColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 0.9)
      ctx.setStrokeColor(accent)
      ctx.setLineWidth(max(1.5, fontSize * 0.09))
      ctx.addPath(
        CGPath(
          roundedRect: fillRect.insetBy(dx: -1, dy: -1), cornerWidth: cornerRadius,
          cornerHeight: cornerRadius, transform: nil))
      ctx.strokePath()
    }

    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    for (line, origin) in lines {
      ctx.textPosition = origin
      CTLineDraw(line, ctx)
    }
    ctx.restoreGState()
  }

  // MARK: Layout

  /// Fraction of the font size between the vertical centre of an OCR line box and the baseline.
  private static let baselineBelowCenter: CGFloat = 0.27
  /// Approximate cap height of the system font, as a fraction of the font size.
  private static let capHeight: CGFloat = 0.72

  /// Empty background-coloured space around a block that a longer translation may grow into.
  struct Room: Sendable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var below: CGFloat = 0
    init(left: CGFloat = 0, right: CGFloat = 0, below: CGFloat = 0) {
      self.left = left; self.right = right; self.below = below
    }
  }

  static func make(block: TextBlock, translation: String, colors: BlockColors, room: Room = Room()) -> BlockLayout {
    let rects = block.lines.map(\.rect)
    let frame = rects.reduce(CGRect.null) { $0.union($1) }
    let fontSize = estimateFontSize(block)

    // Line pitch from the original; single lines get a typical 1.25 leading.
    let tops = rects.map(\.minY)
    let gaps = zip(tops.dropFirst(), tops).map { $0 - $1 }.filter { $0 > fontSize * 0.6 }
    let pitch = gaps.isEmpty ? fontSize * 1.25 : median(gaps)

    // Indents: first line vs the rest (hanging bullets, first-line indents).
    // OCR boxes jitter by a few pixels, so ignore indents smaller than ~0.4 em.
    func snap(_ indent: CGFloat) -> CGFloat { indent < fontSize * 0.4 ? 0 : indent }
    let firstIndent = snap(rects[0].minX - frame.minX)
    let restIndent = rects.count > 1 ? snap(median(rects.dropFirst().map { $0.minX - frame.minX })) : 0

    let textTop = rects[0].midY + fontSize * baselineBelowCenter - fontSize * capHeight
    let originalHeight = CGFloat(rects.count - 1) * pitch

    func layout(scale: CGFloat, width: CGFloat, wrap: Bool) -> [(CTLine, CGPoint, CGFloat)] {
      let size = fontSize * scale
      let font =
        CTFontCreateUIFontForLanguage(.system, size, nil)
        ?? CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
      let attributed = NSAttributedString(
        string: translation,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): colors.text.cgColor,
        ])
      let typesetter = CTTypesetterCreateWithAttributedString(attributed)
      let length = attributed.length
      var result: [(CTLine, CGPoint, CGFloat)] = []
      var start = 0
      let baseline0 = textTop + size * capHeight
      while start < length {
        let indent = result.isEmpty ? firstIndent : restIndent
        let available = wrap ? max(size * 2, width - indent) : .greatestFiniteMagnitude
        var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(available))
        if count <= 0 { count = length - start }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
        let x: CGFloat
        switch block.alignment {
        case .leading: x = frame.minX + indent
        case .center: x = frame.midX - lineWidth / 2
        case .trailing: x = frame.maxX - lineWidth
        }
        let y = baseline0 + CGFloat(result.count) * pitch * scale
        result.append((line, CGPoint(x: x, y: y), lineWidth))
        start += count
      }
      return result
    }

    var chosen: [(CTLine, CGPoint, CGFloat)] = []
    var chosenScale: CGFloat = 1
    let margin = fontSize * 0.5
    if rects.count == 1 {
      // Labels, buttons, headings: never wrap. Grow into empty space first, then shrink a little.
      let natural = layout(scale: 1, width: 0, wrap: false)
      let needed = natural.first?.2 ?? 0
      let extra: CGFloat
      switch block.alignment {
      case .leading: extra = room.right
      case .trailing: extra = room.left
      case .center: extra = 2 * min(room.left, room.right)
      }
      let available = frame.width + fontSize * 0.2 + max(0, extra - margin)
      chosenScale = needed > available ? max(0.8, available / needed) : 1
      chosen = chosenScale == 1 ? natural : layout(scale: chosenScale, width: 0, wrap: false)
    } else {
      let width = frame.width + fontSize * 0.25
      let allowedHeight = originalHeight + pitch * 0.3 + max(0, room.below - margin)
      for scale in stride(from: 1.0, through: 0.7, by: -0.05) {
        chosen = layout(scale: CGFloat(scale), width: width, wrap: true)
        chosenScale = CGFloat(scale)
        let height = CGFloat(chosen.count - 1) * pitch * chosenScale
        if height <= allowedHeight { break }
      }
    }

    // Paint over every original line, plus wherever the translation ended up.
    let size = fontSize * chosenScale
    var textBounds = CGRect.null
    for (_, origin, width) in chosen {
      textBounds = textBounds.union(
        CGRect(
          x: origin.x, y: origin.y - size * capHeight - size * 0.12,
          width: width, height: size * (capHeight + 0.38)))
    }
    let fill = frame.union(textBounds).insetBy(dx: -fontSize * 0.22, dy: -fontSize * 0.16)

    return BlockLayout(
      block: block, translation: translation, colors: colors, fillRect: fill.integral,
      fontSize: size, lines: chosen.map { ($0.0, $0.1) })
  }

  /// Estimates the original font size by setting the original text in the system font and
  /// matching its width to the OCR box. (Box heights vary with ascenders/descenders and
  /// padding, so they're only used as a sanity bound.)
  static func estimateFontSize(_ block: TextBlock) -> CGFloat {
    let reference: CGFloat = 100
    let font = CTFontCreateUIFontForLanguage(.system, reference, nil)!
    var byWidth: [CGFloat] = []
    var byInkHeight: [CGFloat] = []
    for line in block.lines {
      let attributed = NSAttributedString(
        string: line.text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
      let ctLine = CTLineCreateWithAttributedString(attributed)
      let ink = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
      if ink.height > 1 { byInkHeight.append(line.rect.height / ink.height * reference) }
      guard line.text.filter(\.isLetter).count >= 3 else { continue }
      let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
      if width > 0 { byWidth.append(line.rect.width / width * reference) }
    }
    let height = byInkHeight.isEmpty ? median(block.lines.map(\.rect.height)) * 0.8 : median(byInkHeight) * 0.85
    guard !byWidth.isEmpty else { return height }
    return min(max(median(byWidth), height * 0.6), height * 1.15)
  }
}

func median(_ values: [CGFloat]) -> CGFloat {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  let mid = sorted.count / 2
  return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}
