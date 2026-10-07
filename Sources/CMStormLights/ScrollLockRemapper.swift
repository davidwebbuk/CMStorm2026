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
    ///
    /// The direct property write can report success without taking effect, so
    /// each service is read back afterwards; anything that didn't stick is
    /// retried with `/usr/bin/hidutil`. Returns false if the remap still isn't
    /// in place (or, when restoring, still present) afterwards.
    @discardableResult
    static func setSuppressed(_ suppressed: Bool, vendorID: Int, productID: Int) -> Bool {
        let services = keyboardServices(vendorID: vendorID, productID: productID)
        guard !services.isEmpty else {
            NSLog("CMStorm Lights: no HID services for %04X:%04X; trying hidutil", vendorID, productID)
            return setWithHidutil(suppressed ? [ourEntry] : [], vendorID: vendorID, productID: productID)
        }

        var needsHidutil = false
        var hidutilMapping: [[String: Any]] = []
        for service in services {
            let existing = mapping(of: service)
            guard hasOurEntry(existing) != suppressed else { continue } // Already as wanted.

            let updated = updatedMapping(existing, suppressed: suppressed)
            let accepted = IOHIDServiceClientSetProperty(service, mappingKey as CFString, updated as CFArray)
            let stuck = hasOurEntry(mapping(of: service)) == suppressed
            NSLog("CMStorm Lights: %@ remap on %04X:%04X service: accepted=%d verified=%d",
                  suppressed ? "apply" : "remove", vendorID, productID, accepted ? 1 : 0, stuck ? 1 : 0)
            if !stuck {
                needsHidutil = true
                hidutilMapping = updated
            }
        }

        guard needsHidutil else { return true }
        _ = setWithHidutil(hidutilMapping, vendorID: vendorID, productID: productID)
        let ok = keyboardServices(vendorID: vendorID, productID: productID)
            .allSatisfy { hasOurEntry(mapping(of: $0)) == suppressed }
        NSLog("CMStorm Lights: hidutil fallback for %04X:%04X verified=%d", vendorID, productID, ok ? 1 : 0)
        return ok
    }

    /// Human-readable state of every HID service belonging to the keyboard.
    static func diagnostics(vendorID: Int, productID: Int) -> [String] {
        let services = keyboardServices(vendorID: vendorID, productID: productID)
        guard !services.isEmpty else { return ["no HID event-system services found"] }
        return services.map { service in
            let page = intProperty(service, kIOHIDPrimaryUsagePageKey) ?? -1
            let usage = intProperty(service, kIOHIDPrimaryUsageKey) ?? -1
            let entries = mapping(of: service).map { entry -> String in
                let source = (entry[sourceKey] as? NSNumber)?.uint64Value ?? 0
                let destination = (entry[destinationKey] as? NSNumber)?.uint64Value ?? 0
                return String(format: "0x%llX→0x%llX", source, destination)
            }
            return String(format: "service usage %d:%d, UserKeyMapping [%@]",
                          page, usage, entries.joined(separator: ", "))
        }
    }

    private static var ourEntry: [String: Any] {
        [sourceKey: NSNumber(value: scrollLock), destinationKey: NSNumber(value: f20)]
    }

    private static func mapping(of service: IOHIDServiceClient) -> [[String: Any]] {
        IOHIDServiceClientCopyProperty(service, mappingKey as CFString) as? [[String: Any]] ?? []
    }

    private static func hasOurEntry(_ mapping: [[String: Any]]) -> Bool {
        mapping.contains { entry in
            (entry[sourceKey] as? NSNumber)?.uint64Value == scrollLock
                && (entry[destinationKey] as? NSNumber)?.uint64Value == f20
        }
    }

    private static func updatedMapping(_ existing: [[String: Any]], suppressed: Bool) -> [[String: Any]] {
        // When suppressing, replace any Scroll Lock mapping; when restoring,
        // only remove the one we added.
        var mapping = existing.filter { entry in
            let source = (entry[sourceKey] as? NSNumber)?.uint64Value
            let destination = (entry[destinationKey] as? NSNumber)?.uint64Value
            return suppressed ? source != scrollLock : !(source == scrollLock && destination == f20)
        }
        if suppressed { mapping.append(ourEntry) }
        return mapping
    }

    /// Every event-system service of the keyboard. CM Storm boards expose
    /// several HID interfaces, so don't filter on usage: a mapping on an
    /// interface that never sends Scroll Lock is harmless.
    private static func keyboardServices(vendorID: Int, productID: Int) -> [IOHIDServiceClient] {
        let client: IOHIDEventSystemClient? = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let client, let array = IOHIDEventSystemClientCopyServices(client) else { return [] }

        var result: [IOHIDServiceClient] = []
        for index in 0..<CFArrayGetCount(array) {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: IOHIDServiceClient.self)
            guard intProperty(service, kIOHIDVendorIDKey) == vendorID,
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
