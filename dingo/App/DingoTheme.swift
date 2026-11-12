import AppKit
import Eucalyptus

/// Row fills, each an opaque step on the neutral ramp, chosen per appearance so hover and
/// selection always differ from the column and from each other.
@MainActor
enum RowFill {
    /// Light: step 2 over chrome surface (step 1). Dark: step 3 over chrome surface (step 2).
    static let hover = cross(light: 2, dark: 3, name: "rowHover")
    /// Step 4 in both: one clear step past hover.
    static let selected = cross(light: 4, dark: 4, name: "rowSelected")

    private static func cross(light: Int, dark: Int, name: String) -> NSColor {
        let lightColor = Theme.neutral(light), darkColor = Theme.neutral(dark)
        return NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}

extension Theme.Accent {
    /// Dingo ochre, from a dingo's coat. The fill marks focus and selection (3.9:1 on chrome
    /// surface, above the 3:1 non-text floor); the deeper text variant carries labels and filled
    /// buttons at 5.2:1. In dark appearance one lighter ochre does both, with dark text on it.
    static let dingoOchre = Theme.Accent(fill: .init(0xC2631C, 0xF0904A), text: .init(0xA8520F, 0xF0904A),
                                         onFill: .init(0xFFFFFF, 0x2A1406))
}
