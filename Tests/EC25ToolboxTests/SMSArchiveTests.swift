import Foundation
import XCTest
@testable import EC25Toolbox

final class SMSArchiveTests: XCTestCase {
    func testRenameCopiesLegacyDataWithoutDeletingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("EC25 Manager", isDirectory: true)
        let legacyFile = legacy.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyFile)

        let migrated = AppIdentity.applicationSupportDirectory(base: root)
        XCTAssertEqual(migrated.lastPathComponent, "EC25 Toolbox")
        XCTAssertEqual(try Data(contentsOf: migrated.appendingPathComponent("settings.json")), Data("legacy".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(AppIdentity.bundleIdentifier, "ing.fuyaoskyrocket.ec25toolbox")
    }

    func testScopeSeparatesProfilesOnSameEID() {
        let first = SIMMessageScope(eid: "89049032000000000000000000000001", iccid: "8986000000000000001")
        let second = SIMMessageScope(eid: "89049032000000000000000000000001", iccid: "8986000000000000002")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.isIdentified)
    }

    @MainActor
    func testArchivePartitionAndICloudMergeRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let local = root.appendingPathComponent("local", isDirectory: true)
        let restoredLocal = root.appendingPathComponent("restored", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstScope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-1")
        let secondScope = SIMMessageScope(eid: "EID-1", iccid: "ICCID-2")
        let firstMessage = SMSMessage(
            id: "ME-1", storage: "ME", index: 1, status: "REC READ", outgoing: false,
            unread: false, sender: "+86100", date: "26/07/15,10:00:00+32", body: "first"
        )
        let secondMessage = SMSMessage(
            id: "ME-1", storage: "ME", index: 1, status: "REC READ", outgoing: false,
            unread: false, sender: "+86200", date: "26/07/15,10:00:00+32", body: "second"
        )

        let archive = SMSArchiveStore(
            applicationSupportDirectory: local,
            iCloudDriveRoot: cloud
        )
        XCTAssertEqual(try archive.synchronize(liveMessages: [firstMessage], legacySent: [], scope: firstScope).count, 1)
        XCTAssertEqual(try archive.synchronize(liveMessages: [secondMessage], legacySent: [], scope: secondScope).count, 1)
        XCTAssertEqual(archive.messages(in: firstScope.id).map(\.body), ["first"])
        XCTAssertEqual(archive.messages(in: secondScope.id).map(\.body), ["second"])
        try archive.backupNow()

        let restored = SMSArchiveStore(
            applicationSupportDirectory: restoredLocal,
            iCloudDriveRoot: cloud
        )
        try restored.restoreLatestBackup()
        XCTAssertEqual(restored.messages(in: firstScope.id).map(\.body), ["first"])
        XCTAssertEqual(restored.messages(in: secondScope.id).map(\.body), ["second"])
    }

    @MainActor
    func testICloudMergePropagatesDeletionWithoutResurrection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstLocal = root.appendingPathComponent("first", isDirectory: true)
        let secondLocal = root.appendingPathComponent("second", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scope = SIMMessageScope(eid: "EID-SYNC", iccid: "ICCID-SYNC")
        let message = SMSMessage(
            id: "SM-9", storage: "SM", index: 9, status: "REC READ", outgoing: false,
            unread: false, sender: "+86101", date: "26/07/15,11:00:00+32", body: "sync"
        )
        let first = SMSArchiveStore(applicationSupportDirectory: firstLocal, iCloudDriveRoot: cloud)
        let second = SMSArchiveStore(applicationSupportDirectory: secondLocal, iCloudDriveRoot: cloud)

        let firstMessages = try first.synchronize(liveMessages: [message], legacySent: [], scope: scope)
        XCTAssertEqual(firstMessages.count, 1)
        XCTAssertEqual(try second.synchronize(liveMessages: [message], legacySent: [], scope: scope).count, 1)

        try first.delete(messageID: firstMessages[0].id)
        XCTAssertTrue(try second.synchronize(liveMessages: [], legacySent: [], scope: scope).isEmpty)
        XCTAssertTrue(second.messages(in: scope.id).isEmpty)
    }
}
