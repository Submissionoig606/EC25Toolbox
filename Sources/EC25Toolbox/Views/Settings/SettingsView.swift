import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case remote
    case sim
    case network
    case device

    var id: String { rawValue }

    var title: String {
        "settings.category.\(rawValue)"
    }

    var description: String {
        "settings.category.\(rawValue).description"
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .remote: "network.badge.shield.half.filled"
        case .sim: "simcard"
        case .network: "network"
        case .device: "wrench.and.screwdriver"
        }
    }
}

/// Categorized macOS Settings-style interface.
struct SettingsView: View {
    @EnvironmentObject private var store: ModemStore
    @State private var selectedCategory: SettingsCategory = .general
    @State private var usbMode = 1
    @State private var apn = ""
    @State private var ownNumber = ""

    var body: some View {
        SettingsCategoryLayout(selection: selectedCategory) { compact in
            settingsSidebar(compact: compact)
        } header: {
            SettingsCategoryHeader(
                title: selectedCategory.title,
                description: selectedCategory.description,
                systemImage: selectedCategory.systemImage
            )
        } content: {
            categoryContent
        }
        .onAppear {
            usbMode = parseUSBMode(store.state.info.usbNetworkMode) ?? usbMode
            if apn.isEmpty, store.state.info.currentApn != "-" {
                apn = store.state.info.currentApn.replacingOccurrences(
                    of: #"\s*\(.*\)"#,
                    with: "",
                    options: .regularExpression
                )
            }
            if ownNumber.isEmpty, store.state.info.ownNumber != "-" {
                ownNumber = store.state.info.ownNumber
            }
        }
        .onChange(of: store.state.info.usbNetworkMode) { _, newValue in
            if let mode = parseUSBMode(newValue) {
                usbMode = mode
            }
        }
        .onChange(of: store.state.info.ownNumber) { _, newValue in
            if ownNumber.isEmpty, newValue != "-" {
                ownNumber = newValue
            }
        }
    }

