import CryptoKit
import Foundation

/// Identity boundary used to keep SMS history separated across eSTK profiles.
struct SIMMessageScope: Codable, Equatable {
    var id: String
    var eid: String?
    var iccid: String?

    init(eid: String?, iccid: String?) {
        let cleanEID = Self.normalizedIdentifier(eid)
        let cleanICCID = Self.normalizedIdentifier(iccid)
        self.eid = cleanEID
        self.iccid = cleanICCID
        let identity = [cleanEID ?? "NO-EID", cleanICCID ?? "NO-ICCID"].joined(separator: "|")
        id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isIdentified: Bool { iccid != nil }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = trimmed(value).uppercased()
        guard !clean.isEmpty, clean != "-", clean != "UNKNOWN" else { return nil }
        return clean
    }
}

struct SMSBackupState: Equatable {
    var localArchivePath = ""
    var iCloudBackupPath: String?
    var currentScopeID: String?
    var lastBackupAt: Date?
    var lastRestoreAt: Date?
    var lastError: String?
}

private struct SMSArchiveRecord: Codable, Equatable {
    var id: String
    var scopeID: String
    var eid: String?
    var iccid: String?
    var storage: String
    var modemIndex: Int
    var status: String
    var outgoing: Bool
    var unread: Bool
    var peer: String
    var serviceDate: String
    var body: String
    var firstSeenAt: Date
    var updatedAt: Date
    var presentOnModem: Bool
    var deletedAt: Date?

    var message: SMSMessage {
        SMSMessage(
            id: id, storage: storage, index: modemIndex, status: status,
            outgoing: outgoing, unread: unread, sender: peer, date: serviceDate, body: body,
            scopeID: scopeID, presentOnModem: presentOnModem
        )
    }
}

private struct SMSArchiveDocument: Codable, Equatable {
    var schemaVersion = 1
    var records: [SMSArchiveRecord] = []
}

private struct SMSBackupManifest: Codable {
    var schemaVersion = 1
    var updatedAt: Date
    var latestFile = "latest.json"
    var snapshots: [String]
    var lastSnapshotAt: Date?
}

/// Durable local SMS archive with an optional rolling iCloud Drive backup.
@MainActor
final class SMSArchiveStore {
    private let fileManager: FileManager
    private let localDirectory: URL
    private let localURL: URL
    private let iCloudBackupDirectory: URL?
    private var document: SMSArchiveDocument
    private(set) var state: SMSBackupState

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        iCloudDriveRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        let applicationSupport = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        localDirectory = AppIdentity.applicationSupportDirectory(
            base: applicationSupport,
            fileManager: fileManager
        )
            .appendingPathComponent("Messages", isDirectory: true)
        localURL = localDirectory.appendingPathComponent("messages-v1.json")

        let cloudDocuments = iCloudDriveRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fileManager.fileExists(atPath: cloudDocuments.path) {
            iCloudBackupDirectory = AppIdentity.iCloudContainerDirectory(
                base: cloudDocuments,
                fileManager: fileManager
            )
                .appendingPathComponent("Backups", isDirectory: true)
        } else {
            iCloudBackupDirectory = nil
        }

