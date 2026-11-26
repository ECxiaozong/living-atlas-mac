import Foundation
import GRDB

public enum ChatProjectionKind: String, Codable, CaseIterable, Sendable {
  case excerpt, interpretation, question
  public var label: String {
    switch self {
    case .excerpt: "原文摘录"
    case .interpretation: "手写综合解释"
    case .question: "手写补充问题"
    }
  }
}
public struct ChatProjectionItem: Codable, Equatable, Sendable {
  public let kind: ChatProjectionKind
  public let title: String, body: String
  public let sources: [ChatArchiveExcerpt]
  public init(kind: ChatProjectionKind, title: String, body: String, sources: [ChatArchiveExcerpt])
  {
    self.kind = kind
    self.title = title
    self.body = body
    self.sources = sources
  }
}
public struct ChatProjectionChange: Identifiable, Sendable {
  public let id: String, nodeID: String
  public let item: ChatProjectionItem
}
public struct ChatProjectionPlan: Identifiable, Sendable {
  public let id: String, status: String
  public let changes: [ChatProjectionChange]
}
public struct ChatProjectionNode: Identifiable, Sendable {
  public let id: String, versionID: String, title: String, body: String
  public let sources: [ChatArchiveExcerpt]
}
private struct ChatReadScope: Codable {
  let signature: String
  let versionIDs: [String]
}
private let projectionSummary = "聊天原档 · 选段转换"
private func projectionNow() -> String {
  Date.now.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
}

extension AtlasStore {
  /// Reviewing writes proposal operations only; no content, placement, or search entity exists until apply.
  public func proposeChatProjection(_ items: [ChatProjectionItem], permittedVersionIDs: Set<String>)
    throws -> ChatProjectionPlan
  {
    guard !items.isEmpty, items.count <= 64 else { throw ChatImportError("一次转换需包含 1 至 64 项。") }
    let scope = Set(items.flatMap(\.sources).map(\.versionID))
    guard scope.isSubset(of: permittedVersionIDs) else { throw ChatImportError("来源超出本次选定的消息。") }
    return try database.write { db in
      let signature = chatDigest([try chatJSON(items)])
      let stamp = projectionNow()
      for item in items {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !item.sources.isEmpty,
          item.kind != .excerpt
            || (item.sources.count == 1 && item.body.utf8.elementsEqual(item.sources[0].exact.utf8))
        else { throw ChatImportError("摘录须与一个精确原句一致；补写问题和解释需要正文与来源。") }
        for e in item.sources { _ = try checkChatExcerpt(db, e) }
      }
      if let existing = try String.fetchOne(
        db,
        sql:
          "SELECT id FROM change_batch WHERE summary=? AND json_extract(read_scope_json,'$.signature')=? AND status IN ('reviewable','applied') ORDER BY created_at DESC LIMIT 1",
        arguments: [projectionSummary, signature])
      {
        return try readProjectionPlan(db, existing)
      }
      let id = UUID().uuidString.lowercased()
      try db.execute(
        sql:
          "INSERT INTO change_batch(id,status,actor_kind,read_scope_json,write_scope_json,base_revisions_json,policy_revision_at_plan,summary,created_at) VALUES(?,'reviewable','user',?,?,'{}',1,?,?)",
        arguments: [
          id,
          try chatJSON(ChatReadScope(signature: signature, versionIDs: scope.sorted())),
          try chatJSON(["create_content", "create_instance"]), projectionSummary, stamp,
        ])
      for (i, item) in items.enumerated() {
        try db.execute(
          sql:
            "INSERT INTO change_operation(id,batch_id,ordinal,operation_type,target_kind,target_id,facet,expected_revision,after_json) VALUES(?,?,?,'create_content','content',?,'content',0,?)",
          arguments: [
            UUID().uuidString.lowercased(), id, i, UUID().uuidString.lowercased(),
            try chatJSON(item),
          ])
      }
      return try readProjectionPlan(db, id)
    }
  }

  public func chatProjectionPlans() throws -> [ChatProjectionPlan] {
    try database.read { db in
      try String.fetchAll(
        db, sql: "SELECT id FROM change_batch WHERE summary=? ORDER BY created_at DESC",
        arguments: [projectionSummary]
      ).map { try readProjectionPlan(db, $0) }
    }
  }

