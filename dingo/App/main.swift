import AppKit
import Eucalyptus

Perf.app = Perf.App(subsystem: "com.joshoettinger.dingo", name: "Dingo")
Theme.configure(accent: .dingoOchre)
MonoFont.register()
NSScroller.makeAllSmall()

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
