import AppKit
import DingoKit
import Eucalyptus
import SwiftUI

/// The 76pt rail on strip ground: the traffic lights' 40pt, the five buckets with unread counts,
/// Gmail's own mailboxes, and the account filter at the foot.
final class RailContainerView: NSView {
    private let dragArea = RailDragArea()
    private let hosting: NSHostingView<RailView>

    init(model: MailWindowModel) {
        hosting = NSHostingView(rootView: RailView(model: model))
        hosting.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(dragArea)
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = resolved(Theme.stripGround) }

    override func layout() {
        super.layout()
        dragArea.frame = NSRect(x: 0, y: bounds.height - Theme.stripHeight, width: bounds.width, height: Theme.stripHeight)
        hosting.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Theme.stripHeight)
    }
}

struct RailView: View {
    @Bindable var model: MailWindowModel
    private var accounts: [MailAccount] { AppServices.shared.accounts }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Destination.rail) { destination in
                RailItem(destination: destination, count: count(destination), isSelected: model.destination == destination,
                         shortcut: shortcut(destination)) { model.go(to: destination) }
            }
            RailRule().padding(.vertical, 8)
            ForEach(Mailbox.allCases, id: \.self) { mailbox in
                RailItem(destination: .mailbox(mailbox), count: nil, isSelected: model.destination == .mailbox(mailbox),
                         shortcut: nil) { model.go(to: .mailbox(mailbox)) }
            }
            Spacer(minLength: 8)
            AccountFilterButton(model: model, accounts: accounts)
                .padding(.bottom, 12)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    private func count(_ destination: Destination) -> Int? {
        guard case .bucket(let bucket) = destination else { return nil }
        let count = model.unreadCounts[bucket] ?? 0
        return count > 0 ? count : nil
    }

    private func shortcut(_ destination: Destination) -> String? {
        Destination.rail.firstIndex(of: destination).map { "⌘\($0 + 1)" }
    }
}

/// A 17pt symbol over a 10pt label, with the unread count in 0xProto at the symbol's corner.
/// Selected: primary symbol and label on hover fill; ochre stays on the unread counts.
private struct RailItem: View {
    let destination: Destination
    let count: Int?
    let isSelected: Bool
    let shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    /// The filled variant when selected, where SF Symbols has one.
    private var symbol: String {
        let filled = "\(destination.symbol).fill"
        return isSelected && NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil ? filled : destination.symbol
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 28, height: 22)
                    .overlay(alignment: .topTrailing) {
                        if let count {
                            Text(count > 999 ? "999+" : "\(count)")
                                .font(.mono(size: 9, weight: .bold))
                                .foregroundStyle(Color(nsColor: Theme.onAccent))
                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 14)
                                .background(Capsule().fill(Color(nsColor: Theme.accentText)))
                                .offset(x: 10, y: -5)
                        }
                    }
                Text(destination.title).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(isSelected ? pagePrimary : pageSecondary)
            .frame(width: 64, height: 52)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Color(nsColor: isSelected ? Theme.hoverFill : isHovered ? Theme.neutral(4).withAlphaComponent(0.5) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .dropDestination(for: MessageDrag.self) { drags, _ in
            guard case .bucket(let bucket) = destination else { return false }
            Task {
                var messages: [MailMessage] = []
                for drag in drags {
                    if let message = try? await AppServices.shared.store.message(accountID: drag.accountID, messageID: drag.messageID) {
                        messages.append(message)
                    }
                }
                await AppServices.shared.actions.move(messages, to: bucket, rememberSender: false)
            }
            return true
        } isTargeted: { isHovered = $0 }
        .help(shortcut.map { "\(destination.title) (\($0))" } ?? destination.title)
        .accessibilityLabel(count.map { "\(destination.title), \($0) unread" } ?? destination.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RailRule: View {
    @Environment(\.pixelLength) private var pixel
    var body: some View { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(width: 36, height: pixel) }
}

/// Monogram of the account in view, or a stack for all of them. Its menu picks one or all.
private struct AccountFilterButton: View {
    @Bindable var model: MailWindowModel
    let accounts: [MailAccount]

    var body: some View {
        Menu {
            Button("All Accounts") { model.accountFilter = nil }
            if !accounts.isEmpty { Divider() }
            ForEach(accounts) { account in
                Button(account.email) { model.accountFilter = [account.email] }
            }
            Divider()
            Button("Add Account…") { NSApp.sendAction(#selector(AppDelegate.addAccount(_:)), to: nil, from: nil) }
        } label: {
            Monogram(text: monogram, isAll: model.accountFilter == nil && accounts.count > 1)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(model.accountFilter?.first ?? "All accounts")
        .accessibilityLabel("Accounts: \(model.accountFilter?.first ?? "all")")
    }

    private var monogram: String {
        let email = model.accountFilter?.first ?? (accounts.count == 1 ? accounts[0].email : nil)
        return email.map { String($0.prefix(1)).uppercased() } ?? "All"
    }
}

private struct Monogram: View {
    let text: String
    let isAll: Bool
    var body: some View {
        Text(text)
            .font(.system(size: text.count > 1 ? 10 : 13, weight: .semibold))
            .foregroundStyle(pagePrimary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color(nsColor: Theme.neutral(0))))
            .overlay(Circle().strokeBorder(Color(nsColor: Theme.hairline), lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                if isAll {
                    Circle().strokeBorder(Color(nsColor: Theme.hairline), lineWidth: 1)
                        .background(Circle().fill(Color(nsColor: Theme.neutral(0))))
                        .frame(width: 12, height: 12).offset(x: 3, y: 3)
                }
            }
    }
}
