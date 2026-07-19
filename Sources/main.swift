import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var widgets: [Widget] = []
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    private var screenReshuffleWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WidgetStore.load().forEach(spawn)
        persist()
        setUpStatusItem()
        // Covers a display that was reattached while the app wasn't running.
        widgets.forEach { $0.restorePlacementIfDisplayReturned() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // When a display comes (back), wait for the reshuffle to settle, then send
    // widgets home to the frames they last had on that display.
    @objc private func screensChanged() {
        screenReshuffleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.widgets.forEach { $0.restorePlacementIfDisplayReturned() }
        }
        screenReshuffleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Widget management

    private func spawn(config: WidgetConfig) {
        let widget: Widget
        switch config.kind {
        case .browser: widget = BrowserWidget(config: config, cascadeIndex: widgets.count)
        case .folder: widget = FolderWidget(config: config, cascadeIndex: widgets.count)
        }
        widget.onConfigChange = { [weak self] in self?.persist() }
        widget.applyPersistedCollapse()
        widget.recordPlacementIfUnset()
        widgets.append(widget)
        widget.window.makeKeyAndOrderFront(nil)
    }

    private func persist() {
        WidgetStore.save(widgets.map(\.config))
    }

    // MARK: - Status item / manager menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSImage(named: "MenuIconTemplate") {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Widgets")
        }
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    // Rebuilt on every open so widget names, float states, and the list stay fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for widget in widgets {
            let item = NSMenuItem(title: widget.displayName, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: widget.menuSymbol, accessibilityDescription: nil)
            let submenu = NSMenu()
            widget.addMenuItems(to: submenu)
            submenu.addItem(.separator())
            submenu.addItem(widgetItem("Set Size…", #selector(setWidgetSize(_:)), widget))
            let floatItem = widgetItem("Float on Top", #selector(toggleFloat(_:)), widget)
            floatItem.state = widget.isFloating ? .on : .off
            submenu.addItem(floatItem)
            submenu.addItem(.separator())
            submenu.addItem(widgetItem("Remove Widget…", #selector(removeWidget(_:)), widget))
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        var add = menu.addItem(withTitle: "Add Browser Widget…", action: #selector(addBrowserWidget), keyEquivalent: "")
        add.target = self
        add = menu.addItem(withTitle: "Add Folder Widget…", action: #selector(addFolderWidget), keyEquivalent: "")
        add.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
    }

    private func widgetItem(_ title: String, _ action: Selector, _ widget: Widget) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = widget
        return item
    }

    // MARK: - Menu actions

    @objc private func addBrowserWidget() {
        guard let text = runTextPrompt(title: "Browser Widget URL", placeholder: "https://example.com", initial: ""),
              let url = normalizedWidgetURL(from: text) else { return }
        spawn(config: WidgetConfig(kind: .browser, url: url.absoluteString))
        persist()
    }

    @objc private func addFolderWidget() {
        guard let folder = runFolderPicker() else { return }
        spawn(config: WidgetConfig(kind: .folder, folderPath: folder.path))
        persist()
    }

    @objc private func setWidgetSize(_ sender: NSMenuItem) {
        guard let widget = sender.representedObject as? Widget else { return }
        if widget.isCollapsed { widget.toggleCollapsed() }
        guard let size = runSizePrompt(current: widget.window.frame.size) else { return }
        widget.window.setContentSize(size)
        widget.recordPlacement()
    }

    @objc private func toggleFloat(_ sender: NSMenuItem) {
        guard let widget = sender.representedObject as? Widget else { return }
        widget.setFloating(!widget.isFloating)
    }

    @objc private func removeWidget(_ sender: NSMenuItem) {
        guard let widget = sender.representedObject as? Widget else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove “\(widget.displayName)”?"
        alert.informativeText = widget is FolderWidget
            ? "The folder and its files are not affected."
            : "This only removes the widget."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        widget.tearDown()
        widgets.removeAll { $0 === widget }
        persist()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
