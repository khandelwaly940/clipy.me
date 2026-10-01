import AppKit
import Dependencies
import DependenciesTestSupport
import GRDB
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite(.serialized, .dependencies { try $0.bootstrapDatabase() })
struct ClipyMeHistoryStoreTests {
    @Dependency(\.defaultDatabase) private var database
    private let repository = PasteboardHistoryRepository()
    private let store = ClipyMeHistoryStore()

    @discardableResult
    private func save(_ text: String, at time: Int = 10) throws -> PasteboardHistory.ID {
        let content = try #require(PasteboardContent(assets: [.init(type: .string, data: Data(text.utf8))]))
        let id = PasteboardHistory.ID(rawValue: content.hash)
        repository.save(id: id, content: content, updateAt: time)
        return id
    }

    @Test func limitedSearchMatchesCompleteSearchAndFindsOlderClips() throws {
        for index in 0..<280 {
            try save("common clip \(index)" + (index < 4 ? " rareolder" : ""), at: index)
        }
        for sort in ClipyMeHistoryStore.Sort.allCases {
            let complete = try store.search(query: "common", filter: .all, sort: sort, limit: 300)
            let menu = try store.search(query: "common", filter: .all, sort: sort, limit: 31)
            #expect(menu.map(\.id) == Array(complete.prefix(31)).map(\.id))
        }
        let older = try store.search(query: "rareolder", filter: .all, sort: .newest, limit: 31)
        #expect(older.count == 4)
        let paged = try store.search(query: "common", filter: .all, sort: .newest, limit: 31, offset: 31)
        let complete = try store.search(query: "common", filter: .all, sort: .newest, limit: 300)
        #expect(paged.map(\.id) == Array(complete.dropFirst(31).prefix(31)).map(\.id))
    }

    @Test func bestMatchRanksExactPrefixAndPhraseWithoutFalsePositives() throws {
        #expect(ClipyMeHistoryStore.rank(title: "CAFÉ", query: "café") == 0)
        let exact = try save("alpha beta", at: 1)
        let prefix = try save("alpha beta extras", at: 2)
        let phrase = try save("extras alpha beta", at: 3)
        let separate = try save("alpha extras beta", at: 4)
        _ = try save("alpha missing", at: 5)
        #expect(try store.search(query: "alpha beta", filter: .all, sort: .bestMatch).map(\.id) == [exact, prefix, phrase, separate])
        _ = try save("abc --- bcd", at: 6)
        #expect(try store.search(query: "abcd", filter: .all, sort: .bestMatch).isEmpty)
        #expect(try store.search(query: "alpha absent", filter: .all, sort: .bestMatch).isEmpty)
    }

    @Test func streamingSearchAndPreviewCrossUTF8ChunkBoundary() throws {
        let id = try save(String(repeating: "x", count: 65_533) + "CAFÉ boundaryneedle suffix")
        #expect(try store.search(query: "café boundaryneedle", filter: .all, sort: .bestMatch).map(\.id) == [id])
        let preview = try #require(try store.preview(id: id, query: "boundaryneedle", limit: 120))
        #expect(preview.contains("boundaryneedle"))
        #expect(preview.count <= 122)
        #expect(preview.hasPrefix("…"))
        let entry = try #require(store.search(query: "boundaryneedle", filter: .all, sort: .bestMatch).first)
        let item = ClipyMeMenuSearchView.resultItem(entry: entry, titleLimit: 40, previewLimit: 80)
        #expect(item.toolTip?.count == 80)
        #expect(item.representedObject as? PasteboardHistory.ID == id)
        #expect(ClipyMeMenuSearchView.resultItem(entry: entry, titleLimit: 40, previewLimit: nil).toolTip == nil)
    }

    @Test func historyWindowUsesCompactNativeControls() throws {
        let controller = withDependencies {
            $0.pasteboardHistoryRepository = repository
        } operation: {
            ClipyMeHistoryController()
        }
        defer { controller.close() }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(content)
        let search = try #require(views.compactMap { $0 as? NSSearchField }.first)
        #expect(search.frame.width > 400)
        #expect(views.filter { $0 is NSTableView }.count == 1)
        #expect(window.frame.width <= 600)
        let buttonTitles = views.compactMap { ($0 as? NSButton)?.title }
        #expect(buttonTitles.contains("Copy"))
        #expect(buttonTitles.contains("Paste"))
        #expect(buttonTitles.contains("Edit…"))
    }

