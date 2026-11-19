import AppKit
import ImageIO
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
  case displayNotFound
  var errorDescription: String? { "Couldn't find that display to capture." }
}

enum ScreenCapture {
  static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

  /// Development aid, dev builds only:
  /// `defaults write com.ckafrouni.babel.dev debugImage /path/to/screenshot.png`
  /// makes Babel translate that image instead of the screen.
  static var debugImagePath: String? {
    guard Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.0.0" else { return nil }
    return UserDefaults.standard.string(forKey: "debugImage")
  }

  /// Captures `screen` at native pixel resolution, without the cursor or Babel's own windows.
  static func capture(_ screen: NSScreen) async throws -> CGImage {
    if let path = debugImagePath,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    {
      return image
    }
    let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
      throw ScreenCaptureError.displayNotFound
    }
    let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
    let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    config.width = Int(filter.contentRect.width * scale)
    config.height = Int(filter.contentRect.height * scale)
    config.showsCursor = false
    config.captureResolution = .best
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }
}
