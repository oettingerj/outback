import AppKit
import DingoKit
import Eucalyptus

/// The move's one authored moment: an ochre chip leaves the detail pane and lands on the rail
/// item, which then swells once. 200ms, ease-out; nothing under Reduce Motion.
@MainActor
enum BucketFlight {
    static func launch(to bucket: Bucket) {
        guard !Theme.reduceMotion,
              let controller = NSApp.keyWindow?.windowController as? MailWindowController,
              let root = controller.window?.contentView as? MailRootView,
              let index = Destination.rail.firstIndex(of: .bucket(bucket)),
              let host = root.layer else { return }
        // Rail items are 52pt tall with 2pt spacing, below the 40pt titlebar and a 4pt inset.
        let itemCenter = CGPoint(x: MailRootView.railWidth / 2,
                                 y: root.bounds.height - Theme.stripHeight - 4 - CGFloat(index) * 54 - 26)
        let start = CGPoint(x: root.detailHeader.frame.minX + 40, y: root.detailHeader.frame.minY - 40)
        let chip = CALayer()
        chip.bounds = CGRect(x: 0, y: 0, width: 28, height: 20)
        chip.cornerRadius = 6
        chip.cornerCurve = .continuous
        chip.backgroundColor = root.resolved(Theme.accent)
        chip.position = itemCenter
        chip.opacity = 0
        chip.zPosition = 100
        host.addSublayer(chip)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            chip.removeFromSuperlayer()
            pulse(root.rail, at: itemCenter)
        }
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = start
        move.toValue = itemCenter
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.4
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.8, 1]
        let group = CAAnimationGroup()
        group.animations = [move, shrink, fade]
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        chip.add(group, forKey: "flight")
        CATransaction.commit()
    }

    /// A soft ring that swells and fades around the rail item.
    private static func pulse(_ rail: NSView, at center: CGPoint) {
        guard let layer = rail.layer else { return }
        let ring = CALayer()
        ring.bounds = CGRect(x: 0, y: 0, width: 64, height: 52)
        ring.position = center
        ring.cornerRadius = Theme.controlRadius
        ring.cornerCurve = .continuous
        ring.borderWidth = 1.5
        ring.borderColor = rail.resolved(Theme.accent)
        ring.opacity = 0
        layer.addSublayer(ring)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.92
        grow.toValue = 1.04
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = 0.24
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
        CATransaction.commit()
    }
}
