import AppKit
import DingoKit
import Eucalyptus
import SwiftUI
import UniformTypeIdentifiers

/// A compose window: header fields, the editor, attachments, and Send (⌘↩).
@MainActor
final class ComposeWindowController: NSWindowController, NSWindowDelegate {
    let draft: ComposeDraft
    var onClose: (() -> Void)?

    init(draft: ComposeDraft) {
        self.draft = draft
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.title = draft.subject.isEmpty ? "New Message" : draft.subject
        window.contentView = NSHostingView(rootView: ComposeView(draft: draft, close: { [weak self] in self?.finish() }))
        window.delegate = self
        window.setFrameAutosaveName("DingoCompose")
        if let main = NSApp.mainWindow, main.windowController is MailWindowController {
            window.setFrameTopLeftPoint(NSPoint(x: main.frame.midX - 340, y: main.frame.maxY - 60))
        } else {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var closing = false

    private func finish() {
        closing = true
        window?.close()
    }

    /// Closing keeps the message as a Gmail draft; an empty one goes away silently.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closing, draft.state != .sent else { return true }
        if draft.isEmpty {
            Task { await draft.discard() }
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Keep this message as a draft?"
        alert.informativeText = "Drafts are saved in Gmail, so you can finish it here or on any device."
        alert.addButton(withTitle: "Save Draft")
        alert.addButton(withTitle: "Delete Draft")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: Task { await self.draft.save(); self.finish() }
            case .alertSecondButtonReturn: Task { await self.draft.discard(); self.finish() }
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct ComposeView: View {
    @Bindable var draft: ComposeDraft
    let close: () -> Void
    @FocusState private var focus: Field?
    @State private var isDropTarget = false

    enum Field: Hashable { case to, cc, bcc, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            // The titlebar's 28pt carry the window's title and the send state, past the traffic lights.
            HStack(spacing: 10) {
                Text(draft.subject.isEmpty ? "New Message" : draft.subject).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pagePrimary).lineLimit(1)
                Spacer()
                StateText(state: draft.state)
            }
            .padding(.leading, 80).padding(.trailing, 14).frame(height: 28)
            VStack(spacing: 0) {
                FromRow(draft: draft)
                AddressRow(label: "To", text: $draft.to, focus: $focus, field: .to) {
                    if !draft.showsCcBcc {
                        TextButton("Cc/Bcc") { draft.showsCcBcc = true; focus = .cc }
                    }
                }
                if draft.showsCcBcc {
                    AddressRow(label: "Cc", text: $draft.cc, focus: $focus, field: .cc) { EmptyView() }
                    AddressRow(label: "Bcc", text: $draft.bcc, focus: $focus, field: .bcc) { EmptyView() }
                }
                FieldRow(label: "Subject") {
                    TextField("", text: $draft.subject).textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                        .focused($focus, equals: .subject).accessibilityLabel("Subject")
                }
            }
            ComposeEditor(text: $draft.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let quoted = draft.quoted {
                Text(quoted).font(.system(size: 11)).foregroundStyle(pageTertiary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 6)
                    .help("The original message is quoted below your reply when it is sent.")
            }
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(draft.attachments.enumerated()), id: \.offset) { index, attachment in
                            HStack(spacing: 6) {
                                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(pageTertiary)
                                Text(attachment.filename).font(.system(size: 12)).lineLimit(1)
                                FigureText(text: ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                Button { draft.attachments.remove(at: index) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(pageTertiary).accessibilityLabel("Remove \(attachment.filename)")
                            }
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Color(nsColor: Theme.neutral(2))))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            SettingsRule()
            HStack(spacing: 8) {
                Button { attach() } label: { Label("Attach", systemImage: "paperclip") }
                    .help("Attach Files (⇧⌘A)").keyboardShortcut("a", modifiers: [.command, .shift])
                Spacer()
                Button("Send") { Task { if await draft.send() { close() } } }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.state == .sending)
                    .help("Send (⌘↩)")
            }
            .padding(.horizontal, 16).frame(height: 48)
        }
        .background(Color(nsColor: Theme.neutral(0)))
        .ignoresSafeArea(edges: .top)
        .overlay { if isDropTarget { RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(pageAccent, lineWidth: 2).padding(4) } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addFile(url) }
                }
            }
            return true
        }
        .onAppear { focus = draft.to.isEmpty ? .to : draft.subject.isEmpty ? .subject : nil }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addFile)
    }

    private func addFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        draft.attachments.append(.init(filename: url.lastPathComponent, mimeType: type, data: data))
    }
}

private struct StateText: View {
    let state: ComposeDraft.State
    var body: some View {
        switch state {
        case .saving: Text("Saving…").font(.system(size: 11)).foregroundStyle(pageTertiary)
        case .saved(let date): Text("Draft saved \(date.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(pageTertiary)
        case .sending: Text("Sending…").font(.system(size: 11)).foregroundStyle(pageTertiary)
        case .failed(let message): Text(message).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.fail)).lineLimit(1)
        default: EmptyView()
        }
    }
}

/// Label column at 56pt and an 8pt gap, field after it, hairline below: the same anatomy for every header field.
private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundStyle(pageTertiary).frame(width: 56, alignment: .trailing)
                content
            }
            .padding(.horizontal, 12).frame(minHeight: 36)
            SettingsRule()
        }
    }
}

private struct FromRow: View {
    @Bindable var draft: ComposeDraft
    var body: some View {
        let senders = AppServices.shared.senders
        FieldRow(label: "From") {
            if senders.count > 1 {
                Picker("From", selection: Binding(get: { draft.from.email }, set: { email in
                    if let sender = senders.first(where: { $0.email == email }) { draft.from = sender }
                })) {
                    ForEach(senders, id: \.email) { Text($0.fieldText).tag($0.email) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer()
            } else {
                Text(draft.from.fieldText).font(.system(size: 13)).foregroundStyle(pagePrimary)
                Spacer()
            }
        }
    }
}

/// An address field with completions from everyone you've had mail from or sent mail to.
private struct AddressRow<Trailing: View>: View {
    let label: String
    @Binding var text: String
    var focus: FocusState<ComposeView.Field?>.Binding
    let field: ComposeView.Field
    @ViewBuilder var trailing: Trailing
    @State private var suggestions: [EmailAddress] = []

    var body: some View {
        FieldRow(label: label) {
            TextField("", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                .focused(focus, equals: field)
                .accessibilityLabel(label)
                .popover(isPresented: Binding(get: { !suggestions.isEmpty && focus.wrappedValue == field }, set: { if !$0 { suggestions = [] } }),
                         attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions.prefix(6), id: \.email) { address in
                            Button { complete(with: address) } label: {
                                HStack {
                                    Text(address.name ?? address.email).font(.system(size: 13)).foregroundStyle(pagePrimary)
                                    if address.name != nil { Text(address.email).font(.mono(size: 11)).foregroundStyle(pageTertiary) }
                                    Spacer()
                                }
                                .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4).frame(width: 320)
                }
                .onChange(of: text) { _, value in
                    let fragment = value.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    guard fragment.count >= 2, !fragment.contains("<") else { suggestions = []; return }
                    Task { suggestions = await AppServices.shared.contacts(matching: fragment) }
                }
            trailing
        }
    }

    private func complete(with address: EmailAddress) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(address.fieldText)
        text = parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
        suggestions = []
    }
}
