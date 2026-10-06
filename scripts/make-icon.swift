// Draws a utility's app icon: an SF Symbol in white on a colored macOS squircle.
//   swift scripts/make-icon.swift <Name> <SF Symbol> <hex color> [angle]
// Writes Utilities/<Name>/Resources/AppIcon.icns (Info.plist's CFBundleIconFile is AppIcon).
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else {
  print("usage: swift scripts/make-icon.swift <Name> <SF Symbol> <hex color> [angle]")
  exit(1)
}
let (name, symbol, hex) = (args[1], args[2], args[3])
let angle = args.count > 4 ? CGFloat(Double(args[4]) ?? 0) : 0

func color(_ hex: String, _ brightness: CGFloat = 1) -> NSColor {
  let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
  let c = NSColor(
    srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  return brightness == 1 ? c : (brightness > 1 ? c.blended(withFraction: brightness - 1, of: .white)! : c.blended(withFraction: 1 - brightness, of: .black)!)
}

func render(_ size: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(size) / 1024
  // Apple's grid: an 824pt body centered on the 1024pt canvas.
  let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
  let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
  shadow.shadowOffset = CGSize(width: 0, height: -10 * s)
  shadow.shadowBlurRadius = 20 * s
  NSGraphicsContext.saveGraphicsState()
  shadow.set()
  color(hex).setFill()
  squircle.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(starting: color(hex, 1.18), ending: color(hex, 0.82))!.draw(in: squircle, angle: -90)

  let config = NSImage.SymbolConfiguration(pointSize: 400 * s, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
  if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let transform = NSAffineTransform()
    transform.translateX(by: body.midX, yBy: body.midY)
    transform.rotate(byDegrees: angle)
    transform.concat()
    glyph.draw(in: CGRect(x: -glyph.size.width / 2, y: -glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
  } else {
    print("No SF Symbol named \(symbol)")
    exit(1)
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let resources = URL(fileURLWithPath: "Utilities/\(name)/Resources")
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
  try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
  try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try render(1024).write(to: fm.temporaryDirectory.appendingPathComponent("\(name)-icon.png"))
print("Wrote \(resources.path)/AppIcon.icns (preview: \(fm.temporaryDirectory.path)/\(name)-icon.png)")
