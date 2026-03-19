// macos/Engram/Views/Settings/SettingsIO.swift
import Foundation

let engramSettingsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".engram/settings.json")

func readEngramSettings() -> [String: Any]? {
    guard let data = try? Data(contentsOf: engramSettingsPath),
          let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return settings
}

func mutateEngramSettings(_ transform: (inout [String: Any]) -> Void) {
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: engramSettingsPath),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        settings = existing
    }
    transform(&settings)
    if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: engramSettingsPath)
    }
}
