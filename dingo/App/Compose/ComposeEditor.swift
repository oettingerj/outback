import AppKit
import Eucalyptus
import SwiftUI

/// The message editor: an NSTextView with system rich text (⌘B, ⌘I, ⌘K for links), smart
/// quotes and spelling on, and paste that keeps formatting but drops foreign fonts and colors.
struct ComposeEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString

    static let typingAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.textColor,
    ]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = true
        view.allowsUndo = true
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticLinkDetectionEnabled = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 16, height: 14)
        view.typingAttributes = Self.typingAttributes
        view.insertionPointColor = Theme.accent
        view.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.25)]
        view.linkTextAttributes = [.foregroundColor: Theme.accentText, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.textStorage?.setAttributedString(text)
        view.setAccessibilityLabel("Message")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, !context.coordinator.isEditing,
              view.attributedString() != text else { return }
        view.textStorage?.setAttributedString(text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeEditor
        var isEditing = false

        init(_ parent: ComposeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = view.attributedString()
            isEditing = false
        }
    }

    /// Plain text and HTML parts. The HTML carries bold, italic, underline, and links only, in
    /// the recipient's own font; the quote follows as a blockquote.
    static func parts(_ text: NSAttributedString, quote: String?) -> (text: String, html: String) {
        var plain = text.string
        var html = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var run = MessageHTML.escape((text.string as NSString).substring(with: range)).replacingOccurrences(of: "\n", with: "<br>\n")
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { run = "<b>\(run)</b>" }
                if traits.contains(.italic) { run = "<i>\(run)</i>" }
            }
            if attributes[.underlineStyle] != nil, attributes[.link] == nil { run = "<u>\(run)</u>" }
            if let link = attributes[.link] {
                let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                run = "<a href=\"\(MessageHTML.escape(href))\">\(run)</a>"
            }
            html += run
        }
        if let quote, !quote.isEmpty {
            plain += "\n\n" + quote
            let lines = quote.components(separatedBy: "\n")
            let header = MessageHTML.escape(lines.first ?? "")
            let body = lines.dropFirst().map { MessageHTML.escape($0.hasPrefix("> ") ? String($0.dropFirst(2)) : $0) }.joined(separator: "<br>\n")
            html += "<br><br>\n<div>\(header)</div>\n<blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(body)</blockquote>"
        }
        return (plain, "<div dir=\"auto\">\(html)</div>")
    }
}
