// swift-tools-version: 5.10
import Foundation
import PackageDescription

// Every folder in Utilities/ is an app: Utilities/<Name>/Sources builds the
// executable <Name>, with UtilityKit (the menu bar app, hotkeys, updates).
let utilities = (try? FileManager.default.contentsOfDirectory(atPath: Context.packageDirectory + "/Utilities"))?
  .filter { !$0.hasPrefix(".") }
  .sorted() ?? []

let package = Package(
  name: "mac-utilities",
  platforms: [.macOS(.v14)],
  products: utilities.map { .executable(name: $0, targets: [$0]) },
  targets: [
    .target(name: "UtilityKit", path: "Shared/UtilityKit"),
  ] + utilities.map {
    .executableTarget(name: $0, dependencies: ["UtilityKit"], path: "Utilities/\($0)/Sources")
  }
)
