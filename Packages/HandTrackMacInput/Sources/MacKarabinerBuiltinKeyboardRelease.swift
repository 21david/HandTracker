#if os(macOS)
import Foundation

/// Karabiner seizes keyboards with ExclusiveAccess, which strips CGEvent device source and
/// blocks IOHIDDeviceOpen. HandTrack needs the MacBook board unseized so IOHID can attribute
/// built-in keys; the external board can stay under Karabiner.
enum MacKarabinerBuiltinKeyboardRelease {
    private static let appleVendorID = 1452
    private static let appleInternalKeyboardProductID = 832
    private static let appliedDefaultsKey = "HandTrack.karabinerReleasedBuiltinKeyboard"

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/karabiner/karabiner.json")
    }

    /// Ensures the selected Karabiner profile ignores Apple Internal Keyboard (keyboard interface).
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
            if let existing = devices.firstIndex(where: isAppleInternalKeyboardEntry) {
                if devices[existing]["ignore"] as? Bool != true {
                    devices[existing]["ignore"] = true
                    changed = true
                }
            } else {
                devices.append([
                    "identifiers": [
                        "is_keyboard": true,
                        "vendor_id": appleVendorID,
                        "product_id": appleInternalKeyboardProductID,
                    ] as [String: Any],
                    "ignore": true,
                ])
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

    private static func isAppleInternalKeyboardEntry(_ entry: [String: Any]) -> Bool {
        guard let ids = entry["identifiers"] as? [String: Any] else { return false }
        let vendor = ids["vendor_id"] as? Int ?? (ids["vendor_id"] as? NSNumber)?.intValue
        let product = ids["product_id"] as? Int ?? (ids["product_id"] as? NSNumber)?.intValue
        let isKeyboard = ids["is_keyboard"] as? Bool ?? (ids["is_keyboard"] as? NSNumber)?.boolValue
        return vendor == appleVendorID
            && product == appleInternalKeyboardProductID
            && isKeyboard == true
    }
}
#endif
