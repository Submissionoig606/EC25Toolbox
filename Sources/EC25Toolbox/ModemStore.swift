import AppKit
import Darwin
import Foundation
import ServiceManagement

/// Main-actor application store that coordinates modem transport, polling,
/// persistence, and all user-triggered modem actions.
@MainActor
final class ModemStore: ObservableObject {
    /// Live UI state rendered by the SwiftUI panel.
    @Published var state = ModemState()
    /// Persisted user settings.
    @Published var settings = ModemSettings.defaults

    let localTransport: EC25Transport
    var transport: any ModemTransport
    var remoteServer: RemoteManagementServer?
    let smsArchive = SMSArchiveStore()
    private var started = false
    private var infoPollTask: Task<Void, Never>?
    private var smsPollTask: Task<Void, Never>?
    private var recoverTask: Task<Void, Never>?
    private var operationTail: Task<Void, Never>?
    private var foregroundOperationQueued = false
    private var refreshOperationQueued = false
    /// Prevents repeated automatic PIN attempts against the same locked SIM session.
    var simAutoUnlockAttemptedICCID: String?
    /// Prevents every status poll from repeating the same PIN-required user notification.
    var simPINNoticeFingerprint: String?
    /// Modem APDU backend and open logical channels for the current connection.
    var estkAPDUBackend: ESTKAPDUBackend?
    var estkLogicalChannels: [UInt8: UInt8] = [:]
    var estkDetectionICCID: String?
    var vowifiTask: Task<Void, Never>?
    var vowifiDataPlane: VoWiFiDataPlane?
    var vowifiIMSClient: IMSClient?
    var vowifiSessionICCID: String?

