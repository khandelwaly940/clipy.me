import AppKit
import Dependencies
import GRDB
import SQLiteData

/// Uses the existing database pool. No polling, image decoding, or content cache.
final class ClipyMeHistoryStore {
    @Dependency(\.defaultDatabase) private var database

    enum Sort: String, CaseIterable {
        case original, newest, oldest, alphabetical, type

        var title: String {
            switch self {
            case .original: return "Original order"
            case .newest: return "Newest first"
            case .oldest: return "Oldest first"
            case .alphabetical: return "Alphabetical"
            case .type: return "Content type"
            }
        }
        var orderSQL: String {
            switch self {
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

    static let sortKey = "ClipyMe.historySort"
    static let changed = Notification.Name("ClipyMe.historyOptionsChanged")
    static var selectedSort: Sort {
        get { Sort(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .original }
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
        var arguments = StatementArguments()
        for word in words {
            if word.count >= 3 && word.utf8.allSatisfy({ $0 < 128 }) && !word.contains("%") && !word.contains("_") {
                // Trigram LIKE uses a compact positional-data-free index. Parameters keep
                // quotes literal; wildcard characters use the literal fallback below.
                conditions.append("h.id IN (SELECT id FROM clipyMeFullText WHERE text LIKE ?)")
                arguments += ["%" + word + "%"]
            } else {
                // Unicode, short terms and literal SQL wildcards use Unicode-aware matching
                // over text assets only, never image/PDF blobs.
                conditions.append("h.id IN (SELECT id FROM clipyMeTextContent WHERE clipymeContains(text, ?))")
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
        arguments += [max(1, min(limit, 1000)), max(0, offset)]
        return try database.read { connection in
            try Row.fetchAll(connection, sql: """
                SELECT h.*, f.historyID IS NOT NULL AS favorite FROM pasteboardHistories h
                LEFT JOIN clipyMeFavorites f ON f.historyID=h.id
                WHERE \(predicate) ORDER BY \(sort.orderSQL) LIMIT ? OFFSET ?
                """, arguments: arguments).map { row in
                    let types: String = row["pasteboardTypes"]
                    return Entry(id: .init(rawValue: row["id"]), title: row["title"],
                                 types: (try? JSONDecoder().decode([String].self, from: Data(types.utf8))) ?? [],
                                 updatedAt: row["updateAt"], favorite: row["favorite"])
            }
        }
    }

    func menuDetails(includesThumbnails: Bool, limit: Int) throws -> [PasteboardHistoryDetail] {
        try database.read { connection in
            let rawIDs = try String.fetchAll(connection, sql: "SELECT h.id FROM pasteboardHistories h ORDER BY \(Self.selectedSort.orderSQL) LIMIT ?", arguments: [max(0, limit)])
            let ids = rawIDs.map { PasteboardHistory.ID(rawValue: $0) }
            let histories = PasteboardHistory.where { $0.id.in(ids) }
            let details: [PasteboardHistoryDetail]
            if includesThumbnails {
                details = try histories
                    .leftJoin(PasteboardHistoryThumbnailAsset.all) { $0.id.eq($1.pasteboardHistoryID) }
                    .select { PasteboardHistoryDetail.Columns(history: $0, thumbnailAsset: $1) }
                    .fetchAll(connection)
            } else {
                details = try histories.fetchAll(connection).map { PasteboardHistoryDetail(history: $0, thumbnailAsset: nil) }
            }
            let byID = Dictionary(uniqueKeysWithValues: details.map { ($0.history.id, $0) })
            return ids.compactMap { byID[$0] }
        }
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