    @Test func nativeMenuFiltersAndKeepsSnippetsInPlace() async throws {
        let match = try save("Needle native menu result")
        let menu = NSMenu()
        let search = ClipyMeMenuSearchView()
        search.owningMenu = menu
        let header = NSMenuItem()
        header.view = search
        menu.addItem(header)
        let original = NSMenuItem(title: "Original history", action: nil, keyEquivalent: "")
        menu.addItem(original)
        search.historyItems = [original]
        let snippets = NSMenuItem(title: "Snippets", action: nil, keyEquivalent: "")
        snippets.submenu = NSMenu()
        snippets.submenu?.addItem(withTitle: "Example snippet", action: nil, keyEquivalent: "")
        menu.addItem(snippets)
        search.searchField.stringValue = "needle"
        search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(menu.items.contains(original))
        #expect(!menu.items.contains { $0.title == "Searching…" })
        #expect(!original.isEnabled)
        try await Task.sleep(for: .milliseconds(500))
        let matchingIDs = menu.items.compactMap { $0.representedObject as? PasteboardHistory.ID }
        #expect(matchingIDs == [match])
        #expect(menu.items.contains(snippets) && !snippets.isHidden)
        #expect(snippets.submenu?.numberOfItems == 1)
        for _ in 0..<20 {
            search.searchField.stringValue = "another query"
            search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            search.searchField.stringValue = ""
            search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(menu.items.count == 3)
            #expect(menu.items[0] === header)
            #expect(menu.items[1] === original)
            #expect(menu.items[2] === snippets)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(menu.items.count == 3)
        search.reset()
        #expect(!original.isHidden)
        #expect(menu.items.contains(original))
        #expect(menu.items.count == 3)
    }

    @Test func updatesRespectDisableIntervalAndVersionOrdering() {
        let name = "ClipyMeUpdatesTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        let checker = ClipyMeReleaseUpdates(defaults: defaults, domainName: name)
        withExtendedLifetime(checker) {
            #expect(ClipyMeReleaseUpdates.nextDelay(defaults: defaults) == nil)
            defaults.set(true, forKey: Constants.Update.enableAutomaticCheck)
            defaults.set(604800, forKey: Constants.Update.checkInterval)
            let now = Date(timeIntervalSince1970: 1_000_000)
            defaults.set(now.timeIntervalSince1970, forKey: ClipyMeReleaseUpdates.lastAttemptKey)
            #expect(ClipyMeReleaseUpdates.nextDelay(defaults: defaults, now: now) == 604800)
            defaults.set(10, forKey: Constants.Update.checkInterval)
            #expect(ClipyMeReleaseUpdates.nextDelay(defaults: defaults, now: now) == 86400)
            #expect(ClipyMeReleaseUpdates.isNewer("v1.3.10", than: "1.3.9"))
            #expect(!ClipyMeReleaseUpdates.isNewer("v1.3.1", than: "1.3.1"))
            #expect(!ClipyMeReleaseUpdates.isNewer("v1.4.0-beta", than: "1.3.1"))
        }
    }

    @Test func longMultilinePreviewStaysInsideOneRow() throws {
        let table = NSTableView()
        let entry = ClipyMeHistoryStore.Entry(id: .init(rawValue: "layout-test"),
            title: String(repeating: "Long\r\nline\ttoken ", count: 100), types: [], updatedAt: 1, favorite: true)
        let cell = ClipyMeHistoryController.makeCell(entry: entry, query: "token", table: table)
        cell.frame = NSRect(x: 0, y: 0, width: 420, height: 30)
        cell.layoutSubtreeIfNeeded()
        let label = try #require(cell.textField)
        #expect(label.maximumNumberOfLines == 1)
        #expect(label.cell?.wraps == false)
        #expect(label.frame.height <= 20)
        #expect(label.frame.minY >= 0 && label.frame.maxY <= 30)
        #expect(label.frame.maxX <= 420)
        #expect(!label.stringValue.contains("\n"))
        #expect(!label.stringValue.contains("\r"))
        #expect(!label.stringValue.contains("\t"))
        let paragraph = label.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.lineBreakMode == .byTruncatingTail)
    }

