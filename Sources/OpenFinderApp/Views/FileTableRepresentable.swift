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
    case plugin(LoadedPlugin, PluginActionManifest)
}

struct FileTableRepresentable: NSViewRepresentable {
    var items: [FileItem]
    @Binding var selection: Set<String>
    var onOpen: (FileItem) -> Void
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
        table.reloadData()
        let indexes = IndexSet(items.enumerated().compactMap { offset, item in selection.contains(item.id) ? offset : nil })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
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
        private let byteFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        init(_ parent: FileTableRepresentable) {
            self.parent = parent
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
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            switch tableColumn.identifier.rawValue {
            case "name":
                textField.stringValue = (item.isDirectory ? "📁 " : "📄 ") + item.name
            case "kind":
                textField.stringValue = item.kind.rawValue
            case "size":
                textField.stringValue = item.kind == .directory ? "—" : item.size.map { byteFormatter.string(fromByteCount: $0) } ?? "—"
            case "modified":
                textField.stringValue = item.modificationDate.map { dateFormatter.string(from: $0) } ?? "—"
            default:
                textField.stringValue = ""
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            parent.selection = Set(tableView.selectedRowIndexes.compactMap { row in
                row < parent.items.count ? parent.items[row].id : nil
            })
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0, row < parent.items.count else { return }
            parent.onOpen(parent.items[row])
        }

        func makeMenu(tableView: NSTableView, row: Int) -> NSMenu? {
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

        private func perform(_ action: FileTableAction) {
            parent.onAction(action, selectedItems())
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

@MainActor
final class ContextTableView: NSTableView {
    var makeContextMenu: ((NSTableView, Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return makeContextMenu?(self, row(at: point))
    }
}
