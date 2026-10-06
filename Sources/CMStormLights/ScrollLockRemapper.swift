import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Stops macOS acting on a keyboard's Scroll Lock key.
///
/// macOS turns HID Scroll Lock into F14, which by default is "decrease display
/// brightness". We remap Scroll Lock to F20 (no default action) in the
/// keyboard's `UserKeyMapping`, the same per-device mapping `hidutil` and the
/// Modifier Keys settings use. The remap happens in the HID event system, so
/// IOHIDManager still reports the raw Scroll Lock press to us.
///
/// Mappings are reset by macOS when the keyboard is replugged or the Mac
/// restarts, so the controller reapplies them whenever a keyboard appears.
enum ScrollLockRemapper {
    private static let mappingKey = "UserKeyMapping"
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"
    private static let scrollLock: UInt64 = 0x7_0000_0047
    private static let f20: UInt64 = 0x7_0000_006F

    /// Adds or removes the Scroll Lock → F20 remap on every HID service of the
    /// given keyboard, keeping any other mappings already present.
    /// Returns false if no matching service could be updated.
    @discardableResult
    static func setSuppressed(_ suppressed: Bool, vendorID: Int, productID: Int) -> Bool {
        let services = keyboardServices(vendorID: vendorID, productID: productID)
        guard !services.isEmpty else { return false }

        var success = true
        for service in services {
            let existing = IOHIDServiceClientCopyProperty(service, mappingKey as CFString) as? [[String: Any]] ?? []
            var mapping = existing.filter { entry in
                let source = (entry[sourceKey] as? NSNumber)?.uint64Value
                let destination = (entry[destinationKey] as? NSNumber)?.uint64Value
                // When suppressing, replace any Scroll Lock mapping; when
                // restoring, only remove the one we added.
                return suppressed ? source != scrollLock : !(source == scrollLock && destination == f20)
            }
            if suppressed {
                mapping.append([
                    sourceKey: NSNumber(value: scrollLock),
                    destinationKey: NSNumber(value: f20),
                ])
            } else if mapping.count == existing.count {
                continue // Nothing of ours to remove.
            }

            if !IOHIDServiceClientSetProperty(service, mappingKey as CFString, mapping as CFArray) {
                success = setWithHidutil(mapping, vendorID: vendorID, productID: productID) && success
            }
        }
        return success
    }

    private static func keyboardServices(vendorID: Int, productID: Int) -> [IOHIDServiceClient] {
        let client: IOHIDEventSystemClient? = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let client, let array = IOHIDEventSystemClientCopyServices(client) else { return [] }

        var result: [IOHIDServiceClient] = []
        for index in 0..<CFArrayGetCount(array) {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: IOHIDServiceClient.self)
            guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0,
                  intProperty(service, kIOHIDVendorIDKey) == vendorID,
                  intProperty(service, kIOHIDProductIDKey) == productID else { continue }
            result.append(service)
        }
        return result
    }

    private static func intProperty(_ service: IOHIDServiceClient, _ key: String) -> Int? {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
    }

    /// Fallback for systems where the direct property write is refused.
    private static func setWithHidutil(_ mapping: [[String: Any]], vendorID: Int, productID: Int) -> Bool {
        let matching = ["VendorID": vendorID, "ProductID": productID]
        let value = [mappingKey: mapping]
        guard let matchingJSON = try? JSONSerialization.data(withJSONObject: matching),
              let valueJSON = try? JSONSerialization.data(withJSONObject: value) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = [
            "property",
            "--matching", String(decoding: matchingJSON, as: UTF8.self),
            "--set", String(decoding: valueJSON, as: UTF8.self),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
