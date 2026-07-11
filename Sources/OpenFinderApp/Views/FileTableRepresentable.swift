import AppKit
import OpenFinderCore
import SwiftUI

enum FileTableAction {
    case open
    case rename
    case trash
    case revealInFinder
    case openInTerminal
    case quickLook
    case copyToOtherPane
    case moveToOtherPane
    case goBack
    case goForward
    case goUp
    case refresh
    case toggleHidden
    case createFile
    case createFolder
    case selectAll
    case plugin(LoadedPlugin, PluginActionManifest)
}

struct FileTableRepresentable: NSViewRepresentable {
    var items: [FileItem]
    var directorySizeText: [String: String]
    @Binding var selection: Set<String>
    var onOpen: (FileItem) -> Void
    var onActivate: () -> Void
    var onDropFileURLs: ([URL]) -> Void
    var remoteFileDownloader: @Sendable (FileItem, URL) async throws -> Void
    var pluginActionsForSelection: ([FileItem]) -> [(LoadedPlugin, PluginActionManifest)]
    var onAction: (FileTableAction, [FileItem]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ContextTableView()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowSizeStyle = .medium
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        table.target = context.coordinator
        table.makeContextMenu = { [weak coordinator = context.coordinator] tableView, row in
            coordinator?.makeMenu(tableView: tableView, row: row)
        }
        table.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activate()
        }
        table.onClearSelection = { [weak coordinator = context.coordinator] in
            coordinator?.clearSelection()
        }
        table.onModifiedRowClick = { [weak coordinator = context.coordinator] row, modifiers in
            coordinator?.applyModifiedRowClick(row: row, modifiers: modifiers)
        }
        table.handleKeyDown = { [weak coordinator = context.coordinator] event in
            coordinator?.handleKeyDown(event) ?? false
        }
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        addColumn(identifier: "name", title: "Name", width: 280, to: table)
        addColumn(identifier: "kind", title: "Kind", width: 90, to: table)
        addColumn(identifier: "size", title: "Size", width: 90, to: table)
        addColumn(identifier: "modified", title: "Modified", width: 170, to: table)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        context.coordinator.tableView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scrollView.documentView as? NSTableView else { return }
        if context.coordinator.lastRenderedItems != items || context.coordinator.lastRenderedDirectorySizeText != directorySizeText {
            context.coordinator.lastRenderedItems = items
            context.coordinator.lastRenderedDirectorySizeText = directorySizeText
            context.coordinator.clearCompletedOrCancelledFilePromises()
            table.reloadData()
        }
        let indexes = IndexSet(items.enumerated().compactMap { offset, item in selection.contains(item.id) ? offset : nil })
        context.coordinator.syncSelection(indexes, in: table)
    }

    private func addColumn(identifier: String, title: String, width: CGFloat, to table: NSTableView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = min(width, 60)
        table.addTableColumn(column)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FileTableRepresentable
        weak var tableView: NSTableView?
        var lastRenderedItems: [FileItem] = []
        var lastRenderedDirectorySizeText: [String: String] = [:]
        private var selectionAnchorRow: Int?
        private var isSyncingSelection = false
        private var remoteFilePromiseDelegates: [UUID: RemoteFilePromiseDelegate] = [:]
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        init(_ parent: FileTableRepresentable) {
            self.parent = parent
        }

        func clearCompletedOrCancelledFilePromises() {
            remoteFilePromiseDelegates.removeAll()
        }

        func activate() {
            parent.onActivate()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < parent.items.count, let tableColumn else { return nil }
            let item = parent.items[row]
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = tableColumn.identifier
            let textField = cell.textField ?? NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false
            if cell.textField == nil {
                cell.addSubview(textField)
                cell.textField = textField
                if tableColumn.identifier.rawValue == "name" {
                    let imageView = NSImageView()
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    imageView.imageScaling = .scaleProportionallyDown
                    cell.addSubview(imageView)
                    cell.imageView = imageView
                    NSLayoutConstraint.activate([
                        imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                        imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        imageView.widthAnchor.constraint(equalToConstant: 18),
                        imageView.heightAnchor.constraint(equalToConstant: 18),
                        textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
                        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                        textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                } else {
                    NSLayoutConstraint.activate([
                        textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                        textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                }
            }
            switch tableColumn.identifier.rawValue {
            case "name":
                let descriptor = FileIconDescriptor.descriptor(for: item)
                cell.imageView?.image = NSImage(systemSymbolName: descriptor.systemImageName, accessibilityDescription: item.kind.rawValue)
                cell.imageView?.contentTintColor = descriptor.tintColor
                textField.stringValue = item.name
            case "kind":
                textField.stringValue = item.kind.rawValue
            case "size":
                if item.isDirectory {
                    if let text = parent.directorySizeText[item.id] {
                        textField.stringValue = text
                    } else {
                        textField.stringValue = item.localURL == nil ? "—" : "计算中…"
                    }
                } else {
                    textField.stringValue = item.size.map { FileSizeFormatter.openFinderString(fromByteCount: $0) } ?? "—"
                }
            case "modified":
                textField.stringValue = item.modificationDate.map { dateFormatter.string(from: $0) } ?? "—"
            default:
                textField.stringValue = ""
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            activate()
            guard let tableView else { return }
            let newSelection = Set(tableView.selectedRowIndexes.compactMap { row in
                row < parent.items.count ? parent.items[row].id : nil
            })
            if parent.selection != newSelection {
                parent.selection = newSelection
            }
            if let selectedRow = tableView.selectedRowIndexes.last {
                selectionAnchorRow = selectedRow
            } else {
                selectionAnchorRow = nil
            }
        }

        @objc func doubleClick(_ sender: NSTableView) {
            activate()
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0, row < parent.items.count else { return }
            parent.onOpen(parent.items[row])
        }

        func makeMenu(tableView: NSTableView, row: Int) -> NSMenu? {
            activate()
            if row >= 0, row < parent.items.count, !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                parent.selection = [parent.items[row].id]
            }
            let selected = selectedItems(tableView: tableView)
            guard !selected.isEmpty else { return nil }
            let menu = NSMenu()
            addItem("Open", action: #selector(open(_:)), to: menu)
            addItem("Quick Look", action: #selector(quickLook(_:)), to: menu)
            let pluginActions = parent.pluginActionsForSelection(selected)
            if !pluginActions.isEmpty {
                menu.addItem(.separator())
                let pluginMenu = NSMenu()
                for (index, pair) in pluginActions.enumerated() {
                    let item = NSMenuItem(title: "\(pair.0.manifest.name): \(pair.1.title)", action: #selector(pluginAction(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = index
                    pluginMenu.addItem(item)
                }
                let parentItem = NSMenuItem(title: "Plugin Actions", action: nil, keyEquivalent: "")
                parentItem.submenu = pluginMenu
                menu.addItem(parentItem)
            }
            menu.addItem(.separator())
            addItem("Rename…", action: #selector(rename(_:)), to: menu).isEnabled = selected.count == 1
            let deleteTitle = selected.contains { item in if case .local = item.location { return false }; return true } ? "Delete…" : "Move to Trash"
            addItem(deleteTitle, action: #selector(trash(_:)), to: menu)
            menu.addItem(.separator())
            addItem("Copy to Other Pane", action: #selector(copyToOtherPane(_:)), to: menu)
            addItem("Move to Other Pane", action: #selector(moveToOtherPane(_:)), to: menu)
            menu.addItem(.separator())
            addItem("Reveal in Finder", action: #selector(reveal(_:)), to: menu)
            addItem("Open in Terminal", action: #selector(terminal(_:)), to: menu)
            return menu
        }

        @discardableResult
        private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }

        private func selectedItems(tableView: NSTableView? = nil) -> [FileItem] {
            let selected = tableView?.selectedRowIndexes ?? self.tableView?.selectedRowIndexes ?? []
            return selected.compactMap { row in row < parent.items.count ? parent.items[row] : nil }
        }

        func syncSelection(_ indexes: IndexSet, in tableView: NSTableView) {
            guard tableView.selectedRowIndexes != indexes else { return }
            isSyncingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isSyncingSelection = false
        }

        private func perform(_ action: FileTableAction) {
            activate()
            parent.onAction(action, selectedItems())
        }

        func handleKeyDown(_ event: NSEvent) -> Bool {
            activate()
            guard let command = FileTableKeyboardShortcut.action(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags) else {
                return false
            }
            switch command {
            case .open: perform(.open)
            case .rename: perform(.rename)
            case .trash: perform(.trash)
            case .quickLook: perform(.quickLook)
            case .goBack: perform(.goBack)
            case .goForward: perform(.goForward)
            case .goUp: perform(.goUp)
            case .refresh: perform(.refresh)
            case .toggleHidden: perform(.toggleHidden)
            case .createFile: perform(.createFile)
            case .createFolder: perform(.createFolder)
            case .copyToOtherPane: perform(.copyToOtherPane)
            case .moveToOtherPane: perform(.moveToOtherPane)
            case .selectAll: selectAll()
            }
            return true
        }

        private func selectAll() {
            guard let tableView else { return }
            let indexes = IndexSet(integersIn: 0..<parent.items.count)
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            parent.selection = Set(parent.items.map(\.id))
        }

        func clearSelection() {
            tableView?.deselectAll(nil)
            parent.selection = []
            selectionAnchorRow = nil
        }

        func applyModifiedRowClick(row: Int, modifiers: NSEvent.ModifierFlags) {
            activate()
            guard let tableView else { return }
            let result = FileTableSelectionReducer.selection(
                selectedRows: tableView.selectedRowIndexes,
                anchorRow: selectionAnchorRow,
                clickedRow: row,
                rowCount: parent.items.count,
                modifiers: modifiers
            )
            selectionAnchorRow = result.anchorRow
            syncSelection(result.selectedRows, in: tableView)
            parent.selection = Set(result.selectedRows.compactMap { index in
                index < parent.items.count ? parent.items[index].id : nil
            })
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < parent.items.count else { return nil }
            let item = parent.items[row]
            if let url = item.localURL {
                return url as NSURL
            }
            guard !item.isDirectory, item.isReadable, let fileName = safeRemoteFileName(item.name) else { return nil }
            let id = UUID()
            let delegate = RemoteFilePromiseDelegate(
                item: item,
                downloader: parent.remoteFileDownloader,
                fileName: fileName,
                onCompletion: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        self?.remoteFilePromiseDelegates.removeValue(forKey: id)
                    }
                }
            )
            remoteFilePromiseDelegates[id] = delegate
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.remoteFilePromiseDelegates.removeValue(forKey: id)
            }
            return NSFilePromiseProvider(fileType: "public.data", delegate: delegate)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            activate()
            return fileURLs(from: info).isEmpty ? [] : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            activate()
            let urls = fileURLs(from: info)
            guard !urls.isEmpty else { return false }
            parent.onDropFileURLs(urls)
            return true
        }

        private func fileURLs(from info: NSDraggingInfo) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
            return urls.map { $0 as URL }
        }

        @objc private func open(_ sender: Any) { perform(.open) }
        @objc private func rename(_ sender: Any) { perform(.rename) }
        @objc private func trash(_ sender: Any) { perform(.trash) }
        @objc private func reveal(_ sender: Any) { perform(.revealInFinder) }
        @objc private func terminal(_ sender: Any) { perform(.openInTerminal) }
        @objc private func quickLook(_ sender: Any) { perform(.quickLook) }
        @objc private func copyToOtherPane(_ sender: Any) { perform(.copyToOtherPane) }
        @objc private func moveToOtherPane(_ sender: Any) { perform(.moveToOtherPane) }
        @objc private func pluginAction(_ sender: NSMenuItem) {
            let selected = selectedItems()
            let actions = parent.pluginActionsForSelection(selected)
            guard sender.tag >= 0, sender.tag < actions.count else { return }
            let pair = actions[sender.tag]
            parent.onAction(.plugin(pair.0, pair.1), selected)
        }
    }
}

private func safeRemoteFileName(_ name: String) -> String? {
    let baseName = URL(fileURLWithPath: name).lastPathComponent
    guard baseName == name,
          !name.contains("/"),
          !name.contains("\\"),
          !baseName.isEmpty,
          baseName != ".",
          baseName != ".." else { return nil }
    return baseName
}

final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let item: FileItem
    private let downloader: @Sendable (FileItem, URL) async throws -> Void
    private let fileName: String?
    private let onCompletion: () -> Void

    init(
        item: FileItem,
        downloader: @escaping @Sendable (FileItem, URL) async throws -> Void,
        fileName: String? = nil,
        onCompletion: @escaping () -> Void = {}
    ) {
        self.item = item
        self.downloader = downloader
        self.fileName = safeRemoteFileName(fileName ?? item.name)
        self.onCompletion = onCompletion
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName ?? ""
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let item = item
        let downloader = downloader
        guard let fileName else {
            FilePromiseCompletion(completionHandler, cleanup: onCompletion)
                .call(OpenFinderError.operationFailed("Remote file has an unsafe name"))
            return
        }
        let completion = FilePromiseCompletion(completionHandler, cleanup: onCompletion)
        Task {
            do {
                try await downloader(item, url.appendingPathComponent(fileName, isDirectory: false))
                completion.call(nil)
            } catch {
                completion.call(error)
            }
        }
    }
}

private final class FilePromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void
    private let cleanup: () -> Void

    init(_ handler: @escaping (Error?) -> Void, cleanup: @escaping () -> Void) {
        self.handler = handler
        self.cleanup = cleanup
    }

    func call(_ error: Error?) {
        handler(error)
        cleanup()
    }
}

@MainActor
final class ContextTableView: NSTableView {
    var makeContextMenu: ((NSTableView, Int) -> NSMenu?)?
    var onActivate: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var onModifiedRowClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var handleKeyDown: ((NSEvent) -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onActivate?()
        let point = convert(event.locationInWindow, from: nil)
        return makeContextMenu?(self, row(at: point))
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        let point = convert(event.locationInWindow, from: nil)
        if FileTablePointerSelection.shouldClearSelection(clickedRow: row(at: point), modifiers: event.modifierFlags) {
            window?.makeFirstResponder(self)
            deselectAll(nil)
            onClearSelection?()
            return
        }
        let clickedRow = row(at: point)
        let flags = event.modifierFlags.intersection([.command, .shift])
        if clickedRow >= 0, !flags.isEmpty {
            window?.makeFirstResponder(self)
            onModifiedRowClick?(clickedRow, event.modifierFlags)
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate?()
        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onActivate?()
        if handleKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
