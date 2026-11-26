import Darwin
import Foundation
import GRDB

public struct RecyclableObject: Identifiable, Sendable {
  public enum Kind: String, Sendable { case turn, document, content, archive }
  public let objectID: String, title: String
  public let kind: Kind
  public let deleted: Bool
  public var id: String { kind.rawValue + "." + objectID }
}

extension AtlasStore {
  public func recyclableObjects() throws -> [RecyclableObject] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT t.id,'turn' kind,v.plain_text title,(q.deleted_at IS NOT NULL) gone FROM inquiry_turn t
          JOIN content_node q ON q.id=t.question_node_id JOIN content_version v ON v.id=t.question_version_id
          UNION ALL SELECT id,'document',title,deleted_at IS NOT NULL FROM document
          UNION ALL SELECT id,'content',CASE WHEN title='' THEN '未命名内容' ELSE title END,deleted_at IS NOT NULL FROM content_node WHERE kind NOT IN ('question','answer')
          UNION ALL SELECT id,'archive','原聊天档案 · '||imported_at,deleted_at IS NOT NULL FROM import_archive
          ORDER BY 2,3
          """
      ).map {
        RecyclableObject(
          objectID: $0["id"], title: $0["title"],
          kind: RecyclableObject.Kind(rawValue: $0["kind"])!, deleted: $0["gone"])
      }
    }
  }
  public func setRecycled(_ item: RecyclableObject, deleted: Bool) throws {
    guard item.deleted != deleted else { return }
    try database.write { db in
      let id = item.objectID
      let date = deleted ? writingDate() : nil
      var expected = 1
      let table: String
      let predicate: String
      let revision: String
      switch item.kind {
      case .turn:
        guard
          try !Bool.fetchOne(
            db,
            sql:
              "SELECT EXISTS(SELECT 1 FROM generation_run WHERE turn_id=? AND status IN ('queued','preparing','streaming'))",
            arguments: [id])!
        else { throw AtlasStoreError.invalid("请先停止这个问题正在进行的生成。") }
        table = "content_node"
        revision = ",metadata_revision=metadata_revision+1"
        predicate =
          "id IN (SELECT question_node_id FROM inquiry_turn WHERE id=?1 UNION ALL SELECT answer_node_id FROM inquiry_turn WHERE id=?1)"
        expected = 2
      case .document:
        table = "document"
        revision = ",revision=revision+1"
        predicate = "id=?1"
      case .content:
        table = "content_node"
        revision = ",metadata_revision=metadata_revision+1"
        predicate = "id=?1 AND kind NOT IN ('question','answer')"
      case .archive:
        table = "import_archive"
        revision = ""
        predicate = "id=?1"
      }
      try db.execute(
        sql:
          "UPDATE \(table) SET deleted_at=?2\(revision) WHERE \(predicate) AND (deleted_at IS NOT NULL)=?3",
        arguments: [id, date, item.deleted])
      guard db.changesCount == expected else { throw AtlasStoreError.invalid("对象状态已变更，请刷新后再操作。") }
      try db.execute(
        sql:
          "INSERT INTO index_outbox(entity_kind,entity_id,operation,created_at) VALUES (?,?,?,?)",
        arguments: [item.kind.rawValue, id, deleted ? "delete" : "upsert", writingDate()])
    }
  }

  public func defaultRecoveryRoot() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("Living Atlas/恢复点", isDirectory: true)
  }

  private struct Point: Codable {
    let file: String
    let day: String
    let fingerprint: String
    let hash: String
  }
  private func recoveryDirectory(_ root: URL) throws -> URL {
    guard UUID(uuidString: workspaceID) != nil else { throw AtlasStoreError.invalid("工作区身份不合法。") }
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    guard
      !canonicalRoot.pathComponents.starts(
        with: directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
    else { throw AtlasStoreError.invalid("恢复点目录须位于当前 Atlas 之外。") }
    let folder = canonicalRoot.appendingPathComponent(workspaceID, isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.path),
      try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    {
      throw AtlasStoreError.invalid("恢复点目录不能是链接。")
    }
    return folder
  }
  private func recoveryCatalog(_ folder: URL) throws -> [Point] {
    let url = folder.appendingPathComponent("points.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let points = try JSONDecoder().decode([Point].self, from: Data(contentsOf: url))
    for p in points {
      guard p.file.hasPrefix("point-"), p.file.hasSuffix(".latlas"),
        p.file == URL(fileURLWithPath: p.file).lastPathComponent,
        UUID(uuidString: String(p.file.dropFirst(6).dropLast(7))) != nil, safeRecoveryHash(p.hash)
      else { throw AtlasStoreError.invalid("恢复点目录包含无效清单。") }
    }
    return points
  }
  private func safeRecoveryHash(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  public func recoveryPoints(at root: URL) throws -> [URL] {
    let folder = try recoveryDirectory(root)
    return try recoveryCatalog(folder).map { folder.appendingPathComponent($0.file) }
  }

  @discardableResult
  public func saveRecoveryPoint(
    at root: URL, keep: Int = 7, now: Date = Date(), force: Bool = false,
    progress: (String) throws -> Void = { _ in }
  ) throws -> URL? {
    guard (1...365).contains(keep) else { throw AtlasStoreError.invalid("保留数量应在 1 到 365 之间。") }
    recoveryLock.lock()
    defer { recoveryLock.unlock() }
    let fm = FileManager.default
    let folder = try recoveryDirectory(root)
    try fm.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let old = try recoveryCatalog(folder)
    let dateParts = Calendar.current.dateComponents([.year, .month, .day], from: now)
    let day = String(format: "%04d-%02d-%02d", dateParts.year!, dateParts.month!, dateParts.day!)
    let signature = try ["workspace.sqlite", "workspace.sqlite-wal"].map { file -> String in
      let p = directory.appendingPathComponent(file)
      guard fm.fileExists(atPath: p.path) else { return "-" }
      let attributes = try fm.attributesOfItem(atPath: p.path)
      return String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) + ":"
        + String(describing: attributes[.size] ?? "")
    }.joined(separator: "|")
    if !force, let first = old.first, first.fingerprint == signature,
      (try? atlasHash(
        Data(contentsOf: folder.appendingPathComponent(first.file), options: .mappedIfSafe)))
        == first.hash
    {
      return nil
    }
    let name = "point-" + writingID() + ".latlas"
    let out = folder.appendingPathComponent(name)
    _ = try exportProject(to: out, progress: progress)
    let digest = atlasHash(try Data(contentsOf: out, options: .mappedIfSafe))
    let retained = Array(
      ([Point(file: name, day: day, fingerprint: signature, hash: digest)]
        + old.filter { $0.day != day }).prefix(keep))
    try JSONEncoder().encode(retained).write(
      to: folder.appendingPathComponent("points.json"), options: .atomic)
    for prior in old where !retained.contains(where: { $0.file == prior.file }) {
      let url = folder.appendingPathComponent(prior.file)
      if fm.fileExists(atPath: url.path),
        try atlasHash(Data(contentsOf: url, options: .mappedIfSafe)) == prior.hash
      {
        try fm.removeItem(at: url)
      }
    }
    return out
  }

  /// Called only by the native destructive confirmation after the owning session quiesces its jobs.
  public func permanentlyErase(confirming title: String, recoveryRoot: URL) throws {
    try permanentlyErase(confirming: title, recoveryRoots: [recoveryRoot])
  }
  public func permanentlyErase(confirming title: String, recoveryRoots: [URL]) throws {
    recoveryLock.lock()
    defer { recoveryLock.unlock() }
    let fm = FileManager.default
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    let actual = try database.read { db in
      guard
        try
          (Int.fetchOne(
            db,
            sql:
              "SELECT count(*) FROM generation_run WHERE status IN ('queued','preparing','streaming')"
          ) ?? 0) == 0
      else { throw AtlasStoreError.invalid("请先停止正在生成的回答。") }
      return try String.fetchOne(
        db, sql: "SELECT title FROM workspace WHERE id=?", arguments: [workspaceID])
    }
    guard !title.isEmpty, title == actual else { throw AtlasStoreError.invalid("输入的 Atlas 名称不匹配。") }
    let known: Set<String> = [
      "workspace.sqlite", "workspace.sqlite-shm", "workspace.sqlite-wal",
      "workspace.sqlite-journal", "assets", "tmp", "cache", ".DS_Store",
    ]
    let names = try fm.contentsOfDirectory(atPath: root.path)
    guard Set(names).isSubset(of: known), names.contains("workspace.sqlite"),
      !root.pathComponents.dropFirst().isEmpty
    else { throw AtlasStoreError.invalid("项目目录含有未受管文件，已停止清除。") }
    let assets = root.appendingPathComponent("assets")
    if fm.fileExists(atPath: assets.path) {
      for dir in try fm.contentsOfDirectory(
        at: assets, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
      {
        let info = try dir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard info.isDirectory == true, info.isSymbolicLink != true,
          dir.lastPathComponent.utf8.count == 2,
          dir.lastPathComponent.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
          })
        else { throw AtlasStoreError.invalid("资产目录含未受管项目：" + dir.lastPathComponent) }
        for file in try fm.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        {
          let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          let name = file.lastPathComponent
          guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, safeRecoveryHash(name),
            name.hasPrefix(dir.lastPathComponent)
          else { throw AtlasStoreError.invalid("资产目录含未受管文件：" + name) }
        }
      }
    }
    let folders = try Set(recoveryRoots.map { try recoveryDirectory($0) })
    let histories = try folders.map { folder in (folder, try recoveryCatalog(folder)) }
    for (folder, points) in histories {
      for point in points {
        let url = folder.appendingPathComponent(point.file)
        if fm.fileExists(atPath: url.path),
          try atlasHash(Data(contentsOf: url, options: .mappedIfSafe)) != point.hash
        {
          throw AtlasStoreError.invalid("恢复点已被外部修改，已停止清除。")
        }
      }
    }
    try database.close()
    let tombstone = root.deletingLastPathComponent().appendingPathComponent(
      ".atlas-purge-" + writingID())
    guard Darwin.renamex_np(root.path, tombstone.path, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    try fm.removeItem(at: tombstone)
    for (recovery, points) in histories {
      for point in points {
        let url = recovery.appendingPathComponent(point.file)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
      }
      if fm.fileExists(atPath: recovery.path) {
        let catalog = recovery.appendingPathComponent("points.json")
        if fm.fileExists(atPath: catalog.path) { try fm.removeItem(at: catalog) }
        if try fm.contentsOfDirectory(atPath: recovery.path).isEmpty {
          try fm.removeItem(at: recovery)
        }
      }
    }
    try AtlasSearchIndex.removeCache(for: directory, workspaceID: workspaceID)
  }
}
