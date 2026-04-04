import Foundation
import ServiceManagement
import SwiftUI
import Carbon.HIToolbox

enum AppAccentColor: String, CaseIterable, Identifiable {
    case white
    case red
    case blue
    case green
    case orange
    case pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .white:
            return Color.white.opacity(0.9)
        case .red:
            return Color(red: 0.98, green: 0.39, blue: 0.43)
        case .blue:
            return Color(red: 0.36, green: 0.66, blue: 1.0)
        case .green:
            return Color(red: 0.30, green: 0.84, blue: 0.58)
        case .orange:
            return Color(red: 1.0, green: 0.64, blue: 0.30)
        case .pink:
            return Color(red: 1.0, green: 0.46, blue: 0.72)
        }
    }
}

enum Preferences {
    static let isWidgetStorageEncryptionEnabled = false

    private static let showMenuBarIconKey = "showMenuBarIcon"
    private static let openNotchModeKey = "openNotchMode"
    private static let hoverDelayKey = "hoverDelay"
    private static let rememberLastViewKey = "rememberLastView"
    private static let accentColorKey = "accentColor"
    private static let keyboardShortcutsEnabledKey = "keyboardShortcutsEnabled"
    private static let toggleNotchShortcutKeyCodeKey = "toggleNotchShortcutKeyCode"
    private static let toggleNotchShortcutModifiersKey = "toggleNotchShortcutModifiers"

    enum OpenNotchMode: String {
        case click
        case hover
    }

    struct KeyboardShortcut: Equatable {
        var keyCode: UInt32
        var modifiers: NSEvent.ModifierFlags

        static let toggleNotchDefault = KeyboardShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: [.option, .command]
        )

        var displayString: String {
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("⌃") }
            if modifiers.contains(.option) { parts.append("⌥") }
            if modifiers.contains(.shift) { parts.append("⇧") }
            if modifiers.contains(.command) { parts.append("⌘") }
            parts.append(keyDisplayString(for: keyCode))
            return parts.joined()
        }

        var carbonModifiers: UInt32 {
            var result: UInt32 = 0
            if modifiers.contains(.command) { result |= UInt32(cmdKey) }
            if modifiers.contains(.option) { result |= UInt32(optionKey) }
            if modifiers.contains(.control) { result |= UInt32(controlKey) }
            if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
            return result
        }
    }

    static var isLaunchAtLoginEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    @discardableResult
    static func setLaunchAtLoginEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            return true
        } catch {
            NSLog("Failed to update Launch at Login setting: \(error.localizedDescription)")
            return false
        }
    }

    static var isMenuBarIconEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: showMenuBarIconKey) == nil {
                return true
            }

            return UserDefaults.standard.bool(forKey: showMenuBarIconKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showMenuBarIconKey)
            NotificationCenter.default.post(name: .menuBarIconPreferenceDidChange, object: nil)
        }
    }

    static var openNotchMode: OpenNotchMode {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: openNotchModeKey),
                  let mode = OpenNotchMode(rawValue: rawValue) else {
                return .click
            }

            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: openNotchModeKey)
        }
    }

    static var hoverDelay: Double {
        get {
            let value = UserDefaults.standard.double(forKey: hoverDelayKey)
            return value == 0 ? 0.3 : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hoverDelayKey)
        }
    }

    static var rememberLastView: Bool {
        get {
            if UserDefaults.standard.object(forKey: rememberLastViewKey) == nil {
                return true
            }

            return UserDefaults.standard.bool(forKey: rememberLastViewKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: rememberLastViewKey)
        }
    }

    static var accentColor: AppAccentColor {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: accentColorKey),
                  let color = AppAccentColor(rawValue: rawValue) else {
                return .white
            }

            return color
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: accentColorKey)
            NotificationCenter.default.post(name: .accentColorPreferenceDidChange, object: nil)
        }
    }

    static var keyboardShortcutsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: keyboardShortcutsEnabledKey) == nil {
                return false
            }

            return UserDefaults.standard.bool(forKey: keyboardShortcutsEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyboardShortcutsEnabledKey)
            NotificationCenter.default.post(name: .keyboardShortcutsPreferenceDidChange, object: nil)
        }
    }

    static var toggleNotchShortcut: KeyboardShortcut? {
        get {
            guard UserDefaults.standard.object(forKey: toggleNotchShortcutKeyCodeKey) != nil else {
                return .toggleNotchDefault
            }

            let keyCode = UInt32(UserDefaults.standard.integer(forKey: toggleNotchShortcutKeyCodeKey))
            guard keyCode != 0 else {
                return nil
            }
            let modifierRawValue = (UserDefaults.standard.object(forKey: toggleNotchShortcutModifiersKey) as? NSNumber)?.uint64Value ?? 0
            return KeyboardShortcut(
                keyCode: keyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifierRawValue))
            )
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue.keyCode), forKey: toggleNotchShortcutKeyCodeKey)
                UserDefaults.standard.set(newValue.modifiers.rawValue, forKey: toggleNotchShortcutModifiersKey)
            } else {
                UserDefaults.standard.set(0, forKey: toggleNotchShortcutKeyCodeKey)
                UserDefaults.standard.set(0, forKey: toggleNotchShortcutModifiersKey)
            }
            NotificationCenter.default.post(name: .keyboardShortcutPreferenceDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let menuBarIconPreferenceDidChange = Notification.Name("menuBarIconPreferenceDidChange")
    static let accentColorPreferenceDidChange = Notification.Name("accentColorPreferenceDidChange")
    static let keyboardShortcutsPreferenceDidChange = Notification.Name("keyboardShortcutsPreferenceDidChange")
    static let keyboardShortcutPreferenceDidChange = Notification.Name("keyboardShortcutPreferenceDidChange")
}

private func keyDisplayString(for keyCode: UInt32) -> String {
    switch keyCode {
    case UInt32(kVK_Return):
        return "Return"
    case UInt32(kVK_Tab):
        return "Tab"
    case UInt32(kVK_Space):
        return "Space"
    case UInt32(kVK_Delete):
        return "Delete"
    case UInt32(kVK_Escape):
        return "Esc"
    case UInt32(kVK_LeftArrow):
        return "←"
    case UInt32(kVK_RightArrow):
        return "→"
    case UInt32(kVK_DownArrow):
        return "↓"
    case UInt32(kVK_UpArrow):
        return "↑"
    default:
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key"
        }

        let keyboardLayout = unsafeBitCast(layoutData, to: CFData.self)
        guard let layoutPtr = CFDataGetBytePtr(keyboardLayout) else {
            return "Key"
        }

        let layout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(layoutPtr))
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else {
            return "Key"
        }

        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
