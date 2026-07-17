import Foundation

/// Stable product identity and compatibility locations used during the rename.
enum AppIdentity {
    static let applicationSupportName = "EC25 Toolbox"
    static let legacyApplicationSupportNames = ["EC25 Manager"]
    static let bundleIdentifier = "ing.fuyaoskyrocket.ec25toolbox"
    static let legacyBundleIdentifiers = ["one.nickspace.ec25-manager.swiftui"]

    static func applicationSupportDirectory(
        base: URL,
        fileManager: FileManager = .default
    ) -> URL {
        migratedDirectory(
            base: base,
            currentName: applicationSupportName,
            legacyNames: legacyApplicationSupportNames,
            fileManager: fileManager
        )
    }

    static func iCloudContainerDirectory(
        base: URL,
        fileManager: FileManager = .default
    ) -> URL {
        migratedDirectory(
            base: base,
            currentName: applicationSupportName,
            legacyNames: legacyApplicationSupportNames,
            fileManager: fileManager
        )
    }

    private static func migratedDirectory(
        base: URL,
        currentName: String,
        legacyNames: [String],
        fileManager: FileManager
    ) -> URL {
        let destination = base.appendingPathComponent(currentName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return destination }

        for legacyName in legacyNames {
            let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            try? fileManager.copyItem(at: legacy, to: destination)
            break
        }
        return destination
    }
}
