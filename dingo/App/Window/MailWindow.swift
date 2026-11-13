import AppKit
import Eucalyptus

/// The compact toolbar makes the whole titlebar a window-server drag region that ignores the
/// content drawn under it, so a press on a header button would move the window. As in Koala,
/// the window is not movable there and moves itself, and zooms on double-click, from chrome
/// views that allow window moves. Presses on the frame itself (the resize edges) go to AppKit.
final class MailWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, !styleMask.contains(.fullScreen),
              let root = contentView as? MailRootView,
              let hit = root.superview?.hitTest(event.locationInWindow),
              root.isWindowDragRegion(hit), hit.mouseDownCanMoveWindow
        else { return super.sendEvent(event) }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": performMiniaturize(nil)
            case "None": break
            default: performZoom(nil)
            }
        } else {
            performDrag(with: event)
        }
    }

    /// Single-key commands (j, k, e, r…) go to the window model before text views see them,
    /// unless a text field or the compose editor is taking typing.
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Lays out the rail, the middle column, and the detail pane, each with a 40pt header that
/// shares the titlebar's height so every hairline lines up. Frame-based, so a window resize
/// costs one layout pass.
final class MailRootView: NSView {
    let rail: NSView
    let middleHeader = ColumnHeaderView()
    let detailHeader = ColumnHeaderView()
    let middleBody: NSView
    let detailBody: NSView
    private let middleRule = HairlineView()
    private let detailRule = HairlineView()
    private let railEdge = HairlineView()
    private let middleEdge = HairlineView()
    private let divider = ColumnDivider()

    static let railWidth: CGFloat = 76
    static let middleRange: ClosedRange<CGFloat> = 280...520
    private static let widthKey = "MiddleColumnWidth"
    private(set) var middleWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: MailRootView.widthKey)
        return saved > 0 ? min(max(saved, middleRange.lowerBound), middleRange.upperBound) : 340
    }()

    init(rail: NSView, middle: NSView, detail: NSView) {
        self.rail = rail
        middleBody = middle
        detailBody = detail
        super.init(frame: .zero)
        wantsLayer = true
        middleRule.isHorizontal = true
        detailRule.isHorizontal = true
        for view in [rail, middleBody, detailBody, middleHeader, detailHeader, middleRule, detailRule, railEdge, middleEdge, divider] {
            addSubview(view)
        }
        middleHeader.surface = Theme.chromeSurface
        detailHeader.surface = Theme.neutral(0)
        divider.onDrag = { [weak self] delta in
            guard let self else { return }
            middleWidth = min(max(middleWidth + delta, Self.middleRange.lowerBound), Self.middleRange.upperBound)
            UserDefaults.standard.set(middleWidth, forKey: Self.widthKey)
            needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Header backgrounds and labels, and the empty rail top behind the traffic lights.
    /// Buttons answer `mouseDownCanMoveWindow` with false, so they still click.
    func isWindowDragRegion(_ hit: NSView) -> Bool {
        hit is RailDragArea || [middleHeader, detailHeader].contains { hit === $0 || hit.isDescendant(of: $0) }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = resolved(Theme.neutral(0)) }

    override func layout() {
        super.layout()
        let height = bounds.height
        let header = Theme.stripHeight
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        // Narrow windows give the detail pane its room first; the middle column yields down to its floor.
        let middle = min(middleWidth, max(Self.middleRange.lowerBound, bounds.width - Self.railWidth - 360))
        rail.frame = NSRect(x: 0, y: 0, width: Self.railWidth, height: height)
        railEdge.frame = NSRect(x: Self.railWidth - pixel, y: 0, width: pixel, height: height)
        let middleX = Self.railWidth
        middleHeader.frame = NSRect(x: middleX, y: height - header, width: middle, height: header)
        middleRule.frame = NSRect(x: middleX, y: height - header - pixel, width: middle, height: pixel)
        middleBody.frame = NSRect(x: middleX, y: 0, width: middle, height: height - header - pixel)
        let detailX = middleX + middle
        middleEdge.frame = NSRect(x: detailX - pixel, y: 0, width: pixel, height: height)
        divider.frame = NSRect(x: detailX - 3, y: 0, width: 6, height: height - header)
        let detailWidth = max(0, bounds.width - detailX)
        detailHeader.frame = NSRect(x: detailX, y: height - header, width: detailWidth, height: header)
        detailRule.frame = NSRect(x: detailX, y: height - header - pixel, width: detailWidth, height: pixel)
        detailBody.frame = NSRect(x: detailX, y: 0, width: detailWidth, height: height - header - pixel)
    }
}

/// Marks the rail's empty top (behind the traffic lights) as a place the window moves from.
final class RailDragArea: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// A 40pt column header: a title with a count on the leading side, buttons trailing.
/// AppKit, not SwiftUI, so presses on its background move the window and presses on its
/// buttons click them.
final class ColumnHeaderView: NSView {
    var surface: NSColor = Theme.chromeSurface { didSet { needsDisplay = true } }
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var leadingInset: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = Theme.textPrimary
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityRole(.staticText)
        countField.font = Theme.mono(ofSize: 11)
        countField.textColor = Theme.textTertiary
        stack.orientation = .horizontal
        stack.spacing = 2
        for view in [titleField, countField, stack] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = resolved(surface) }

    func set(title: String, count: String? = nil) {
        titleField.stringValue = title
        countField.stringValue = count ?? ""
        countField.isHidden = count == nil
        setAccessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        needsLayout = true
    }

    func set(buttons: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.forEach(stack.addArrangedSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let stackSize = stack.fittingSize
        stack.frame = NSRect(x: bounds.width - stackSize.width - 8, y: (bounds.height - stackSize.height) / 2,
                             width: stackSize.width, height: stackSize.height)
        let count = countField.isHidden ? .zero : countField.fittingSize
        let title = titleField.fittingSize
        let titleWidth = min(title.width, stack.frame.minX - leadingInset - count.width - 16)
        titleField.frame = NSRect(x: leadingInset, y: (bounds.height - title.height) / 2, width: max(0, titleWidth), height: title.height)
        // Count sits on the title's baseline.
        countField.frame = NSRect(x: titleField.frame.maxX + 6, y: titleField.frame.minY + 1, width: count.width, height: count.height)
    }
}

final class HairlineView: NSView {
    var isHorizontal = false
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = resolved(Theme.hairline) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The invisible six-point grip on the middle column's trailing edge.
final class ColumnDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var last: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - last)
        last = x
    }
}
