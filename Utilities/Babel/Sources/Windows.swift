import AppKit
import Combine
import SwiftUI
import Translation
import UtilityKit

// MARK: - Window presentation

/// Creates and shows small utility windows for a menu-bar (LSUIElement) app.
@MainActor
enum WindowPresenter {
  private static var windows: [String: NSWindow] = [:]

  static func show<V: View>(id: String, title: String, view: V) {
    let window = windows[id] ?? makeWindow(title: title)
    windows[id] = window
    window.contentViewController = NSHostingController(rootView: view)
    if !window.isVisible { window.center() }
    // A menu-bar app can't always take focus (activation is cooperative), so also order
    // the window front regardless; it becomes key as soon as it's clicked.
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  static func close(_ id: String) {
    windows[id]?.close()
  }

  private static func makeWindow(title: String) -> NSWindow {
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = title
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    return window
  }
}

// MARK: - Settings model

@available(macOS 26.4, *)
@MainActor
final class SettingsModel: ObservableObject {
  private let settings = Settings.shared

  @Published var shortcut: Shortcut? {
    didSet {
      guard shortcut != oldValue else { return }
      settings.shortcut = shortcut
      onShortcutChange?()
    }
  }
  @Published var targetLanguage: String { didSet { settings.targetLanguage = targetLanguage } }
  @Published var quality: TranslationQuality { didSet { settings.quality = quality } }
  @Published private(set) var openAtLogin = false
  @Published private(set) var hasPermission = ScreenCapture.hasPermission
  /// Set when the shortcut couldn't be registered.
  @Published var shortcutProblem: String?
  @Published var copiedLink = false

  /// Re-register the global shortcut after it changes.
  var onShortcutChange: (() -> Void)?
  /// Pause the global shortcut while recording a new one, so pressing it doesn't fire.
  var onRecording: ((Bool) -> Void)?

  private var poll: AnyCancellable?

  init() {
    shortcut = settings.shortcut
    targetLanguage = settings.targetLanguage
    quality = settings.quality
    openAtLogin = LoginItem.isEnabled
    poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
      guard let self else { return }
      let granted = ScreenCapture.hasPermission
      if granted != self.hasPermission { self.hasPermission = granted }
    }
  }

  func setOpenAtLogin(_ enabled: Bool) {
    if enabled != LoginItem.isEnabled { LoginItem.toggle() }
    openAtLogin = LoginItem.isEnabled
  }

  func requestPermission() {
    if !CGRequestScreenCaptureAccess() {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
  }

  func copyLink() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("babel://translate", forType: .string)
    copiedLink = true
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      self?.copiedLink = false
    }
  }
}

// MARK: - Settings window

