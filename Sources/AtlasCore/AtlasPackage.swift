import CryptoKit
import Darwin
import Foundation
import GRDB

public struct ProjectArchiveSummary: Sendable {
  public let workspaceID: String
  public let title: String
  public let assets: Int
  public let bytes: Int
  public let originalArchives: Int
}

private struct PackageFile: Codable, Equatable {
  let path: String, sha256: String
  let bytes: Int
  var media_type: String?
}
private struct PackageManifest: Codable {
  let format_version: String
  let schema_version: Int
  let workspace_id: String
  let origin_workspace_id: String?
  let created_at: String
  let producer_app_version: String
  let database: PackageFile
  let assets: [PackageFile]
  let required_features: [String]?
}

private func validPackageDate(_ text: String) -> Bool {
  let f = ISO8601DateFormatter()
  if f.date(from: text) != nil { return true }
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f.date(from: text) != nil
}
private func safeDigest(_ s: String) -> Bool {
  s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
private func verifiedFile(_ url: URL, expected: PackageFile? = nil) throws -> PackageFile {
  let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
  guard values.isRegularFile == true, values.isSymbolicLink != true else {
    throw AtlasStoreError.invalid("不是普通文件：" + url.lastPathComponent)
  }
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hash = SHA256()
  var size = 0
  while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
    hash.update(data: chunk)
    size += chunk.count
  }
  let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
  if let expected, expected.sha256 != digest || expected.bytes != size {
    throw AtlasStoreError.invalid("文件校验失败：" + expected.path)
  }
  return PackageFile(
    path: expected?.path ?? url.lastPathComponent, sha256: digest, bytes: size,
    media_type: expected?.media_type)
}
private func validFile(_ f: PackageFile, isDatabase: Bool) throws {
  guard safeDigest(f.sha256), f.bytes >= (isDatabase ? 1 : 0),
    isDatabase
      ? f.path == "workspace.sqlite" && f.media_type == nil
      : f.path == "assets/" + f.sha256.prefix(2) + "/" + f.sha256 && !(f.media_type ?? "").isEmpty
        && (f.media_type?.count ?? 0) <= 128
  else { throw AtlasStoreError.invalid("清单中的文件记录无效：" + f.path) }
}
private func assetsInDatabase(_ db: Database) throws -> [PackageFile] {
  try Row.fetchAll(
    db, sql: "SELECT sha256,relative_path,byte_count,media_type,status FROM asset ORDER BY sha256"
  ).map { r in
    let f = PackageFile(
      path: r["relative_path"], sha256: r["sha256"], bytes: r["byte_count"],
      media_type: r["media_type"])
    try validFile(f, isDatabase: false)
    guard (r["status"] as String) == "ready" else {
      throw AtlasStoreError.invalid("缺失资产：" + f.path)
    }
    return f
  }
}
private let packageExtensionsKey = "package.extensions"
// Local authentication is held in Keychain. These namespaces also exclude future device-specific authorizations.
private func removeLocalAuthorizations(_ db: Database) throws {
  try db.execute(
    sql: """
      DELETE FROM workspace_settings WHERE lower(key) GLOB 'credential.*' OR lower(key) GLOB 'secret.*' OR
        lower(key) GLOB 'cli.auth.*' OR lower(key) GLOB 'automation.permission.*' OR lower(key) GLOB 'device.authorization.*'
      """)
}
func withTemporarySibling<T>(_ dest: URL, _ body: (URL) throws -> T) throws -> T {
  let parent = dest.deletingLastPathComponent()
  let fm = FileManager.default
  let tmp = parent.appendingPathComponent(".atlas-" + writingID(), isDirectory: true)
  try fm.createDirectory(
    at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? fm.removeItem(at: tmp) }
  return try body(tmp)
}
private func syncFile(_ url: URL) throws {
  let h = try FileHandle(forWritingTo: url)
  defer { try? h.close() }
  try h.synchronize()
}
func publishFile(_ source: URL, to destination: URL, replacing: Bool) throws {
  try syncFile(source)
  let result =
    replacing
    ? Darwin.rename(source.path, destination.path)
    : Darwin.renamex_np(source.path, destination.path, UInt32(RENAME_EXCL))
  guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
  let fd = Darwin.open(
    destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  if fd >= 0 {
    defer { Darwin.close(fd) }
    if fsync(fd) != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
  }
}

extension AtlasStore {
  public func projectArchiveSummary() throws -> ProjectArchiveSummary {
    try database.read { db in
      let files = try assetsInDatabase(db)
      let title =
        try String.fetchOne(db, sql: "SELECT title FROM workspace WHERE singleton=1") ?? ""
      return ProjectArchiveSummary(
        workspaceID: workspaceID, title: title, assets: files.count,
        bytes: files.map(\.bytes).reduce(0, +),
        originalArchives: try Int.fetchOne(db, sql: "SELECT count(*) FROM import_archive") ?? 0)
    }
  }
  @discardableResult
  public func exportProject(
    to destination: URL, replacing: Bool = false, progress: (String) throws -> Void = { _ in }
  ) throws -> ProjectArchiveSummary {
    recoveryLock.lock()
    defer { recoveryLock.unlock() }
    let fm = FileManager.default
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    let dest = destination.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(destination.lastPathComponent).standardizedFileURL
    guard !dest.pathComponents.starts(with: root.pathComponents) else {
      throw AtlasStoreError.invalid("请选择 Atlas 目录之外的备份位置。")
    }
    if fm.fileExists(atPath: dest.path) {
      guard replacing else { throw AtlasStoreError.invalid("目标文件已存在。") }
      guard dest.pathExtension.lowercased() == "latlas",
        let existing = try? ValidatedPackage(url: dest),
        existing.manifest.workspace_id == workspaceID
      else {
        throw AtlasStoreError.invalid("为保留已有文件，请为本项目包选择新的文件名。")
      }
    }
    return try withTemporarySibling(dest) { tmp in
      let folder = tmp.appendingPathComponent("snapshot")
      let archive = tmp.appendingPathComponent("backup.zip")
      try fm.createDirectory(at: folder, withIntermediateDirectories: false)
      let databaseURL = folder.appendingPathComponent("workspace.sqlite")
      try progress("正在创建数据库一致快照")
      let snap = try DatabaseQueue(path: databaseURL.path)
      try database.backup(to: snap)
      try snap.write { db in try removeLocalAuthorizations(db) }
      let info = try snap.read { db in
        let row = try Row.fetchOne(
          db, sql: "SELECT id,title,origin_workspace_id FROM workspace WHERE singleton=1")!
        return (
          row["id"] as String, row["title"] as String, row["origin_workspace_id"] as String?,
          try assetsInDatabase(db),
          try String.fetchOne(
            db, sql: "SELECT value_json FROM workspace_settings WHERE key=?",
            arguments: [packageExtensionsKey]),
          try Int.fetchOne(db, sql: "SELECT count(*) FROM import_archive") ?? 0
        )
      }
      // VACUUM removes freed pages left by scrubbed local state before sealing the snapshot.
      try snap.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
      try snap.close()
      for (index, file) in info.3.enumerated() {
        try progress("校验资产 \(index+1)/\(info.3.count)")
        let src = root.appendingPathComponent(file.path)
        guard src.resolvingSymlinksInPath().standardizedFileURL.path == src.standardizedFileURL.path
        else { throw AtlasStoreError.invalid("资产路径包含链接：" + file.path) }
        _ = try verifiedFile(src, expected: file)
      }
      let dbFile = try verifiedFile(databaseURL)
      let manifest = PackageManifest(
        format_version: "1.0", schema_version: 1, workspace_id: info.0, origin_workspace_id: info.2,
        created_at: ISO8601DateFormatter().string(from: Date()),
        producer_app_version: (Bundle.main.object(
          forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.1-dev",
        database: dbFile, assets: info.3, required_features: [])
      var value =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
      if let extras = info.4 {
        value["extensions"] = try JSONSerialization.jsonObject(with: Data(extras.utf8))
      }
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: folder.appendingPathComponent("manifest.json"))
      try progress("正在写入与核验项目包")
      let files =
        [
          ("manifest.json", folder.appendingPathComponent("manifest.json")),
          ("workspace.sqlite", databaseURL),
        ] + info.3.map { ($0.path, root.appendingPathComponent($0.path)) }
      try ProjectZIP.write(files, to: archive) { try Task.checkCancellation() }
      let parsed = try ValidatedPackage(url: archive)
      try parsed.visitFiles { _ in nil }
      try progress("发布已核验的项目包")
      try publishFile(archive, to: dest, replacing: replacing)
      return ProjectArchiveSummary(
        workspaceID: info.0, title: info.1, assets: info.3.count,
        bytes: info.3.map(\.bytes).reduce(0, +), originalArchives: info.5)
    }
  }

  /// Publish a fresh, independently identified copy only after all input validation succeeds.
  @discardableResult
  public static func restoreProject(
    from source: URL, to destination: URL, progress: (String) throws -> Void = { _ in }
  ) throws -> String {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: destination.path) else {
      throw AtlasStoreError.invalid("恢复目标已存在，请选择新的目录名。")
    }
    try progress("检查项目包与清单")
    let parsed = try ValidatedPackage(url: source)
    var required = parsed.manifest.database.bytes
    for asset in parsed.manifest.assets {
      let value = required.addingReportingOverflow(asset.bytes)
      guard !value.overflow else { throw AtlasStoreError.invalid("恢复内容总量超出支持范围。") }
      required = value.partialValue
    }
    if let available = try destination.deletingLastPathComponent().resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ]).volumeAvailableCapacityForImportantUsage,
      required > available
    {
      throw POSIXError(.ENOSPC)
    }
    return try withTemporarySibling(destination) { tmp in
      let result = tmp.appendingPathComponent("Atlas")
      try fm.createDirectory(at: result, withIntermediateDirectories: false)
      try parsed.visitFiles { file in
        try progress("校验并恢复 " + file.path)
        let dest = result.appendingPathComponent(file.path)
        try fm.createDirectory(
          at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        return dest
      }
      let id = UUID().uuidString.lowercased()
      let databaseURL = result.appendingPathComponent("workspace.sqlite")
      try progress("验证数据库、工作区身份与资产关系")
      try validateRecoveredDatabase(url: databaseURL, manifest: parsed.manifest)
      let copy = try DatabaseQueue(path: databaseURL.path)
      try copy.write { db in
        try removeLocalAuthorizations(db)
        try db.execute(
          sql: "UPDATE workspace SET id=?,origin_workspace_id=?,updated_at=? WHERE singleton=1",
          arguments: [id, parsed.manifest.workspace_id, writingDate()])
        try db.execute(
          sql:
            "INSERT INTO workspace_settings(key,value_json,revision,updated_at) VALUES ('view.restore.needs-model-confirmation','true',1,?) ON CONFLICT(key) DO UPDATE SET value_json='true',revision=revision+1,updated_at=excluded.updated_at",
          arguments: [writingDate()])
        if let ext = parsed.extensions {
          try db.execute(
            sql:
              "INSERT INTO workspace_settings(key,value_json,revision,updated_at) VALUES (?,?,1,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at",
            arguments: [packageExtensionsKey, ext, writingDate()])
        }
        try db.execute(
          sql:
            "INSERT INTO index_outbox(entity_kind,entity_id,operation,created_at) VALUES ('workspace',?,'rebuild',?)",
          arguments: [id, writingDate()])
      }
      try copy.close()
      // Run the same interrupted-generation reconciliation as a normal open, in staging.
      let finalCache = try AtlasSearchIndex.cacheDirectory(
        for: destination.standardizedFileURL, workspaceID: id)
      guard !fm.fileExists(atPath: finalCache.path) else {
        throw AtlasStoreError.invalid("新副本的索引目录已存在，未发布副本。")
      }
      var published = false
      defer {
        if !published {
          try? AtlasSearchIndex.removeCache(for: destination.standardizedFileURL, workspaceID: id)
        }
      }
      do {
        let recovered = try AtlasStore(directory: result)
        try progress("重建恢复副本的检索索引")
        _ = try AtlasSearchIndex(store: recovered, cacheDirectory: finalCache).rebuild()
        try recovered.database.close()
      }
      try syncFile(databaseURL)
      try progress("登记恢复副本")
      guard Darwin.renamex_np(result.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      published = true
      return id
    }
  }
}

private struct ValidatedPackage {
  let zip: ProjectZIP
  let metadataBytes: Data
  let manifest: PackageManifest
  let extensions: String?
  init(url: URL) throws {
    let archive = ProjectZIP(url: url)
    var fileNames = Set<String>()
    var directoryNames = Set<String>()
    var bytes = Data()
    try archive.visit { member in
      if member.directory {
        directoryNames.insert(member.path)
        return
      }
      fileNames.insert(member.path)
      if member.path == "manifest.json" {
        guard member.size > 0, member.size <= 16 * 1024 * 1024 else {
          throw AtlasStoreError.invalid("manifest.json 长度无效。")
        }
        try member.stream { bytes.append($0) }
      }
    }
    guard !bytes.isEmpty else { throw AtlasStoreError.invalid("项目包缺少 manifest.json。") }
    self.metadataBytes = bytes
    guard let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let manifest = try? JSONDecoder().decode(PackageManifest.self, from: bytes),
      Set(obj.keys).isSubset(of: [
        "format_version", "schema_version", "workspace_id", "origin_workspace_id", "created_at",
        "producer_app_version", "database", "assets", "required_features", "extensions",
      ]),
      manifest.format_version == "1.0", manifest.schema_version == 1,
      UUID(uuidString: manifest.workspace_id) != nil,
      manifest.workspace_id == manifest.workspace_id.lowercased(),
      manifest.origin_workspace_id.map({ UUID(uuidString: $0) != nil }) ?? true,
      !manifest.producer_app_version.isEmpty, manifest.producer_app_version.count <= 64,
      manifest.created_at.hasSuffix("Z"), validPackageDate(manifest.created_at)
    else { throw AtlasStoreError.invalid("不支持的项目包格式、数据库版本或清单字段。") }
    guard (manifest.required_features ?? []).isEmpty else {
      throw AtlasStoreError.invalid(
        "此版本缺少项目包必须的能力：" + (manifest.required_features ?? []).joined(separator: "、"))
    }
    if let ext = obj["extensions"] {
      guard ext is [String: Any] else { throw AtlasStoreError.invalid("可选扩展必须是对象。") }
      self.extensions = String(
        decoding: try JSONSerialization.data(withJSONObject: ext, options: .sortedKeys),
        as: UTF8.self)
    } else {
      extensions = nil
    }
    try validFile(manifest.database, isDatabase: true)
    for f in manifest.assets { try validFile(f, isDatabase: false) }
    let names = Set([manifest.database.path, "manifest.json"] + manifest.assets.map(\.path))
    let directories = Set(
      ["assets"] + manifest.assets.map { "assets/" + $0.sha256.prefix(2) })
    guard names.count == manifest.assets.count + 2,
      fileNames == names, directoryNames.isSubset(of: directories),
      (obj["database"] as? [String: Any]).map({ Set($0.keys) == ["path", "sha256", "bytes"] })
        == true,
      (obj["assets"] as? [[String: Any]])?.allSatisfy({
        Set($0.keys) == ["path", "sha256", "bytes", "media_type"]
      }) == true
    else { throw AtlasStoreError.invalid("项目包目录与清单不一致，存在缺失、重复或额外成员。") }
    self.zip = archive
    self.manifest = manifest
  }
  func visitFiles(_ destination: (PackageFile) throws -> URL?) throws {
    let files = Dictionary(
      uniqueKeysWithValues: ([manifest.database] + manifest.assets).map { ($0.path, $0) })
    var visited = Set<String>()
    try zip.visit { m in
      if m.directory { return }
      if m.path == "manifest.json" {
        var check = Data()
        guard m.size == metadataBytes.count else { throw AtlasStoreError.invalid("读取期间项目包已改变。") }
        try m.stream { check.append($0) }
        guard check == metadataBytes else { throw AtlasStoreError.invalid("读取期间项目包已改变。") }
        return
      }
      guard let f = files[m.path], m.size == f.bytes else {
        throw AtlasStoreError.invalid("成员或长度与清单不符：" + m.path)
      }
      let url = try destination(f)
      var handle: FileHandle?
      if let url {
        guard !FileManager.default.fileExists(atPath: url.path),
          FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw AtlasStoreError.invalid("无法写入恢复文件：" + f.path) }
        handle = try FileHandle(forWritingTo: url)
      }
      defer { try? handle?.close() }
      var hasher = SHA256()
      try m.stream { chunk in
        try Task.checkCancellation()
        hasher.update(data: chunk)
        try handle?.write(contentsOf: chunk)
      }
      guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == f.sha256 else {
        throw AtlasStoreError.invalid("SHA-256 校验失败：" + f.path)
      }
      try handle?.synchronize()
      visited.insert(m.path)
    }
    guard visited == Set(files.keys) else { throw AtlasStoreError.invalid("项目包缺少清单内的文件。") }
  }
}

