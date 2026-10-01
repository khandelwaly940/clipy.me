import AppKit
import Dependencies
import GRDB
import SQLiteData

/// Uses the existing database pool. No polling, image decoding, or content cache.
final class ClipyMeHistoryStore {
    @Dependency(\.defaultDatabase) private var database

    enum Sort: String, CaseIterable {
        case bestMatch, original, newest, oldest, alphabetical, type

        var title: String {
            switch self {
            case .bestMatch: return "Best match (search)"
            case .original: return "Original order"
            case .newest: return "Newest first"
            case .oldest: return "Oldest first"
            case .alphabetical: return "Alphabetical"
            case .type: return "Content type"
            }
        }
        var orderSQL: String {
            switch self {
            case .bestMatch: return Sort.original.orderSQL
            case .original:
                return UserDefaults.standard.bool(forKey: Constants.UserDefaults.reorderClipsAfterPasting)
                    ? "h.updateAt DESC, h.id" : "h.updateAt ASC, h.id"
            case .newest: return "h.updateAt DESC, h.id"
            case .oldest: return "h.updateAt ASC, h.id"
            case .alphabetical: return "h.title COLLATE NOCASE, h.updateAt DESC, h.id"
            case .type: return "h.pasteboardTypes, h.updateAt DESC, h.id"
            }
        }
    }

    enum Filter: String, CaseIterable {
        case all = "All clips", text = "Text", links = "Links", images = "Images", favorites = "Favorites"
    }

    struct Entry {
        let id: PasteboardHistory.ID
        let title: String
        let types: [String]
        let updatedAt: Int
        let favorite: Bool
        var label: String {
            if !title.isEmpty { return title.replacingOccurrences(of: "\n", with: " ") }
            if types.contains("public.png") || types.contains("public.tiff") { return "(Image)" }
            if types.contains("com.adobe.pdf") { return "(PDF)" }
            return "(Files or other content)"
        }
    }

