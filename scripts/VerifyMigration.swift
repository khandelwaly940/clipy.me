// ClipyMe migration verification helper. MIT license, see LICENSE.
import Foundation
import CryptoKit
import SQLite3

struct Failure: Error, CustomStringConvertible { let description: String }
let files = FileManager.default
func require(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(description: message) } }
func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func copyTree(_ source: URL, _ destination: URL) throws {
    try require(!files.fileExists(atPath: destination.path), "Copy destination already exists")
    let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
    if values.isSymbolicLink == true || values.isRegularFile == true {
        try files.copyItem(at: source, to: destination)
    } else if values.isDirectory == true {
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try copyTree(child, destination.appendingPathComponent(child.lastPathComponent))
        }
    } // Realm notification FIFOs and sockets contain no stored clipboard data.
}
func database(_ path: String) throws -> OpaquePointer {
    var connection: OpaquePointer?
    let result = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil)
    guard result == SQLITE_OK, let connection else {
        if let connection { sqlite3_close(connection) }
        throw Failure(description: "Cannot read database")
    }
    return connection
}
func strings(_ connection: OpaquePointer, _ sql: String) throws -> [String] {
    var statement: OpaquePointer?
    try require(sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, "Unsupported or damaged database schema")
    defer { sqlite3_finalize(statement) }
    var result = [String]()
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
        if let value = sqlite3_column_text(statement, 0) { result.append(String(cString: value)) }
        status = sqlite3_step(statement)
    }
    try require(status == SQLITE_DONE, "Database read failed")
    return result
}
func validate(_ connection: OpaquePointer) throws {
    try require(try strings(connection, "PRAGMA integrity_check") == ["ok"], "Database integrity check failed")
    let tables = Set(try strings(connection, "SELECT name FROM sqlite_master WHERE type='table'"))
    let required: Set<String> = ["pasteboardHistories", "pasteboardHistoryAssets", "pasteboardHistoryThumbnailAssets", "snippets", "snippetFolders"]
    try require(required.isSubset(of: tables), "Required clipboard tables are missing")
    try require(try strings(connection, "PRAGMA foreign_key_check").isEmpty, "Database relationship check failed")
    let known: Set<String> = ["Create initial tables", "Create search indexes", "ClipyMe full text and favorites"]
    let migrations = try strings(connection, "SELECT identifier FROM grdb_migrations")
    try require(Set(migrations).isSubset(of: known), "This Clipy database is newer than supported. Original installation was not changed.")
}
func digestTable(_ connection: OpaquePointer, _ table: String) throws -> (Int, String) {
    var statement: OpaquePointer?
    try require(sqlite3_prepare_v2(connection, "SELECT * FROM \"\(table)\" ORDER BY 1", -1, &statement, nil) == SQLITE_OK, "Missing clipboard table")
    defer { sqlite3_finalize(statement) }
    var hash = SHA256()
    var count = 0
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
        count += 1
        for column in 0..<sqlite3_column_count(statement) {
            let type = sqlite3_column_type(statement, column)
            hash.update(data: Data([UInt8(type)]))
            let length = Int(sqlite3_column_bytes(statement, column))
            var size = UInt64(length).littleEndian
            withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }
            if let value = sqlite3_column_blob(statement, column) { hash.update(data: Data(bytes: value, count: length)) }
        }
        status = sqlite3_step(statement)
    }
    try require(status == SQLITE_DONE, "Clipboard row verification failed")
    return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
}
func manifest(_ root: URL) throws -> [String: String] {
    var result = [String: String]()
    let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
    while let url = enumerator.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isRegularFile == true && values.isSymbolicLink != true && url.standardizedFileURL.path != root.appendingPathComponent("manifest.json").standardizedFileURL.path {
            result[String(url.path.dropFirst(root.path.count + 1))] = try hashFile(url)
        }
    }
    return result
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    try require(args.count >= 2, "Usage: ClipyMeVerify copy-tree|compare-db|compare-plists|manifest|verify-manifest PATH [PATH]")
    let source = URL(fileURLWithPath: args[1])
    switch args[0] {
    case "locate-copyclip":
        // Search only the caller's known CopyClip support directory, never the
        // entire home directory. Print paths, never clipboard contents.
        let enumerator = files.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
            guard ["sqlite", "db"].contains(url.pathExtension.lowercased()) else { continue }
            if let connection = try? database(url.path) {
                let tables = (try? strings(connection, "SELECT name FROM sqlite_master WHERE type='table'")) ?? []
                sqlite3_close(connection)
                if tables.contains("ZCLIPPING") && tables.contains("Z_METADATA") { print(url.path) }
            }
        }
    case "copy-tree":
        try require(args.count == 3, "Destination required")
        try copyTree(source, URL(fileURLWithPath: args[2]))
    case "compare-copyclip-db":
        try require(args.count == 3, "Destination required")
        let first = try database(args[1]); defer { sqlite3_close(first) }
        let second = try database(args[2]); defer { sqlite3_close(second) }
        try require(try strings(first, "PRAGMA integrity_check") == ["ok"], "CopyClip database is damaged")
        try require(try strings(second, "PRAGMA integrity_check") == ["ok"], "CopyClip backup is damaged")
        let tables = Set(try strings(first, "SELECT name FROM sqlite_master WHERE type='table'"))
        try require(tables.contains("ZCLIPPING") && tables.contains("Z_METADATA"), "Unrecognized CopyClip database")
        for table in ["ZCLIPPING", "ZSOURCEAPP", "Z_METADATA", "Z_PRIMARYKEY"] where tables.contains(table) {
            try require(try digestTable(first, table) == digestTable(second, table), "CopyClip backup differs; migration stopped")
        }
        print("Verified CopyClip backup rows and asset bytes")
    case "compare-db":
        try require(args.count == 3, "Destination required")
        let first = try database(args[1]); defer { sqlite3_close(first) }
        let second = try database(args[2]); defer { sqlite3_close(second) }
        try validate(first); try validate(second)
        let tables = try strings(first, "SELECT name FROM sqlite_master WHERE type='table'")
        for table in ["pasteboardHistories", "pasteboardHistoryAssets", "pasteboardHistoryThumbnailAssets", "snippets", "snippetFolders", "clipyMeFavorites"] where tables.contains(table) {
            let before = try digestTable(first, table)
            let after = try digestTable(second, table)
            try require(before == after, "Clipboard data differs in \(table); installation stopped")
            print("Verified \(table): \(before.0) rows")
        }
    case "compare-plists":
        try require(args.count == 3, "Destination required")
        let before = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as! NSDictionary
        let after = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: args[2])), format: nil) as! NSDictionary
        try require(before.isEqual(after), "Preferences differ; installation stopped")
        print("Verified all saved preferences")
    case "manifest":
        try JSONEncoder().encode(manifest(source)).write(to: source.appendingPathComponent("manifest.json"), options: .atomic)
    case "verify-manifest":
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        try require(try manifest(source) == expected, "Backup checksum verification failed")
        print("Verified backup checksums")
    default: throw Failure(description: "Unknown command")
    }
} catch {
    FileHandle.standardError.write(Data("ClipyMe: \(error)\n".utf8))
    exit(1)
}
