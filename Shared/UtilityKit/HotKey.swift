import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon hot keys: no Accessibility permission needed).
@MainActor
public enum HotKey {
  private static var handlers: [UInt32: @MainActor () -> Void] = [:]
  private static var refs: [EventHotKeyRef] = []
  private static var installed = false

  /// `keyCode` is a virtual key code such as `kVK_ANSI_1`.
  public static func register(keyCode: Int, modifiers: NSEvent.ModifierFlags, action: @escaping @MainActor () -> Void) {
    installHandler()
    let id = UInt32(handlers.count + 1)
    handlers[id] = action
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x4F54_5452), id: id)  // "OTTR"
    let status = RegisterEventHotKey(UInt32(keyCode), carbonFlags(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    if status == noErr, let ref { refs.append(ref) } else { NSLog("Couldn't register hot key \(keyCode): \(status)") }
  }

  private static func installHandler() {
    guard !installed else { return }
    installed = true
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hotKeyID = EventHotKeyID()
      GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      let id = hotKeyID.id
      DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handlers[id]?() } }
      return noErr
    }, 1, &spec, nil, nil)
  }

  private static func carbonFlags(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
    var flags = 0
    if modifiers.contains(.command) { flags |= cmdKey }
    if modifiers.contains(.shift) { flags |= shiftKey }
    if modifiers.contains(.option) { flags |= optionKey }
    if modifiers.contains(.control) { flags |= controlKey }
    return UInt32(flags)
  }
}
