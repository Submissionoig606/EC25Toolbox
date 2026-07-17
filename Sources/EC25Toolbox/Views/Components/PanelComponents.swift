import AppKit
import SwiftUI

/// Native macOS pop-up button whose selected value is aligned to the trailing edge.
struct RightAlignedMenuPicker<Value: Hashable>: NSViewRepresentable {
    struct Option {
        var title: String
        var value: Value
    }

    @Binding var selection: Value
    var options: [Option]

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.bezelStyle = .rounded
        button.alignment = .right
        button.cell?.alignment = .right
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self

        button.removeAllItems()
        button.addItems(withTitles: options.map(\.title))
        button.alignment = .right
        button.cell?.alignment = .right

        if let index = options.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var parent: RightAlignedMenuPicker

        init(parent: RightAlignedMenuPicker) {
            self.parent = parent
        }

        @MainActor @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}

/// Shared rounded surface used by settings rows and richer feature cards.
struct MacSettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.58),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

/// macOS Settings-style group with a small category label and rounded row container.
struct MacSettingsGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 14)

            MacSettingsCard {
                content
            }
        }
    }
}

/// Aligned label/help/control row used by the categorized Settings pages.
struct MacSettingsRow<Control: View>: View {
    var title: String
    var help: String?
    @ViewBuilder var control: Control

    init(
        title: String,
        help: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: help == nil ? 0 : 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(localized(title))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 10)

                control
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let help {
                Text(localized(help))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
        .help(help.map(localized) ?? localized(title))
    }
}

/// Right-aligned native switch row matching macOS Settings.
struct MacSettingsToggleRow: View {
    var title: String
    var help: String?
    @Binding var isOn: Bool

    var body: some View {
        MacSettingsRow(title: title, help: help) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
        }
    }
}

/// Inset separator aligned with macOS Settings row labels.
struct MacSettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
            .opacity(0.48)
    }
}

/// Settings-style rounded content group for feature pages that need richer layouts than a single row.
struct MacSettingsContentGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        MacSettingsGroup(title) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Rich settings-style content without a second section title.
struct MacSettingsContentCard<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        MacSettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Section label plus parameter tiles without an additional enclosing card.
/// This avoids a visually heavy card-within-card hierarchy.
struct MacSettingsParameterGroup: View {
    var title: String
    var values: [ParameterValue]
    var columnCount = 2
    var fullValueDisplay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 7)

            ParameterGrid(
                values: values,
                columnCount: columnCount,
                fullValueDisplay: fullValueDisplay
            )
        }
    }
}

/// Heading for one settings category detail page.
struct SettingsCategoryHeader<Actions: View>: View {
    var title: String
    var description: String
    var systemImage: String
    @ViewBuilder var actions: Actions

    init(
        title: String,
        description: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(localized(title))
                    .font(.title3.weight(.semibold))
                Text(localized(description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsCategoryHeader where Actions == EmptyView {
    init(title: String, description: String, systemImage: String) {
        self.init(title: title, description: description, systemImage: systemImage) {
            EmptyView()
        }
    }
}

/// Shared sidebar-detail composition for categorized feature pages.
struct SettingsCategoryLayout<Selection: Hashable, Sidebar: View, Header: View, Content: View>: View {
    var selection: Selection
    private var sidebar: (Bool) -> Sidebar
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    init(
        selection: Selection,
        @ViewBuilder sidebar: @escaping (Bool) -> Sidebar,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.selection = selection
        self.sidebar = sidebar
        self.header = header()
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let compactSidebar = geometry.size.width < 680

            HStack(spacing: 0) {
                sidebar(compactSidebar)
                    .frame(width: compactSidebar ? 62 : 185)

                Divider().opacity(0.55)

                ScrollView {
                    VStack(alignment: .leading, spacing: compactSidebar ? 14 : 18) {
                        header
                        content
                    }
                    .padding(.horizontal, compactSidebar ? 14 : 18)
                    .padding(.top, 10)
                    .padding(.bottom, compactSidebar ? 14 : 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .id(selection)
            }
        }
    }
}

/// Responsive category button shared by Settings-style sidebars.
struct SettingsSidebarButton: View {
    var title: String
    var systemImage: String
    var isSelected: Bool
    var compact: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if compact {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48, height: 48, alignment: .center)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 24, height: 24)
                    Text(localized(title))
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 42)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.78))
        .background(
            isSelected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .help(localized(title))
        .accessibilityLabel(localized(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Compact checkbox cell used by the overview field picker.
struct FieldToggleCell: View {
    var label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(localized(label), isOn: $isOn)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .help(ParameterHelp.text(for: label))
    }
}

/// Labeled row that hosts a native picker, stepper, or other AppKit-style control.
struct SettingsPickerRow<Control: View>: View {
    var title: String
    var help: String?
    @ViewBuilder var control: Control

    init(title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(localized(title))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .layoutPriority(1)
            Spacer(minLength: 12)
            control
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
        .help(help.map(localized) ?? localized(title))
    }
}

/// Compact number plus native stepper used in trailing settings controls.
struct CompactNumericStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            Text(String(value))
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .trailing)

            Stepper(value: $value, in: range) {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
        }
        .fixedSize()
    }
}

/// Fixed-size apply button used by settings rows.
struct ApplyButton: View {
    var help: String
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .frame(width: 46)
        .help(localized(help))
        .disabled(disabled)
    }
}

