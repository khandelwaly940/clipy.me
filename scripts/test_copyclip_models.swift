// Developer validation using a separately downloaded vendor app; no vendor models are redistributed.
// Usage: swift test_copyclip_models.swift /path/to/Model.momd /path/to/ClipyMe.app/Contents/MacOS/ClipyMe
import Foundation
import CoreData
import AppKit
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let executable = URL(fileURLWithPath: CommandLine.arguments[2])
let target = FileManager.default.temporaryDirectory.appendingPathComponent("clipyme-model-test-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: target) }
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for url in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: {$0.path < $1.path}) where url.pathExtension == "mom" {
 let model = NSManagedObjectModel(contentsOf: url)!
 model.entities.forEach { $0.managedObjectClassName = "NSManagedObject" }
 let path = target.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
 try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
 let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
 let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName:nil, at:path.appendingPathComponent("copyclip.sqlite"), options:[NSSQLitePragmasOption:["journal_mode":"DELETE"]])
 let context = NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator = coordinator
 for index in 0..<3 {
  let clipping = NSEntityDescription.insertNewObject(forEntityName:"Clipping",into:context)
  clipping.setValue("Synthetic CopyClip \(index) café",forKey:"contents")
  clipping.setValue(Date(timeIntervalSinceReferenceDate:Double(index+1)*100),forKey:"dateRecorded")
  clipping.setValue("NSStringPboardType",forKey:"type")
  if clipping.entity.attributesByName["pinned"] != nil {clipping.setValue(index == 0,forKey:"pinned")}
  if clipping.entity.attributesByName["attributedContents"] != nil {
   clipping.setValue(NSAttributedString(string:"Synthetic CopyClip \(index) café",attributes:[.font:NSFont.boldSystemFont(ofSize:14)]),forKey:"attributedContents")
  }
 }
 try context.save()
 try coordinator.remove(store)
 let prefs:[String:Any] = ["startAtLogin":false,"saveClippingsCount":200,"pasteDirectly":true]
 try PropertyListSerialization.data(fromPropertyList:prefs,format:.xml,options:0).write(to:path.appendingPathComponent("preferences.plist"))
 let process = Process()
 process.executableURL = executable
 process.arguments = ["--clipyme-import-copyclip", path.appendingPathComponent("copyclip.sqlite").path,
                      path.appendingPathComponent("imported").path, path.appendingPathComponent("preferences.plist").path]
 try process.run(); process.waitUntilExit()
 guard process.terminationStatus == 0 else { fatalError("Import failed: " + url.lastPathComponent) }
 let check = Process(); let pipe = Pipe()
 check.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
 check.arguments = [path.appendingPathComponent("imported/sqlite.db").path,
                    "SELECT count(*) FROM pasteboardHistories; SELECT count(*) FROM pasteboardHistoryAssets; PRAGMA integrity_check;"]
 check.standardOutput = pipe
 try check.run(); check.waitUntilExit()
 let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
 let assets = model.entitiesByName["Clipping"]!.attributesByName["attributedContents"] == nil ? 3 : 6
 guard check.terminationStatus == 0 && result == "3\n\(assets)\nok\n" else { fatalError("Verification failed: " + url.lastPathComponent) }
 print("Validated " + url.lastPathComponent)
}
