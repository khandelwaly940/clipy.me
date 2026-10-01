import AppKit
import GRDB

/// One-shot installer import. Reads a backup, writes a new staging directory,
/// and never opens the user's ClipyMe database or starts clipboard monitoring.
enum ClipyMeCopyClipImporter {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func run(source: URL, destination: URL, preferences: URL) throws {
        let files = FileManager.default
        try require(!files.fileExists(atPath: destination.path), "Import destination already exists")
        var configuration = Configuration()
        configuration.readonly = true
        let input = try DatabaseQueue(path: source.path, configuration: configuration)
        try input.read { database in
            try require(try String.fetchOne(database, sql: "PRAGMA integrity_check") == "ok", "CopyClip database failed integrity check")
            let tables = Set(try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
            try require(tables.contains("Z_METADATA") && tables.contains("ZCLIPPING"), "Unsupported CopyClip database format")
            let columns = Set(try database.columns(in: "ZCLIPPING").map(\.name))
            let required: Set<String> = ["Z_PK", "ZCONTENTS", "ZDATERECORDED", "ZTYPE"]
            let supported: Set<String> = ["Z_PK", "Z_ENT", "Z_OPT", "ZCONTENTS", "ZDATERECORDED", "ZTYPE", "ZDISPLAYNAME", "ZDISPLAYNAMELENGTH", "ZDISPLAYTITLE", "ZPINNED", "ZPINNEDORDER", "ZTOTALPASTES", "ZATTRIBUTEDCONTENTS", "ZSOURCE"]
            try require(required.isSubset(of: columns) && columns.isSubset(of: supported), "Unrecognized CopyClip schema; original data was not changed")
        }
        try files.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let output = try DatabaseQueue(path: destination.appendingPathComponent("sqlite.db").path)
            var migrator = DatabaseMigrator()
            migrator.registerMigration()
            try migrator.migrate(output)
            var imported = 0
            var missingDates = 0
            var prefs = [String: Any]()
            let sourcePrefs = try PropertyListSerialization.propertyList(from: Data(contentsOf: preferences), format: nil) as? [String: Any] ?? [:]
            try input.read { sourceDB in
                try output.write { targetDB in
                    let cursor = try Row.fetchCursor(sourceDB, sql: "SELECT * FROM ZCLIPPING ORDER BY ZDATERECORDED, Z_PK")
                    while let row = try cursor.next() {
                        try autoreleasepool {
                            let columns = Set(row.columnNames)
                            let plain: String? = row["ZCONTENTS"]
                            var attributed: NSAttributedString?
                            if columns.contains("ZATTRIBUTEDCONTENTS"), let archived: Data = row["ZATTRIBUTEDCONTENTS"], !archived.isEmpty {
                                attributed = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: archived)
                                try require(attributed != nil, "CopyClip rich text could not be decoded; import stopped")
                            }
                            guard let text = plain ?? attributed?.string else {
                                throw Failure(description: "CopyClip contains a clip without readable text; import stopped")
                            }
                            var assets = [PasteboardContent.Asset(type: .string, data: Data(text.utf8))]
                            if let attributed {
                                try require(attributed.string == text, "CopyClip plain and formatted text disagree; import stopped")
                                let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                                assets.append(.init(type: .rtf, data: rtf))
                            }
                            let content = PasteboardContent(assets: assets)!
                            let date: Double? = row["ZDATERECORDED"]
                            let primaryKey: Int = row["Z_PK"]
                            if date == nil { missingDates += 1 }
                            let time = (date ?? Double(primaryKey)) + Date.timeIntervalBetween1970AndReferenceDate
                            try require(time.isFinite && time >= 0 && time < 253_402_300_799, "Invalid CopyClip timestamp")
                            let title: String? = columns.contains("ZDISPLAYTITLE") ? row["ZDISPLAYTITLE"] : nil
                            try targetDB.execute(sql: """
                                INSERT INTO pasteboardHistories(id,title,pasteboardTypes,updateAt)
                                VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,
                                updateAt=max(pasteboardHistories.updateAt,excluded.updateAt)
                                """, arguments: [content.hash, title?.isEmpty == false ? title! : String(text.prefix(10_001)),
                                    String(data: try JSONEncoder().encode(content.types.map(\.rawValue)), encoding: .utf8)!, Int(time)])
                            for (index, asset) in assets.enumerated() {
                                let assetID = content.hash + "-" + String(index)
                                try targetDB.execute(sql: """
                                    INSERT OR IGNORE INTO pasteboardHistoryAssets(id,pasteboardHistoryID,"index",pasteboardType,data)
                                    VALUES (?,?,?,?,?)
                                    """, arguments: [assetID, content.hash, index, asset.type.rawValue, asset.data])
                                let verified = try Data.fetchOne(targetDB, sql: "SELECT data FROM pasteboardHistoryAssets WHERE id=?", arguments: [assetID])
                                try require(verified == asset.data, "Imported clip failed byte verification")
                            }
                            if columns.contains("ZPINNED"), let pinned: Bool = row["ZPINNED"], pinned {
                                try targetDB.execute(sql: "INSERT OR IGNORE INTO clipyMeFavorites(historyID) VALUES (?)", arguments: [content.hash])
                            }
                            imported += 1
                        }
                    }
                    try require(try Int.fetchOne(sourceDB, sql: "SELECT count(*) FROM ZCLIPPING") == imported, "Imported clip count differs")
                    try require(try Row.fetchAll(targetDB, sql: "PRAGMA foreign_key_check").isEmpty, "Imported clip relationships failed verification")
                }
                if try sourceDB.tableExists("ZSOURCEAPP") {
                    let columns = Set(try sourceDB.columns(in: "ZSOURCEAPP").map(\.name))
                    if columns.contains("ZISBLACKLISTED") {
                        let excluded = try Row.fetchAll(sourceDB, sql: "SELECT * FROM ZSOURCEAPP WHERE ZISBLACKLISTED=1")
                        let apps = try excluded.map { row -> CPYAppInfo in
                            let bundle: String? = columns.contains("ZBUNDLE") ? row["ZBUNDLE"] : nil
                            let name: String? = columns.contains("ZNAME") ? row["ZNAME"] : nil
                            guard let bundle, !bundle.isEmpty, let app = CPYAppInfo(info: [
                                kCFBundleIdentifierKey as String: bundle as NSString,
                                kCFBundleNameKey as String: (name ?? bundle) as NSString]) else {
                                throw Failure(description: "An excluded CopyClip app has no bundle identifier; import stopped to preserve exclusions")
                            }
                            return app
                        }
                        prefs[Constants.UserDefaults.excludeApplications] = try NSKeyedArchiver.archivedData(withRootObject: apps, requiringSecureCoding: false)
                    }
                }
            }
            for (old, new) in ["startAtLogin": Constants.UserDefaults.loginItem,
                                "pasteDirectly": Constants.UserDefaults.inputPasteCommand,
                                "ignoreConcealedData": Constants.UserDefaults.ignoreConcealedPasteboardType] {
                if let value = sourcePrefs[old] as? NSNumber { prefs[new] = value.boolValue }
            }
            // Never prune imported history on the first clipboard change.
            prefs[Constants.UserDefaults.maxHistorySize] = max(100, imported, (sourcePrefs["saveClippingsCount"] as? NSNumber)?.intValue ?? 0)
            prefs[Constants.UserDefaults.reorderClipsAfterPasting] = true
            prefs["ClipyMe.searchSort"] = "bestMatch"
            let prefData = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
            try prefData.write(to: destination.appendingPathComponent("imported-preferences.plist"), options: .atomic)
            try output.close()
            print("Verified CopyClip import: \(imported) source clips; identical content consolidated. Missing dates: \(missingDates).")
            print("Mapped history limit, compatible paste/login settings, exclusions, and pins. Other CopyClip settings remain in the backup.")
        } catch {
            try? files.removeItem(at: destination)
            throw error
        }
    }
}