private func validateRecoveredDatabase(url: URL, manifest: PackageManifest) throws {
  var config = Configuration()
  config.readonly = true
  config.prepareDatabase { db in try db.execute(sql: "PRAGMA trusted_schema=OFF") }
  let input = try DatabaseQueue(path: url.path, configuration: config)
  let expected = try DatabaseQueue()
  guard let sql = Bundle.module.url(forResource: "schema", withExtension: "sql") else {
    throw AtlasStoreError.invalid("缺少本机数据库规格。")
  }
  try expected.writeWithoutTransaction { db in
    try db.execute(sql: String(contentsOf: sql, encoding: .utf8))
  }
  func definitions(_ db: Database) throws -> [String] {
    try String.fetchAll(
      db,
      sql:
        "SELECT type||'|'||name||'|'||sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL ORDER BY type,name"
    )
  }
  let schema = try expected.read(definitions)
  try input.read { db in
    guard try definitions(db) == schema else {
      throw AtlasStoreError.invalid("数据库结构与已支持的版本不符，暂未登记副本。")
    }
    guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty
    else { throw AtlasStoreError.invalid("数据库完整性或外键校验失败。") }
    guard
      try Int.fetchOne(
        db,
        sql:
          "SELECT schema_version FROM schema_meta WHERE singleton=1 AND application_id='living-atlas'"
      ) == manifest.schema_version,
      try String.fetchOne(db, sql: "SELECT id FROM workspace WHERE singleton=1")
        == manifest.workspace_id,
      try assetsInDatabase(db) == manifest.assets.sorted(by: { $0.sha256 < $1.sha256 })
    else { throw AtlasStoreError.invalid("数据库与清单中的工作区、版本或资产不一致。") }
  }
  try input.close()
}
