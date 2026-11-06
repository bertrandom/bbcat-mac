import AppKit

/// Lists the artwork files that live alongside the currently open file and
/// lets the user pick one to open.
final class FileSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let supportedExtensions: Set<String> = [
        "ans", "asc", "diz", "nfo", "ddw", "adf", "rip", "tnd", "xb", "xbin",
    ]

    /// Called when the user selects a file in the list.
    var onSelect: ((URL) -> Void)?

    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Open an artwork to browse the other files in its folder.")
    private var directoryURL: URL?
    private var files: [URL] = []
    private var selectedURL: URL?
    private var isUpdatingSelection = false

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("FileCell")
    private static let headerIdentifier = NSUserInterfaceItemIdentifier("HeaderCell")

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Artwork files")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        updateEmptyState()
    }

    /// Shows the folder containing `url` and highlights `url` in the list.
    func show(fileAt url: URL) {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        selectedURL = url.standardizedFileURL
        if directory != directoryURL {
            directoryURL = directory
            reload()
        } else {
            syncSelection()
        }
    }

    /// Re-reads the current folder, e.g. after the app becomes active again.
    func refresh() {
        guard directoryURL != nil else { return }
        reload()
    }

    private func reload() {
        files = directoryURL.map(Self.artworkFiles(in:)) ?? []
        tableView.reloadData()
        updateEmptyState()
        syncSelection()
    }

    private static func artworkFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func syncSelection() {
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
        if let selectedURL, let index = files.firstIndex(of: selectedURL) {
            let row = index + 1
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = directoryURL != nil
        if directoryURL != nil, files.isEmpty {
            emptyLabel.stringValue = "No artwork files in this folder."
            emptyLabel.isHidden = false
        }
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int {
        directoryURL == nil ? 0 : files.count + 1
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { row == 0 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { row > 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == 0 {
            let cell = tableView.makeView(withIdentifier: Self.headerIdentifier, owner: self) as? NSTableCellView
                ?? makeCell(identifier: Self.headerIdentifier, withImage: false)
            cell.textField?.stringValue = directoryURL?.lastPathComponent ?? ""
            return cell
        }
        let url = files[row - 1]
        let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: Self.cellIdentifier, withImage: true)
        cell.textField?.stringValue = url.lastPathComponent
        cell.toolTip = url.lastPathComponent
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        let row = tableView.selectedRow
        guard row > 0, row - 1 < files.count else { return }
        let url = files[row - 1]
        guard url != selectedURL else { return }
        selectedURL = url
        onSelect?(url)
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text

        var constraints = [
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if withImage {
            let image = NSImageView(image: NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!)
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    /// Restores the highlighted row to `url` (e.g. after the selected file failed to open).
    func revertSelection(to url: URL?) {
        selectedURL = url?.standardizedFileURL
        syncSelection()
    }
}
