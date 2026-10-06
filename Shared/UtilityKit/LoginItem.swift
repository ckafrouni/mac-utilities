import ServiceManagement

/// Open at Login, through the app's own login item.
@MainActor
public enum LoginItem {
  public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  public static func toggle() {
    do {
      if isEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
    } catch {
      UtilityApp.alert("Couldn't change Open at Login", error.localizedDescription)
    }
  }
}
