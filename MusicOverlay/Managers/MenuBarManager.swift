import AppKit

@MainActor
public class MenuBarManager: NSObject {
    public static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?

    private override init() {
        super.init()
    }

    public func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            hide()
        }
    }

    public func show() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicOverlay")
            image?.isTemplate = true
            // Constrain to the menu bar height while preserving aspect ratio.
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
        }

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Overlay", action: #selector(showOverlay), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MusicOverlay", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    public func hide() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.statusItem = nil
    }

    @objc private func showOverlay() {
        WindowManager.shared.showHUD()
    }

    @objc private func openSettings() {
        WindowManager.shared.showHUD()
        if let vm = WindowManager.shared.activeViewModel, !vm.showSettings {
            vm.toggleSettings()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
