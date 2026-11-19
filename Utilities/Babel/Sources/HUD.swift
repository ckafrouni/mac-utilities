import SwiftUI

/// The small status pill shown at the bottom of the overlay.
@MainActor
final class HUDModel: ObservableObject {
  enum State {
    case working(String)
    case done(title: String)
    case message(String, symbol: String, action: Action?)
  }

  struct Action {
    var title: String
    var run: () -> Void
  }

  @Published var state: State = .working("Reading screen…")
  @Published var flashText: String?
  @Published var pinnedOriginal = false
  var onCopyAll: (() -> Void)?
  var onToggleOriginal: (() -> Void)?

  private var flashTask: Task<Void, Never>?

  func flash(_ text: String) {
    flashText = text
    flashTask?.cancel()
    flashTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled else { return }
      self?.flashText = nil
    }
  }
}

struct HUDView: View {
  @ObservedObject var model: HUDModel

  var body: some View {
    HStack(spacing: 10) {
      if let flash = model.flashText {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text(flash)
      } else {
        content
      }
    }
    .font(.system(size: 13, weight: .medium))
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Capsule().fill(Color.black.opacity(0.82)))
    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    .fixedSize()
    .padding(20)  // room for the shadow
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder private var content: some View {
    switch model.state {
    case let .working(text):
      ProgressView().controlSize(.small)
      Text(text)
    case let .done(title):
      Image(systemName: "translate")
      Text(title)
      Text("⌥ hold for original · click to copy · esc")
        .foregroundStyle(.white.opacity(0.55))
        .font(.system(size: 12))
      Divider().frame(height: 14).overlay(Color.white.opacity(0.25))
      pillButton(model.pinnedOriginal ? "Translation" : "Original") { model.onToggleOriginal?() }
      pillButton("Copy all") { model.onCopyAll?() }
    case let .message(text, symbol, action):
      Image(systemName: symbol)
      Text(text)
      if let action {
        pillButton(action.title, action: action.run)
      }
    }
  }

  private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.16)))
    }
    .buttonStyle(.plain)
  }
}
