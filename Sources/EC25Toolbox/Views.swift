import SwiftUI

/// Shared font choices for the compact menu-bar panel.
enum PanelTypography {
    static let metricLabel = Font.caption.weight(.semibold)
    static let metricValue = Font.callout.weight(.semibold)
    static let rowLabel = Font.subheadline
    static let rowValue = Font.subheadline.weight(.medium)
    static let secondary = Font.caption
    static let control = Font.body
}

/// Top-level panel sections.
enum PanelTab: String, CaseIterable, Identifiable {
    case overview
    case phone
    case sms
    case estk
    case vowifi
    case terminal
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: localized("nav.overview")
        case .phone: localized("nav.phone")
        case .sms: localized("nav.sms")
        case .estk: localized("nav.estk")
        case .vowifi: localized("nav.vowifi")
        case .terminal: localized("nav.terminal")
        case .settings: localized("nav.settings")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "antenna.radiowaves.left.and.right"
        case .phone: "phone"
        case .sms: "message"
        case .estk: "simcard.2"
        case .vowifi: "wifi.badge.shield"
        case .terminal: "terminal"
        case .settings: "gearshape"
        }
    }
}

/// Shared root for the menu-bar popover and standalone native window.
struct StatusWindowView: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var presentation: WindowPresentationModel
    let surface: PresentationSurface

    var body: some View {
        VStack(spacing: 0) {
            AppChrome(surface: surface)
            PanelTabPicker(selectedTab: $presentation.selectedTab)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            PanelContent(selectedTab: presentation.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Segmented controls and NSViewRepresentable-backed pickers cache
        // localized titles. Recreate the SwiftUI subtree when the user changes
        // language so every native control updates in the same transaction.
        .id(store.settings.preferredLanguage ?? "")
        .onChange(of: store.state.estk.availability) { _, availability in
            if !availability.shouldShowTab, presentation.selectedTab == .estk {
                presentation.selectedTab = .overview
            }
        }
        // NSPopover owns the menu-bar panel width. Keep the SwiftUI root free
        // of a second popover-width constraint so there is one source of truth.
        .frame(minWidth: surface == .standaloneWindow ? 720 : nil)
    }
}

/// Header area containing device status and refresh action.
struct AppChrome: View {
    @EnvironmentObject private var store: ModemStore
    @EnvironmentObject private var presentation: WindowPresentationModel
    let surface: PresentationSurface

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.state.remoteManagement.mode == .remote
                ? "network.badge.shield.half.filled"
                : "antenna.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(localized("app.name"))
                        .font(.headline.weight(.semibold))
                    Text(localized(store.state.remoteManagement.mode.localizationKey))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(store.state.connected ? store.state.usbDescription : localized("device.waiting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(localizedFormat(
                        "common.full_value_help",
                        store.state.connected ? store.state.usbDescription : localized("device.waiting")
                    ))
            }

            Spacer(minLength: 8)

            StatusLabel(text: store.statusText, color: statusColor)

            if surface == .popover {
                Button {
                    presentation.togglePopoverPinned()
                } label: {
                    Image(systemName: presentation.isPopoverPinned ? "pin.slash" : "pin")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(localized(
                    presentation.isPopoverPinned ? "action.unpin_popover" : "action.pin_popover"
                ))

                Button {
                    presentation.openStandaloneWindow()
                } label: {
                    Image(systemName: "macwindow")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(localized("action.open_standalone_window"))
            }

            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, value: store.state.refreshing)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized("action.refresh_status"))
            .disabled(store.state.busy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var statusColor: Color {
        store.state.connected || store.state.busy || store.state.refreshing ? .accentColor : .secondary
    }
}

/// Native segmented picker used for top-level panel navigation.
struct PanelTabPicker: View {
    @EnvironmentObject private var store: ModemStore
    @Binding var selectedTab: PanelTab

    private var visibleTabs: [PanelTab] {
        PanelTab.allCases.filter { tab in
            tab != .estk || store.state.estk.availability.shouldShowTab
        }
    }

    var body: some View {
        Picker(localized("nav.view"), selection: $selectedTab) {
            ForEach(visibleTabs) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .frame(maxWidth: .infinity, minHeight: 28)
    }
}

/// Selected panel page content.
struct PanelContent: View {
    var selectedTab: PanelTab

    var body: some View {
        switch selectedTab {
        case .overview:
            OverviewView()
        case .phone:
            PhoneView()
        case .sms:
            SMSView()
        case .estk:
            ESTKView()
        case .vowifi:
            VoWiFiView()
        case .terminal:
            TerminalView()
        case .settings:
            SettingsView()
        }
    }
}
