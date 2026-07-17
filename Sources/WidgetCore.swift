import Cocoa

let widgetCornerRadius: CGFloat = 16
let desktopWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

enum WidgetKind: String, Codable { case browser, folder }

struct WidgetConfig: Codable {
    var id = UUID()
    var kind: WidgetKind
    var url: String? = nil
    var folderPath: String? = nil
    var collapsed: Bool? = nil
    var expandedFrame: String? = nil // NSStringFromRect, kept while collapsed
}

enum WidgetStore {
    private static let key = "widgetConfigs"

    static func load() -> [WidgetConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([WidgetConfig].self, from: data) else { return [] }
        return configs
    }

    static func save(_ configs: [WidgetConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// Borderless windows refuse key status by default; content needs it for typing.
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Accessory apps have no menu bar, so standard edit shortcuts must be routed manually.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            let action: Selector?
            switch key {
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            case "q": NSApp.terminate(nil); return true
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        } else if flags == [.command, .shift], event.charactersIgnoringModifiers == "z" {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// A label that never intercepts clicks; content beneath it stays interactive.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Invisible strip across the top: drag to move, double-click to roll up/down.
final class DragHandleView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}

// One on-screen widget: a desktop-level window with the shared visual chrome.
// Subclasses install their content and contribute their menu items.
class Widget: NSObject {
    var config: WidgetConfig { didSet { onConfigChange?() } }
    var onConfigChange: (() -> Void)?
    let window: WidgetWindow
    let container = NSVisualEffectView()
    let titleLabel = PassThroughLabel(labelWithString: "")
    private let handle = DragHandleView()
    private(set) var content: NSView?

    private static let expandedMinSize = NSSize(width: 240, height: 180)
    private static let barHeight: CGFloat = 24
    private var expandedFrameRect: NSRect?
    private var handleHeight: NSLayoutConstraint!
    var isCollapsed: Bool { expandedFrameRect != nil }

    var displayName: String { "Widget" }
    var menuSymbol: String { "square" }
    private var frameName: String { "Widget-\(config.id.uuidString)" }

    init(config: WidgetConfig, cascadeIndex: Int) {
        self.config = config
        window = WidgetWindow(
            contentRect: NSRect(x: 120 + 32 * CGFloat(cascadeIndex), y: 160, width: 440, height: 560),
            styleMask: [.borderless, .resizable],
            backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = desktopWindowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.minSize = Self.expandedMinSize
        window.isReleasedWhenClosed = false

        // Widget-style container: vibrancy material, continuous rounded corners, hairline border.
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = widgetCornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(white: 0.5, alpha: 0.28).cgColor
        window.contentView = container

        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        handle.onDoubleClick = { [weak self] in self?.toggleCollapsed() }

        window.setFrameAutosaveName(frameName)
    }

    // Pins content to fill the container, with the title and drag handle layered on top.
    // belowTitleBar insets the content so the title keeps the glass background to itself.
    func installContent(_ content: NSView, belowTitleBar: Bool = false) {
        self.content = content
        content.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        handle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        container.addSubview(titleLabel)
        container.addSubview(handle)
        handleHeight = handle.heightAnchor.constraint(equalToConstant: 18)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: belowTitleBar ? Self.barHeight : 0),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Fixed spot that reads right in both states: the vertical center of the folded bar.
            titleLabel.centerYAnchor.constraint(equalTo: container.topAnchor, constant: Self.barHeight / 2),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            handle.topAnchor.constraint(equalTo: container.topAnchor),
            handle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            handle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            handleHeight,
        ])
        titleLabel.stringValue = displayName
    }

    // MARK: - Roll-up (double-click on the drag pill)

    func toggleCollapsed() {
        if let expanded = expandedFrameRect {
            expandedFrameRect = nil
            config.collapsed = false
            config.expandedFrame = nil
            applyCollapsedChrome(false)
            var frame = expanded
            frame.origin.x = window.frame.origin.x
            frame.origin.y = window.frame.maxY - expanded.height
            window.setFrame(frame, display: true, animate: true)
        } else {
            expandedFrameRect = window.frame
            config.collapsed = true
            config.expandedFrame = NSStringFromRect(window.frame)
            applyCollapsedChrome(true)
            var frame = window.frame
            frame.origin.y = frame.maxY - Self.barHeight
            frame.size.height = Self.barHeight
            window.setFrame(frame, display: true, animate: true)
        }
    }

    // Restores a collapse that was active when the app last quit.
    func applyPersistedCollapse() {
        guard config.collapsed == true else { return }
        expandedFrameRect = config.expandedFrame.map(NSRectFromString) ?? window.frame
        applyCollapsedChrome(true)
        var frame = window.frame
        frame.size.height = Self.barHeight
        window.setFrame(frame, display: true)
    }

    private func applyCollapsedChrome(_ collapsed: Bool) {
        if collapsed {
            window.styleMask.remove(.resizable)
            window.minSize = NSSize(width: 160, height: Self.barHeight)
        } else {
            window.minSize = Self.expandedMinSize
            window.styleMask.insert(.resizable)
        }
        // The bar is shorter than 2× the corner radius; go capsule so corners stay clean.
        container.layer?.cornerRadius = collapsed ? Self.barHeight / 2 : widgetCornerRadius
        handleHeight.constant = collapsed ? Self.barHeight : 18
        content?.isHidden = collapsed
        didSetCollapsed(collapsed)
    }

    // Subclasses hide/restore any extra chrome that sits outside `content`.
    func didSetCollapsed(_ collapsed: Bool) {}

    func addMenuItems(to menu: NSMenu) {}

    var isFloating: Bool { window.level != desktopWindowLevel }

    // Fallback for login flows in case the desktop layer refuses keyboard focus.
    func setFloating(_ floating: Bool) {
        window.level = floating ? .floating : desktopWindowLevel
        if floating { window.makeKeyAndOrderFront(nil) }
    }

    func tearDown() {
        window.orderOut(nil)
        NSWindow.removeFrame(usingName: frameName)
    }
}

// MARK: - Small modal helpers (accessory app: activate first so dialogs come forward)

func runTextPrompt(title: String, placeholder: String, initial: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = initial
    field.placeholderString = placeholder
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespaces)
}

func runFolderPicker() -> URL? {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url : nil
}

func runSizePrompt(current: NSSize) -> NSSize? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Widget Size"
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
    let widthLabel = NSTextField(labelWithString: "W:")
    widthLabel.frame = NSRect(x: 20, y: 3, width: 26, height: 18)
    let widthField = NSTextField(frame: NSRect(x: 48, y: 0, width: 70, height: 24))
    widthField.stringValue = String(Int(current.width))
    let heightLabel = NSTextField(labelWithString: "H:")
    heightLabel.frame = NSRect(x: 138, y: 3, width: 26, height: 18)
    let heightField = NSTextField(frame: NSRect(x: 166, y: 0, width: 70, height: 24))
    heightField.stringValue = String(Int(current.height))
    [widthLabel, widthField, heightLabel, heightField].forEach(box.addSubview)
    alert.accessoryView = box
    alert.window.initialFirstResponder = widthField
    guard alert.runModal() == .alertFirstButtonReturn,
          let w = Double(widthField.stringValue), let h = Double(heightField.stringValue) else { return nil }
    return NSSize(width: max(w, 240), height: max(h, 180))
}

// Accepts "example.com" or a full URL; returns nil if it can't become a valid http(s) URL.
func normalizedWidgetURL(from text: String) -> URL? {
    var text = text.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") { text = "https://" + text }
    guard let url = URL(string: text), url.host != nil else { return nil }
    return url
}