  public func applyChatProjection(_ planID: String) throws -> ChatProjectionPlan {
    try database.write { db in
      let p = try readProjectionPlan(db, planID)
      if p.status == "applied" { return p }
      guard p.status == "reviewable" else { throw ChatImportError("此建议已关闭。") }
      let stamp = projectionNow()
      try db.execute(sql: "INSERT OR IGNORE INTO canvas_view(id,title) VALUES('atlas','图谱')")
      var y =
        try Double.fetchOne(db, sql: "SELECT max(y+height+32) FROM placement WHERE view_id='atlas'")
        ?? 72
      for c in p.changes {
        let v = UUID().uuidString.lowercased()
        let item = c.item
        try db.execute(
          sql: "INSERT INTO content_node(id,kind,title,created_at) VALUES(?,?,?,?)",
          arguments: [c.nodeID, item.kind.rawValue, item.title, stamp])
        try db.execute(
          sql:
            "INSERT INTO content_version(id,node_id,ordinal,body_markdown,plain_text,body_sha256,origin_kind,actor_kind,created_at) VALUES(?,?,1,?,?,?,?,?,?)",
          arguments: [
            v, c.nodeID, item.body, item.body, atlasHash(Data(item.body.utf8)),
            item.kind == .excerpt ? "import" : "user", item.kind == .excerpt ? "importer" : "user",
            stamp,
          ])
        try db.execute(
          sql: "UPDATE content_node SET current_version_id=? WHERE id=?", arguments: [v, c.nodeID])
        for excerpt in item.sources {
          let ref = try recordChatReference(db, excerpt)
          try db.execute(
            sql:
              "INSERT OR IGNORE INTO node_origin(content_version_id,reference_id,origin_role) VALUES(?,?,?)",
            arguments: [
              v, ref,
              item.kind == .excerpt
                ? "excerpt" : item.kind == .interpretation ? "synthesis" : "interpretation",
            ])
        }
        try db.execute(
          sql:
            "INSERT INTO placement(id,view_id,target_kind,content_id,x,y,width,height,display_mode) VALUES(?,'atlas','content',?,64,?,248,116,'overview')",
          arguments: ["map.content." + c.nodeID, c.nodeID, y])
        try db.execute(
          sql:
            "INSERT INTO index_outbox(entity_kind,entity_id,version_id,operation,created_at) VALUES('content',?,?,'upsert',?)",
          arguments: [c.nodeID, v, stamp])
        y += 148
      }
      try db.execute(
        sql: "UPDATE change_batch SET status='applied',applied_at=? WHERE id=?",
        arguments: [stamp, p.id])
      return try readProjectionPlan(db, p.id)
    }
  }

  /// Declining a suggestion changes its status; archived messages stay immutable.
  public func discardChatProjection(_ id: String) throws {
    try database.write { db in
      let p = try readProjectionPlan(db, id)
      guard p.status == "reviewable" else { throw ChatImportError("只可放弃尚未应用的建议。") }
      try db.execute(sql: "UPDATE change_batch SET status='cancelled' WHERE id=?", arguments: [id])
    }
  }

