import CoreGraphics
import Foundation

/// One line of recognised text, in image pixel coordinates (top-left origin).
struct TextLine: Sendable, Hashable {
  var text: String
  var rect: CGRect

  init(text: String, rect: CGRect) {
    self.text = text
    self.rect = rect
  }
}

enum BlockAlignment: Sendable, Hashable {
  case leading, center, trailing
}

/// A paragraph found on screen. Everything is in image pixel coordinates (top-left origin).
struct TextBlock: Sendable, Identifiable {
  let id: Int
  var lines: [TextLine]
  var alignment: BlockAlignment

  /// Source text with soft line wraps joined, ready to translate.
  var sourceText: String
  /// BCP-47 code of the detected source language (e.g. "de"), nil if not foreign.
  var sourceLanguage: String?
  var translatedText: String?
  /// Which OCR pass produced this block (0 = original image, 1 = inverted).
  var pass = 0

  init(id: Int, lines: [TextLine], alignment: BlockAlignment) {
    self.id = id
    self.lines = lines
    self.alignment = alignment
    self.sourceText = TextBlock.join(lines.map(\.text))
  }

  var rect: CGRect {
    lines.reduce(CGRect.null) { $0.union($1.rect) }
  }

  /// Joins OCR lines into running text, undoing end-of-line hyphenation.
  static func join(_ lines: [String]) -> String {
    var out = ""
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if out.isEmpty {
        out = line
      } else if out.hasSuffix("-"), out.dropLast().last?.isLetter == true {
        // "Daten-" + "flüsse" -> "Datenflüsse"; keep the hyphen before capitals/slashes
        // ("Kubernetes-" + "/Deployment", "E-" + "Mail").
        if let first = line.first, first.isLowercase {
          out.removeLast()
        }
        out += line
      } else {
        out += " " + line
      }
    }
    return out
  }
}
