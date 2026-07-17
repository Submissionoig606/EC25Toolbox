import Foundation

/// Normalized radio signal state used by both the menu bar icon and overview UI.
struct SignalInfo: Equatable {
    /// RSSI-like signal value in dBm when the modem returns a valid reading.
    var dbm: Int?
    /// Four-step signal level used for compact UI and SF Symbols variable values.
    var bars: Int
    /// Approximate user-facing strength percentage.
    var percent: Int
    /// Display-ready signal text, usually including the `dBm` suffix.
    var text: String

    /// Empty signal placeholder for offline or not-yet-polled states.
    static let empty = SignalInfo(dbm: nil, bars: 0, percent: 0, text: "-")
}

/// PDP/APN profile returned by `AT+CGDCONT?`.
struct APNProfile: Identifiable, Equatable {
    var id: String { cid }
    var cid: String
    var type: String
    var apn: String
}

/// Aggregated modem snapshot displayed across the overview and settings pages.
struct ModemInfo: Equatable {
    var manufacturer = "-"
    var model = "-"
    var revision = "-"
    var imei = "-"
    var imsi = "-"
    var iccid = "-"
    var ownNumber = "-"
    var simStatus = "-"
    var simInserted = "-"
    var operatorName = "-"
    var tech = "-"
    var signal = SignalInfo.empty
    var ber = "-"
    var registration = "-"
    var gprsRegistration = "-"
    var epsRegistration = "-"
    var packetAttached = "-"
    var activePdp = "-"
    var pdpAddress = "-"
    var dataNetworkType = "-"
    var plmn = "-"
    var networkLabel = "-"
    var servingCell = "-"
    var carrierAggregation = "-"
    var usbNetworkMode = "-"
    var apnProfiles: [APNProfile] = []
    var currentApn = "-"
    var temperature = "-"
    var temperatureAvg = "-"
    var band = "-"
    var duplexMode = "-"
    var channel = "-"
    var rsrp = "-"
    var rsrq = "-"
    var rssiDbm = "-"
    var sinr = "-"
    var cqi = "-"
    var modulation = "-"
    var dlBandwidth = "-"
    var ulBandwidth = "-"
    var pci = "-"
    var cellId = "-"
    var tac = "-"
    var earfcn = "-"
    var freqMhz = "-"

    static let empty = ModemInfo()
}

/// SMS message normalized from modem storage or the local sent-message log.
struct SMSMessage: Identifiable, Equatable {
    var id: String
    var storage: String
    var index: Int
    var status: String
    var outgoing: Bool
    var unread: Bool
    var sender: String
    var date: String
    var body: String
    var scopeID: String = ""
    var presentOnModem: Bool = true
}

/// Locally persisted sent SMS entry.
struct SentMessage: Codable, Equatable {
    var ts: Int64
    var to: String
    var body: String
    var date: String
}

/// One AT query result shown in the terminal/status diagnostics area.
struct CommandRecord: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var command: String
    var lines: [String]
    var error: String?
}

/// Phone call event recorded by the voice-calling feature.
struct CallEvent: Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
    var failed: Bool = false
}

/// User-configurable modem field shown on the overview page.
struct FieldDescriptor: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var label: String
    var wide: Bool = false
    var value: (ModemInfo) -> String

    static func == (lhs: FieldDescriptor, rhs: FieldDescriptor) -> Bool {
        lhs.key == rhs.key && lhs.label == rhs.label && lhs.wide == rhs.wide
    }
}

