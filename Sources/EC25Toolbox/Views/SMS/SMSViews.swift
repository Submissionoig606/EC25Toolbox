import SwiftUI

/// Grouped SMS conversation used by the message list.
struct Conversation: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var messages: [SMSMessage]
    var last: SMSMessage
    var unread: Int
}

/// Apple Messages-style SMS center with a conversation sidebar and persistent thread detail.
struct SMSView: View {
    @EnvironmentObject private var store: ModemStore
    @State private var activeSender: String?
    @State private var draftTo = ""
    @State private var draftBody = ""

    private var conversations: [Conversation] {
        let groups = Dictionary(grouping: store.state.messages) { message in
            message.sender.isEmpty || message.sender == "-" ? localized("common.unknown") : message.sender
        }
        return groups.compactMap { key, messages in
            let sorted = messages.sorted {
                if $0.date == $1.date { return $0.index < $1.index }
                return $0.date < $1.date
            }
            guard let last = sorted.last else { return nil }
            return Conversation(key: key, messages: sorted, last: last, unread: sorted.filter(\.unread).count)
        }
        .sorted { $0.last.date > $1.last.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader

            HStack(spacing: 0) {
                conversationSidebar
                    .frame(width: 260)

                Divider().opacity(0.55)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: selectInitialConversation)
        .onChange(of: conversations.map(\.id)) { _, _ in
            keepSelectionValid()
        }
    }

    private var pageHeader: some View {
        PageHeader(
            title: "sms.center",
            subtitle: localizedFormat("sms.conversations_count", conversations.count),
            systemImage: "message"
        ) {
            Button {
                store.markAllRead()
            } label: {
                Image(systemName: "envelope.open")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized("sms.mark_all_read"))
            .disabled(store.state.unreadCount == 0 || store.state.busy)

            Button {
                draftTo = ""
                draftBody = ""
                activeSender = ""
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized("sms.new_message"))

            Button {
                store.refreshMessages()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized("sms.refresh"))
            .disabled(store.state.busy)
        }
    }

    private var conversationSidebar: some View {
        VStack(spacing: 0) {
            if conversations.isEmpty {
                EmptyState(title: "sms.empty.title", subtitle: "sms.empty.description", systemImage: "message")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                List(selection: selectedConversation) {
                    ForEach(conversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.key)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Divider().opacity(0.45)

            backupFooter
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.28))
    }

    @ViewBuilder
    private var detail: some View {
        if let sender = activeSender {
            ThreadView(
                sender: sender,
                conversation: conversations.first { $0.key == sender },
                draftTo: $draftTo,
                draftBody: $draftBody
            )
        } else {
            EmptyState(
                title: "sms.select_conversation.title",
                subtitle: "sms.select_conversation.description",
                systemImage: "message"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var backupFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: store.state.smsBackup.iCloudBackupPath == nil ? "externaldrive" : "icloud.and.arrow.up")
                Text(backupStatusText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(localizedFormat("common.full_value_help", backupStatusText))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button(localized("sms.backup.restore")) {
                    store.restoreSMSFromICloudDrive()
                }
                .disabled(store.state.busy || store.state.smsBackup.iCloudBackupPath == nil)

                Button(localized("sms.backup.now")) {
                    store.backupSMSNow()
                }
                .disabled(store.state.busy || store.state.smsBackup.iCloudBackupPath == nil)
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    private var backupStatusText: String {
        if let error = store.state.smsBackup.lastError {
            return error
        }
        if let date = store.state.smsBackup.lastBackupAt {
            return localizedFormat("sms.backup.last", date.formatted(date: .abbreviated, time: .shortened))
        }
        return localized(store.state.smsBackup.iCloudBackupPath == nil ? "sms.backup.local_only" : "sms.backup.ready")
    }

    private var selectedConversation: Binding<String?> {
        Binding {
            activeSender
        } set: { newValue in
            guard let sender = newValue else {
                activeSender = nil
                return
            }
            activeSender = sender
            draftTo = sender
            if conversations.first(where: { $0.key == sender })?.unread ?? 0 > 0 {
                store.markConversationRead(sender: sender)
            }
        }
    }

    private func selectInitialConversation() {
        guard activeSender == nil, let first = conversations.first else { return }
        activeSender = first.key
        draftTo = first.key
        if first.unread > 0 {
            store.markConversationRead(sender: first.key)
        }
    }

    private func keepSelectionValid() {
        guard let activeSender else {
            selectInitialConversation()
            return
        }
        if activeSender.isEmpty { return }
        guard conversations.contains(where: { $0.key == activeSender }) else {
            self.activeSender = conversations.first?.key
            draftTo = conversations.first?.key ?? ""
            return
        }
    }
}

struct ConversationRow: View {
    var conversation: Conversation

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(conversation.unread > 0 ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                Text(avatarText(conversation.key))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(conversation.unread > 0 ? Color.accentColor : Color.secondary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(localized(conversation.key))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .help(localizedFormat("common.full_value_help", localized(conversation.key)))
                    Spacer(minLength: 6)
                    Text(conversation.last.date.components(separatedBy: ",").first ?? conversation.last.date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(conversation.last.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(localizedFormat("common.full_value_help", conversation.last.body))
            }

            Text(conversation.unread > 0 ? "\(conversation.unread)" : "\(conversation.messages.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(conversation.unread > 0 ? Color.accentColor : Color.secondary)
                .frame(minWidth: 20)
        }
        .padding(.vertical, 4)
    }

    private func avatarText(_ name: String) -> String {
        let digits = name.filter(\.isNumber)
        if digits.count >= 2 { return String(digits.suffix(2)) }
        return String(name.prefix(2)).uppercased()
    }
}

struct ThreadView: View {
    @EnvironmentObject private var store: ModemStore
    var sender: String
    var conversation: Conversation?
    @Binding var draftTo: String
    @Binding var draftBody: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "person.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(sender.isEmpty ? localized("sms.new_message") : sender)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(conversation.map { localizedFormat("sms.messages_count", $0.messages.count) } ?? localized("sms.new_conversation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                if let conversation {
                    Button {
                        conversation.messages.forEach { store.deleteSMS($0) }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(localized("sms.clear_conversation"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.45)

            ScrollView {
                LazyVStack(spacing: 9) {
                    if let conversation {
                        ForEach(conversation.messages) { message in
                            MessageBubble(message: message)
                        }
                    } else {
                        EmptyState(title: "sms.compose.empty_title", subtitle: "sms.compose.empty_description", systemImage: "square.and.pencil")
                            .frame(height: 220)
                    }
                }
                .padding(12)
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])

            ComposerCard(draftTo: $draftTo, draftBody: $draftBody, sender: sender)
                .padding(10)
        }
    }
}

struct ComposerCard: View {
    @EnvironmentObject private var store: ModemStore
    @Binding var draftTo: String
    @Binding var draftBody: String
    var sender: String

    var body: some View {
        VStack(spacing: 7) {
            if sender.isEmpty {
                TextField(localized("sms.recipient.placeholder"), text: $draftTo)
                    .textFieldStyle(.plain)
                    .font(PanelTypography.control)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help(localized("sms.recipient.help"))
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(localized("sms.body.placeholder"), text: $draftBody, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .help(localized("sms.body.help"))

                Button {
                    store.sendSMS(to: draftTo, body: draftBody)
                    draftBody = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .help(localized("action.send"))
                .disabled(store.state.busy || trimmed(draftTo).isEmpty || trimmed(draftBody).isEmpty)
            }
        }
    }
}

struct MessageBubble: View {
    @EnvironmentObject private var store: ModemStore
    var message: SMSMessage

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 42) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 6) {
                Text(message.body)
                    .font(.subheadline)
                    .textSelection(.enabled)
                Text(message.date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(message.outgoing ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                Button(localized("action.delete"), role: .destructive) {
                    store.deleteSMS(message)
                }
            }
            if !message.outgoing { Spacer(minLength: 42) }
        }
    }
}
