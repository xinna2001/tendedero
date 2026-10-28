import AppKit

/// Standard responder-chain editing actions, available from both menu and keyboard.
@MainActor
enum ApplicationMenu {
    static func install(show: @escaping () -> Void, capture: @escaping () -> Void, note: @escaping () -> Void) {
        let bar = NSMenu()
        let app = NSMenu(title: "ClipLine · 图绳")
        app.addItem(ClosureMenuItem(L("Show line"), handler: show))
        app.addItem(ClosureMenuItem(L("New note"), handler: note))
        app.addItem(ClosureMenuItem(L("Region capture"), handler: capture))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: L("Quit ClipLine"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem(title: "ClipLine", action: nil, keyEquivalent: "")
        appItem.submenu = app; bar.addItem(appItem)
        let edit = NSMenu(title: L("Edit"))
        for (title, action, key) in [
            (L("Undo"), Selector(("undo:")), "z"),
            (L("Redo"), Selector(("redo:")), "Z"),
            (L("Cut"), #selector(NSText.cut(_:)), "x"),
            (L("Copy"), #selector(NSText.copy(_:)), "c"),
            (L("Paste"), #selector(NSText.paste(_:)), "v"),
            (L("Select All"), #selector(NSText.selectAll(_:)), "a")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : .command
            edit.addItem(item)
        }
        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        editItem.submenu = edit; bar.addItem(editItem)
        NSApp.mainMenu = bar
    }
}