    static let sortKey = "ClipyMe.searchSort"
    static let changed = Notification.Name("ClipyMe.historyOptionsChanged")
    static var searchSort: Sort {
        // The former shared history sort must not become the search default.
        // Only explicit choices made with the separate search control persist.
        get { Sort(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .bestMatch }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sortKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // Only text assets enter the search index. Image/PDF blobs remain in their original tables.
    // Existing Clipy tables and migration identifiers are unchanged.
    static let migrationSQL = """
    CREATE TABLE clipyMeFavorites (
      historyID TEXT PRIMARY KEY NOT NULL REFERENCES pasteboardHistories(id) ON DELETE CASCADE
    ) STRICT;
    CREATE VIEW clipyMeTextContent AS
      SELECT rowid, pasteboardHistoryID AS id, CAST(data AS TEXT) AS text
      FROM pasteboardHistoryAssets
      WHERE pasteboardType IN ('public.utf8-plain-text', 'NSStringPboardType');
    CREATE VIRTUAL TABLE clipyMeFullText USING fts5(
      id UNINDEXED, text, content='clipyMeTextContent', content_rowid='rowid',
      tokenize='trigram', detail=none, columnsize=0
    );
    INSERT INTO clipyMeFullText(clipyMeFullText) VALUES('rebuild');
    CREATE TRIGGER clipyMe_insert_text AFTER INSERT ON pasteboardHistoryAssets
      WHEN new.pasteboardType IN ('public.utf8-plain-text', 'NSStringPboardType') BEGIN
      INSERT INTO clipyMeFullText(rowid, id, text) VALUES(new.rowid, new.pasteboardHistoryID, CAST(new.data AS TEXT));
    END;
    CREATE TRIGGER clipyMe_delete_text AFTER DELETE ON pasteboardHistoryAssets
      WHEN old.pasteboardType IN ('public.utf8-plain-text', 'NSStringPboardType') BEGIN
      INSERT INTO clipyMeFullText(clipyMeFullText, rowid, id, text)
      VALUES('delete', old.rowid, old.pasteboardHistoryID, CAST(old.data AS TEXT));
    END;
    CREATE TRIGGER clipyMe_update_text AFTER UPDATE ON pasteboardHistoryAssets BEGIN
      INSERT INTO clipyMeFullText(clipyMeFullText, rowid, id, text)
      SELECT 'delete', old.rowid, old.pasteboardHistoryID, CAST(old.data AS TEXT)
      WHERE old.pasteboardType IN ('public.utf8-plain-text', 'NSStringPboardType');
      INSERT INTO clipyMeFullText(rowid, id, text)
      SELECT new.rowid, new.pasteboardHistoryID, CAST(new.data AS TEXT)
      WHERE new.pasteboardType IN ('public.utf8-plain-text', 'NSStringPboardType');
    END;
    """

    func search(query: String, filter: Filter, sort: Sort, limit: Int = 200, offset: Int = 0) throws -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var conditions = [String]()
        var indexConditions = [String]()
        var indexArguments = StatementArguments()
        var arguments = StatementArguments()
        for word in words {
            if word.count >= 3 && word.utf8.allSatisfy({ $0 < 128 }) {
                // detail=none keeps the index compact. Intersect single trigrams,
                // then verify the literal substring in chunks: grams alone are
                // candidates, never proof of a valid match.
                let letters = Array(word.lowercased())
                let grams = Set((0..<(letters.count - 2)).prefix(32).map {
                    "\"" + String(letters[$0...($0 + 2)]).replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }).sorted().joined(separator: " AND ")
                indexConditions.append("h.id IN (SELECT pasteboardHistoryID FROM pasteboardHistoryAssets WHERE rowid IN (SELECT rowid FROM clipyMeFullText WHERE clipyMeFullText MATCH ?))")
                indexArguments += [grams]
                conditions.append("""
                    EXISTS (SELECT 1 FROM pasteboardHistoryAssets s WHERE s.pasteboardHistoryID=h.id
                      AND CASE WHEN s.pasteboardType IN ('public.utf8-plain-text', 'NSStringPboardType')
                        AND s.rowid IN (SELECT rowid FROM clipyMeFullText WHERE clipyMeFullText MATCH ?)
                        THEN clipymeAssetContains(s.rowid, ?) ELSE 0 END)
                    """)
                arguments += [grams, word]
            } else {
                // CASE guarantees binary assets are never opened, even if SQLite
                // reorders the other WHERE predicates while optimizing the view.
                conditions.append("""
                    EXISTS (SELECT 1 FROM pasteboardHistoryAssets s WHERE s.pasteboardHistoryID=h.id
                      AND CASE WHEN s.pasteboardType IN ('public.utf8-plain-text', 'NSStringPboardType')
                        THEN clipymeAssetContains(s.rowid, ?) ELSE 0 END)
                    """)
                arguments += [word]
            }
        }
        switch filter {
        case .all: break
        case .favorites: conditions.append("f.historyID IS NOT NULL")
        case .text: conditions.append("EXISTS (SELECT 1 FROM clipyMeTextContent s WHERE s.id=h.id)")
        case .links:
            conditions.append("(h.title LIKE 'http://%' OR h.title LIKE 'https://%' OR h.pasteboardTypes LIKE '%public.url%')")
        case .images:
            conditions.append("(h.pasteboardTypes LIKE '%public.png%' OR h.pasteboardTypes LIKE '%public.tiff%' OR h.pasteboardTypes LIKE '%NSTIFFPboardType%')")
        }
        let predicate = conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
        var order = sort.orderSQL
        var rankArguments = StatementArguments()
        if sort == .bestMatch, !words.isEmpty {
            let phrase = words.joined(separator: " ")
            if phrase.utf8.allSatisfy({ $0 < 128 }) {
                let title = "trim(h.title, char(9) || char(10) || char(13) || ' ')"
                let titleTerms = words.map { _ in "instr(lower(h.title), lower(?)) > 0" }.joined(separator: " AND ")
                order = """
                    CASE WHEN length(CAST(h.title AS BLOB)) = length(h.title) THEN
                      CASE WHEN \(title) = ? COLLATE NOCASE THEN 0
                           WHEN instr(lower(\(title)), lower(?)) = 1 THEN 1
                           WHEN instr(lower(\(title)), lower(?)) > 0 THEN 2
                           WHEN (\(titleTerms)) THEN 3 ELSE 4 END
                    ELSE clipymeRank(h.title, ?) END, length(h.title), h.updateAt DESC, h.id
                    """
                rankArguments += [phrase, phrase, phrase]
                rankArguments += StatementArguments(words)
                rankArguments += [phrase]
            } else {
                order = "clipymeRank(h.title, ?), length(h.title), h.updateAt DESC, h.id"
                rankArguments += [phrase]
            }
        }
        arguments += rankArguments
        arguments += [max(1, min(limit, 1000)), max(0, offset)]
        return try database.read { connection in
            // Title matches always outrank body-only matches. Verify a bounded
            // page of the best titles first; stop only when the whole requested
            // page is valid. Otherwise fall back to the full-history query.
            if sort == .bestMatch, filter == .all, offset == 0, limit > 0, limit <= 31,
               !words.isEmpty, words.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }) {
                let titlePredicate = words.map { _ in
                    "CASE WHEN length(CAST(h.title AS BLOB)) = length(h.title) THEN instr(lower(h.title), lower(?)) > 0 ELSE clipymeRank(h.title, ?) < 4 END"
                }.joined(separator: " AND ")
                let indexPredicate = indexConditions.isEmpty ? "1" : indexConditions.joined(separator: " AND ")
                var titleArguments = indexArguments
                titleArguments += StatementArguments(words.flatMap { [$0, $0] })
                titleArguments += rankArguments
                let candidates = try Row.fetchAll(connection, sql: """
                    SELECT h.*, f.historyID IS NOT NULL AS favorite FROM pasteboardHistories h
                    LEFT JOIN clipyMeFavorites f ON f.historyID=h.id
                    WHERE \(indexPredicate) AND \(titlePredicate)
                      AND EXISTS (SELECT 1 FROM clipyMeTextContent s WHERE s.id=h.id)
                    ORDER BY \(order) LIMIT 128
                    """, arguments: titleArguments)
                var verified = [Entry]()
                for candidate in candidates {
                    let id: String = candidate["id"]
                    let assetRows = try Int64.fetchAll(connection, sql: "SELECT rowid FROM clipyMeTextContent WHERE id=?", arguments: [id])
                    let valid = try words.allSatisfy { word in
                        try assetRows.contains { rowID in
                            try ClipyMeTextReader.match(database: connection, rowID: rowID, term: word) != nil
                        }
                    }
                    if valid { verified.append(Self.entry(candidate)) }
                    if verified.count == limit { return verified }
                }
            }
            return try Row.fetchAll(connection, sql: """
                SELECT h.*, f.historyID IS NOT NULL AS favorite FROM pasteboardHistories h
                LEFT JOIN clipyMeFavorites f ON f.historyID=h.id
                WHERE \(predicate) ORDER BY \(order) LIMIT ? OFFSET ?
                """, arguments: arguments).map(Self.entry)
        }
    }

    static func rank(title: String, query: String) -> Int {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        let phrase = query.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        if title == phrase { return 0 }
        if title.hasPrefix(phrase) { return 1 }
        if title.range(of: phrase, options: .literal) != nil { return 2 }
        return phrase.split(whereSeparator: \.isWhitespace).allSatisfy {
            title.range(of: String($0), options: .literal) != nil
        } ? 3 : 4
    }

    func preview(id: PasteboardHistory.ID, query: String, limit: Int) throws -> String? {
        guard let term = query.split(whereSeparator: \.isWhitespace).first else { return nil }
        return try database.read { connection in
            let rows = try Int64.fetchAll(connection, sql: "SELECT rowid FROM clipyMeTextContent WHERE id=?", arguments: [id.rawValue])
            for rowID in rows {
                if let preview = try ClipyMeTextReader.match(database: connection, rowID: rowID,
                                                            term: String(term), previewLength: max(1, min(limit, 10_000))) {
                    return preview
                }
            }
            return nil
        }
    }

    private static func entry(_ row: Row) -> Entry {
        let types: String = row["pasteboardTypes"]
        return Entry(id: .init(rawValue: row["id"]), title: row["title"],
                     types: (try? JSONDecoder().decode([String].self, from: Data(types.utf8))) ?? [],
                     updatedAt: row["updateAt"], favorite: row["favorite"])
    }

    func favoriteIDs() throws -> Set<String> {
        try database.read { connection in
            Set(try String.fetchAll(connection, sql: "SELECT historyID FROM clipyMeFavorites"))
        }
    }

    func setFavorite(id: PasteboardHistory.ID, enabled: Bool) throws {
        try database.write { connection in
            if enabled {
                try connection.execute(sql: "INSERT OR IGNORE INTO clipyMeFavorites(historyID) VALUES (?)", arguments: [id.rawValue])
            } else {
                try connection.execute(sql: "DELETE FROM clipyMeFavorites WHERE historyID=?", arguments: [id.rawValue])
            }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    enum EditError: LocalizedError {
        case missing, unsupported, duplicate, empty

        var errorDescription: String? {
            switch self {
            case .missing: return "This clip is no longer in history. Your edit has not been saved."
            case .unsupported: return "Only plain-text clips can be replaced. Use Save as New to create a plain-text copy."
            case .duplicate: return "Another clip already contains this text. Use Save as New to keep both clips."
            case .empty: return "Enter some text before saving."
            }
        }
    }

    /// One transaction: any failure leaves the original clip, assets and favorite intact.
    @discardableResult
    func edit(id: PasteboardHistory.ID, text: String, asNew: Bool) throws -> PasteboardHistory.ID {
        guard !text.isEmpty, let content = PasteboardContent(assets: [.init(type: .string, data: Data(text.utf8))]) else {
            throw EditError.empty
        }
        let newID = PasteboardHistory.ID(rawValue: asNew ? UUID().uuidString : content.hash)
        return try database.write { connection -> PasteboardHistory.ID in
            guard let original = try PasteboardHistory.find(id).fetchOne(connection) else { throw EditError.missing }
            let types = original.pasteboardTypes
            guard asNew || types == [.string] || types == [.deprecatedString] else { throw EditError.unsupported }
            if !asNew {
                let originalText = try Data.fetchOne(connection, sql: "SELECT data FROM pasteboardHistoryAssets WHERE pasteboardHistoryID=? ORDER BY \"index\" LIMIT 1", arguments: [id.rawValue])
                if originalText == Data(text.utf8) { return id }
            }
            guard try PasteboardHistory.find(newID).fetchOne(connection) == nil else { throw EditError.duplicate }
            let favorite = try Bool.fetchOne(connection, sql: "SELECT EXISTS(SELECT 1 FROM clipyMeFavorites WHERE historyID=?)", arguments: [id.rawValue]) ?? false
            let history = PasteboardHistory(id: newID, title: String(text.prefix(10001)), pasteboardTypes: content.types,
                                            updateAt: asNew ? Int(Date().timeIntervalSince1970) : original.updateAt,
                                            deviceID: original.deviceID)
            try PasteboardHistory.insert { history }.execute(connection)
            let asset = PasteboardHistoryAsset.Draft(pasteboardHistoryID: newID, index: 0, pasteboardType: .string, data: Data(text.utf8))
            try PasteboardHistoryAsset.insert { asset }.execute(connection)
            if let image = content.colorCodeImage, let data = image.tiffRepresentation {
                let thumbnail = PasteboardHistoryThumbnailAsset(pasteboardHistoryID: newID, kind: .colorCode, data: data)
                try PasteboardHistoryThumbnailAsset.insert { thumbnail }.execute(connection)
            }
            if !asNew {
                if favorite {
                    try connection.execute(sql: "INSERT INTO clipyMeFavorites(historyID) VALUES (?)", arguments: [newID.rawValue])
                }
                try PasteboardHistory.delete().where { $0.id.eq(id) }.execute(connection)
            }
            return newID
        }
    }
}
