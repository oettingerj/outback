import AppKit
import DingoKit
import Eucalyptus

/// The menu bar is the single source of truth for every command and its shortcut. The command
/// bar and the header buttons read their shortcuts from here.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(messageMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func item(_ title: String, _ action: Selector?, _ key: String = "",
                     _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        MenuShortcuts.register(item)
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Dingo")
        menu.addItem(item("About Dingo", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide Dingo", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Dingo", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Message", #selector(AppDelegate.newMessage(_:)), "n"))
        menu.addItem(item("New Viewer Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Get New Mail", #selector(AppDelegate.syncNow(_:)), "n", [.command, .shift]))
        menu.addItem(item("Add Account…", #selector(AppDelegate.addAccount(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Search Mail…", #selector(AppDelegate.searchMail(_:)), "f", [.command, .option]))
        let format = NSMenu(title: "Format")
        format.addItem(item("Bold", #selector(NSFontManager.addFontTrait(_:)), "b", tag: Int(NSFontTraitMask.boldFontMask.rawValue)))
        format.addItem(item("Italic", #selector(NSFontManager.addFontTrait(_:)), "i", tag: Int(NSFontTraitMask.italicFontMask.rawValue)))
        format.addItem(item("Underline", #selector(NSText.underline(_:)), "u"))
        format.addItem(item("Add Link…", #selector(NSTextView.orderFrontLinkPanel(_:)), "k", [.command, .shift]))
        for formatItem in format.items where formatItem.action == #selector(NSFontManager.addFontTrait(_:)) {
            formatItem.target = NSFontManager.shared
        }
        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatItem.submenu = format
        menu.addItem(.separator())
        menu.addItem(formatItem)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        for (index, destination) in Destination.rail.enumerated() {
            menu.addItem(item(destination.title, #selector(AppDelegate.showDestination(_:)), "\(index + 1)", tag: index))
        }
        menu.addItem(.separator())
        for (index, mailbox) in Mailbox.allCases.enumerated() {
            menu.addItem(item(mailbox.title, #selector(AppDelegate.showDestination(_:)), "\(Destination.rail.count + index + 1)",
                              tag: Destination.rail.count + index))
        }
        menu.addItem(.separator())
        menu.addItem(item("Command Bar", #selector(AppDelegate.showCommandBar(_:)), "k"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func messageMenu() -> NSMenu {
        let menu = NSMenu(title: "Message")
        menu.addItem(item("Reply", #selector(AppDelegate.reply(_:)), "r"))
        menu.addItem(item("Reply All", #selector(AppDelegate.replyAll(_:)), "r", [.command, .shift]))
        menu.addItem(item("Forward", #selector(AppDelegate.forward(_:)), "f", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Archive", #selector(AppDelegate.archive(_:)), "a", [.command, .control]))
        menu.addItem(item("Move to Trash", #selector(AppDelegate.trash(_:)), "\u{8}"))
        menu.addItem(item("Mark as Read", #selector(AppDelegate.toggleRead(_:)), "u", [.command, .shift]))
        menu.addItem(item("Star", #selector(AppDelegate.toggleStar(_:)), "l", [.command, .shift]))
        menu.addItem(.separator())
        let move = NSMenu(title: "Move to Bucket")
        for (index, bucket) in Bucket.allCases.enumerated() {
            move.addItem(item(bucket.title, #selector(AppDelegate.moveToBucket(_:)), "\(index + 1)", [.command, .control], tag: index))
        }
        let moveItem = NSMenuItem(title: "Move to Bucket", action: nil, keyEquivalent: "")
        moveItem.submenu = move
        menu.addItem(moveItem)
        let always = NSMenu(title: "Always Put Mail from Sender In")
        for (index, bucket) in Bucket.allCases.enumerated() {
            always.addItem(item(bucket.title, #selector(AppDelegate.alwaysMoveSender(_:)), tag: index))
        }
        let alwaysItem = NSMenuItem(title: "Always Put Mail from Sender In", action: nil, keyEquivalent: "")
        alwaysItem.submenu = always
        menu.addItem(alwaysItem)
        menu.addItem(.separator())
        menu.addItem(item("Unsubscribe", #selector(AppDelegate.unsubscribe(_:))))
        menu.addItem(item("Open in Gmail", #selector(AppDelegate.openInGmail(_:)), "g", [.command, .option]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
