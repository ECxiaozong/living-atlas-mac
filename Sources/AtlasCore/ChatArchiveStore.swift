import Darwin
import Foundation
import GRDB

public struct ChatImportChanges: Equatable, Sendable {
  public init() {}
  public var new = 0, changed = 0, unchanged = 0
}
public struct ChatArchiveSource: Identifiable, Sendable {
  /// The identifier pins an immutable message version and remains valid after subsequent imports.
  public let id: String
  public let conversationID: String, conversationTitle: String, archiveID: String, filename: String
  public let messageID: String, externalID: String?, role: String, rawRole: String?
  public let timestamp: String?, parent: String?, body: String, version: Int
  public let parts: [ChatContentPart], location: ChatRawLocation
}
public struct SavedChatArchive: Identifiable, Sendable {
  public let id: String, filename: String, namespace: String, sha256: String, status: String,
    importedAt: String
  public let savedConversations: Int
  public let selection: [String]
}
public struct ChatImportReceipt: Sendable {
  public let archiveID: String
  public let changedVersionIDs: [String]
  public let completed: [String], pending: [String], diagnostics: [String],
    changes: ChatImportChanges
}

private struct ArchiveDetails: Codable {
  let filename: String, namespace: String, sha256: String
  var selection: [String]
}
private struct SavedConversation: Codable {
  let location: ChatRawLocation
  let versionIDs: [String]
}
private struct SavedMessage: Codable {
  let location: ChatRawLocation
  let rawRole: String?
}
private func chatDecode<T: Decodable>(_ t: T.Type, _ value: String) throws -> T {
  try JSONDecoder().decode(t, from: Data(value.utf8))
}
private func chatNow() -> String {
  Date.now.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
}

extension AtlasStore {
  private func archiveID(_ preview: ChatImportPreview) -> String {
    chatID(["archive", preview.provider, preview.namespace, preview.sha256])
  }
  private func importKey(_ c: ChatParsedConversation, _ m: ChatParsedMessage, _ sha: String)
    -> String
  {
    if let id = m.externalID { return chatID(["message", c.id, id]) }
    return chatID(["message-at", c.id, sha, m.location.member ?? "", m.location.pointer])
  }

  public func chatImportChanges(_ preview: ChatImportPreview) throws -> [String: ChatImportChanges]
  {
    try database.read { db in
      var result: [String: ChatImportChanges] = [:]
      for c in preview.conversations {
        var stats = ChatImportChanges()
        if try savedConversation(db, archiveID(preview), c.id) != nil {
          stats.unchanged = c.messages.count
        } else {
          for msg in c.messages {
            let old = try currentDigest(db, importKey(c, msg, preview.sha256))
            if old == nil {
              stats.new += 1
            } else if old == msg.digest {
              stats.unchanged += 1
            } else {
              stats.changed += 1
            }
          }
        }
        result[c.id] = stats
      }
      return result
    }
  }