  public func undoChatProjection(_ id: String) throws {
    try database.write { db in
      let p = try readProjectionPlan(db, id)
      if p.status == "rolled_back" { return }
      guard p.status == "applied" else { throw ChatImportError("这份建议尚未应用。") }
      let stamp = projectionNow()
      let rollback = UUID().uuidString.lowercased()
      for c in p.changes {
        let conflict = try Int.fetchOne(
          db,
          sql: """
            SELECT NOT EXISTS(SELECT 1 FROM content_node n JOIN placement p ON p.content_id=n.id
                 WHERE n.id=? AND n.content_revision=1 AND n.metadata_revision=1 AND n.deleted_at IS NULL AND p.layout_revision=1 AND p.id=?)
            OR EXISTS(SELECT 1 FROM placement WHERE content_id=? AND id<>?)
            OR EXISTS(SELECT 1 FROM reference_snapshot r JOIN content_version v ON v.id=r.content_version_id
                 WHERE v.node_id=? AND (EXISTS(SELECT 1 FROM inquiry_reference i WHERE i.reference_id=r.id)
                  OR EXISTS(SELECT 1 FROM node_origin o WHERE o.reference_id=r.id)
                  OR EXISTS(SELECT 1 FROM relation_version k WHERE k.from_reference_id=r.id OR k.to_reference_id=r.id)
                  OR EXISTS(SELECT 1 FROM relation_evidence e WHERE e.reference_id=r.id)
                  OR EXISTS(SELECT 1 FROM annotation_version a WHERE a.source_reference_id=r.id)))
            OR EXISTS(SELECT 1 FROM topic_membership WHERE content_id=?)
            OR EXISTS(SELECT 1 FROM content_version WHERE node_id=? AND ordinal>1)
            """,
          arguments: [
            c.nodeID, "map.content." + c.nodeID, c.nodeID, "map.content." + c.nodeID, c.nodeID,
            c.nodeID, c.nodeID,
          ])
        guard conflict == 0 else { throw ChatImportError("「\(c.item.title)」已有后续引用或改动，已保留整批内容。") }
      }
      try db.execute(
        sql:
          "INSERT INTO change_batch(id,status,actor_kind,read_scope_json,write_scope_json,base_revisions_json,policy_revision_at_plan,summary,created_at,applied_at,rollback_of_batch_id) VALUES(?,'applied','user','[]','[]','{}',1,'撤回聊天选段转换',?,?,?)",
        arguments: [rollback, stamp, stamp, id])
      for (i, c) in p.changes.enumerated() {
        try db.execute(
          sql:
            "INSERT INTO change_operation(id,batch_id,ordinal,operation_type,target_kind,target_id,facet,expected_revision,before_json) VALUES(?,?,?,'archive_content','content',?,'lifecycle',1,?)",
          arguments: [UUID().uuidString.lowercased(), rollback, i, c.nodeID, try chatJSON(c.item)])
        try db.execute(
          sql: "UPDATE content_node SET deleted_at=? WHERE id=?", arguments: [stamp, c.nodeID])
        try db.execute(sql: "DELETE FROM placement WHERE content_id=?", arguments: [c.nodeID])
        try db.execute(
          sql:
            "INSERT INTO index_outbox(entity_kind,entity_id,operation,created_at) VALUES('content',?,'delete',?)",
          arguments: [c.nodeID, stamp])
      }
      try db.execute(
        sql: "UPDATE change_batch SET status='rolled_back' WHERE id=?", arguments: [id])
    }
  }

