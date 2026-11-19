import Foundation
import Translation

@available(macOS 26.4, *)
enum TranslationQuality: String, Sendable, CaseIterable {
  case fast, highFidelity

  var strategy: TranslationSession.Strategy {
    self == .fast ? .lowLatency : .highFidelity
  }
}

@available(macOS 26.4, *)
enum TranslatorError: LocalizedError {
  case notInstalled(source: String, target: String)
  case unsupported(source: String, target: String)

  var errorDescription: String? {
    switch self {
    case let .notInstalled(source, target):
      return "\(Translator.displayName(source)) → \(Translator.displayName(target)) isn't downloaded yet."
    case let .unsupported(source, target):
      return "Apple Translation can't translate \(Translator.displayName(source)) → \(Translator.displayName(target))."
    }
  }
}

/// On-device translation via Apple's Translation framework. Sessions are cached per
/// language pair so repeated use is fast.
///
/// The two strategies have different language coverage (e.g. low-latency may lack Italian or
/// Swedish that high-fidelity has), so availability is checked per strategy and we fall back
/// to the other one rather than failing.
@available(macOS 26.4, *)
@MainActor
final class Translator {
  var quality: TranslationQuality = .fast
  private var sessions: [String: TranslationSession] = [:]

  init() {}

  /// The strategy to use for a pair, or why none can be used.
  private func strategy(source: String, target: String) async throws -> TranslationSession.Strategy {
    let order: [TranslationSession.Strategy] = quality == .fast ? [.lowLatency, .highFidelity] : [.highFidelity, .lowLatency]
    var downloadable = false
    for strategy in order {
      let status = await LanguageAvailability(preferredStrategy: strategy)
        .status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
      if status == .installed { return strategy }
      if status == .supported { downloadable = true }
    }
    throw downloadable
      ? TranslatorError.notInstalled(source: source, target: target)
      : TranslatorError.unsupported(source: source, target: target)
  }

  /// Translates `texts` (keyed by block id), calling `onResult` as each translation arrives.
  func translate(
    _ texts: [(id: Int, text: String)],
    from source: String,
    to target: String,
    onResult: (Int, String) -> Void
  ) async throws {
    guard !texts.isEmpty else { return }
    let strategy = try await strategy(source: source, target: target)
    let key = "\(source)>\(target)>\(strategy == .lowLatency ? "fast" : "hf")"
    let session =
      sessions[key]
      ?? TranslationSession(
        installedSource: Locale.Language(identifier: source),
        target: Locale.Language(identifier: target),
        preferredStrategy: strategy
      )
    sessions[key] = session

    let requests = texts.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
    var done = Set<Int>()
    do {
      for try await response in session.translate(batch: requests) {
        if let id = response.clientIdentifier.flatMap(Int.init) {
          done.insert(id)
          onResult(id, response.targetText)
        }
      }
    } catch {
      try Task.checkCancellation()
      // One unreadable paragraph (OCR noise) fails the whole batch. Retry the rest one
      // by one so the good ones still get translated.
      sessions[key] = nil
      let fresh = TranslationSession(
        installedSource: Locale.Language(identifier: source),
        target: Locale.Language(identifier: target), preferredStrategy: strategy)
      var translatedAny = !done.isEmpty
      for item in texts where !done.contains(item.id) {
        try Task.checkCancellation()
        if let response = try? await fresh.translate(item.text) {
          translatedAny = true
          onResult(item.id, response.targetText)
        }
      }
      sessions[key] = fresh
      if !translatedAny { throw error }
    }
  }

  nonisolated static func displayName(_ code: String) -> String {
    Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
  }
}
