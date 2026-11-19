import CoreGraphics
import Foundation
import NaturalLanguage

/// Decides which paragraphs on screen are foreign and what language they're in.
///
/// Detecting the language of short UI strings ("Anna", "# general", a product name) is
/// unreliable, so this works in passes:
///  1. Classify paragraphs that are long enough to judge on their own.
///  2. From those, work out which foreign languages are on screen.
///  3. Classify everything, constrained to {target} ∪ {those languages}. Short strings are
///     only translated when they sit next to foreign paragraphs (a greeting or sign-off), or
///     when most of the screen is foreign (a German web page, a PDF).
struct LanguagePlanner {
  var targetLanguage: String

  init(targetLanguage: String) {
    self.targetLanguage = Self.base(targetLanguage)
  }

  struct Plan {
    /// Foreign languages found on screen, most prominent first.
    var screenLanguages: [String]
    /// Block id -> source language for blocks that should be translated.
    var sources: [Int: String]
  }

  struct Stats {
    var letters: Int
    var words: Int
    var isLong: Bool { words >= 3 && letters >= 15 }
    /// Sentence-like: enough to vouch for short labels next to it.
    var isSentence: Bool { words >= 4 && letters >= 20 }
    /// "BIST", "OK", "PDF": a lone all-caps token is a label or acronym, not prose.
    var isShoutedToken: Bool
    /// Has at least one real word ("Grüße"), not just icon noise ("•Il 4G").
    var hasWord: Bool

    init(_ text: String) {
      letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
      let tokens = text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }
      words = tokens.count
      isShoutedToken = tokens.count == 1 && tokens[0].filter(\.isLetter).allSatisfy(\.isUppercase)
      hasWord = tokens.contains { $0.filter(\.isLetter).count >= 3 }
    }
  }

  func plan(_ blocks: [TextBlock]) -> Plan {
    let stats = blocks.map { Stats($0.sourceText) }

    // 1 + 2: languages present, from paragraphs long enough to classify confidently.
    var weights: [String: Int] = [:]
    var longLetters = 0
    for (block, s) in zip(blocks, stats) where s.isLong {
      longLetters += s.letters
      guard let (language, p) = classify(block.sourceText, constraints: nil), p >= 0.7,
        language != targetLanguage
      else { continue }
      weights[language, default: 0] += s.letters
    }
    var screen = weights.sorted { $0.value > $1.value }
      .filter { $0.value * 100 >= weights.values.reduce(0, +) * 15 }
      .map(\.key)

    if screen.isEmpty {
      // No long foreign paragraphs: maybe the whole screen is short foreign labels
      // (e.g. a German settings page). Judge everything together.
      let all = blocks.map(\.sourceText).joined(separator: "\n")
      if let (language, p) = classify(all, constraints: nil), p >= 0.6, language != targetLanguage {
        screen = [language]
      }
    }
    guard !screen.isEmpty else { return Plan(screenLanguages: [], sources: [:]) }

    // 3: classify every block among the languages actually present.
    let constraints = [targetLanguage] + screen
    // Priors from how much of the screen is in each language, so an ambiguous short
    // label ("Reiskosten") leans towards the language around it.
    let foreignTotal = weights.values.reduce(0, +)
    var hints: [String: Double] = [targetLanguage: Double(max(1, longLetters - foreignTotal))]
    for language in screen { hints[language] = Double(max(1, weights[language] ?? 1)) }
    let hintTotal = hints.values.reduce(0, +)
    hints = hints.mapValues { $0 / hintTotal }

    var sources: [Int: String] = [:]
    var anchors: [CGRect] = []
    var foreignLongLetters = 0
    var shortCandidates: [(id: Int, language: String, p: Double)] = []
    for (block, s) in zip(blocks, stats) where s.letters >= 2 {
      guard let (language, p) = classify(block.sourceText, constraints: constraints, hints: hints),
        language != targetLanguage
      else { continue }
      if s.isLong {
        guard p >= 0.55 else { continue }
        sources[block.id] = language
        foreignLongLetters += s.letters
        if s.isSentence {
          let lineHeight = block.lines.map(\.rect.height).max() ?? 0
          anchors.append(block.rect.insetBy(dx: -lineHeight * 1.5, dy: -lineHeight * 2.5))
        }
      } else if !s.isShoutedToken, s.hasWord {
        shortCandidates.append((block.id, language, p))
      }
    }

    let mostlyForeign = longLetters > 0 && Double(foreignLongLetters) / Double(longLetters) >= 0.6
    for candidate in shortCandidates {
      let rect = blocks[candidate.id].rect
      if mostlyForeign
        ? candidate.p >= 0.6
        : candidate.p >= 0.75 && anchors.contains(where: { $0.intersects(rect) })
      {
        sources[candidate.id] = candidate.language
      }
    }
    return Plan(screenLanguages: screen, sources: sources)
  }

  private func classify(_ text: String, constraints: [String]?, hints: [String: Double] = [:]) -> (String, Double)? {
    let recognizer = NLLanguageRecognizer()
    if let constraints { recognizer.languageConstraints = constraints.map { NLLanguage(rawValue: $0) } }
    if !hints.isEmpty {
      recognizer.languageHints = Dictionary(uniqueKeysWithValues: hints.map { (NLLanguage(rawValue: $0.key), $0.value) })
    }
    recognizer.processString(text)
    guard let (top, p) = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }) else {
      return nil
    }
    return (Self.base(top.rawValue), p)
  }

  /// "de-DE" -> "de", but keep the script for Chinese ("zh-Hans").
  static func base(_ code: String) -> String {
    let parts = code.split(separator: "-")
    guard let first = parts.first else { return code }
    if first == "zh", parts.count > 1 { return "zh-\(parts[1])" }
    return String(first)
  }
}