  /// The byte-verified raw archive is committed first. Every conversation then commits as one SQLite transaction.
  public func saveChatImport(
    _ preview: ChatImportPreview, selected: Set<String>,
    cancelled: @Sendable () -> Bool = { false },
    progress: @Sendable (Int, Int) -> Void = { _, _ in }
  ) throws -> ChatImportReceipt {
    let aid = archiveID(preview)
    let stamp = chatNow()
    let subset = preview.conversations.filter { selected.contains($0.id) }
    guard selected.count == subset.count else { throw ChatImportError("选择包含当前预览以外的会话。") }
    let relative = "assets/\(preview.sha256.prefix(2))/\(preview.sha256)"
    let dest = directory.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: dest.path) {
      let temporary = directory.appendingPathComponent("tmp/chat-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: temporary) }
      try preview.bytes.write(to: temporary, options: .withoutOverwriting)
      guard atlasHash(try Data(contentsOf: temporary, options: .mappedIfSafe)) == preview.sha256
      else {
        throw ChatImportError("暂存原件校验失败：\(preview.filename)")
      }
      if link(temporary.path, dest.path) != 0, errno != EEXIST {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
    }
    guard atlasHash(try Data(contentsOf: dest, options: .mappedIfSafe)) == preview.sha256 else {
      throw ChatImportError("原件字节校验不一致：\(preview.filename)")
    }
    try database.write { db in
      try db.execute(
        sql:
          "INSERT OR IGNORE INTO asset(sha256,byte_count,media_type,relative_path,status,created_at) VALUES(?,?,?,?,'ready',?)",
        arguments: [preview.sha256, preview.bytes.count, preview.mediaType, relative, stamp])
      try db.execute(
        sql:
          "INSERT OR IGNORE INTO import_archive(id,raw_asset_sha256,provider_kind,adapter_version,imported_at,status,diagnostics_json) VALUES(?,?,?,?,?,'partial',?)",
        arguments: [
          aid, preview.sha256, preview.provider, ChatImportPreview.adapter, stamp,
          try chatJSON(preview.diagnostics),
        ])
      try db.execute(sql: "UPDATE import_archive SET status='partial' WHERE id=?", arguments: [aid])
      let details = ArchiveDetails(
        filename: preview.filename, namespace: preview.namespace, sha256: preview.sha256,
        selection: subset.map(\.id))
      try db.execute(
        sql:
          "INSERT INTO workspace_settings(key,value_json,revision,updated_at) VALUES(?,?,1,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at",
        arguments: ["chat-import/" + aid, try chatJSON(details), stamp])
    }
    var completed: [String] = []
    var errors = preview.diagnostics
    var totals = ChatImportChanges()
    var changedVersions: [String] = []
    for c in subset {
      if cancelled() { break }
      do {
        let counts = try database.write { db -> (ChatImportChanges, [String]) in
          if try savedConversation(db, aid, c.id) != nil {
            var result = ChatImportChanges()
            result.unchanged = c.messages.count
            return (result, [])
          }
          try db.execute(
            sql:
              "INSERT INTO import_conversation(id,source_namespace,external_conversation_id,title,created_at) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title",
            arguments: [
              c.id, preview.provider + "/" + preview.namespace, c.externalID, c.title, stamp,
            ])
          var result = ChatImportChanges()
          var versions: [String] = []
          var newVersions: [String] = []
          for (index, m) in c.messages.enumerated() {
            let key = importKey(c, m, preview.sha256)
            let current = try Row.fetchOne(
              db,
              sql:
                "SELECT m.current_version_id AS vid,v.ordinal,v.content_sha256 FROM import_message m JOIN import_message_version v ON v.id=m.current_version_id WHERE m.id=?",
              arguments: [key])
            if let current, (current["content_sha256"] as String) == m.digest {
              versions.append(current["vid"])
              result.unchanged += 1
              continue
            }
            try db.execute(
              sql:
                "INSERT OR IGNORE INTO import_message(id,conversation_id,external_message_id,source_order) VALUES(?,?,?,?)",
              arguments: [key, c.id, m.externalID, index])
            let vid = UUID().uuidString.lowercased()
            let ordinal = (current?["ordinal"] as Int? ?? 0) + 1
            try db.execute(
              sql: """
                INSERT INTO import_message_version(id,message_id,ordinal,source_archive_id,raw_locator_json,role,original_timestamp,body_text,parts_json,source_parent_external_id,content_sha256,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """,
              arguments: [
                vid, key, ordinal, aid,
                try chatJSON(SavedMessage(location: m.location, rawRole: m.roleRaw)), m.role,
                m.timestamp, m.body, try chatJSON(m.parts), m.parent, m.digest, stamp,
              ])
            try db.execute(
              sql: "UPDATE import_message SET current_version_id=?,source_order=? WHERE id=?",
              arguments: [vid, index, key])
            versions.append(vid)
            newVersions.append(vid)
            if current == nil { result.new += 1 } else { result.changed += 1 }
          }
          try db.execute(
            sql:
              "INSERT INTO archive_conversation(archive_id,conversation_id,raw_locator_json) VALUES(?,?,?)",
            arguments: [
              aid, c.id,
              try chatJSON(SavedConversation(location: c.location, versionIDs: versions)),
            ])
          return (result, newVersions)
        }
        changedVersions += counts.1
        totals.new += counts.0.new
        totals.changed += counts.0.changed
        totals.unchanged += counts.0.unchanged
        completed.append(c.id)
        progress(completed.count, subset.count)
      } catch { errors.append("\(c.title)：\(error.localizedDescription)") }
    }
    let done = Set(completed)
    let pending = subset.map(\.id).filter { !done.contains($0) }
    let status =
      preview.conversations.isEmpty
      ? "failed" : errors.isEmpty && pending.isEmpty ? "parsed" : "partial"
    try database.write { db in
      try db.execute(
        sql: "UPDATE import_archive SET status=?,diagnostics_json=? WHERE id=?",
        arguments: [status, try chatJSON(errors), aid])
    }
    return .init(
      archiveID: aid, changedVersionIDs: changedVersions, completed: completed, pending: pending,
      diagnostics: errors, changes: totals)
  }

  public func chatArchives() throws -> [SavedChatArchive] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT a.id,a.status,a.imported_at,s.value_json,(SELECT COUNT(*) FROM archive_conversation ac WHERE ac.archive_id=a.id) AS saved
          FROM import_archive a JOIN workspace_settings s ON s.key='chat-import/'||a.id WHERE a.deleted_at IS NULL ORDER BY a.imported_at DESC
          """
      ).map { row in
        let d = try chatDecode(ArchiveDetails.self, row["value_json"])
        return SavedChatArchive(
          id: row["id"], filename: d.filename, namespace: d.namespace, sha256: d.sha256,
          status: row["status"], importedAt: row["imported_at"], savedConversations: row["saved"],
          selection: d.selection)
      }
    }
  }
  public func reopenChatArchive(_ id: String) throws -> ChatImportPreview {
    let row = try database.read { db in
      try Row.fetchOne(
        db,
        sql:
          "SELECT a.provider_kind,s.value_json FROM import_archive a JOIN workspace_settings s ON s.key='chat-import/'||a.id WHERE a.id=? AND a.deleted_at IS NULL",
        arguments: [id])
    }
    guard let row else { throw ChatImportError("找不到聊天档案。") }
    let d = try chatDecode(ArchiveDetails.self, row["value_json"])
    let bytes = try rawChatBytes(d.sha256)
    return try ChatArchiveParser.preview(
      bytes: bytes, filename: d.filename, namespace: d.namespace,
      plain: (row["provider_kind"] as String) == "plain_text")
  }
  public func chatSources(archiveID: String, selected: Set<String>) throws -> [ChatArchiveSource] {
    try database.read { db in
      var result: [ChatArchiveSource] = []
      for id in selected.sorted() {
        guard let saved = try savedConversation(db, archiveID, id) else { continue }
        for vid in saved.versionIDs { result.append(try chatSource(db, vid)) }
      }
      return result
    }
  }
  public func chatSource(versionID: String) throws -> ChatArchiveSource {
    try database.read { try chatSource($0, versionID) }
  }
  /// The resolver opens the immutable original bytes and follows the stored pointer, including escaped keys.
  public func chatOriginal(versionID: String) throws -> String {
    let source = try chatSource(versionID: versionID)
    let hash = try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT raw_asset_sha256 FROM import_archive WHERE id=?",
        arguments: [source.archiveID])
    }
    guard let hash else { throw ChatImportError("原件不存在。") }
    let bytes = try rawChatBytes(hash)
    let loc = source.location
    if loc.pointer.isEmpty { return String(decoding: bytes, as: UTF8.self) }
    let json: Data
    if let name = loc.member {
      let archive = try ChatExportZIP(bytes)
      guard let entry = archive.members.first(where: { $0.name == name }) else {
        throw ChatImportError("原档缺少成员：\(name)")
      }
      json = try archive.bytes(entry)
    } else {
      json = bytes
    }
    var value = try JSONSerialization.jsonObject(with: json)
    for segment in loc.pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
      let token = segment.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(
        of: "~0", with: "~")
      if let obj = value as? [String: Any], let next = obj[token] {
        value = next
      } else if let arr = value as? [Any], let i = Int(token), arr.indices.contains(i) {
        value = arr[i]
      } else {
        throw ChatImportError("原消息定位不匹配：\(loc.pointer)")
      }
    }
    return String(
      decoding: try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
      as: UTF8.self)
  }

  private func rawChatBytes(_ hash: String) throws -> Data {
    guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
      throw ChatImportError("原档摘要无效。")
    }
    let bytes = try Data(
      contentsOf: directory.appendingPathComponent("assets/\(hash.prefix(2))/\(hash)"),
      options: .mappedIfSafe)
    guard atlasHash(bytes) == hash else { throw ChatImportError("原件校验失败：\(hash)") }
    return bytes
  }
  private func currentDigest(_ db: Database, _ id: String) throws -> String? {
    try String.fetchOne(
      db,
      sql:
        "SELECT v.content_sha256 FROM import_message m JOIN import_message_version v ON v.id=m.current_version_id WHERE m.id=?",
      arguments: [id])
  }
  private func savedConversation(_ db: Database, _ aid: String, _ cid: String) throws
    -> SavedConversation?
  {
    try String.fetchOne(
      db,
      sql:
        "SELECT raw_locator_json FROM archive_conversation WHERE archive_id=? AND conversation_id=?",
      arguments: [aid, cid]
    ).map { try chatDecode(SavedConversation.self, $0) }
  }
  func chatSource(_ db: Database, _ version: String) throws -> ChatArchiveSource {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT v.*,m.external_message_id,c.id AS cid,c.title,s.value_json FROM import_message_version v JOIN import_message m ON m.id=v.message_id
          JOIN import_conversation c ON c.id=m.conversation_id JOIN workspace_settings s ON s.key='chat-import/'||v.source_archive_id WHERE v.id=?
          """, arguments: [version])
    else { throw ChatImportError("无法定位原消息版本。") }
    let s = try chatDecode(SavedMessage.self, row["raw_locator_json"])
    return .init(
      id: version, conversationID: row["cid"], conversationTitle: row["title"],
      archiveID: row["source_archive_id"],
      filename: try chatDecode(ArchiveDetails.self, row["value_json"]).filename,
      messageID: row["message_id"], externalID: row["external_message_id"], role: row["role"],
      rawRole: s.rawRole, timestamp: row["original_timestamp"],
      parent: row["source_parent_external_id"], body: row["body_text"], version: row["ordinal"],
      parts: try chatDecode([ChatContentPart].self, row["parts_json"]), location: s.location)
  }
}