@available(macOS 26.4, *)
struct SettingsView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 30)
        .padding(.top, 34)

      Form {
        if !model.hasPermission {
          Section { permissionBanner }
        }

        Section("Shortcut") {
          LabeledContent {
            ShortcutField(model: model)
          } label: {
            Text("Translate screen")
            if let problem = model.shortcutProblem {
              Text(problem).foregroundStyle(.orange)
            }
          }
          LabeledContent("Raycast & Shortcuts") {
            HStack(spacing: 8) {
              Text("babel://translate")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              Button(model.copiedLink ? "Copied" : "Copy") { model.copyLink() }
                .controlSize(.small)
            }
          }
          .help("Open this link from a Raycast quicklink, Shortcuts or a Stream Deck to translate")
        }

        Section("Translation") {
          Picker("Translate into", selection: $model.targetLanguage) {
            ForEach(Settings.targetLanguages, id: \.code) { language in
              Text(language.name).tag(language.code)
            }
          }
          LabeledContent {
            Picker("", selection: $model.quality) {
              Text("Fast").tag(TranslationQuality.fast)
              Text("Best").tag(TranslationQuality.highFidelity)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
          } label: {
            Text("Quality")
            Text("Best is slower, and covers a few more languages.")
          }
        }

        Section("General") {
          Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
          if model.hasPermission {
            LabeledContent("Screen Recording") {
              Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
          }
        }

        Section {
          HStack(spacing: 0) {
            tip("⌥", "hold for original")
            Spacer(minLength: 12)
            tip("click", "copy")
            Spacer(minLength: 12)
            tip("esc", "close")
          }
        } header: {
          Text("While translating")
        } footer: {
          Label("Text recognition and translation run entirely on this Mac.", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .scrollDisabled(true)
    }
    .frame(width: 520, height: model.hasPermission ? 668 : 748)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 54, height: 54)
      VStack(alignment: .leading, spacing: 2) {
        Text("Babel")
          .font(.system(size: 20, weight: .bold))
        Text("Translate anything on your screen, right where it is.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private var permissionBanner: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "rectangle.dashed.badge.record")
        .font(.system(size: 22))
        .foregroundStyle(.orange)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text("Allow Screen Recording").font(.headline)
        Text("Babel needs it to read what's on screen. macOS may ask you to reopen Babel afterwards.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button("Allow…") { model.requestPermission() }
        .buttonStyle(.borderedProminent)
    }
    .padding(.vertical, 4)
  }

  private func tip(_ key: String, _ text: String) -> some View {
    HStack(spacing: 7) {
      Keycap(key)
      Text(text).foregroundStyle(.secondary)
    }
  }
}

// MARK: - Shortcut field

/// Shows the shortcut as keycaps; click to record a new one (Esc cancels, ⌫ clears).
@available(macOS 26.4, *)
struct ShortcutField: View {
  @ObservedObject var model: SettingsModel
  @State private var recording = false
  @State private var monitor: Any?
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 6) {
      Button(action: toggleRecording) {
        HStack(spacing: 4) {
          if recording {
            Text("Type shortcut…")
              .foregroundStyle(Color.accentColor)
              .opacity(pulse ? 0.55 : 1)
          } else if let shortcut = model.shortcut {
            ForEach(shortcut.keys, id: \.self) { Keycap($0) }
          } else {
            Text("Record shortcut").foregroundStyle(.secondary)
          }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(minWidth: 116, minHeight: 28)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: recording ? 2 : 1)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(recording ? "Press a key combination · Esc to cancel · ⌫ to clear" : "Click to change")

      if model.shortcut != nil, !recording {
        Button {
          model.shortcut = nil
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Remove the shortcut")
      }
    }
    .onDisappear(perform: stop)
  }

  private func toggleRecording() {
    recording ? stop() : start()
  }

  private func start() {
    recording = true
    model.onRecording?(true)
    withAnimation(.easeInOut(duration: 0.7).repeatForever()) { pulse = true }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      switch Int(event.keyCode) {
      case 53:  // Esc
        stop()
      case 51, 117:  // ⌫ / ⌦
        model.shortcut = nil
        stop()
      default:
        if let shortcut = Shortcut(event: event) {
          model.shortcut = shortcut
          stop()
        } else {
          NSSound.beep()  // needs ⌘, ⌥ or ⌃
        }
      }
      return nil
    }
  }

  private func stop() {
    guard recording else { return }
    recording = false
    pulse = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    model.onRecording?(false)
  }
}

struct Keycap: View {
  let label: String
  init(_ label: String) { self.label = label }

  var body: some View {
    Text(label)
      .font(.system(size: 12, weight: .semibold, design: .rounded))
      .foregroundStyle(.primary)
      .frame(minWidth: 22, minHeight: 22)
      .padding(.horizontal, label.count > 1 ? 6 : 0)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(Color(nsColor: .controlColor))
          .shadow(color: .black.opacity(0.22), radius: 0, x: 0, y: 1)
      )
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
  }
}

// MARK: - Language download

/// Asks the system to download a translation model (it shows its own download sheet).
@available(macOS 26.4, *)
struct LanguageDownloadView: View {
  let source: String
  let target: String
  var onFinished: () -> Void
  @State private var configuration: TranslationSession.Configuration?
  @State private var status: String?

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "arrow.down.circle.fill")
        .font(.system(size: 40))
        .foregroundStyle(.tint)
        .padding(.top, 12)
      VStack(spacing: 6) {
        Text("Download \(Translator.displayName(source))")
          .font(.title3.bold())
        Text(
          "Babel translates on this Mac, so \(Translator.displayName(source)) → \(Translator.displayName(target)) needs a one-time download. After that it works offline."
        )
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      if let status {
        Text(status).font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Button("Translation Settings…") {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
        }
        Spacer()
        Button("Download") {
          status = "Waiting for the download…"
          configuration = .init(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target))
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 420)
    .translationTask(configuration) { session in
      do {
        try await session.prepareTranslation()
        status = "Ready. Press the shortcut again."
        try? await Task.sleep(for: .seconds(1))
        onFinished()
      } catch {
        status = "The download didn't finish: \(error.localizedDescription)"
      }
    }
  }
}
