import AppKit
import Combine
import Dependencies

/// Optional advanced history editing. Everyday search stays in the native menu.
final class ClipyMeHistoryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    @Dependency(\.pasteboardHistoryRepository) private var repository
    private let store = ClipyMeHistoryStore()
    private let searchField = NSSearchField()
    private let filterButton = NSPopUpButton()
    private let sortButton = NSPopUpButton()
    private let table = HistoryTable()
    private let status = NSTextField(labelWithString: "")
    private let favoriteButton = NSButton(title: "Favorite", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let pasteButton = NSButton(title: "Paste", target: nil, action: nil)
    private let moreButton = NSButton(title: "Load more", target: nil, action: nil)
    private let queue = DispatchQueue(label: "ClipyMe.search", qos: .userInitiated)
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var entries = [ClipyMeHistoryStore.Entry]()
    private var cancellables = Set<AnyCancellable>()
    private var previousApp: NSRunningApplication?
    private var pageOffset = 0
    private var isSearching = false

    init() {
        let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Search Clipboard History"
        panel.minSize = NSSize(width: 500, height: 320)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.center()
        panel.setFrameAutosaveName("ClipyMe.historyWindow")
        buildInterface()
        panel.onAdvanced = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.searchField)
        }
        panel.onEscape = { [weak self] in self?.dismiss() }
        repository.observeHistories().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.refresh()
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showHistory() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = frontmost }
        sortButton.selectItem(at: ClipyMeHistoryStore.Sort.allCases.firstIndex(of: ClipyMeHistoryStore.searchSort) ?? 0)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(searchField)
        refresh()
    }

    func showAdvanced(query: String = "") {
        searchField.stringValue = query
        showHistory()
    }

    private func dismiss() {
        close()
        previousApp?.activate(options: [.activateIgnoringOtherApps])
    }

    func windowWillClose(_ notification: Notification) {
        pending?.cancel()
        generation += 1
        entries.removeAll()
        table.reloadData()
    }

    private func buildInterface() {
        guard let root = window?.contentView else { return }
        searchField.placeholderString = "Search full clip text…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        filterButton.addItems(withTitles: ClipyMeHistoryStore.Filter.allCases.map(\.rawValue))
        sortButton.addItems(withTitles: ClipyMeHistoryStore.Sort.allCases.map(\.title))
        filterButton.target = self
        filterButton.action = #selector(optionsChanged)
        sortButton.target = self
        sortButton.action = #selector(optionsChanged)
        let options = NSStackView(views: [filterButton, sortButton])
        options.orientation = .horizontal
        options.distribution = .fillEqually
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        column.width = 520
        table.addTableColumn(column)
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.rowHeight = 30
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(pasteSelected)
        table.onReturn = { [weak self] in self?.pasteSelected() }
        table.onEscape = { [weak self] in self?.dismiss() }
        table.onEdit = { [weak self] in self?.editSelected() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let actions: [(NSButton, Selector)] = [
            (favoriteButton, #selector(toggleFavorite)), (editButton, #selector(editSelected)),
            (copyButton, #selector(copySelected)), (pasteButton, #selector(pasteSelected)),
            (moreButton, #selector(loadMore))
        ]
        for (button, action) in actions {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [favoriteButton, editButton, moreButton, copyButton, pasteButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [searchField, options, scroll, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        let fullWidthViews: [NSView] = [searchField, options, scroll, status, buttons]
        for view in fullWidthViews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        updateActions()
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            selectRow(min(table.selectedRow + 1, entries.count - 1)); return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            selectRow(max(table.selectedRow - 1, 0)); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { pasteSelected(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        return false
    }

    private func selectRow(_ row: Int) {
        guard entries.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func optionsChanged() {
        ClipyMeHistoryStore.searchSort = ClipyMeHistoryStore.Sort.allCases[sortButton.indexOfSelectedItem]
        refresh()
    }

    private func refresh(append: Bool = false) {
        pending?.cancel()
        generation += 1
        let request = generation
        if !append { pageOffset = 0 }
        let offset = pageOffset
        let query = searchField.stringValue
        let filter = ClipyMeHistoryStore.Filter.allCases[filterButton.indexOfSelectedItem]
        let sort = ClipyMeHistoryStore.Sort.allCases[sortButton.indexOfSelectedItem]
        let selectedID = selected?.id
        isSearching = true
        if !append {
            entries.removeAll()
            table.reloadData()
        }
        updateActions()
        status.stringValue = "Searching…"
        moreButton.isEnabled = false
        let store = self.store
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try store.search(query: query, filter: filter, sort: sort, limit: 201, offset: offset) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.isSearching = false
                switch result {
                case .success(let rows):
                    let page = Array(rows.prefix(200))
                    self.entries = append ? self.entries + page : page
                    self.pageOffset = offset + page.count
                    self.table.reloadData()
                    self.moreButton.isEnabled = rows.count > 200
                    self.status.stringValue = self.entries.isEmpty ? "No matching clips" :
                        "\(self.entries.count) clips\(rows.count > 200 ? " · more available" : "") · ↵ Paste · ⌘E Edit"
                    self.selectRow(self.entries.firstIndex(where: { $0.id == selectedID }) ?? 0)
                case .failure:
                    self.entries = []
                    self.table.reloadData()
                    self.status.stringValue = "Could not search history. Your clips have not been changed."
                }
                self.updateActions()
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    @objc private func loadMore() { refresh(append: true) }

    private var selected: ClipyMeHistoryStore.Entry? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private func updateActions() {
        favoriteButton.isEnabled = !isSearching && selected != nil
        favoriteButton.title = selected?.favorite == true ? "Unfavorite" : "Favorite"
        copyButton.isEnabled = !isSearching && selected != nil
        pasteButton.isEnabled = !isSearching && selected != nil
        editButton.isEnabled = !isSearching && selected?.types.contains(where: { ["public.utf8-plain-text", "NSStringPboardType"].contains($0) }) == true
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        Self.makeCell(entry: entries[row], query: searchField.stringValue, table: tableView)
    }

    static func makeCell(entry: ClipyMeHistoryStore.Entry, query: String, table: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("clipCell")
        let cell = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.cell?.isScrollable = true
            label.cell?.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.heightAnchor.constraint(equalToConstant: 20)
            ])
        }
        let preview = entry.label.prefix(500).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let label = (entry.favorite ? "★ " : "") + preview
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSMutableAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .paragraphStyle: paragraph
        ])
        for word in query.split(whereSeparator: \.isWhitespace) {
            let range = (label as NSString).range(of: String(word), options: [.caseInsensitive])
            if range.location != NSNotFound {
                attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: range)
            }
        }
        cell.textField?.attributedStringValue = attributed
        cell.toolTip = nil
        return cell
    }

    @objc private func toggleFavorite() {
        guard !isSearching, let entry = selected else { return }
        do {
            try store.setFavorite(id: entry.id, enabled: !entry.favorite)
            refresh()
        } catch { showError(error) }
    }
    @objc private func copySelected() {
        guard !isSearching, let entry = selected, let content = repository.fetchContent(id: entry.id) else { NSSound.beep(); return }
        content.writeObjects(to: .general)
        status.stringValue = "Copied to clipboard"
    }
    @objc private func pasteSelected() {
        guard !isSearching, let entry = selected, let content = repository.fetchContent(id: entry.id) else { NSSound.beep(); return }
        // An NSMenu does not take focus; this panel does. Restore the captured target first.
        guard let target = previousApp, !target.isTerminated else {
            content.writeObjects(to: .general)
            status.stringValue = "Copied. Switch to your destination app and paste."
            return
        }
        close()
        target.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                content.writeObjects(to: .general); return
            }
            AppEnvironment.current.pasteService.paste(id: entry.id, content: content)
        }
    }
    @objc private func editSelected() {
        guard !isSearching, let entry = selected, let content = repository.fetchContent(id: entry.id) else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Clip"
        alert.informativeText = content.isOnlyStringType
            ? "Save replaces this clip and keeps its date. Save as New keeps the original."
            : "This clip includes formatting or other content. Save a plain-text copy to keep the original intact."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Save as New")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = content.isOnlyStringType
        alert.buttons[2].keyEquivalent = "\u{1b}"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = content.stringValue
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = editor
        while true {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            do {
                try store.edit(id: entry.id, text: editor.string, asNew: response == .alertSecondButtonReturn)
                refresh()
                return
            } catch { showError(error) }
        }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not save the change"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

private final class HistoryTable: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onEdit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            onReturn?()
        } else if event.keyCode == 53 {
            onEscape?()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "e" {
            onEdit?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class HistoryPanel: NSPanel {
    var onAdvanced: (() -> Void)?
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" {
            onAdvanced?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
