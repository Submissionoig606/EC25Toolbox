import Foundation

// The active localization bundle. A lock keeps terminal/background work safe
// while Settings swaps the language at runtime.
private let appBundleLock = NSLock()
private nonisolated(unsafe) var appBundleStorage: Bundle = .module

var appLocalizedBundle: Bundle {
    appBundleLock.lock()
    defer { appBundleLock.unlock() }
    return appBundleStorage
}

/// A language shipped by the app and displayed using its own name.
struct AppLanguage: Identifiable, Hashable {
    let id: String
    let name: String
}

enum AppLanguages {
    static let available: [AppLanguage] = Bundle.module.localizations
        .filter { $0 != "Base" }
        .map { rawCode in
            let code = Locale.canonicalLanguageIdentifier(from: rawCode)
            let locale = Locale(identifier: code)
            let display = locale.localizedString(forIdentifier: code) ?? code
            let name = display.isEmpty
                ? code
                : display.prefix(1).capitalized(with: locale) + display.dropFirst()
            return AppLanguage(id: code, name: name)
        }
        .sorted { $0.id < $1.id }
}

/// Selects a bundled localization, or follows the system when the identifier is empty.
func setAppLocale(_ identifier: String) {
    let resolved: Bundle
    if identifier.isEmpty {
        resolved = .module
    } else if let url = Bundle.module.url(forResource: identifier, withExtension: "lproj"),
              let bundle = Bundle(url: url) {
        resolved = bundle
    } else {
        resolved = .module
    }

    appBundleLock.lock()
    appBundleStorage = resolved
    appBundleLock.unlock()
}

/// Localizes a runtime string key from the active app bundle.
func localized(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: appLocalizedBundle)
}

/// Localizes and formats a string key using the user's current formatting locale.
func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: .autoupdatingCurrent, arguments: arguments)
}

/// Concise parameter explanations used by hover help throughout the app.
enum ParameterHelp {
    private static let descriptions: [String: String] = [
        "parameter.signal.label": "parameter.signal.help",
        "parameter.signal_percent.label": "parameter.signal_percent.help",
        "parameter.network.label": "parameter.network.help",
        "parameter.operator.label": "parameter.operator.help",
        "parameter.updated.label": "parameter.updated.help",
        "parameter.data_network_type.label": "parameter.data_network_type.help",
        "parameter.plmn.label": "parameter.plmn.help",
        "parameter.radio_access.label": "parameter.radio_access.help",
        "parameter.registration.label": "parameter.registration.help",
        "parameter.cs_registration.label": "parameter.cs_registration.help",
        "parameter.ps_registration.label": "parameter.ps_registration.help",
        "parameter.eps_registration.label": "parameter.eps_registration.help",
        "parameter.packet_attach.label": "parameter.packet_attach.help",
        "parameter.pdp_activation.label": "parameter.pdp_activation.help",
        "parameter.pdp_address.label": "parameter.pdp_address.help",
        "parameter.usb_networking.label": "parameter.usb_networking.help",
        "parameter.usb_mode.label": "parameter.usb_mode.help",
        "parameter.current_apn.label": "parameter.current_apn.help",
        "parameter.rsrp.label": "parameter.rsrp.help",
        "parameter.rsrq.label": "parameter.rsrq.help",
        "parameter.sinr.label": "parameter.sinr.help",
        "parameter.rssi.label": "parameter.rssi.help",
        "parameter.band.label": "parameter.band.help",
        "parameter.duplex.label": "parameter.duplex.help",
        "parameter.duplex_mode.label": "parameter.duplex_mode.help",
        "parameter.temperature.label": "parameter.temperature.help",
        "parameter.module_temperature.label": "parameter.module_temperature.help",
        "parameter.average_temperature.label": "parameter.average_temperature.help",
        "parameter.sim_status.label": "parameter.sim_status.help",
        "parameter.sim_inserted.label": "parameter.sim_inserted.help",
        "parameter.own_number.label": "parameter.own_number.help",
        "parameter.imei.label": "parameter.imei.help",
        "parameter.imsi.label": "parameter.imsi.help",
        "parameter.iccid.label": "parameter.iccid.help",
        "parameter.frequency.label": "parameter.frequency.help",
        "parameter.downlink_frequency.label": "parameter.downlink_frequency.help",
        "parameter.earfcn.label": "parameter.earfcn.help",
        "parameter.channel_earfcn.label": "parameter.channel_earfcn.help",
        "parameter.pci.label": "parameter.pci.help",
        "parameter.cell_id.label": "parameter.cell_id.help",
        "parameter.tac.label": "parameter.tac.help",
        "parameter.carrier_aggregation.label": "parameter.carrier_aggregation.help",
        "parameter.cqi.label": "parameter.cqi.help",
        "parameter.modulation.label": "parameter.modulation.help",
        "parameter.downlink_bandwidth.label": "parameter.downlink_bandwidth.help",
        "parameter.uplink_bandwidth.label": "parameter.uplink_bandwidth.help",
        "parameter.ber.label": "parameter.ber.help",
        "parameter.manufacturer.label": "parameter.manufacturer.help",
        "parameter.model.label": "parameter.model.help",
        "parameter.firmware.label": "parameter.firmware.help"
    ]

    static func text(for label: String) -> String {
        if let description = descriptions[label] {
            return localized(description)
        }
        return localizedFormat("parameter.generic.help", localized(label))
    }
}