/// Reusable page header with an SF Symbol, title, subtitle, and optional actions.
struct PageHeader<Actions: View>: View {
    static var height: CGFloat { 42 }

    var title: String
    var subtitle: String
    var systemImage: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(localized(title))
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .help(localizedFormat("common.full_value_help", localized(title)))
                Text(localized(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(localizedFormat("common.full_value_help", localized(subtitle)))
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                actions
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.45)
        }
    }
}

/// Lightweight section container for grouped panel content.
struct SectionCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    var fillHeight: Bool
    @ViewBuilder var content: Content

    init(
        title: String? = nil,
        systemImage: String? = nil,
        fillHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.fillHeight = fillHeight
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let title, let systemImage {
                    Label(localized(title), systemImage: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                content
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: fillHeight ? .infinity : nil,
                alignment: .topLeading
            )
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: fillHeight ? .infinity : nil,
            alignment: .topLeading
        )
    }
}

/// Native label used for connectivity and progress status.
struct StatusLabel: View {
    var text: String
    var color: Color

    var body: some View {
        Label {
            Text(localized(text))
        } icon: {
            Image(systemName: systemImage)
                .symbolEffect(.pulse, value: isBusy)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .help(localized("status.help"))
    }

    private var isBusy: Bool {
        text == "status.working" || text == "status.connecting"
    }

    private var systemImage: String {
        switch text {
        case "status.online": "checkmark.circle.fill"
        case "status.offline": "xmark.circle"
        default: "arrow.triangle.2.circlepath"
        }
    }
}

/// SF Symbol based signal visualization for radio quality cards.
struct SignalBars: View {
    var level: Int
    var color: Color

    var body: some View {
        Image(systemName: "cellularbars", variableValue: Double(normalizedLevel) / 4.0)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(color)
        .accessibilityLabel(localizedFormat("accessibility.signal_bars", level))
    }

    private var normalizedLevel: Int {
        min(max(level, 0), 4)
    }
}

/// Standard two-column label/value row.
struct KeyValueRow: View {
    var label: String
    var value: String
    var labelWidth: CGFloat = 88

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(localized(label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .trailing)
                .help(ParameterHelp.text(for: label))
            Text(localized(value.isEmpty ? "-" : value))
                .font(PanelTypography.rowValue)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(localizedFormat(
                    "common.full_value_help",
                    localized(value.isEmpty ? "-" : value)
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One value in a compact multi-column parameter grid.
struct ParameterValue: Identifiable {
    var id: String { label }
    var label: String
    var value: String
}

/// Dense label-over-value grid used for at-a-glance modem data.
struct ParameterGrid: View {
    var values: [ParameterValue]
    var columnCount = 2
    var fullValueDisplay = false
    var showsCellBackground = true

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .topLeading), count: columnCount)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(values) { item in
                let displayValue = localized(item.value.isEmpty ? "-" : item.value)
                VStack(alignment: .leading, spacing: 1) {
                    Text(localized(item.label))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(fullValueDisplay ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(ParameterHelp.text(for: item.label))
                    Text(displayValue)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(fullValueDisplay ? nil : 2)
                        .truncationMode(.middle)
                        .minimumScaleFactor(fullValueDisplay ? 1 : 0.82)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(localizedFormat("common.full_value_help", displayValue))
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, showsCellBackground ? 7 : 0)
                .padding(.vertical, showsCellBackground ? 4 : 2)
                .background(
                    showsCellBackground
                        ? Color(nsColor: .controlBackgroundColor).opacity(0.38)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Placeholder shown when a feature has no rows to display.
struct EmptyState: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tertiary)

            Text(localized(title))
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(localized(subtitle))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Returns whether a modem value should be treated as missing.
func isPlaceholder(_ value: String) -> Bool {
    let clean = trimmed(value)
    return clean.isEmpty || clean == "-"
}

/// Returns a display value only when it is not a placeholder.
func firstPresent(_ value: String) -> String? {
    isPlaceholder(value) ? nil : value
}
