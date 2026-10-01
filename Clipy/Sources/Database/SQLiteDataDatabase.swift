//
//  SQLiteDataDatabase.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Shunsuke Furubayashi on 2026/05/22.
//
//  Copyright © 2015-2026 Clipy Project.
//

import Dependencies
import Foundation
import SQLiteData
import GRDB
import SQLite3
import SwiftData

enum SQLiteDataDatabase {
    static func databaseURL() throws -> URL {
        var applicationSupportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            applicationSupportDirectory.append(path: bundleIdentifier)
            try? FileManager.default.createDirectory(
                at: applicationSupportDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        return applicationSupportDirectory.appendingPathComponent("sqlite.db")
    }

    @available(macOS 14, *)
    static var isCloudKitEnabled: Bool {
        ModelConfiguration(groupContainer: .automatic).cloudKitContainerIdentifier != nil
    }
}

extension DependencyValues {
    mutating func bootstrapDatabase() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            database.add(function: DatabaseFunction("clipymeRank", argumentCount: 2, pure: true) { values in
                guard let title = String.fromDatabaseValue(values[0]),
                      let query = String.fromDatabaseValue(values[1]) else { return 4 }
                return ClipyMeHistoryStore.rank(title: title, query: query)
            })
            database.add(function: DatabaseFunction("clipymeAssetContains", argumentCount: 2, pure: true) { [weak database] values in
                guard let database, let rowID = Int64.fromDatabaseValue(values[0]),
                      let term = String.fromDatabaseValue(values[1]) else { return false }
                return try ClipyMeTextReader.match(database: database, rowID: rowID, term: term) != nil
            })
            // SQLite's built-in lower() only handles ASCII. Short search terms need
            // Unicode-aware matching because trigram indexes require 3 characters.
            database.add(function: DatabaseFunction("clipymeContains", argumentCount: 2, pure: true) { values in
                guard let text = String.fromDatabaseValue(values[0]),
                      let term = String.fromDatabaseValue(values[1]) else { return false }
                return text.range(of: term, options: .caseInsensitive) != nil
            })
        }
        let database = try SQLiteData.defaultDatabase(
            path: SQLiteDataDatabase.databaseURL().absoluteString,
            configuration: configuration
        )

        var migrator = DatabaseMigrator()
        migrator.registerMigration()
        // Never erase personal clipboard data when a development schema changes.
        try migrator.migrate(database)

        defaultDatabase = database
        if #available(macOS 14, *), SQLiteDataDatabase.isCloudKitEnabled {
            defaultSyncEngine = try SyncEngine(
                for: database,
                tables: PasteboardHistory.self, PasteboardHistoryAsset.self, PasteboardHistoryThumbnailAsset.self, SnippetFolder.self, Snippet.self,
                // Keep iCloud synchronization disabled for now. Setting this to true starts
                // synchronization, and a future release will make this user-configurable.
                startImmediately: false
            )
        }
    }
}

/// Scan text assets without materializing a potentially very large clipboard blob.
/// Overlap includes complete UTF-8 characters and matches crossing chunk boundaries.
enum ClipyMeTextReader {
    static func match(database: Database, rowID: Int64, term: String, previewLength: Int = 0) throws -> String? {
        guard !term.isEmpty else { return nil }
        var blob: OpaquePointer?
        let opened = sqlite3_blob_open(database.sqliteConnection, "main", "pasteboardHistoryAssets", "data", rowID, 0, &blob)
        guard opened == SQLITE_OK, let blob else {
            throw NSError(domain: "ClipyMeTextRead", code: Int(opened))
        }
        defer { sqlite3_blob_close(blob) }
        let foldedTerm = term.utf8.allSatisfy({ $0 < 128 }) ? term.lowercased()
            : term.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        let needle = Data(foldedTerm.utf8)
        let size = Int(sqlite3_blob_bytes(blob))
        let overlap = max(32, term.utf8.count * 4)
        let chunkSize = max(65_536, overlap * 2)
        var offset = 0
        var carry = Data()
        while offset < size {
            let length = min(chunkSize, size - offset)
            var chunk = Data(count: length)
            let status = chunk.withUnsafeMutableBytes { bytes in
                sqlite3_blob_read(blob, bytes.baseAddress, Int32(length), Int32(offset))
            }
            guard status == SQLITE_OK else { throw NSError(domain: "ClipyMeTextRead", code: Int(status)) }
            var combined = carry
            combined.append(chunk)
            let text = String(decoding: combined, as: UTF8.self)
            let matches: Bool
            if combined.withUnsafeBytes({ (bytes: UnsafeRawBufferPointer) in bytes.allSatisfy { $0 < 128 } }) {
                matches = containsASCII(combined, needle: needle)
            } else {
                let folded = text.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
                matches = folded.range(of: foldedTerm, options: .literal) != nil
            }
            if matches {
                let range = previewLength > 0 ? text.range(of: term, options: .caseInsensitive) : nil
                guard previewLength > 0 else { return "" }
                let start = text.index(range?.lowerBound ?? text.startIndex, offsetBy: -min(80, previewLength / 4), limitedBy: text.startIndex) ?? text.startIndex
                let snippet = String(text[start...].prefix(previewLength))
                let before = offset > carry.count || start != text.startIndex
                let after = offset + length < size || text.distance(from: start, to: text.endIndex) > previewLength
                return (before ? "…" : "") + snippet + (after ? "…" : "")
            }
            carry = Data(combined.suffix(overlap))
            offset += length
        }
        return nil
    }

    private static func containsASCII(_ data: Data, needle: Data) -> Bool {
        guard !needle.isEmpty, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { raw in
            needle.withUnsafeBytes { targetRaw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let target = targetRaw.bindMemory(to: UInt8.self)
                for start in 0...(bytes.count - target.count) {
                    var index = 0
                    while index < target.count {
                        let byte = bytes[start + index]
                        let folded = byte >= 65 && byte <= 90 ? byte + 32 : byte
                        if folded != target[index] { break }
                        index += 1
                    }
                    if index == target.count { return true }
                }
                return false
            }
        }
    }

}
