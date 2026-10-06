import AppKit
import Combine
import Foundation
import IOKit.hid
import ServiceManagement

/// Finds external keyboards via IOHIDManager and drives their backlight LED.
///
/// macOS rewrites a keyboard's whole LED output report whenever Caps Lock
/// changes, on wake, and when a device is (re)attached, which switches the
/// Scroll Lock LED (and therefore the CM Storm backlight) off again. The
/// controller reapplies the desired state after each of those events.
final class KeyboardLightController: ObservableObject {
    static let shared = KeyboardLightController()

    enum Permission: Equatable {
        case unknown
        case granted
        case denied
    }

    private enum Keys {
        static let lightsOn = "lightsOn"
        static let target = "ledTarget"
        static let scrollLockToggles = "scrollLockKeyToggles"
        static let keepAlive = "keepAlive"
        static let excluded = "excludedKeyboards"
    }

    @Published private(set) var keyboards: [Keyboard] = []
    @Published private(set) var permission: Permission = .unknown
    @Published private(set) var lastError: String?

    @Published var lightsOn: Bool {
        didSet {
            defaults.set(lightsOn, forKey: Keys.lightsOn)
            applyToAll()
        }
    }

    @Published var target: LEDTarget {
        didSet {
            guard target != oldValue else { return }
            defaults.set(target.rawValue, forKey: Keys.target)
            // Switch the previously chosen LED off so it isn't left stranded.
            for keyboard in activeKeyboards { keyboard.set(false, target: oldValue) }
            applyToAll()
        }
    }

    @Published var scrollLockToggles: Bool {
        didSet {
            defaults.set(scrollLockToggles, forKey: Keys.scrollLockToggles)
            for keyboard in activeKeyboards { updateScrollLockRemap(for: keyboard) }
        }
    }

    @Published var keepAlive: Bool {
        didSet {
            defaults.set(keepAlive, forKey: Keys.keepAlive)
            updateKeepAliveTimer()
        }
    }

    @Published private var excluded: Set<String> {
        didSet { defaults.set(Array(excluded).sorted(), forKey: Keys.excluded) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private var manager: IOHIDManager?
    private var managerOpen = false
    private var keepAliveTimer: Timer?
    private var permissionTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {
        defaults.register(defaults: [
            Keys.lightsOn: true,
            Keys.target: LEDTarget.scrollLock.rawValue,
            Keys.scrollLockToggles: true,
            Keys.keepAlive: false,
        ])
        lightsOn = defaults.bool(forKey: Keys.lightsOn)
        target = LEDTarget(rawValue: defaults.string(forKey: Keys.target) ?? "") ?? .scrollLock
        scrollLockToggles = defaults.bool(forKey: Keys.scrollLockToggles)
        keepAlive = defaults.bool(forKey: Keys.keepAlive)
        excluded = Set(defaults.stringArray(forKey: Keys.excluded) ?? [])
    }

    // MARK: - Lifecycle

    func start() {
        guard manager == nil else { return }

        refreshPermission()
        if permission != .granted {
            // Shows the system "Input Monitoring" prompt the first time.
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            refreshPermission()
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let keyboardMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, keyboardMatch as CFDictionary)

        let keyMatches: [[String: Any]] = [
            [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad, kIOHIDElementUsageKey: kHIDUsage_KeyboardScrollLock],
            [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad, kIOHIDElementUsageKey: kHIDUsage_KeyboardCapsLock],
        ]
        IOHIDManagerSetInputValueMatchingMultiple(manager, keyMatches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KeyboardLightController>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KeyboardLightController>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<KeyboardLightController>.fromOpaque(context).takeUnretainedValue().inputValue(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        openManager()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reapplySoon(after: [0.5, 2, 5])
            })
        }

        updateKeepAliveTimer()
    }

    private func openManager() {
        guard let manager, !managerOpen else { return }
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == 0 {
            managerOpen = true
            lastError = nil
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else {
            lastError = String(format: "Could not open keyboards (IOReturn 0x%08X)", UInt32(bitPattern: result))
            watchForPermission()
        }
        refreshPermission()
    }

    // MARK: - Permission

    func refreshPermission() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let newValue: Permission
        if access == kIOHIDAccessTypeGranted {
            newValue = .granted
        } else if access == kIOHIDAccessTypeDenied {
            newValue = .denied
        } else {
            newValue = .unknown
        }
        if permission != newValue { permission = newValue }
    }

    private func watchForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshPermission()
            if self.permission == .granted { self.openManager() }
        }
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Keyboards