/// Catalog of all overview fields the settings page can show or hide.
@MainActor
let fieldCatalog: [FieldDescriptor] = [
    FieldDescriptor(key: "dataNetworkType", label: "parameter.data_network_type.label", wide: true) { $0.dataNetworkType },
    FieldDescriptor(key: "signalPercent", label: "parameter.signal_percent.label") { $0.signal.percent > 0 ? "\($0.signal.percent)%" : "-" },
    FieldDescriptor(key: "operator", label: "parameter.operator.label") { $0.operatorName },
    FieldDescriptor(key: "plmn", label: "parameter.plmn.label") { $0.plmn },
    FieldDescriptor(key: "tech", label: "parameter.radio_access.label") { $0.tech },
    FieldDescriptor(key: "regCS", label: "parameter.cs_registration.label") { $0.registration },
    FieldDescriptor(key: "regPS", label: "parameter.ps_registration.label") { $0.gprsRegistration },
    FieldDescriptor(key: "regEPS", label: "parameter.eps_registration.label") { $0.epsRegistration },
    FieldDescriptor(key: "attach", label: "parameter.packet_attach.label") {
        $0.packetAttached == "1" ? "network.attached" : ($0.packetAttached == "0" ? "network.detached" : $0.packetAttached)
    },
    FieldDescriptor(key: "activePdp", label: "parameter.pdp_activation.label", wide: true) { $0.activePdp },
    FieldDescriptor(key: "imei", label: "parameter.imei.label") { $0.imei },
    FieldDescriptor(key: "imsi", label: "parameter.imsi.label") { $0.imsi },
    FieldDescriptor(key: "iccid", label: "parameter.iccid.label", wide: true) { $0.iccid },
    FieldDescriptor(key: "simStatus", label: "parameter.sim_status.label") { $0.simStatus },
    FieldDescriptor(key: "simInserted", label: "parameter.sim_inserted.label") { $0.simInserted },
    FieldDescriptor(key: "ownNumber", label: "parameter.own_number.label") { $0.ownNumber },
    FieldDescriptor(key: "pdp", label: "parameter.pdp_address.label", wide: true) { $0.pdpAddress },
    FieldDescriptor(key: "band", label: "parameter.band.label") { $0.band },
    FieldDescriptor(key: "duplex", label: "parameter.duplex_mode.label") { $0.duplexMode },
    FieldDescriptor(key: "earfcn", label: "parameter.channel_earfcn.label") { $0.earfcn },
    FieldDescriptor(key: "freq", label: "parameter.downlink_frequency.label") { $0.freqMhz },
    FieldDescriptor(key: "rsrp", label: "parameter.rsrp.label") { $0.rsrp },
    FieldDescriptor(key: "rsrq", label: "parameter.rsrq.label") { $0.rsrq },
    FieldDescriptor(key: "rssi", label: "parameter.rssi.label") { $0.rssiDbm },
    FieldDescriptor(key: "sinr", label: "parameter.sinr.label") { $0.sinr },
    FieldDescriptor(key: "cqi", label: "parameter.cqi.label") { $0.cqi },
    FieldDescriptor(key: "modulation", label: "parameter.modulation.label") { $0.modulation },
    FieldDescriptor(key: "dlbw", label: "parameter.downlink_bandwidth.label") { $0.dlBandwidth },
    FieldDescriptor(key: "ulbw", label: "parameter.uplink_bandwidth.label") { $0.ulBandwidth },
    FieldDescriptor(key: "pci", label: "parameter.pci.label") { $0.pci },
    FieldDescriptor(key: "cellId", label: "parameter.cell_id.label") { $0.cellId },
    FieldDescriptor(key: "tac", label: "parameter.tac.label") { $0.tac },
    FieldDescriptor(key: "temp", label: "parameter.module_temperature.label") { $0.temperature },
    FieldDescriptor(key: "tempAvg", label: "parameter.average_temperature.label") { $0.temperatureAvg },
    FieldDescriptor(key: "ber", label: "parameter.ber.label") { $0.ber },
    FieldDescriptor(key: "usbnet", label: "parameter.usb_mode.label") { $0.usbNetworkMode }
]