    @Test func rapidQueryChangesOnlyDisplayLatestResults() async throws {
        try save("Alpha result")
        try save("Beta result")
        let controller = withDependencies {
            $0.pasteboardHistoryRepository = repository
        } operation: { ClipyMeHistoryController() }
        defer { controller.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try #require(controller.window?.contentView))
        let search = try #require(views.compactMap { $0 as? NSSearchField }.first)
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        search.stringValue = "Alpha"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        search.stringValue = "Beta"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(controller.numberOfRows(in: table) == 0)
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.numberOfRows(in: table) == 1)
        let cell = controller.tableView(table, viewFor: nil, row: 0) as? NSTableCellView
        #expect(cell?.textField?.stringValue == "Beta result")
        search.stringValue = "No matching content"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.numberOfRows(in: table) == 0)
    }

    @Test func searchFullTextAndLiteralPunctuation() throws {
        let id = try save(String(repeating: "x", count: 12000) + " Needle Punctuation \"%_\" café")
        #expect(try store.search(query: "needle punctuation", filter: .text, sort: .newest).map(\.id) == [id])
        #expect(try store.search(query: "\"%_\"", filter: .all, sort: .newest).map(\.id) == [id])
        #expect(try store.search(query: "É", filter: .all, sort: .newest).map(\.id) == [id])
        #expect(try store.search(query: "CAFÉ", filter: .all, sort: .newest).map(\.id) == [id])
        #expect(try store.search(query: "NEEDLE absent", filter: .all, sort: .newest).isEmpty)
        #expect(try store.search(query: "  ", filter: .all, sort: .newest).map(\.id) == [id])
    }

    @Test func sortAndPagination() throws {
        let first = try save("Zebra", at: 1)
        let second = try save("Apple", at: 2)
        #expect(try store.search(query: "", filter: .all, sort: .oldest).map(\.id) == [first, second])
        #expect(try store.search(query: "", filter: .all, sort: .newest).map(\.id) == [second, first])
        #expect(try store.search(query: "", filter: .all, sort: .alphabetical).map(\.id) == [second, first])
        #expect(try store.search(query: "", filter: .all, sort: .newest, limit: 1, offset: 1).map(\.id) == [first])
    }

    @Test func editPreservesDateAndFavoriteAndUpdatesSearch() throws {
        let oldID = try save("Old text", at: 42)
        try store.setFavorite(id: oldID, enabled: true)
        let newID = try store.edit(id: oldID, text: "Changed text", asNew: false)
        #expect(repository.fetchHistory(id: oldID) == nil)
        #expect(repository.fetchHistory(id: newID)?.updateAt == 42)
        #expect(repository.fetchContent(id: newID)?.stringValue == "Changed text")
        #expect(try store.favoriteIDs() == [newID.rawValue])
        #expect(try store.search(query: "Old", filter: .all, sort: .newest).isEmpty)
        #expect(try store.search(query: "Changed", filter: .favorites, sort: .newest).map(\.id) == [newID])
    }

    @Test func duplicateEditDoesNotDestroyEitherClip() throws {
        let original = try save("First", at: 1)
        let existing = try save("Second", at: 2)
        #expect(throws: ClipyMeHistoryStore.EditError.self) {
            try store.edit(id: original, text: "Second", asNew: false)
        }
        #expect(repository.fetchContent(id: original)?.stringValue == "First")
        #expect(repository.fetchHistory(id: existing)?.updateAt == 2)
        let copy = try store.edit(id: original, text: "Second", asNew: true)
        #expect(copy != original && copy != existing)
        #expect(repository.fetchContent(id: original)?.stringValue == "First")
        #expect(repository.fetchContent(id: copy)?.stringValue == "Second")
    }

    @Test func savingUnchangedCopyKeepsItsIdentityAndDate() throws {
        let original = try save("Same text", at: 77)
        let copy = try store.edit(id: original, text: "Same text", asNew: true)
        let timestamp = repository.fetchHistory(id: copy)?.updateAt
        let saved = try store.edit(id: copy, text: "Same text", asNew: false)
        #expect(saved == copy)
        #expect(repository.fetchHistory(id: copy)?.updateAt == timestamp)
        #expect(repository.fetchHistory(id: original)?.updateAt == 77)
    }

    @Test func failedWriteRollsBackAllChanges() throws {
        let original = try save("Keep this", at: 77)
        try store.setFavorite(id: original, enabled: true)
        try database.write { connection in
            try connection.execute(sql: """
                CREATE TEMP TRIGGER deny_new_assets BEFORE INSERT ON pasteboardHistoryAssets
                BEGIN SELECT RAISE(ABORT, 'Simulated write failure'); END;
                """)
        }
        #expect(throws: (any Error).self) {
            try store.edit(id: original, text: "Cannot save", asNew: false)
        }
        #expect(repository.fetchContent(id: original)?.stringValue == "Keep this")
        #expect(try store.favoriteIDs() == [original.rawValue])
        #expect(try store.search(query: "", filter: .all, sort: .newest).map(\.id) == [original])
    }

    @Test func favoritesSurviveAutomaticPruningButCanBeExplicitlyDeleted() throws {
        let favorite = try save("Favorite", at: 1)
        let old = try save("Old", at: 2)
        let recent = try save("Recent", at: 3)
        try store.setFavorite(id: favorite, enabled: true)
        repository.deleteOverflowingHistories(maxHistorySize: 1)
        #expect(repository.fetchHistory(id: favorite) != nil)
        #expect(repository.fetchHistory(id: recent) != nil)
        #expect(repository.fetchHistory(id: old) == nil)
        repository.deleteOverflowingHistories(maxHistorySize: 0)
        #expect(repository.fetchHistory(id: favorite) != nil)
        #expect(repository.fetchHistory(id: recent) == nil)
        repository.deleteAll()
        #expect(try store.favoriteIDs().isEmpty)
    }

    @Test func richTextRequiresSavingANewCopy() throws {
        let content = try #require(PasteboardContent(assets: [
            .init(type: .string, data: Data("Rich".utf8)),
            .init(type: .rtf, data: Data("{\\rtf1 Rich}".utf8))
        ]))
        let id = PasteboardHistory.ID(rawValue: content.hash)
        repository.save(id: id, content: content, updateAt: 1)
        #expect(throws: ClipyMeHistoryStore.EditError.self) {
            try store.edit(id: id, text: "Edited", asNew: false)
        }
        let copy = try store.edit(id: id, text: "Edited", asNew: true)
        #expect(repository.fetchContent(id: id) == content)
        #expect(repository.fetchContent(id: copy)?.isOnlyStringType == true)
    }
}