    private var activeKeyboards: [Keyboard] {
        keyboards.filter { !excluded.contains($0.settingsKey) }
    }

    func isEnabled(_ keyboard: Keyboard) -> Bool {
        !excluded.contains(keyboard.settingsKey)
    }

    func setEnabled(_ enabled: Bool, for keyboard: Keyboard) {
        if enabled {
            excluded.remove(keyboard.settingsKey)
            apply(to: keyboard)
        } else {
            keyboard.set(false, target: target)
            excluded.insert(keyboard.settingsKey)
        }
        updateScrollLockRemap(for: keyboard)
    }

    func toggle() {
        lightsOn.toggle()
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        guard !keyboards.contains(where: { $0.device === device }),
              let keyboard = Keyboard(device: device),
              !keyboard.isBuiltIn else { return }
        keyboards.append(keyboard)
        // macOS sets the LED report itself just after attach; apply after it.
        apply(to: keyboard)
        reapplySoon(after: [0.3, 1.5])
        // The keyboard's event-system services can appear slightly after the
        // IOHIDDevice does, so retry the remap a couple of times.
        for delay in [0.0, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak keyboard] in
                guard let self, let keyboard, self.keyboards.contains(where: { $0 === keyboard }) else { return }
                self.updateScrollLockRemap(for: keyboard)
            }
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        keyboards.removeAll { $0.device === device }
    }

    private func inputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        let pressed = IOHIDValueGetIntegerValue(value) != 0

        switch IOHIDElementGetUsage(element) {
        case UInt32(kHIDUsage_KeyboardScrollLock):
            if pressed, scrollLockToggles { toggle() }
        case UInt32(kHIDUsage_KeyboardCapsLock):
            // macOS rewrites all LEDs when Caps Lock changes state.
            reapplySoon(after: [0.1, 0.5])
        default:
            break
        }
    }

    // MARK: - Scroll Lock remap

    /// While the Scroll Lock key toggles the lights, stop macOS also treating
    /// it as F14 ("decrease display brightness").
    private func updateScrollLockRemap(for keyboard: Keyboard) {
        let suppress = scrollLockToggles && isEnabled(keyboard)
        if !ScrollLockRemapper.setSuppressed(suppress, vendorID: keyboard.vendorID, productID: keyboard.productID), suppress {
            lastError = "\(keyboard.name): couldn't stop Scroll Lock dimming the display"
        }
    }

    /// Puts every keyboard's Scroll Lock key back to normal (used on quit).
    func restoreScrollLockKeys() {
        for keyboard in keyboards {
            ScrollLockRemapper.setSuppressed(false, vendorID: keyboard.vendorID, productID: keyboard.productID)
        }
    }

    // MARK: - Applying

    func applyToAll() {
        for keyboard in activeKeyboards { apply(to: keyboard) }
    }

    private func apply(to keyboard: Keyboard) {
        guard isEnabled(keyboard) else { return }
        if let failure = keyboard.set(lightsOn, target: target) {
            lastError = String(format: "%@: write failed (IOReturn 0x%08X)", keyboard.name, UInt32(bitPattern: failure))
        }
    }

    private func reapplySoon(after delays: [TimeInterval]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyToAll()
            }
        }
    }

    private func updateKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        guard keepAlive else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.lightsOn else { return }
            self.applyToAll()
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }
}
