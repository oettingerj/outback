import AppKit
import Eucalyptus

extension Theme.Accent {
    /// Dingo ochre, from a dingo's coat. The fill marks focus and selection (3.9:1 on chrome
    /// surface, above the 3:1 non-text floor); the deeper text variant carries labels and filled
    /// buttons at 5.2:1. In dark appearance one lighter ochre does both, with dark text on it.
    static let dingoOchre = Theme.Accent(fill: .init(0xC2631C, 0xF0904A), text: .init(0xA8520F, 0xF0904A),
                                         onFill: .init(0xFFFFFF, 0x2A1406))
}
