import AppKit
import Security

/// Updates from this repository's GitHub Releases. Each utility is released
/// on its own as `<id>-vX.Y.Z` with a notarized `<Name>.zip`; `<id>` is the
/// app's `UtilityID` (its lowercased name, set by scripts/build-app.sh).
/// Development builds (version 0.0.0) don't update.
@MainActor
public final class Updater {
  public static let shared = Updater()

  public struct Update {
    public let version: String
    let url: URL
  }

  public private(set) var available: Update?
  private var installing = false
  private let releasesURL = URL(string: "https://api.github.com/repos/ckafrouni/mac-utilities/releases?per_page=100")!

  private var utilityID: String? { Bundle.main.object(forInfoDictionaryKey: "UtilityID") as? String }

  public var isEnabled: Bool { utilityID != nil && UtilityApp.version != "0.0.0" }

  func start() {
    guard isEnabled else { return }
    check()
    Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
      MainActor.assumeIsolated { Updater.shared.check() }
    }
  }

  public func check(userInitiated: Bool = false) {
    Task {
      do {
        available = try await latest()
        guard userInitiated else { return }
        if let available {
          if UtilityApp.alert("\(UtilityApp.name) \(available.version) is available", "You have \(UtilityApp.version).", buttons: ["Update", "Later"]) == 0 {
            install()
          }
        } else {
          UtilityApp.alert("\(UtilityApp.name) is up to date", "You have \(UtilityApp.version), the latest version.")
        }
      } catch {
        if userInitiated { UtilityApp.alert("Couldn't check for updates", error.localizedDescription) }
      }
    }
  }

  private func latest() async throws -> Update? {
    struct Release: Decodable {
      struct Asset: Decodable { let name: String; let browser_download_url: URL }
      let tag_name: String
      let draft: Bool
      let prerelease: Bool
      let assets: [Asset]
    }
    guard let utilityID else { return nil }
    var request = URLRequest(url: releasesURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, _) = try await URLSession.shared.data(for: request)
    let prefix = "\(utilityID)-v"
    let zipName = "\(UtilityApp.name).zip"
    let newest = try JSONDecoder().decode([Release].self, from: data)
      .filter { !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(prefix) }
      .compactMap { release -> Update? in
        guard let asset = release.assets.first(where: { $0.name == zipName }) else { return nil }
        return Update(version: String(release.tag_name.dropFirst(prefix.count)), url: asset.browser_download_url)
      }
      .max { Self.isNewer($1.version, than: $0.version) }
    guard let newest, Self.isNewer(newest.version, than: UtilityApp.version) else { return nil }
    return newest
  }

  static func isNewer(_ a: String, than b: String) -> Bool {
    let parse = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
    return parse(b).lexicographicallyPrecedes(parse(a))
  }

  /// Downloads the update, checks it's signed by the same team as this app,
  /// swaps it in once this process has quit and opens it.
  public func install() {
    guard let update = available, !installing else { return }
    installing = true
    Task {
      defer { installing = false }
      do {
        let (zip, _) = try await URLSession.shared.download(from: update.url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", "-x", "-k", zip.path, dir.path)
        let app = dir.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        guard Self.isSignedLikeMe(app) else {
          throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "The download isn’t signed by the same developer."])
        }
        let script = """
          while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
          rm -rf "$2" && mv "$3" "$2" && open "$2"
          """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "sh", "\(getpid())", Bundle.main.bundlePath, app.path]
        try swap.run()
        NSApp.terminate(nil)
      } catch {
        UtilityApp.alert("Couldn't update \(UtilityApp.name)", error.localizedDescription)
      }
    }
  }

  private func run(_ tool: String, _ args: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(tool) failed."])
    }
  }

  /// Valid Developer ID signature from this app's team, for this bundle ID.
  private static func isSignedLikeMe(_ app: URL) -> Bool {
    var me: SecCode?
    var myStatic: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
      SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic,
      SecCodeCopySigningInformation(myStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
      let bundleID = Bundle.main.bundleIdentifier
    else { return false }

    var code: SecStaticCode?
    var requirement: SecRequirement?
    let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
    else { return false }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
  }
}
