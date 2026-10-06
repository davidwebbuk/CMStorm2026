import IOKit.hid

/// Which keyboard LED drives the backlight.
///
/// CM Storm keyboards (Devastator, Octane, etc.) wire their backlight to the
/// Scroll Lock LED, which macOS never switches on by itself. Some rebadged
/// boards use a different LED, so the choice is configurable.
enum LEDTarget: String, CaseIterable, Identifiable {
    case scrollLock
    case numLock
    case capsLock
    case compose
    case kana
    case all

    var id: String { rawValue }

    /// HID usage on the LED page (0x08), or nil to drive every LED.
    var usage: UInt32? {
        switch self {
        case .numLock: return UInt32(kHIDUsage_LED_NumLock)
        case .capsLock: return UInt32(kHIDUsage_LED_CapsLock)
        case .scrollLock: return UInt32(kHIDUsage_LED_ScrollLock)
        case .compose: return UInt32(kHIDUsage_LED_Compose)
        case .kana: return UInt32(kHIDUsage_LED_Kana)
        case .all: return nil
        }
    }

    var title: String {
        self == .scrollLock ? "Scroll Lock (CM Storm default)" : shortName
    }

    var shortName: String {
        switch self {
        case .scrollLock: return "Scroll Lock"
        case .numLock: return "Num Lock"
        case .capsLock: return "Caps Lock"
        case .compose: return "Compose"
        case .kana: return "Kana"
        case .all: return "All LEDs"
        }
    }
}