        if let data = try? Data(contentsOf: localURL),
           let decoded = try? Self.decoder.decode(SMSArchiveDocument.self, from: data),
           decoded.schemaVersion == 1 {
            document = decoded
        } else {
            document = SMSArchiveDocument()
        }
        var initialState = SMSBackupState(
            localArchivePath: localURL.path,
            iCloudBackupPath: iCloudBackupDirectory?.path
        )
        if let directory = iCloudBackupDirectory,
           let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let manifest = try? Self.decoder.decode(SMSBackupManifest.self, from: data) {
            initialState.lastBackupAt = manifest.updatedAt
        }
        state = initialState
    }

    func synchronize(liveMessages: [SMSMessage], legacySent: [SentMessage], scope: SIMMessageScope) throws -> [SMSMessage] {
        state.currentScopeID = scope.id
        let now = Date()
        var changed = false
        if iCloudBackupDirectory != nil {
            do {
                changed = try mergeLatestCloudBackup() || changed
                state.lastError = nil
            } catch {
                state.lastError = error.localizedDescription
            }
        }
        changed = migrateRecordsToKnownEID(scope) || changed
        let liveIDs = Set(liveMessages.map { stableID(for: $0, scopeID: scope.id) })

        for index in document.records.indices where document.records[index].scopeID == scope.id {
            let record = document.records[index]
            guard record.deletedAt == nil else { continue }
            guard record.storage == "ME" || record.storage == "SM" else { continue }
            let shouldBePresent = liveIDs.contains(record.id)
            if record.presentOnModem != shouldBePresent {
                document.records[index].presentOnModem = shouldBePresent
                document.records[index].updatedAt = now
                changed = true
            }
        }

        for message in liveMessages {
            let id = stableID(for: message, scopeID: scope.id)
            let replacement = SMSArchiveRecord(
                id: id, scopeID: scope.id, eid: scope.eid, iccid: scope.iccid,
                storage: message.storage, modemIndex: message.index, status: message.status,
                outgoing: message.outgoing, unread: message.unread, peer: message.sender,
                serviceDate: message.date, body: message.body, firstSeenAt: now, updatedAt: now,
                presentOnModem: true, deletedAt: nil
            )
            changed = upsert(replacement) || changed
        }

        for sent in legacySent {
            let message = SMSMessage(
                id: "legacy-sent-\(sent.ts)", storage: "SENT", index: Int(sent.ts), status: "STO SENT",
                outgoing: true, unread: false, sender: sent.to, date: sent.date, body: sent.body
            )
            let record = SMSArchiveRecord(
                id: stableID(for: message, scopeID: scope.id, nonce: String(sent.ts)),
                scopeID: scope.id, eid: scope.eid, iccid: scope.iccid,
                storage: "SENT", modemIndex: Int(sent.ts), status: message.status,
                outgoing: true, unread: false, peer: sent.to, serviceDate: sent.date, body: sent.body,
                firstSeenAt: now, updatedAt: now, presentOnModem: false, deletedAt: nil
            )
            changed = upsert(record) || changed
        }

        if changed { try persistAndBackup() }
        return messages(in: scope.id)
    }

    func addSent(to number: String, body: String, serviceDate: String, scope: SIMMessageScope) throws {
        let now = Date()
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let message = SMSMessage(
            id: "sent-\(timestamp)", storage: "SENT", index: Int(timestamp), status: "STO SENT",
            outgoing: true, unread: false, sender: number, date: serviceDate, body: body
        )
        let record = SMSArchiveRecord(
            id: stableID(for: message, scopeID: scope.id, nonce: String(timestamp)),
            scopeID: scope.id, eid: scope.eid, iccid: scope.iccid,
            storage: "SENT", modemIndex: Int(timestamp), status: message.status,
            outgoing: true, unread: false, peer: number, serviceDate: serviceDate, body: body,
            firstSeenAt: now, updatedAt: now, presentOnModem: false, deletedAt: nil
        )
        if upsert(record) { try persistAndBackup() }
    }

    func addReceived(
        from sender: String,
        body: String,
        serviceDate: String,
        scope: SIMMessageScope
    ) throws {
        let now = Date()
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let message = SMSMessage(
            id: "vowifi-\(timestamp)", storage: "VOWIFI", index: Int(timestamp),
            status: "REC UNREAD", outgoing: false, unread: true,
            sender: sender, date: serviceDate, body: body,
            scopeID: scope.id, presentOnModem: false
        )
        let record = SMSArchiveRecord(
            id: stableID(for: message, scopeID: scope.id, nonce: String(timestamp)),
            scopeID: scope.id, eid: scope.eid, iccid: scope.iccid,
            storage: "VOWIFI", modemIndex: Int(timestamp), status: message.status,
            outgoing: false, unread: true, peer: sender, serviceDate: serviceDate,
            body: body, firstSeenAt: now, updatedAt: now,
            presentOnModem: false, deletedAt: nil
        )
        if upsert(record) { try persistAndBackup() }
    }

    func delete(messageID: String) throws {
        guard let index = document.records.firstIndex(where: { $0.id == messageID }),
              document.records[index].deletedAt == nil else { return }
        let now = Date()
        document.records[index].deletedAt = now
        document.records[index].updatedAt = now
        document.records[index].presentOnModem = false
        try persistAndBackup()
    }

    func markRead(messageIDs: Set<String>) throws {
        var changed = false
        for index in document.records.indices
            where document.records[index].deletedAt == nil
                && messageIDs.contains(document.records[index].id)
                && document.records[index].unread {
            document.records[index].unread = false
            document.records[index].status = "REC READ"
            document.records[index].updatedAt = Date()
            changed = true
        }
        if changed { try persistAndBackup() }
    }

    func messages(in scopeID: String) -> [SMSMessage] {
        document.records.filter { $0.scopeID == scopeID && $0.deletedAt == nil }.map(\.message).sorted {
            if $0.date == $1.date { return $0.id > $1.id }
            return $0.date > $1.date
        }
    }

    func backupNow() throws {
        if iCloudBackupDirectory == nil {
            try persistLocal()
            throw SMSArchiveError.iCloudDriveUnavailable
        }
        try backupToICloud(forceSnapshot: true)
    }

    func restoreLatestBackup() throws {
        guard let directory = iCloudBackupDirectory else { throw SMSArchiveError.iCloudDriveUnavailable }
        let data = try Data(contentsOf: directory.appendingPathComponent("latest.json"))
        let backup = try Self.decoder.decode(SMSArchiveDocument.self, from: data)
        guard backup.schemaVersion == document.schemaVersion else { throw SMSArchiveError.unsupportedBackup }

        _ = merge(backup)
        try persistLocal()
        state.lastRestoreAt = Date()
        state.lastError = nil
    }

    private func stableID(for message: SMSMessage, scopeID: String, nonce: String = "") -> String {
        let identity = [scopeID, message.outgoing ? "out" : "in", message.sender, message.date, message.body, nonce]
            .joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func upsert(_ replacement: SMSArchiveRecord) -> Bool {
        guard let index = document.records.firstIndex(where: { $0.id == replacement.id }) else {
            document.records.append(replacement)
            return true
        }
        var updated = replacement
        updated.firstSeenAt = document.records[index].firstSeenAt
        updated.updatedAt = document.records[index].updatedAt
        if updated == document.records[index] { return false }
        updated.updatedAt = Date()
        document.records[index] = updated
        return true
    }

    private func migrateRecordsToKnownEID(_ scope: SIMMessageScope) -> Bool {
        guard let eid = scope.eid, let iccid = scope.iccid else { return false }
        var changed = false
        for index in document.records.indices
            where document.records[index].eid == nil && document.records[index].iccid == iccid {
            var record = document.records[index]
            record.eid = eid
            record.scopeID = scope.id
            if record.storage != "SENT" {
                record.id = stableID(for: record.message, scopeID: scope.id)
            }
            record.updatedAt = Date()
            document.records[index] = record
            changed = true
        }
        if changed {
            var newestByID: [String: SMSArchiveRecord] = [:]
            for record in document.records {
                if let existing = newestByID[record.id], existing.updatedAt >= record.updatedAt { continue }
                newestByID[record.id] = record
            }
            document.records = Array(newestByID.values)
        }
        return changed
    }

    private func persistAndBackup() throws {
        guard iCloudBackupDirectory != nil else {
            try persistLocal()
            state.lastError = nil
            return
        }
        do {
            try backupToICloud(forceSnapshot: false)
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    private func persistLocal() throws {
        try fileManager.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(document).write(to: localURL, options: .atomic)
    }

    private func backupToICloud(forceSnapshot: Bool) throws {
        guard let directory = iCloudBackupDirectory else { throw SMSArchiveError.iCloudDriveUnavailable }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let latestURL = directory.appendingPathComponent("latest.json")
        var coordinationError: NSError?
        var operationError: Error?
        var data = Data()
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: latestURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                if let cloudData = try? Data(contentsOf: coordinatedURL),
                   let cloudDocument = try? Self.decoder.decode(SMSArchiveDocument.self, from: cloudData),
                   cloudDocument.schemaVersion == document.schemaVersion {
                    _ = merge(cloudDocument)
                }
                data = try Self.encoder.encode(document)
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        try persistLocal()

        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? Self.decoder.decode(SMSBackupManifest.self, from: $0) }
            ?? SMSBackupManifest(updatedAt: .distantPast, snapshots: [], lastSnapshotAt: nil)
        let needsSnapshot = forceSnapshot
            || manifest.lastSnapshotAt.map { Date().timeIntervalSince($0) >= 86_400 } != false
        if needsSnapshot {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "messages-\(formatter.string(from: Date())).json"
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            manifest.snapshots.append(name)
            manifest.lastSnapshotAt = Date()
            while manifest.snapshots.count > 30 {
                let removed = manifest.snapshots.removeFirst()
                try? fileManager.removeItem(at: directory.appendingPathComponent(removed))
            }
        }
        manifest.updatedAt = Date()
        try Self.encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        state.lastBackupAt = manifest.updatedAt
    }

    private func mergeLatestCloudBackup() throws -> Bool {
        guard let directory = iCloudBackupDirectory else { return false }
        let latestURL = directory.appendingPathComponent("latest.json")
        guard fileManager.fileExists(atPath: latestURL.path) else { return false }

        var coordinationError: NSError?
        var operationError: Error?
        var changed = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: latestURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let cloudData = try Data(contentsOf: coordinatedURL)
                let cloudDocument = try Self.decoder.decode(SMSArchiveDocument.self, from: cloudData)
                guard cloudDocument.schemaVersion == document.schemaVersion else {
                    throw SMSArchiveError.unsupportedBackup
                }
                changed = merge(cloudDocument)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        return changed
    }

    private func merge(_ incoming: SMSArchiveDocument) -> Bool {
        var changed = false
        for record in incoming.records {
            if let index = document.records.firstIndex(where: { $0.id == record.id }) {
                let current = document.records[index]
                let incomingWins = record.updatedAt > current.updatedAt
                    || (record.updatedAt == current.updatedAt && record.deletedAt != nil && current.deletedAt == nil)
                if incomingWins {
                    document.records[index] = record
                    changed = true
                }
            } else {
                document.records.append(record)
                changed = true
            }
        }
        return changed
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum SMSArchiveError: LocalizedError {
    case iCloudDriveUnavailable
    case unsupportedBackup

    var errorDescription: String? {
        switch self {
        case .iCloudDriveUnavailable: localized("sms.backup.error.icloud_unavailable")
        case .unsupportedBackup: localized("sms.backup.error.unsupported")
        }
    }
}
