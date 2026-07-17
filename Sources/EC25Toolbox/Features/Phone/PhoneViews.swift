import SwiftUI

private enum PhoneCategory: String, CaseIterable, Identifiable {
    case dialer
    case history

    var id: String { rawValue }
    var title: String { "phone.\(rawValue).title" }
    var description: String { "phone.\(rawValue).description" }

    var systemImage: String {
        switch self {
        case .dialer: "circle.grid.3x3"
        case .history: "clock"
        }
    }
}

/// Voice-call page for dialing and reviewing the local call event log.
struct PhoneView: View {
    @EnvironmentObject private var store: ModemStore
    @State private var selectedCategory: PhoneCategory = .dialer
    @State private var number = ""

    private let keypad = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"]
    ]

    var body: some View {
        SettingsCategoryLayout(selection: selectedCategory) { compact in
            phoneSidebar(compact: compact)
        } header: {
            SettingsCategoryHeader(
                title: selectedCategory.title,
                description: selectedCategory.description,
                systemImage: selectedCategory.systemImage
            )
        } content: {
            categoryContent
        }
    }

    private func phoneSidebar(compact: Bool) -> some View {
        VStack(spacing: 5) {
            ForEach(PhoneCategory.allCases) { category in
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
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .dialer:
            dialer
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity, alignment: .top)
        case .history:
            callHistory
        }
    }

    private var dialer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: store.state.activeCallNumber == nil ? "phone" : "phone.connection.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(store.state.activeCallNumber == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 20)

                Text(activeCallStatus)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(store.state.activeCallNumber == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .help(activeCallStatus)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            TextField(localized("phone.number.placeholder"), text: $number)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: 38)
                .textSelection(.enabled)
                .help(localized("phone.number.help"))

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 14), count: 3), spacing: 10) {
                ForEach(keypad.flatMap { $0 }, id: \.self) { key in
                    DialKey(key: key) {
                        number.append(key)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 14), count: 3), spacing: 0) {
                PhoneCircleButton(systemImage: "delete.left", accessibilityLabel: "action.delete", disabled: number.isEmpty) {
                    number = String(number.dropLast())
                }
                .buttonRepeatBehavior(.enabled)

                PhoneCircleButton(systemImage: "phone.fill", accessibilityLabel: "action.call", prominent: true, disabled: store.state.busy || sanitizedDialNumber(number).isEmpty) {
                    store.dial(number: number)
                }

                PhoneCircleButton(systemImage: "phone.down.fill", accessibilityLabel: "action.hang_up", disabled: store.state.busy || !store.state.connected) {
                    store.hangUp()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var callHistory: some View {
        if store.state.callLog.isEmpty {
            EmptyState(title: "phone.history.empty_title", subtitle: "phone.history.empty_description", systemImage: "phone")
                .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            MacSettingsContentCard {
                VStack(spacing: 12) {
                    ForEach(store.state.callLog) { event in
                        CallEventRow(event: event)
                    }
                }
            }
        }
    }

    private var activeCallStatus: String {
        store.state.activeCallNumber.map {
            localizedFormat("phone.active_call.number", $0)
        } ?? localized("phone.active_call.none")
    }
}

/// Single dial-pad key.
struct DialKey: View {
    var key: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(key)
                .font(.title3.weight(.medium))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.34), in: Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .help(localizedFormat("phone.key_input", key))
    }
}

/// Circular action button matching the dial-pad layout.
struct PhoneCircleButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var prominent = false
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .background(buttonFill, in: Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
        .accessibilityLabel(localized(accessibilityLabel))
        .help(localized(accessibilityLabel))
    }

    private var buttonFill: Color {
        prominent ? Color.accentColor : Color.secondary.opacity(0.16)
    }
}

/// Row describing one optional phone call event.
struct CallEventRow: View {
    var event: CallEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.failed ? "exclamationmark.triangle" : "phone")
                .foregroundStyle(event.failed ? Color.secondary : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(event.title))
                    .font(.subheadline.weight(.medium))
                Text(localized(event.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(event.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
