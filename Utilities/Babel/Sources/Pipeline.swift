import CoreGraphics
import Foundation

enum PipelineEvent {
  /// Foreign text found; translation is starting.
  case translating(languages: [String], blockCount: Int)
  /// A paragraph has been translated and laid out.
  case layout(BlockLayout)
}

struct PipelineSummary {
  var languages: [String]
  var translatedCount: Int
  /// Languages that couldn't be translated, with the reason.
  var failures: [(language: String, error: Error)]
  var timings: [(String, TimeInterval)]
}

/// image -> paragraphs -> foreign ones -> translations -> in-place layouts.
@available(macOS 26.4, *)
@MainActor
final class TranslationPipeline {
  let translator = Translator()
  var targetLanguage: String
  /// Paragraphs from the last run, with detected languages (for diagnostics).
  private(set) var lastBlocks: [TextBlock] = []

  init(targetLanguage: String = "en") {
    self.targetLanguage = targetLanguage
  }

  func run(image: CGImage, onEvent: (PipelineEvent) -> Void) async throws -> PipelineSummary {
    var timings: [(String, TimeInterval)] = []
    var mark = Date()
    func lap(_ name: String) {
      timings.append((name, Date().timeIntervalSince(mark)))
      mark = Date()
    }

    var blocks = try await TextExtractor.paragraphs(in: image)
    lap("ocr")
    let target = LanguagePlanner.base(targetLanguage)
    let plan = LanguagePlanner(targetLanguage: target).plan(blocks)
    lap("detect")
    for (id, language) in plan.sources { blocks[id].sourceLanguage = language }
    lastBlocks = blocks

    let foreign = blocks.filter { $0.sourceLanguage != nil }
    var summary = PipelineSummary(languages: [], translatedCount: 0, failures: [], timings: [])
    guard !foreign.isEmpty else {
      summary.timings = timings
      return summary
    }

    let byLanguage = Dictionary(grouping: foreign, by: { $0.sourceLanguage! })
    let languages = byLanguage.keys.sorted { byLanguage[$0]!.count > byLanguage[$1]!.count }
    onEvent(.translating(languages: languages, blockCount: foreign.count))

    let sampler = PixelSampler(image: image)
    lap("pixels")
    for language in languages {
      let group = byLanguage[language]!
      do {
        try await translator.translate(group.map { ($0.id, $0.sourceText) }, from: language, to: target) { id, text in
          var block = blocks[id]
          let translation = Self.restoreMarkers(source: block.sourceText, translation: text)
          guard Self.normalized(translation) != Self.normalized(block.sourceText) else { return }
          block.translatedText = translation
          blocks[id] = block
          let colors =
            sampler?.colors(for: block)
            ?? BlockColors(background: .white, text: .black, backgroundUniformity: 1)
          let room = sampler?.room(around: block, background: colors.background, limit: 320) ?? .init()
          onEvent(.layout(BlockLayout.make(block: block, translation: translation, colors: colors, room: room)))
          summary.translatedCount += 1
          if !summary.languages.contains(language) { summary.languages.append(language) }
        }
      } catch {
        summary.failures.append((language, error))
      }
    }
    lap("translate+layout")
    lastBlocks = blocks
    summary.timings = timings
    return summary
  }

  /// Keep a leading bullet if the translation dropped it.
  static func restoreMarkers(source: String, translation: String) -> String {
    let bullets: [Character] = ["•", "◦", "▪", "-", "–", "*"]
    if let first = source.first, bullets.contains(first), translation.first != first {
      return "\(first) " + translation.trimmingCharacters(in: .whitespaces)
    }
    return translation
  }

  static func normalized(_ s: String) -> String {
    s.lowercased().filter { $0.isLetter || $0.isNumber }
  }
}
