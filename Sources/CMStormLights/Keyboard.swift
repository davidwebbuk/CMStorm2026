import Foundation
import IOKit.hid

/// A connected HID keyboard that exposes at least one LED output element.
final class Keyboard: Identifiable {
    let device: IOHIDDevice
    let name: String
    let vendorID: Int
    let productID: Int
    let isBuiltIn: Bool
    private let leds: [IOHIDElement]

    var id: ObjectIdentifier { ObjectIdentifier(device) }

    /// Stable key used to remember per-keyboard preferences across replugs.
    var settingsKey: String { String(format: "%04X:%04X", vendorID, productID) }

    init?(device: IOHIDDevice) {
        self.device = device

        let leds = Keyboard.ledElements(of: device)
        guard !leds.isEmpty else { return nil }
        self.leds = leds

        let product = Keyboard.property(device, kIOHIDProductKey) as? String
        let manufacturer = Keyboard.property(device, kIOHIDManufacturerKey) as? String
        vendorID = (Keyboard.property(device, kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0
        productID = (Keyboard.property(device, kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0

        let transport = (Keyboard.property(device, kIOHIDTransportKey) as? String) ?? ""
        let builtInFlag = (Keyboard.property(device, "Built-In") as? NSNumber)?.boolValue ?? false
        isBuiltIn = builtInFlag || ["SPI", "FIFO", "I2C"].contains(transport.uppercased())

        switch (manufacturer?.trimmingCharacters(in: .whitespaces), product?.trimmingCharacters(in: .whitespaces)) {
        case let (m?, p?) where !m.isEmpty && !p.isEmpty && !p.localizedCaseInsensitiveContains(m):
            name = "\(m) \(p)"
        case let (_, p?) where !p.isEmpty:
            name = p
        default:
            name = String(format: "Keyboard %04X:%04X", vendorID, productID)
        }
    }

    func elements(for target: LEDTarget) -> [IOHIDElement] {
        guard let usage = target.usage else { return leds }
        return leds.filter { IOHIDElementGetUsage($0) == usage }
    }

    func supports(_ target: LEDTarget) -> Bool { !elements(for: target).isEmpty }

    /// Writes the on/off value to every LED element matching `target`.
    /// Returns the first non-success IOReturn, or nil on success.
    @discardableResult
    func set(_ on: Bool, target: LEDTarget) -> IOReturn? {
        var failure: IOReturn?
        for element in elements(for: target) {
            let raw = on ? IOHIDElementGetLogicalMax(element) : IOHIDElementGetLogicalMin(element)
            let value: IOHIDValue? = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, raw)
            guard let value else { continue }
            let result = IOHIDDeviceSetValue(device, element, value)
            if result != 0, failure == nil { failure = result }
        }
        return failure
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    private static func ledElements(of device: IOHIDDevice) -> [IOHIDElement] {
        let matching = [kIOHIDElementUsagePageKey: kHIDPage_LEDs] as CFDictionary
        guard let array = IOHIDDeviceCopyMatchingElements(device, matching, IOOptionBits(kIOHIDOptionsTypeNone)) else {
            return []
        }
        var result: [IOHIDElement] = []
        for index in 0..<CFArrayGetCount(array) {
            let element = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: IOHIDElement.self)
            guard IOHIDElementGetType(element) == kIOHIDElementTypeOutput,
                  IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_LEDs) else { continue }
            result.append(element)
        }
        return result
    }
}