  public func chatProjection(nodeID: String) throws -> ChatProjectionNode? {
    try database.read { db in
      guard
        let r = try Row.fetchOne(
          db,
          sql:
            "SELECT n.id,n.title,v.id AS vid,v.plain_text FROM content_node n JOIN content_version v ON v.id=n.current_version_id WHERE n.id=? AND n.deleted_at IS NULL AND EXISTS(SELECT 1 FROM node_origin o JOIN reference_snapshot r ON r.id=o.reference_id WHERE o.content_version_id=v.id AND r.source_kind='message')",
          arguments: [nodeID])
      else { return nil }
      let version: String = r["vid"]
      return .init(
        id: r["id"], versionID: version, title: r["title"], body: r["plain_text"],
        sources: try projectionOrigins(db, version))
    }
  }
  public func chatReference(_ excerpt: ChatArchiveExcerpt) throws -> String {
    try database.write { try recordChatReference($0, excerpt) }
  }
  public func chatProjectionReference(nodeID: String) throws -> String {
    try database.write { db in
      guard
        let r = try Row.fetchOne(
          db,
          sql:
            "SELECT v.id,v.plain_text FROM content_node n JOIN content_version v ON v.id=n.current_version_id WHERE n.id=? AND n.deleted_at IS NULL AND EXISTS(SELECT 1 FROM node_origin o WHERE o.content_version_id=v.id)",
          arguments: [nodeID])
      else { throw ChatImportError("找不到这项转换。") }
      let v: String = r["id"]
      let body: String = r["plain_text"]
      let ref = chatID(["chat-projection-ref", v])
      try db.execute(
        sql:
          "INSERT OR IGNORE INTO reference_snapshot(id,source_kind,content_version_id,quote_snapshot,created_at) VALUES(?,'content',?,?,?)",
        arguments: [ref, v, body, projectionNow()])
      return ref
    }
  }
  /// Returns archival evidence for both a direct message reference and a converted content reference.
  public func chatOrigins(referenceID: String) throws -> [ChatArchiveExcerpt] {
    try database.read { db in
      guard
        let r = try Row.fetchOne(
          db, sql: "SELECT source_kind,content_version_id FROM reference_snapshot WHERE id=?",
          arguments: [referenceID])
      else { return [] }
      if (r["source_kind"] as String) == "message" {
        return try fetchExcerpts(db, "r.id=?", referenceID)
      }
      guard let v: String = r["content_version_id"] else { return [] }
      return try projectionOrigins(db, v)
    }
  }
  private func projectionOrigins(_ db: Database, _ version: String) throws -> [ChatArchiveExcerpt] {
    try fetchExcerpts(
      db, "o.content_version_id=?", version,
      link: "JOIN node_origin o ON o.reference_id=r.id", order: "o.rowid"
    )
  }
  private func fetchExcerpts(
    _ db: Database, _ predicate: String, _ id: String, link: String = "", order: String = "r.rowid"
  ) throws
    -> [ChatArchiveExcerpt]
  {
    try Row.fetchAll(
      db,
      sql:
        "SELECT r.message_version_id,r.quote_snapshot,a.start_offset,a.end_offset,a.text_sha256 FROM reference_snapshot r JOIN source_anchor a ON a.reference_id=r.id "
        + link + " WHERE r.source_kind='message' AND "
        + predicate + " ORDER BY " + order, arguments: [id]
    ).map {
      ChatArchiveExcerpt(
        versionID: $0["message_version_id"], start: $0["start_offset"], end: $0["end_offset"],
        exact: $0["quote_snapshot"], textSHA256: $0["text_sha256"],
        offsetUnit: "unicode_code_points")
    }
  }
  private func checkChatExcerpt(_ db: Database, _ e: ChatArchiveExcerpt) throws -> ChatArchiveSource
  {
    let s = try chatSource(db, e.versionID)
    guard e.offsetUnit == "unicode_code_points", atlasHash(Data(s.body.utf8)) == e.textSHA256,
      let r = s.body.atlasUTF16Range(start: e.start, end: e.end),
      (s.body as NSString).substring(with: r).utf8.elementsEqual(e.exact.utf8)
    else { throw ChatImportError("引文无法定位到原消息版本。") }
    return s
  }
  private func recordChatReference(_ db: Database, _ e: ChatArchiveExcerpt) throws -> String {
    _ = try checkChatExcerpt(db, e)
    let ref = chatID(["chat-ref", e.versionID, String(e.start), String(e.end), e.textSHA256])
    try db.execute(
      sql:
        "INSERT OR IGNORE INTO reference_snapshot(id,source_kind,message_version_id,quote_snapshot,created_at) VALUES(?,'message',?,?,?)",
      arguments: [ref, e.versionID, e.exact, projectionNow()])
    try db.execute(
      sql:
        "INSERT OR IGNORE INTO source_anchor(id,reference_id,segment_order,selector_type,offset_unit,start_offset,end_offset,text_sha256) VALUES(?,?,0,'text','unicode_code_points',?,?,?)",
      arguments: [chatID(["anchor", ref]), ref, e.start, e.end, e.textSHA256])
    return ref
  }
  private func readProjectionPlan(_ db: Database, _ id: String) throws -> ChatProjectionPlan {
    guard
      let state = try String.fetchOne(
        db, sql: "SELECT status FROM change_batch WHERE id=? AND summary=?",
        arguments: [id, projectionSummary])
    else { throw ChatImportError("找不到这份聊天转换建议。") }
    let rows = try Row.fetchAll(
      db,
      sql: "SELECT id,target_id,after_json FROM change_operation WHERE batch_id=? ORDER BY ordinal",
      arguments: [id])
    return .init(
      id: id, status: state,
      changes: try rows.map { row in
        let raw: String = row["after_json"]
        return .init(
          id: row["id"], nodeID: row["target_id"],
          item: try JSONDecoder().decode(ChatProjectionItem.self, from: Data(raw.utf8)))
      })
  }
}