/// Persisted app preferences controlling polling, startup, and overview fields.
struct ModemSettings: Codable, Equatable {
    var openAtLogin = true
    var infoPollSeconds = 12
    var smsPollSeconds = 30
    var restartOnWake = true
    /// BCP-47 override, or nil/empty to follow the system language.
    var preferredLanguage: String?
    /// Optional ISD-R AID override for cards with a non-standard applet identifier.
    var estkISDRAID: String?
    /// Optional ES10x segment-size override for slower removable eUICCs.
    var estkES10xMSS: Int?
    /// Automatically deliver installation notifications after a profile download.
    var estkNotifyDownloads: Bool?
    /// Automatically deliver deletion notifications after removing a profile.
    var estkNotifyDeletions: Bool?
    /// Automatically deliver enable/disable notifications after switching profiles.
    var estkNotifySwitches: Bool?
    /// Optional HTTP(S) proxy used only by bundled lpac requests.
    var estkHTTPProxy: String?
    /// Developer compatibility override that disables SM-DP+/SM-DS TLS validation.
    var estkIgnoreTLSCertificate: Bool?
    /// `direct` uses the local USB device; `remote` uses the encrypted network transport.
    var managementMode: ManagementMode?
    var remoteHost: String?
    var remotePort: Int?
    var remoteLANPort: Int?
    var remoteTailscalePort: Int?
    var remoteSharingEnabled: Bool?
    /// Whether the app may unlock the currently inserted SIM using its Keychain PIN.
    var simAutoUnlock: Bool?
    /// Enables the application-contained VoWiFi client after the modem is ready.
    var vowifiEnabled: Bool?
    /// Reconnects ePDG and IMS automatically after transient failures or wake.
    var vowifiAutoConnect: Bool?
    /// Optional operator-provided ePDG FQDN/IP override.
    var vowifiEPDGAddress: String?
    /// Optional IMS realm override; derived from IMSI when empty.
    var vowifiIMSRealm: String?
    /// Optional P-CSCF host override; configuration payload discovery is preferred.
    var vowifiPCSCFAddress: String?
    /// Optional IMS private identity override used only if ISIM is unavailable.
    var vowifiPrivateIdentity: String?
    /// Optional IMS public identity override used only if ISIM is unavailable.
    var vowifiPublicIdentity: String?
    var visibleFields = [
        "dataNetworkType", "signalPercent", "operator", "plmn", "regEPS",
        "activePdp", "imei", "imsi", "iccid", "simStatus", "ownNumber",
        "rsrp", "rsrq", "sinr", "modulation", "temp", "tempAvg",
        "band", "duplex", "freq", "usbnet"
    ]

    static let defaults = ModemSettings()

    var effectiveESTKNotifyDownloads: Bool { estkNotifyDownloads ?? true }
    var effectiveESTKNotifyDeletions: Bool { estkNotifyDeletions ?? true }
    var effectiveESTKNotifySwitches: Bool { estkNotifySwitches ?? false }
    var effectiveManagementMode: ManagementMode { managementMode ?? .direct }
    var effectiveRemotePort: Int { remotePort ?? RemoteDefaults.lanPort }
    var effectiveRemoteLANPort: Int { remoteLANPort ?? RemoteDefaults.lanPort }
    var effectiveRemoteTailscalePort: Int { remoteTailscalePort ?? RemoteDefaults.tailscalePort }
    var effectiveRemoteSharingEnabled: Bool { remoteSharingEnabled ?? true }
    var effectiveVoWiFiEnabled: Bool { vowifiEnabled ?? false }
    var effectiveVoWiFiAutoConnect: Bool { vowifiAutoConnect ?? true }
}

/// Runtime state for the menu-bar panel.
struct ModemState: Equatable {
    var connected = false
    var busy = false
    var refreshing = false
    var usbDescription = "USB 2c7c:0125"
    var lastError: String?
    var lastUpdated: Date?
    var info = ModemInfo.empty
    var messages: [SMSMessage] = []
    var unreadCount = 0
    var sentMessages: [SentMessage] = []
    var smsBackup = SMSBackupState()
    var logLines: [String] = []
    var terminalLines: [String] = []
    var commandRecords: [CommandRecord] = []
    var networkHints: [String] = []
    var estk = ESTKState()
    var vowifi = VoWiFiState()
    var simSecurity = SIMSecurityState()
    var remoteManagement = RemoteManagementState()
    var activeCallNumber: String?
    var callLog: [CallEvent] = []
}
