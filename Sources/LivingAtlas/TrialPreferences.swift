import Foundation

enum TrialPreferences {
  // cfprefsd may strip directory components from a suite name. A persistent, random
  // domain per trial directory also survives moving an already opened trial folder.
  private static let identityFile = "preferences-id"
  private static func suite(for directory: URL, create: Bool) throws -> UserDefaults? {
    let file = directory.appendingPathComponent(identityFile)
    if create {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: file.path) {
        do { try Data(UUID().uuidString.utf8).write(to: file, options: .withoutOverwriting) }
        catch CocoaError.fileWriteFileExists { }
      }
    } else if !FileManager.default.fileExists(atPath: file.path) { return nil }
    let id = try String(contentsOf: file, encoding: .utf8)
    let domain = "local.livingatlas.trial." + id
    guard UUID(uuidString: id) != nil, let defaults = UserDefaults(suiteName: domain)
    else { throw CocoaError(.fileReadCorruptFile) }
    // Earlier launchers sometimes persisted a plist inside the isolated home itself.
    let legacy = directory.appendingPathComponent("Library/Preferences/local.livingatlas.mac.plist")
    if create, defaults.persistentDomain(forName: domain) == nil, FileManager.default.fileExists(atPath: legacy.path),
       let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: legacy), format: nil) as? [String: Any] {
      defaults.setPersistentDomain(values, forName: domain)
    }
    return defaults
  }

  static func open(at directory: URL, inheritModelFrom host: URL?) throws -> UserDefaults {
    guard let prefs = try suite(for: directory, create: true) else { throw CocoaError(.fileWriteUnknown) }
    if let host, host.standardizedFileURL != directory.standardizedFileURL,
       prefs.data(forKey: "modelProfile") == nil, let model = try suite(for: host, create: false)?.data(forKey: "modelProfile") {
      prefs.set(model, forKey: "modelProfile")
    }
    return prefs
  }
}