    private func settingsSidebar(compact: Bool) -> some View {
        ScrollView {
            VStack(spacing: 5) {
                ForEach(SettingsCategory.allCases) { category in
                    SettingsSidebarButton(
                        title: category.title,
                        systemImage: category.systemImage,
                        isSelected: selectedCategory == category,
                        compact: compact
                    ) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .general:
            generalSettings
        case .remote:
            RemoteManagementSettingsCard()
        case .sim:
            SIMPINSettingsCard()
        case .network:
            networkSettings
        case .device:
            deviceSettings
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("settings.group.behavior") {
                MacSettingsToggleRow(
                    title: "settings.launch_at_login.title",
                    help: "settings.launch_at_login.help",
                    isOn: Binding(
                        get: { store.settings.openAtLogin },
                        set: { value in store.updateSettings { $0.openAtLogin = value } }
                    )
                )

                MacSettingsDivider()

                MacSettingsToggleRow(
                    title: "settings.restart_on_wake.title",
                    help: "settings.restart_on_wake.help",
                    isOn: Binding(
                        get: { store.settings.restartOnWake },
                        set: { value in store.updateSettings { $0.restartOnWake = value } }
                    )
                )
            }

            MacSettingsGroup("settings.group.refresh") {
                MacSettingsRow(
                    title: "settings.status_interval.title",
                    help: "settings.status_interval.help"
                ) {
                    RightAlignedMenuPicker(
                        selection: Binding(
                            get: { store.settings.infoPollSeconds },
                            set: { value in store.updateSettings { $0.infoPollSeconds = value } }
                        ),
                        options: [6, 10, 12, 15, 20, 30].map { seconds in
                            .init(
                                title: localizedFormat("format.seconds", seconds),
                                value: seconds
                            )
                        }
                    )
                    .frame(width: 96)
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "settings.sms_interval.title",
                    help: "settings.sms_interval.help"
                ) {
                    RightAlignedMenuPicker(
                        selection: Binding(
                            get: { store.settings.smsPollSeconds },
                            set: { value in store.updateSettings { $0.smsPollSeconds = value } }
                        ),
                        options: [
                            .init(title: localized("common.off"), value: 0)
                        ] + [15, 30, 60, 120].map { seconds in
                            .init(
                                title: localizedFormat("format.seconds", seconds),
                                value: seconds
                            )
                        }
                    )
                    .frame(width: 96)
                }
            }

            MacSettingsGroup("settings.group.language") {
                MacSettingsRow(
                    title: "settings.language.title",
                    help: "settings.language.help"
                ) {
                    RightAlignedMenuPicker(
                        selection: Binding(
                            get: { store.settings.preferredLanguage ?? "" },
                            set: { value in store.updateSettings { $0.preferredLanguage = value } }
                        ),
                        options: [
                            .init(title: localized("common.system_default"), value: "")
                        ] + AppLanguages.available.map { language in
                            .init(title: language.name, value: language.id)
                        }
                    )
                    .frame(width: 132, height: 26)
                }
            }
        }
    }

    private var networkSettings: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("settings.group.usb") {
                MacSettingsRow(
                    title: "settings.section.usb_mode",
                    help: "settings.usb_mode.help"
                ) {
                    RightAlignedMenuPicker(
                        selection: Binding(
                            get: { usbMode },
                            set: { mode in
                                guard mode != usbMode else { return }
                                usbMode = mode
                                store.setUSBMode(mode)
                            }
                        ),
                        options: [
                            .init(title: "QMI", value: 0),
                            .init(title: "ECM", value: 1),
                            .init(title: "MBIM", value: 2),
                            .init(title: "RNDIS", value: 3)
                        ]
                    )
                    .frame(width: 96)
                    .disabled(store.state.busy)
                }

                MacSettingsDivider()

                VStack(alignment: .leading, spacing: 14) {
                    ForEach([0, 1, 2, 3], id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(usbModeName(mode))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Text(localized(usbModeDescriptionKey(for: mode)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            MacSettingsGroup("settings.group.apn") {
                MacSettingsRow(
                    title: "settings.apn.placeholder",
                    help: "settings.apn.input_help"
                ) {
                    HStack(spacing: 8) {
                        TextField(localized("settings.apn.placeholder"), text: $apn)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        ApplyButton(
                            help: "settings.apn.apply",
                            disabled: store.state.busy || trimmed(apn).isEmpty
                        ) {
                            store.setAPN(apn)
                        }
                    }
                }

                MacSettingsDivider()

                MacSettingsRow(title: "parameter.current_apn.label") {
                    Text(localized(store.state.info.currentApn))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !store.state.info.apnProfiles.isEmpty {
                    MacSettingsDivider()
                    MacSettingsRow(
                        title: "settings.apn.all_contexts",
                        help: "settings.apn.all_contexts_help"
                    ) {
                        Text(apnProfilesText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    private var deviceSettings: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("settings.group.actions") {
                MacSettingsRow(
                    title: "action.search_network",
                    help: "action.search_network.help"
                ) {
                    Button(localized("action.search_network")) {
                        store.researchNetwork()
                    }
                    .disabled(store.state.busy)
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "action.reconnect",
                    help: "action.reconnect.help"
                ) {
                    Button(localized("action.reconnect")) {
                        store.reconnect()
                    }
                    .disabled(store.state.busy)
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "action.restart_modem",
                    help: "action.restart_modem.help"
                ) {
                    Button(localized("action.restart_modem"), role: .destructive) {
                        store.restartModule()
                    }
                    .disabled(store.state.busy)
                }
            }

            MacSettingsGroup("settings.group.identity") {
                MacSettingsRow(title: "parameter.manufacturer.label") {
                    selectableValue(store.state.info.manufacturer)
                }
                MacSettingsDivider()
                MacSettingsRow(title: "parameter.model.label") {
                    selectableValue(store.state.info.model)
                }
                MacSettingsDivider()
                MacSettingsRow(title: "parameter.firmware.label") {
                    selectableValue(store.state.info.revision)
                }
                MacSettingsDivider()
                MacSettingsRow(title: "settings.network_interfaces") {
                    selectableValue(
                        store.state.networkHints.isEmpty
                            ? localized("settings.ecm_network.none")
                            : store.state.networkHints.joined(separator: " / ")
                    )
                }
            }

            MacSettingsGroup("settings.group.own_number") {
                MacSettingsRow(
                    title: "settings.own_number.current_label",
                    help: "settings.own_number.current_help"
                ) {
                    Text(currentOwnNumber)
                        .foregroundStyle(
                            store.state.info.ownNumber == "-"
                                ? Color.primary.opacity(0.55)
                                : Color.primary
                        )
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                MacSettingsDivider()

                MacSettingsRow(
                    title: "settings.own_number.edit",
                    help: "parameter.own_number.help"
                ) {
                    HStack(spacing: 8) {
                        TextField(localized("parameter.own_number.label"), text: $ownNumber)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        ApplyButton(
                            help: "settings.own_number.apply",
                            disabled: store.state.busy || sanitizedDialNumber(ownNumber).isEmpty
                        ) {
                            store.setOwnNumber(ownNumber)
                        }
                    }
                }
            }
        }
    }

    private func selectableValue(_ value: String) -> some View {
        Text(localized(value.isEmpty ? "-" : value))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(localizedFormat("common.full_value_help", localized(value.isEmpty ? "-" : value)))
    }

    private var apnProfilesText: String {
        store.state.info.apnProfiles
            .map { "cid\($0.cid): \($0.apn) (\($0.type))" }
            .joined(separator: "\n")
    }

    private func usbModeDescriptionKey(for mode: Int) -> String {
        switch mode {
        case 0: "settings.usb_mode.qmi.description"
        case 1: "settings.usb_mode.ecm.description"
        case 2: "settings.usb_mode.mbim.description"
        case 3: "settings.usb_mode.rndis.description"
        default: "settings.usb_mode.help"
        }
    }

    private func usbModeName(_ mode: Int) -> String {
        switch mode {
        case 0: "QMI"
        case 1: "ECM"
        case 2: "MBIM"
        case 3: "RNDIS"
        default: localized("common.unknown")
        }
    }

    private var currentOwnNumber: String {
        let value = trimmed(store.state.info.ownNumber)
        return value.isEmpty || value == "-"
            ? localized("settings.own_number.not_stored")
            : value
    }

    private func parseUSBMode(_ text: String) -> Int? {
        guard
            let open = text.lastIndex(of: "("),
            let close = text.lastIndex(of: ")"),
            open < close
        else {
            return nil
        }
        return Int(text[text.index(after: open)..<close])
    }
}
