import Cocoa

// Watches one directory via kqueue. Distinguishes content changes, renames
// (reports the new path, resolved from the open file descriptor), and deletion.
final class FolderMonitor {
    var onChange: (() -> Void)?
    var onVanish: (() -> Void)?
    var onMove: ((String) -> Void)?

    private var source: DispatchSourceFileSystemObject?

    @discardableResult
    func start(path: String) -> Bool {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.revoke) {
                self.onVanish?()
            } else if flags.contains(.rename) {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                if fcntl(fd, F_GETPATH, &buffer) != -1 {
                    let newPath = String(cString: buffer)
                    // A move to the Trash is a rename too; treat it as gone, not as a move.
                    if newPath.isEmpty || newPath.contains("/.Trash") {
                        self.onVanish?()
                    } else {
                        self.onMove?(newPath)
                    }
                } else {
                    self.onVanish?()
                }
            } else if flags.contains(.write) {
                self.onChange?()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

// Collection view with Finder-like keys: Return renames, ⌘⌫ trashes, double-click opens.
final class CanvasCollectionView: NSCollectionView {
    var onTrash: (() -> Void)?
    var onOpenSelection: (() -> Void)?
    var onBeginRename: (() -> Void)?
    var menuProvider: ((IndexPath?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        // Right-clicking an unselected item selects it first, like Finder.
        if let indexPath, !selectionIndexPaths.contains(indexPath) {
            deselectAll(nil)
            selectItems(at: [indexPath], scrollPosition: [])
        }
        return menuProvider?(indexPath)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !selectionIndexPaths.isEmpty {
            onBeginRename?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "\u{7F}", !selectionIndexPaths.isEmpty {
            onTrash?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onOpenSelection?() }
    }
}

final class FileCell: NSCollectionViewItem, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")

    var fileURL: URL?
    var onRename: ((URL, String) -> Void)?
    private var originalName = ""

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(string: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.delegate = self

        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon)
        root.addSubview(label)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -3),
        ])
        view = root
        imageView = icon
        textField = label
    }

    func configure(with url: URL) {
        fileURL = url
        imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        textField?.stringValue = url.lastPathComponent
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : nil
        }
    }

    func beginRename() {
        guard let field = textField else { return }
        originalName = field.stringValue
        field.isEditable = true
        field.isSelectable = true
        view.window?.makeFirstResponder(field)
        // Select the name without its extension, like Finder.
        if let editor = field.currentEditor() {
            let base = (field.stringValue as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = textField, field.isEditable else { return }
        field.isEditable = false
        field.isSelectable = false
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        if let url = fileURL, !newName.isEmpty, newName != originalName {
            onRename?(url, newName)
        } else {
            field.stringValue = originalName
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.stringValue = originalName
            textField?.isEditable = false
            textField?.isSelectable = false
            view.window?.makeFirstResponder(collectionView)
            return true
        }
        return false
    }
}

final class FolderWidget: Widget, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let scrollView = NSScrollView()
    private let collectionView = CanvasCollectionView()
    private let monitor = FolderMonitor()
    private var fileURLs: [URL] = []
    private var recoveryTimer: Timer?
    private var reloadDebounce: DispatchWorkItem?

    private let missingOverlay = NSStackView()
    private let missingLabel = NSTextField(labelWithString: "")
    private let recreateButton = NSButton(title: "Recreate Folder", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "Drop files here")

    private var folderURL: URL? { config.folderPath.map { URL(fileURLWithPath: $0) } }

    override var displayName: String {
        guard let path = config.folderPath else { return "Folder" }
        return (path as NSString).lastPathComponent
    }
    override var menuSymbol: String { "folder" }

    override init(config: WidgetConfig, cascadeIndex: Int) {
        super.init(config: config, cascadeIndex: cascadeIndex)
        buildUI()
        monitor.onChange = { [weak self] in self?.scheduleReload() }
        monitor.onVanish = { [weak self] in self?.enterMissingState() }
        monitor.onMove = { [weak self] newPath in
            self?.config.folderPath = newPath
            self?.connectFolder()
        }
        connectFolder()
    }

    private func buildUI() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 84, height: 84)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 30, left: 10, bottom: 10, right: 10)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(FileCell.self, forItemWithIdentifier: FileCell.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collectionView.onTrash = { [weak self] in self?.trashSelection() }
        collectionView.onOpenSelection = { [weak self] in self?.openSelection() }
        collectionView.onBeginRename = { [weak self] in self?.beginRenameSelection() }
        collectionView.menuProvider = { [weak self] indexPath in self?.contextMenu(for: indexPath) }

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        installContent(scrollView)

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        missingOverlay.orientation = .vertical
        missingOverlay.alignment = .centerX
        missingOverlay.spacing = 10
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: "Folder missing")
        icon.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.font = .systemFont(ofSize: 12)
        missingLabel.alignment = .center
        missingLabel.lineBreakMode = .byTruncatingMiddle
        missingLabel.maximumNumberOfLines = 3
        missingLabel.preferredMaxLayoutWidth = 220
        let chooseButton = NSButton(title: "Choose Folder…", target: self, action: #selector(changeFolder))
        recreateButton.target = self
        recreateButton.action = #selector(recreateFolder)
        let buttons = NSStackView(views: [chooseButton, recreateButton])
        buttons.spacing = 8
        [icon, missingLabel, buttons].forEach(missingOverlay.addArrangedSubview)
        missingOverlay.isHidden = true
        missingOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(missingOverlay)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            missingOverlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            missingOverlay.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            missingOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            missingOverlay.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Folder lifecycle

    // (Re)attach to config.folderPath; falls into the missing state if it isn't a readable directory.
    private func connectFolder() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        var isDirectory: ObjCBool = false
        guard let path = config.folderPath,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              monitor.start(path: path) else {
            enterMissingState()
            return
        }
        titleLabel.stringValue = displayName
        missingOverlay.isHidden = true
        scrollView.isHidden = isCollapsed
        reloadContents()
    }

    private func enterMissingState() {
        monitor.stop()
        titleLabel.stringValue = displayName
        fileURLs = []
        collectionView.reloadData()
        scrollView.isHidden = true
        emptyLabel.isHidden = true
        missingLabel.stringValue = config.folderPath.map { "Folder not found\n\($0)" } ?? "No folder selected"
        recreateButton.isHidden = config.folderPath == nil
        missingOverlay.isHidden = isCollapsed
        // Auto-recover if the folder comes back (e.g. restored from the Trash or volume remounted).
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let path = self.config.folderPath else { return }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                self.connectFolder()
            }
        }
    }

    private func scheduleReload() {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadContents() }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func reloadContents() {
        guard let folder = folderURL, missingOverlay.isHidden else { return }
        do {
            fileURLs = try FileManager.default
                .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            // Covers permission loss and races with deletion.
            enterMissingState()
            return
        }
        emptyLabel.isHidden = isCollapsed || !fileURLs.isEmpty
        collectionView.reloadData()
    }

    // Rolled up, only the title bar shows; on expand, re-derive the folder state.
    override func didSetCollapsed(_ collapsed: Bool) {
        if collapsed {
            missingOverlay.isHidden = true
            emptyLabel.isHidden = true
        } else {
            connectFolder()
        }
    }

    override func tearDown() {
        monitor.stop()
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        super.tearDown()
    }

    // MARK: - Menu & missing-state actions

    override func addMenuItems(to menu: NSMenu) {
        for (title, action) in [
            ("Reveal in Finder", #selector(revealInFinder)),
            ("Change Folder…", #selector(changeFolder)),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
    }

    @objc private func revealInFinder() {
        guard let folder = folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    @objc private func changeFolder() {
        guard let url = runFolderPicker() else { return }
        config.folderPath = url.path
        connectFolder()
    }

    @objc private func recreateFolder() {
        guard let path = config.folderPath else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        connectFolder()
    }

    // MARK: - Context menu

    private func contextMenu(for indexPath: IndexPath?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
        }
        if indexPath != nil {
            add("Open", #selector(menuOpen))
            add("Show in Finder", #selector(menuShowInFinder))
            menu.addItem(.separator())
            add("Rename", #selector(menuRename), enabled: collectionView.selectionIndexPaths.count == 1)
            add("Duplicate", #selector(menuDuplicate))
            add("Copy", #selector(menuCopy))
            menu.addItem(.separator())
            add("Move to Trash", #selector(menuTrash))
        } else {
            add("New Folder", #selector(menuNewFolder))
            let canPaste = NSPasteboard.general.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            add("Paste", #selector(menuPaste), enabled: canPaste)
            menu.addItem(.separator())
            add("Show in Finder", #selector(revealInFinder))
        }
        return menu
    }

    @objc private func menuOpen() { openSelection() }
    @objc private func menuRename() { beginRenameSelection() }
    @objc private func menuTrash() { trashSelection() }

    @objc private func menuShowInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedURLs)
    }

    @objc private func menuDuplicate() {
        guard let folder = folderURL else { return }
        for url in selectedURLs {
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent
            let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            do { try FileManager.default.copyItem(at: url, to: uniqueDestination(for: copyName, in: folder)) }
            catch { NSSound.beep() }
        }
        scheduleReload()
    }

    @objc private func menuCopy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(selectedURLs as [NSURL])
    }

    @objc private func menuPaste() {
        guard let folder = folderURL else { return }
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                     options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        for url in urls {
            do { try FileManager.default.copyItem(at: url, to: uniqueDestination(for: url.lastPathComponent, in: folder)) }
            catch { NSSound.beep() }
        }
        scheduleReload()
    }

    @objc private func menuNewFolder() {
        guard let folder = folderURL else { return }
        let destination = uniqueDestination(for: "untitled folder", in: folder)
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
        catch { NSSound.beep() }
        scheduleReload()
    }

    // MARK: - File actions

    private var selectedURLs: [URL] {
        collectionView.selectionIndexPaths.compactMap {
            fileURLs.indices.contains($0.item) ? fileURLs[$0.item] : nil
        }
    }

    private func trashSelection() {
        for url in selectedURLs {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { NSSound.beep() }
        }
        scheduleReload()
    }

    private func openSelection() {
        selectedURLs.forEach { NSWorkspace.shared.open($0) }
    }

    private func beginRenameSelection() {
        guard collectionView.selectionIndexPaths.count == 1,
              let indexPath = collectionView.selectionIndexPaths.first,
              let cell = collectionView.item(at: indexPath) as? FileCell else { return }
        cell.beginRename()
    }

    private func rename(_ url: URL, to newName: String) {
        guard !newName.contains("/") else { NSSound.beep(); scheduleReload(); return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        do { try FileManager.default.moveItem(at: url, to: destination) }
        catch { NSSound.beep() }
        scheduleReload()
    }

    // MARK: - Collection view data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        fileURLs.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileCell.identifier, for: indexPath) as! FileCell
        item.configure(with: fileURLs[indexPath.item])
        item.onRename = { [weak self] url, newName in self?.rename(url, to: newName) }
        return item
    }

    // MARK: - Drag out

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        fileURLs.indices.contains(indexPath.item) ? fileURLs[indexPath.item] as NSURL : nil
    }

    // MARK: - Drag in

    private func incomingURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // Finder semantics: move on the same volume, copy across volumes; Option forces copy.
    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        guard missingOverlay.isHidden, let folder = folderURL else { return [] }
        let urls = incomingURLs(info)
        guard !urls.isEmpty else { return [] }
        // Nothing to do if everything is already in this folder, or the folder is dropped into itself.
        let meaningful = urls.filter {
            $0.deletingLastPathComponent().path != folder.path
                && $0.path != folder.path && !folder.path.hasPrefix($0.path + "/")
        }
        guard !meaningful.isEmpty else { return [] }
        let canMove = info.draggingSourceOperationMask.contains(.move)
            && meaningful.allSatisfy { sameVolume($0, folder) }
        return canMove ? .move : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        proposedDropOperation.pointee = .before
        // Reordering within the widget is not a thing; the folder itself is the target.
        guard (draggingInfo.draggingSource as? NSCollectionView) !== collectionView else { return [] }
        return operation(for: draggingInfo)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let folder = folderURL else { return false }
        let op = operation(for: draggingInfo)
        guard op != [] else { return false }
        var accepted = false
        for source in incomingURLs(draggingInfo) {
            guard source.deletingLastPathComponent().path != folder.path,
                  source.path != folder.path, !folder.path.hasPrefix(source.path + "/") else { continue }
            let destination = uniqueDestination(for: source.lastPathComponent, in: folder)
            do {
                if op == .move {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                accepted = true
            } catch {
                NSSound.beep()
            }
        }
        scheduleReload()
        return accepted
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.resourceValues(forKeys: [.volumeURLKey]).volume
        let vb = try? b.resourceValues(forKeys: [.volumeURLKey]).volume
        return va != nil && va == vb
    }

    private func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var destination = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: destination.path) else { return destination }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var counter = 2
        repeat {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            destination = folder.appendingPathComponent(candidate)
            counter += 1
        } while fm.fileExists(atPath: destination.path)
        return destination
    }
}