public struct ChatArchiveExcerpt: Codable, Equatable, Sendable {
  public let versionID: String
  public let start: Int, end: Int
  public let exact: String
  public let textSHA256: String
  public let offsetUnit: String

  public static func capture(_ source: ChatArchiveSource, range: NSRange) throws -> Self {
    let text = source.body
    guard range.length > 0, let bounds = Range(range, in: text),
      text.indices.contains(bounds.lowerBound),
      bounds.upperBound == text.endIndex || text.indices.contains(bounds.upperBound)
    else {
      throw ChatImportError("选区必须落在完整字符边界。")
    }
    return .init(
      versionID: source.id, start: text[..<bounds.lowerBound].unicodeScalars.count,
      end: text[..<bounds.upperBound].unicodeScalars.count, exact: String(text[bounds]),
      textSHA256: atlasHash(Data(text.utf8)), offsetUnit: "unicode_code_points")
  }
  public func resolve(in store: AtlasStore) throws -> (ChatArchiveSource, NSRange) {
    let source = try store.chatSource(versionID: versionID)
    guard offsetUnit == "unicode_code_points", atlasHash(Data(source.body.utf8)) == textSHA256,
      let r = source.body.atlasUTF16Range(start: start, end: end),
      (source.body as NSString).substring(with: r).utf8.elementsEqual(exact.utf8)
    else {
      throw ChatImportError("该版本片段无法精确定位，已保留引文。")
    }
    return (source, r)
  }
}
