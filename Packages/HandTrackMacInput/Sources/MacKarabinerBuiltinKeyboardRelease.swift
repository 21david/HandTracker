#if os(macOS)
import Foundation

/// Karabiner seizes keyboards with ExclusiveAccess, which strips CGEvent device source and
/// blocks IOHIDDeviceOpen. HandTrack needs the MacBook board unseized so IOHID can attribute
/// built-in keys. The Keychron (Apple VID/PID in Mac mode) is also ignored so its HID claims
/// work; the Kinesis board stays under Karabiner for remaps.
enum MacKarabinerBuiltinKeyboardRelease {
    private static let appleVendorID = 1452
    private static let appleInternalKeyboardProductID = 832
    private static let keychronK8ProductID = 591
    private static let appliedDefaultsKey = "HandTrack.karabinerReleasedBuiltinKeyboard"

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/karabiner/karabiner.json")
    }

    /// Ensures the selected Karabiner profile ignores Apple Internal Keyboard and Keychron K8.
    /// Returns true when the file was modified.
    @discardableResult
    static func ensureBuiltinKeyboardIgnored() -> Bool {
        let url = configURL
        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var profiles = root["profiles"] as? [[String: Any]]
        else { return false }

        var changed = false
        for index in profiles.indices {
            guard profiles[index]["selected"] as? Bool == true else { continue }
            var devices = profiles[index]["devices"] as? [[String: Any]] ?? []
            if upsertIgnoreEntry(
                in: &devices,
                matching: isAppleInternalKeyboardEntry,
                identifiers: [
                    "is_keyboard": true,
                    "vendor_id": appleVendorID,
                    "product_id": appleInternalKeyboardProductID,
                ]
            ) {
                changed = true
            }
            // is_virtual_device=false so we do not ignore Karabiner's virtual HID
            // which reuses Keychron's Apple VID/PID 1452/591.
            if upsertIgnoreEntry(
                in: &devices,
                matching: isKeychronK8Entry,
                identifiers: [
                    "is_keyboard": true,
                    "is_virtual_device": false,
                    "vendor_id": appleVendorID,
                    "product_id": keychronK8ProductID,
                ]
            ) {
                changed = true
            }
            if changed {
                profiles[index]["devices"] = devices
            }
            break
        }

        guard changed else {
            UserDefaults.standard.set(true, forKey: appliedDefaultsKey)
            return false
        }

        root["profiles"] = profiles
        guard JSONSerialization.isValidJSONObject(root),
              let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return false }

        // Atomic replace so Karabiner’s file watcher reloads cleanly.
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent("karabiner.json.handtrack-tmp")
        do {
            try out.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            UserDefaults.standard.set(true, forKey: appliedDefaultsKey)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    @discardableResult
    private static func upsertIgnoreEntry(
        in devices: inout [[String: Any]],
        matching: ([String: Any]) -> Bool,
        identifiers: [String: Any]
    ) -> Bool {
        if let existing = devices.firstIndex(where: matching) {
            if devices[existing]["ignore"] as? Bool != true {
                devices[existing]["ignore"] = true
                return true
            }
            return false
        }
        devices.append([
            "identifiers": identifiers,
            "ignore": true,
        ])
        return true
    }

    private static func isAppleInternalKeyboardEntry(_ entry: [String: Any]) -> Bool {
        guard let ids = entry["identifiers"] as? [String: Any] else { return false }
        return intValue(ids["vendor_id"]) == appleVendorID
            && intValue(ids["product_id"]) == appleInternalKeyboardProductID
            && boolValue(ids["is_keyboard"]) == true
    }

    private static func isKeychronK8Entry(_ entry: [String: Any]) -> Bool {
        guard let ids = entry["identifiers"] as? [String: Any] else { return false }
        return intValue(ids["vendor_id"]) == appleVendorID
            && intValue(ids["product_id"]) == keychronK8ProductID
            && boolValue(ids["is_keyboard"]) == true
            && boolValue(ids["is_virtual_device"]) == false
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        return (raw as? NSNumber)?.intValue
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        return (raw as? NSNumber)?.boolValue
    }
}
#endif