    private var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return AppIdentity.applicationSupportDirectory(base: base)
    }

    private var sentLogURL: URL {
        appSupportDirectory.appendingPathComponent("sent.json")
    }

    init() {
        let localTransport = EC25Transport()
        self.localTransport = localTransport
        self.transport = localTransport
        settings = loadSettings()
        setAppLocale(settings.preferredLanguage ?? "")
        state.sentMessages = loadSentLog()
        state.smsBackup = smsArchive.state
        configureTransportFromSettings()
        observeWakeNotifications()
    }

    deinit {
        infoPollTask?.cancel()
        smsPollTask?.cancel()
        recoverTask?.cancel()
        operationTail?.cancel()
        vowifiTask?.cancel()
        remoteServer?.stop()
    }

    /// SF Symbol name used for menu-bar fallback labels and accessibility.
    var menuBarSystemImage: String {
        if !state.connected { return "antenna.radiowaves.left.and.right.slash" }
        switch state.info.signal.bars {
        case 1...4: return "cellularbars"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Spoken menu-bar status including connectivity and signal strength.
    var menuBarAccessibilityLabel: String {
        guard state.connected else { return localized("accessibility.app_offline") }
        let bars = min(max(state.info.signal.bars, 0), 4)
        let signalText = state.info.signal.text == "-" ? "" : localizedFormat("format.comma_value", localized(state.info.signal.text))
        return localizedFormat("accessibility.app_signal", bars, signalText)
    }

    /// Compact status text shown in the panel header.
    var statusText: String {
        let working = state.busy || state.refreshing
        return state.connected ? (working ? "status.working" : "status.online") : (working ? "status.connecting" : "status.offline")
    }

    /// Starts login-item synchronization, polling, and the initial modem connection.
    func start() {
        guard !started else { return }
        started = true
        applyLoginItemSetting()
        startRemoteSharingIfNeeded()
        restartPollers()
        connect()
    }

    /// Opens the USB AT transport and initializes modem state.
    func connect() {
        run {
            try await self.connectImpl(prefix: localized("log.connected"))
        }
    }

    /// Reopens the USB AT transport after a manual reconnect request.
    func reconnect() {
        run {
            try await self.connectImpl(prefix: localized("log.reconnected"))
        }
    }

    /// Refreshes both modem information and SMS messages.
    func refreshAll() {
        runRefresh {
            try await self.refreshInfoImpl()
            if self.state.simSecurity.isReady {
                try await self.refreshMessagesImpl()
            } else {
                self.clearMessagesForLockedSIM()
            }
            self.state.lastUpdated = Date()
        }
    }

    /// Refreshes SMS storage while preserving the current status snapshot.
    func refreshMessages() {
        runRefresh {
            guard self.state.simSecurity.isReady else {
                self.clearMessagesForLockedSIM()
                throw SIMPINError.simNotReady
            }
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Performs a lightweight connectivity probe and refreshes modem information.
    func refreshInfoOnly() {
        runRefresh {
            do {
                _ = try await self.send("AT", timeout: 2_500)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await self.markDisconnected()
                return
            }
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Sends a text message through the modem and persists a local sent copy.
    ///
    /// - Parameters:
    ///   - number: Destination number as entered by the user.
    ///   - body: Message body encoded to UCS-2 before transmission.
    func sendSMS(to number: String, body: String) {
        let cleanNumber = trimmed(number)
        let cleanBody = trimmed(body)
        guard !cleanNumber.isEmpty, !cleanBody.isEmpty else {
            state.lastError = localized("error.sms_empty")
            return
        }
        guard state.simSecurity.isReady else {
            state.lastError = localized("sim_pin.error.sim_not_ready")
            return
        }

        run {
            _ = try await self.send("AT+CMGF=1")
            _ = try await self.send("AT+CSCS=\"UCS2\"")
            let encodedNumber = UCS2.encode(cleanNumber)
            let encodedBody = UCS2.encode(cleanBody)
            _ = try await self.send("AT+CMGS=\"\(encodedNumber)\"", payload: encodedBody + String(UnicodeScalar(0x1A)!), timeout: 25_000)

            let scope = self.currentSIMMessageScope()
            try self.smsArchive.addSent(to: cleanNumber, body: cleanBody, serviceDate: modemDateNow(), scope: scope)
            self.state.smsBackup = self.smsArchive.state
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Deletes a modem-stored SMS or removes a locally persisted sent message.
    func deleteSMS(_ message: SMSMessage) {
        run {
            if message.storage == "SENT" || !message.presentOnModem {
                try self.smsArchive.delete(messageID: message.id)
                self.state.smsBackup = self.smsArchive.state
                try await self.refreshMessagesImpl()
                return
            }

            _ = try await self.send("AT+CMGF=1")
            _ = try? await self.send("AT+CPMS=\"\(message.storage)\",\"\(message.storage)\",\"\(message.storage)\"")
            _ = try await self.send("AT+CMGD=\(message.index)")
            try self.smsArchive.delete(messageID: message.id)
            self.state.smsBackup = self.smsArchive.state
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Marks every unread modem-stored message as read.
    func markAllRead() {
        run {
            try await self.markRead(self.state.messages)
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Marks unread messages from one sender as read.
    ///
    /// - Parameter sender: Conversation sender label displayed by the UI.
    func markConversationRead(sender: String) {
        run {
            let messages = self.state.messages.filter { ($0.sender.isEmpty ? localized("common.unknown") : $0.sender) == sender }
            guard messages.contains(where: \.unread) else { return }
            try await self.markRead(messages)
            try await self.refreshMessagesImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Executes an arbitrary AT command from the terminal page.
    func runTerminalCommand(_ command: String) {
        let clean = trimmed(command)
        guard !clean.isEmpty else { return }

        run {
            self.appendTerminal("> \(clean)")
            do {
                let lines = try await self.executeTerminalCommand(clean, timeout: 15_000)
                if lines.isEmpty {
                    self.appendTerminal("OK")
                } else {
                    lines.forEach { self.appendTerminal($0) }
                    self.appendTerminal("OK")
                }
            } catch {
                self.appendTerminal("ERROR: \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// Sends a terminal command after ensuring that the selected transport is
    /// connected. A stale UI connection state is recovered once when the
    /// transport reports that its underlying session is no longer open.
    func executeTerminalCommand(_ command: String, timeout: Int32 = 15_000) async throws -> [String] {
        if !state.connected {
            try await connectImpl(prefix: localized("log.reconnected"))
        }

        do {
            return try await send(command, timeout: timeout)
        } catch EC25TransportError.notOpen {
            try await connectImpl(prefix: localized("log.reconnected"))
            return try await send(command, timeout: timeout)
        }
    }

    /// Updates the modem USB networking mode.
    ///
    /// - Parameter mode: Quectel `usbnet` mode integer, such as ECM or RNDIS.
    func setUSBMode(_ mode: Int) {
        run {
            _ = try await self.send("AT+QCFG=\"usbnet\",\(mode)", timeout: 8_000)
            _ = try await self.send("AT+QCFG=\"usbnet\"", timeout: 6_000)
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Writes the primary PDP context APN.
    func setAPN(_ apn: String) {
        let clean = trimmed(apn)
        guard !clean.isEmpty else {
            state.lastError = localized("error.apn_empty")
            return
        }

        run {
            _ = try await self.send("AT+CGDCONT=1,\"IPV4V6\",\"\(clean)\"", timeout: 8_000)
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Stores the device's own number in the SIM/phonebook entry when supported.
    func setOwnNumber(_ number: String) {
        let clean = sanitizedDialNumber(number)
        guard !clean.isEmpty else {
            state.lastError = localized("error.own_number_empty")
            return
        }

        run {
            let type = clean.hasPrefix("+") ? 145 : 129
            do {
                _ = try await self.send("AT+CSCS=\"IRA\"", timeout: 5_000)
                _ = try await self.send("AT+CPBS=\"ON\"", timeout: 5_000)
                let rangeLines = try await self.send("AT+CPBR=?", timeout: 5_000)
                let index = parsePhonebookIndexRange(rangeLines)?.lowerBound ?? 1
                _ = try await self.send(
                    "AT+CPBW=\(index),\"\(clean)\",\(type),\"EC25 Toolbox\"",
                    timeout: 10_000
                )
                _ = try? await self.send("AT+CSCS=\"UCS2\"", timeout: 5_000)
            } catch {
                _ = try? await self.send("AT+CSCS=\"UCS2\"", timeout: 5_000)
                throw error
            }
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Forces a fresh network search by temporarily deregistering and returning to auto mode.
    func researchNetwork() {
        run {
            self.log(localized("log.searching_network"))
            _ = try await self.send("AT+COPS=2", timeout: 20_000)
            _ = try await self.send("AT+COPS=0", timeout: 60_000)
            try await self.refreshInfoImpl()
            self.state.lastUpdated = Date()
        }
    }

    /// Requests a modem reboot and waits for automatic recovery to reconnect.
    func restartModule() {
        run {
            _ = try? await self.send("AT+CFUN=1,1", timeout: 4_000)
            await self.markDisconnected(logRemoval: false)
            self.log(localized("log.restarting_modem"))
        }
    }

    /// Mutates persisted settings and restarts dependent services.
    ///
    /// - Parameter mutate: Closure that edits a copy of current settings.
    func updateSettings(_ mutate: (inout ModemSettings) -> Void) {
        var next = settings
        mutate(&next)
        if next.visibleFields.isEmpty {
            next.visibleFields = ModemSettings.defaults.visibleFields
        }
        setAppLocale(next.preferredLanguage ?? "")
        settings = next
        saveSettings(next)
        applyLoginItemSetting()
        restartPollers()
    }

    /// Runs a user operation with shared busy/error handling.
    ///
    /// Feature extensions use this to participate in the same serialized action
    /// pipeline as the core status, SMS, and configuration commands.
    func run(_ operation: @escaping () async throws -> Void) {
        guard !state.busy, !foregroundOperationQueued else { return }
        foregroundOperationQueued = true
        enqueueOperation(refreshing: false, operation)
    }

    /// Runs a refresh without putting every control in the disabled state.
    /// Foreground actions remain clickable and are serialized behind the poll.
    func runRefresh(_ operation: @escaping () async throws -> Void) {
        guard !state.busy, !foregroundOperationQueued, !refreshOperationQueued else { return }
        refreshOperationQueued = true
        enqueueOperation(refreshing: true, operation)
    }

    private func enqueueOperation(
        refreshing: Bool,
        _ operation: @escaping () async throws -> Void
    ) {
        let previous = operationTail
        operationTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }

            if refreshing {
                self.state.refreshing = true
            } else {
                self.state.busy = true
            }
            self.state.lastError = nil

            do {
                try await operation()
            } catch is CancellationError {
                // App shutdown or a cancelled queued operation needs no UI error.
            } catch {
                self.state.lastError = error.localizedDescription
                self.log(localizedFormat("common.error_format", error.localizedDescription))
            }

            if refreshing {
                self.state.refreshing = false
                self.refreshOperationQueued = false
            } else {
                self.state.busy = false
                self.foregroundOperationQueued = false
            }
        }
    }

    func connectImpl(prefix: String) async throws {
        // The transport is not usable until the complete AT initialization has
        // succeeded. Keeping this false prevents eSTK views from launching lpac
        // against a session that may still be torn down on initialization error.
        state.connected = false
        estkAPDUBackend = nil
        estkLogicalChannels.removeAll()
        await transport.disconnect()
        do {
            let description = try await transport.connect()
            state.usbDescription = description.isEmpty ? state.usbDescription : description
            try await initialize()
            state.connected = true
            updateSIMPINBlockedServiceNotice()
            log("\(prefix) \(state.usbDescription)")
        } catch {
            await markDisconnected(logRemoval: false)
            throw error
        }
    }

    private func initialize() async throws {
        _ = try await send("AT", timeout: 5_000)
        _ = try await send("ATE0", timeout: 5_000)
        // A PIN-locked SIM may reject SMS configuration commands even though
        // the modem and its AT interface are healthy. Establish connectivity
        // from the basic AT probe first, then configure SMS only after CPIN is
        // READY so the UI can stay online and expose the PIN unlock controls.
        _ = try? await send("AT+CMEE=2")
        try await refreshInfoImpl()
        if state.simSecurity.isReady {
            _ = try? await send("AT+CNMI=2,1,0,0,0")
            do {
                try await refreshMessagesImpl()
            } catch {
                log(localizedFormat("common.error_format", error.localizedDescription))
            }
        } else {
            clearMessagesForLockedSIM()
        }
        state.lastUpdated = Date()
        ensureVoWiFiStarted()
    }

    func refreshInfoImpl() async throws {
        refreshNetworkHints()
        state.commandRecords = []
        await refreshSIMSecurityState(allowAutoUnlock: true)

        let manufacturer = await query(localized("parameter.manufacturer.label"), "AT+CGMI")
        let model = await query(localized("parameter.model.label"), "AT+CGMM")
        let revision = await query(localized("parameter.firmware.label"), "AT+CGMR")
        let imei = await query("IMEI", "AT+CGSN")
        let imsi = await query("IMSI", "AT+CIMI")
        let iccid = await query("ICCID", "AT+QCCID")
        let ownNumber = await query(localized("parameter.own_number.label"), "AT+CNUM")
        var resolvedOwnNumber = parseOwnNumber(ownNumber)
        if resolvedOwnNumber == "-", state.simSecurity.isReady {
            _ = await query(localized("query.own_number_phonebook"), "AT+CPBS=\"ON\"")
            let rangeLines = await query(localized("query.own_number_phonebook"), "AT+CPBR=?")
            if let range = parsePhonebookIndexRange(rangeLines) {
                let upper = min(range.upperBound, range.lowerBound + 9)
                let phonebook = await query(
                    localized("query.own_number_phonebook"),
                    "AT+CPBR=\(range.lowerBound),\(upper)"
                )
                resolvedOwnNumber = parseOwnNumberPhonebook(phonebook)
            }
        }
        let sim = await query(localized("parameter.sim_status.label"), "AT+CPIN?")
        let simInserted = await query(localized("parameter.sim_inserted.label"), "AT+QSIMSTAT?")
        let operatorName = await query(localized("parameter.operator.label"), "AT+COPS?")
        let signal = await query(localized("parameter.signal.label"), "AT+CSQ")
        let registration = await query(localized("parameter.cs_registration.label"), "AT+CREG?")
        let gprsRegistration = await query(localized("parameter.ps_registration.label"), "AT+CGREG?")
        let epsRegistration = await query(localized("parameter.eps_registration.label"), "AT+CEREG?")
        let packetAttached = await query(localized("parameter.packet_attach.label"), "AT+CGATT?")
        let activePdp = await query(localized("parameter.pdp_activation.label"), "AT+CGACT?")
        let pdpAddress = await query(localized("parameter.pdp_address.label"), "AT+CGPADDR")
        let networkInfo = await query(localized("parameter.data_network_type.label"), "AT+QNWINFO")
        let servingCell = await query(localized("overview.section.serving_cell"), "AT+QENG=\"servingcell\"", timeout: 8_000)
        let carrierAggregation = await query(localized("parameter.carrier_aggregation.label"), "AT+QCAINFO", timeout: 8_000)
        let usbMode = await query(localized("settings.section.usb_mode"), "AT+QCFG=\"usbnet\"")
        let apnProfiles = await query(localized("query.apn_pdp_configuration"), "AT+CGDCONT?", timeout: 8_000)
        let temperature = await query(localized("parameter.temperature.label"), "AT+QTEMP")

        var csq = parseSignal(signal)
        let network = parseNetworkType(networkInfo)
        let cell = parseServingCell(servingCell)
        let temperatures = parseTemperatures(temperature)
        let band = cell.band ?? Int(network.band.filter(\.isNumber))
        let earfcn = cell.earfcn ?? Int(network.channel)
        let frequency = earfcnToDlMHz(band: band, earfcn: earfcn)
        if let rsrpBars = barsFromRSRP(cell.rsrp) {
            csq.bars = rsrpBars
        }
        let profiles = parseAPNProfiles(apnProfiles)

        state.info = ModemInfo(
            manufacturer: firstNonCommandLine(manufacturer) ?? "-",
            model: firstNonCommandLine(model) ?? "-",
            revision: firstNonCommandLine(revision) ?? "-",
            imei: firstNonCommandLine(imei) ?? "-",
            imsi: firstNonCommandLine(imsi) ?? "-",
            iccid: parseICCID(iccid),
            ownNumber: resolvedOwnNumber,
            simStatus: parsePrefixed(sim, prefix: "+CPIN:"),
            simInserted: parsePrefixed(simInserted, prefix: "+QSIMSTAT:"),
            operatorName: parseOperator(operatorName),
            tech: parseTech(operatorLines: operatorName, fallback: network.label),
            signal: csq,
            ber: parseBER(signal),
            registration: parseRegistration(registration, prefix: "+CREG:"),
            gprsRegistration: parseRegistration(gprsRegistration, prefix: "+CGREG:"),
            epsRegistration: parseRegistration(epsRegistration, prefix: "+CEREG:"),
            packetAttached: parsePrefixed(packetAttached, prefix: "+CGATT:"),
            activePdp: compactLines(activePdp, prefix: "+CGACT:"),
            pdpAddress: compactLines(pdpAddress, prefix: "+CGPADDR:"),
            dataNetworkType: network.full,
            plmn: cell.plmn ?? "-",
            networkLabel: network.label,
            servingCell: compactLines(servingCell, prefix: "+QENG:"),
            carrierAggregation: compactLines(carrierAggregation, prefix: "+QCAINFO:"),
            usbNetworkMode: parseUSBNetworkMode(usbMode),
            apnProfiles: profiles,
            currentApn: currentAPN(profiles),
            temperature: temperatures.all,
            temperatureAvg: temperatures.average,
            band: band.map { "Band \($0)" } ?? "-",
            duplexMode: cell.duplexMode ?? "-",
            channel: earfcn.map(String.init) ?? "-",
            rsrp: cell.rsrp.map { "\($0) dBm" } ?? "-",
            rsrq: cell.rsrq.map { "\($0) dB" } ?? "-",
            rssiDbm: cell.rssi.map { "\($0) dBm" } ?? csq.text,
            sinr: cell.sinr.map(String.init) ?? "-",
            cqi: cell.cqi.map(String.init) ?? "-",
            modulation: cqiToModulation(cell.cqi),
            dlBandwidth: cell.dlBandwidth ?? "-",
            ulBandwidth: cell.ulBandwidth ?? "-",
            pci: cell.pci.map(String.init) ?? "-",
            cellId: cell.cellId ?? "-",
            tac: cell.tac ?? "-",
            earfcn: earfcn.map(String.init) ?? "-",
            freqMhz: frequency.map { "\($0) MHz" } ?? "-"
        )
        updateSIMPINBlockedServiceNotice()
        await refreshESTKAvailabilityIfNeeded()
        ensureVoWiFiStarted()
    }

    func refreshMessagesImpl() async throws {
        guard state.simSecurity.isReady else {
            clearMessagesForLockedSIM()
            return
        }
        _ = try await send("AT+CMGF=1")
        _ = try await send("AT+CSCS=\"UCS2\"")

        var all: [SMSMessage] = []
        for storage in ["ME", "SM"] {
            do {
                _ = try await send("AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\"")
                let lines = try await send("AT+CMGL=\"ALL\"", timeout: 12_000)
                all.append(contentsOf: parseMessageList(lines, storage: storage))
            } catch {
                continue
            }
        }

        let scope = currentSIMMessageScope()
        guard scope.isIdentified else {
            state.messages = []
            state.unreadCount = 0
            return
        }
        state.messages = try smsArchive.synchronize(liveMessages: all, legacySent: state.sentMessages, scope: scope)
        if !state.sentMessages.isEmpty {
            state.sentMessages.removeAll()
            try? FileManager.default.removeItem(at: sentLogURL)
        }
        state.smsBackup = smsArchive.state
        state.unreadCount = state.messages.filter(\.unread).count
    }

    func clearMessagesForLockedSIM() {
        state.messages = []
        state.unreadCount = 0
    }

    func backupSMSNow() {
        run {
            try self.smsArchive.backupNow()
            self.state.smsBackup = self.smsArchive.state
        }
    }

    func restoreSMSFromICloudDrive() {
        run {
            try self.smsArchive.restoreLatestBackup()
            let scope = self.currentSIMMessageScope()
            self.state.messages = scope.isIdentified ? self.smsArchive.messages(in: scope.id) : []
            self.state.smsBackup = self.smsArchive.state
            self.state.unreadCount = self.state.messages.filter(\.unread).count
        }
    }

    private func currentSIMMessageScope() -> SIMMessageScope {
        SIMMessageScope(eid: state.estk.chipInfo?.eidValue, iccid: state.info.iccid)
    }

    private func markRead(_ messages: [SMSMessage]) async throws {
        let targets = messages.filter(\.unread)
        guard !targets.isEmpty else { return }
        let modemTargets = targets.filter { $0.storage != "SENT" && $0.presentOnModem }
        let grouped = Dictionary(grouping: modemTargets, by: \.storage)
        _ = try await send("AT+CMGF=1")
        for (storage, messages) in grouped {
            _ = try? await send("AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\"")
            for message in messages {
                _ = try? await send("AT+CMGR=\(message.index)", timeout: 6_000)
            }
        }
        try smsArchive.markRead(messageIDs: Set(targets.map(\.id)))
        state.smsBackup = smsArchive.state
    }

    @discardableResult
    private func query(_ title: String, _ command: String, timeout: Int32 = 5_000) async -> [String] {
        do {
            let lines = try await send(command, timeout: timeout)
            state.commandRecords.append(CommandRecord(title: title, command: command, lines: lines, error: nil))
            return lines
        } catch {
            state.commandRecords.append(CommandRecord(title: title, command: command, lines: [], error: error.localizedDescription))
            return []
        }
    }

    /// Sends one AT command through the transport and mirrors the response into the app log.
    ///
    /// - Parameters:
    ///   - command: AT command line without trailing carriage return.
    ///   - payload: Optional payload sent after the command prompt, used by SMS.
    ///   - timeout: Command timeout in milliseconds.
    /// - Returns: Response lines with transport framing removed.
    @discardableResult
    func send(_ command: String, payload: String? = nil, timeout: Int32 = 4_000) async throws -> [String] {
        log("> \(command)")
        let lines = try await transport.transact(command: command, payload: payload, timeoutMs: timeout)
        if lines.isEmpty {
            log("< OK")
        } else {
            lines.forEach { log("< \($0)") }
        }
        return lines
    }

    /// Sends a sensitive command without mirroring APDU or activation-session data
    /// into the in-memory diagnostics log.
    @discardableResult
    func sendUnlogged(_ command: String, timeout: Int32 = 4_000) async throws -> [String] {
        try await transport.transact(command: command, payload: nil, timeoutMs: timeout)
    }

    private func markDisconnected(logRemoval: Bool = true) async {
        if state.connected && logRemoval {
            log(localized("log.device_removed"))
        }
        let previousESTKAvailability = state.estk.availability
        state.connected = false
        state.info = .empty
        state.estk = ESTKState()
        // Keep the last confirmed card type while the modem is temporarily
        // offline. A new ICCID is probed again after reconnecting, so swapping
        // the SIM while disconnected still updates the tab correctly.
        state.estk.availability = previousESTKAvailability
        estkAPDUBackend = nil
        estkLogicalChannels.removeAll()
        state.simSecurity = SIMSecurityState()
        simAutoUnlockAttemptedICCID = nil
        simPINNoticeFingerprint = nil
        state.usbDescription = "USB 2c7c:0125"
        state.activeCallNumber = nil
        await stopVoWiFiSession(resetPhase: settings.effectiveVoWiFiEnabled ? .waitingForSIM : .disabled)
        await transport.disconnect()
    }

    /// Explains the common “device connected but no signal” state caused by an unentered SIM PIN.
    func updateSIMPINBlockedServiceNotice() {
        guard state.connected, state.simSecurity.requiresPIN else {
            simPINNoticeFingerprint = nil
            return
        }

        let fingerprint = state.simSecurity.iccid.isEmpty
            ? state.usbDescription
            : state.simSecurity.iccid
        guard simPINNoticeFingerprint != fingerprint else { return }
        simPINNoticeFingerprint = fingerprint
        SIMPINNotification.postLockedSIMNotice()
    }

    private func attemptRecover() {
        guard !state.connected,
              !state.busy,
              !state.refreshing,
              !foregroundOperationQueued,
              !refreshOperationQueued else { return }

        // Recovery uses the same serialized pipeline as refresh and foreground
        // actions. This prevents a reconnect/disconnect cycle from racing an
        // lpac APDU session while keeping normal controls responsive.
        runRefresh {
            try await self.connectImpl(prefix: localized("log.connected"))
        }
    }

    private func handleWake() {
        run {
            self.log(localized("log.resuming"))
            var description: String?
            for attempt in 0..<3 where description == nil {
                do {
                    description = try await self.transport.connect()
                } catch {
                    if attempt < 2 {
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }

            guard let description else {
                await self.markDisconnected()
                return
            }

            if self.settings.restartOnWake, self.settings.effectiveManagementMode == .direct {
                self.log(localized("log.wake_restarting"))
                _ = try? await self.send("AT+CFUN=1,1", timeout: 4_000)
                await self.markDisconnected(logRemoval: false)
                return
            }

            self.state.connected = true
            self.state.usbDescription = description.isEmpty ? self.state.usbDescription : description
            self.log(localizedFormat("log.wake_reconnected", self.state.usbDescription))
            do {
                try await self.initialize()
            } catch {
                await self.markDisconnected(logRemoval: false)
                throw error
            }
        }
    }

    private func restartPollers() {
        infoPollTask?.cancel()
        smsPollTask?.cancel()
        recoverTask?.cancel()

        let infoSeconds = max(2, settings.infoPollSeconds)
        infoPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(infoSeconds))
                if !Task.isCancelled, state.connected, !state.busy, !state.refreshing {
                    refreshInfoOnly()
                }
            }
        }

        recoverTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled {
                    attemptRecover()
                }
            }
        }

        if settings.smsPollSeconds > 0 {
            let smsSeconds = settings.smsPollSeconds
            smsPollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(smsSeconds))
                    if !Task.isCancelled, state.connected, !state.busy, !state.refreshing, state.simSecurity.isReady {
                        refreshMessages()
                    }
                }
            }
        }
    }

    private func observeWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    private func refreshNetworkHints() {
        var hints: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            state.networkHints = []
            return
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = buffer.prefix { $0 != 0 }.withUnsafeBufferPointer { pointer in
                String(decoding: pointer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            if ip.hasPrefix("192.168.225.") {
                hints.append("\(name) · \(ip)")
            }
        }

        state.networkHints = hints.sorted()
    }

    private func sentAsMessages() -> [SMSMessage] {
        state.sentMessages.map {
            SMSMessage(
                id: "SENT-\($0.ts)",
                storage: "SENT",
                index: Int($0.ts),
                status: "STO SENT",
                outgoing: true,
                unread: false,
                sender: $0.to,
                date: $0.date,
                body: $0.body
            )
        }
    }

    /// Adds a bounded phone call event for the Phone feature.
    func addCallEvent(title: String, detail: String, failed: Bool = false) {
        state.callLog.insert(CallEvent(title: title, detail: detail, failed: failed), at: 0)
        if state.callLog.count > 30 {
            state.callLog.removeLast(state.callLog.count - 30)
        }
    }

    private func log(_ line: String) {
        state.logLines.append(line)
        if state.logLines.count > 600 {
            state.logLines.removeFirst(state.logLines.count - 600)
        }
    }

    private func appendTerminal(_ line: String) {
        state.terminalLines.append(line)
        if state.terminalLines.count > 600 {
            state.terminalLines.removeFirst(state.terminalLines.count - 600)
        }
    }

    private func loadSettings() -> ModemSettings {
        let defaults = UserDefaults.standard
        if defaults.data(forKey: "settings") == nil {
            for legacyIdentifier in AppIdentity.legacyBundleIdentifiers {
                guard let legacyDefaults = UserDefaults(suiteName: legacyIdentifier),
                      let legacyData = legacyDefaults.data(forKey: "settings") else { continue }
                defaults.set(legacyData, forKey: "settings")
                break
            }
        }
        guard let data = defaults.data(forKey: "settings"),
              let decoded = try? JSONDecoder().decode(ModemSettings.self, from: data) else {
            return .defaults
        }
        return decoded.visibleFields.isEmpty ? .defaults : decoded
    }

    private func saveSettings(_ settings: ModemSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
    }

    private func loadSentLog() -> [SentMessage] {
        guard let data = try? Data(contentsOf: sentLogURL),
              let decoded = try? JSONDecoder().decode([SentMessage].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveSentLog() {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state.sentMessages)
            try data.write(to: sentLogURL, options: .atomic)
        } catch {
            // Sent-message persistence is best-effort.
        }
    }

    private func applyLoginItemSetting() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if settings.openAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log(localizedFormat("error.login_item", error.localizedDescription))
        }
    }
}
