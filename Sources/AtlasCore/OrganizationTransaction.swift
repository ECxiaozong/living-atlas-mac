import Foundation
import GRDB

public struct OrganizationConflict: Codable, Identifiable, Sendable {
  public let id, reason: String
}
extension AtlasStore {
  private func key(_ plan: String, _ edit: OrganizationEdit, _ part: String) -> String {
    chatID(["organization", plan, edit.id, part])
  }

  // Older applied batches still contain the reviewed entrance IDs, even after undo or removal.
  static func restoreOrganizationRelationEntrances(_ db: Database) throws {
    let marker = "migration.organization-relation-entrances.1"
    if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM workspace_settings WHERE key=?)",
                         arguments: [marker]) == true { return }
    let edits = try Row.fetchAll(db, sql: """
      SELECT b.id AS batch, json_extract(o.after_json,'$.id') AS edit,
        json_extract(o.after_json,'$.target') AS lhs, json_extract(o.after_json,'$.peer') AS rhs
      FROM change_operation o JOIN change_batch b ON b.id=o.batch_id
      WHERE o.operation_type='relate' AND b.applied_at IS NOT NULL
        AND b.rollback_of_batch_id IS NULL AND b.summary LIKE ?
      """, arguments: [organizationTag + "%"])
    for row in edits {
      guard let edit: String = row["edit"], let lhs: String = row["lhs"], let rhs: String = row["rhs"] else { continue }
      let relation = chatID(["organization", row["batch"], edit, "relation"])
      if let stamp = try String.fetchOne(db, sql: """
        SELECT created_at FROM semantic_relation WHERE id=?
          AND NOT EXISTS(SELECT 1 FROM workspace_settings WHERE key=?)
        """, arguments: [relation, "view.map.relation-pair." + relation]) {
        try saveRelationEntrances(db, relation: relation, from: lhs, to: rhs, stamp: stamp)
      }
    }
    try db.execute(sql: "INSERT INTO workspace_settings(key,value_json,revision,updated_at) VALUES (?,'true',1,?)",
                   arguments: [marker, orgStamp()])
  }

  public func applyOrganization(_ id: String) throws -> OrganizationPlan {
    let failure: String? = try database.write { db in
      try applyOrganizationInsideTransaction(db, id)
    }
    if let failure { throw organizationError(failure) }
    return try database.read { try loadOrganization($0, id) }
  }
  func applyOrganizationInsideTransaction(_ db: Database, _ id: String) throws -> String? {
    let p = try loadOrganization(db, id)
    if p.status == "applied" { return nil }
    guard p.status == "reviewable" else { throw organizationError("此提案已经结束或过时。") }
    let issues = try forwardConflicts(db, p)
    if !issues.isEmpty {
      try db.execute(sql: "UPDATE change_batch SET status='stale' WHERE id=?", arguments: [id])
      return issues.map(\.reason).joined(separator: "\n")
    }
    try db.execute(sql: "UPDATE change_batch SET status='applying' WHERE id=?", arguments: [id])
    let actor =
      try String.fetchOne(
        db, sql: "SELECT actor_kind FROM change_batch WHERE id=?", arguments: [id]) ?? "user"
    for e in p.edits { try performOrganization(db, p, e, actor: actor) }
    try db.execute(
      sql: "UPDATE change_batch SET status='applied',applied_at=? WHERE id=?",
      arguments: [orgStamp(), id])
    return nil
  }
  public func organizationConflicts(_ id: String) throws -> [OrganizationConflict] {
    try database.read { db in
      let p = try loadOrganization(db, id)
      if p.status == "rolled_back" || p.status == "cancelled" { return [] }
      if p.status == "applied" {
        let pending = try remainingEdits(db, p)
        return try pending.compactMap { e in
          try reverseIssue(db, p, e).map { OrganizationConflict(id: e.id, reason: $0) }
        }
      }
      return try forwardConflicts(db, p)
    }
  }

  private func forwardConflicts(_ db: Database, _ p: OrganizationPlan) throws
    -> [OrganizationConflict]
  {
    let policy = try Int.fetchOne(
      db, sql: "SELECT policy_revision FROM workspace WHERE singleton=1")
    if policy != p.scope.policy { return [.init(id: "policy", reason: "授权已变更，请重新选择范围。")] }
    var issues: [OrganizationConflict] = []
    for e in p.edits {
      let s = p.scope.objects.first { $0.id == e.target }!
      guard let live = try organizationObject(db, e.target, displayedRunID: s.displayedRunID), live.target == s.target else {
        issues.append(.init(id: e.id, reason: s.title + "的入口已改变。"))
        continue
      }
      let issue: String?
      switch e.action {
      case .move, .removeEntrance:
        if e.action == .move, p.scope.presentationSizes != nil, let peerID = e.peer,
          let anchor = p.scope.objects.first(where: { $0.id == peerID }) {
          let revision = try Int.fetchOne(db, sql: "SELECT layout_revision FROM placement WHERE id=? AND view_id='atlas'",
                                         arguments: [peerID])
          if revision != anchor.layoutRevision {
            issues.append(.init(id: e.id, reason: anchor.title + " · 参照入口的位置或状态已经改变"))
            continue
          }
        }
        issue =
          live.layoutRevision != s.layoutRevision || live.x != s.x || live.y != s.y
            || live.region != s.region ? "入口位置或状态已经改变" : nil
      case .rewrite:
        let draft = try hasDraft(db, s)
        issue =
          live.version != s.version || live.contentRevision != s.contentRevision
          ? "正文版本已经改变" : draft ? "有活动草稿" : nil
      case .relate:
        let base = p.scope.objects.first { $0.id == e.peer }
        let peer = try e.peer.flatMap { try organizationObject(db, $0, displayedRunID: base?.displayedRunID) }
        issue =
          live.version != s.version || peer == nil || peer?.version != base?.version
          ? "来源端点已经改变" : nil
      case .addEntrance:
        let region = p.scope.regions.first { $0.id == e.region }!
        let fresh = try Int.fetchOne(
          db,
          sql:
            "SELECT r.revision FROM region r JOIN topic t ON t.id=r.topic_id WHERE r.id=? AND t.deleted_at IS NULL",
          arguments: [region.id])
        let existing =
          try Bool.fetchOne(
            db,
            sql:
              "SELECT EXISTS(SELECT 1 FROM topic_membership WHERE topic_id=? AND target_kind=? AND coalesce(content_id,turn_id,document_id)=?) OR EXISTS(SELECT 1 FROM placement WHERE parent_region_id=? AND target_kind=? AND coalesce(content_id,turn_id,document_id)=?)",
            arguments: [region.topic, s.kind, s.target, region.id, s.kind, s.target]) ?? false
        issue = (fresh != region.revision ? "主题地域已经改变" : existing ? "主题已有此内容的入口" : nil)
      }
      if let issue { issues.append(.init(id: e.id, reason: s.title + " · " + issue)) }
    }
    return issues
  }

  private func hasDraft(_ db: Database, _ s: OrganizationObject) throws -> Bool {
    try Bool.fetchOne(
      db, sql: "SELECT EXISTS(SELECT 1 FROM draft WHERE content_id=? OR document_id=?)",
      arguments: [s.kind == "content" ? s.target : nil, s.kind == "document" ? s.target : nil])
      ?? false
  }
  private func reference(_ db: Database, _ s: OrganizationObject) throws -> String {
    guard !s.version.isEmpty else { throw organizationError("此对象没有可引用版本。") }
    let type = s.kind == "document" ? "document" : "content"
    let pdfText = s.pdfTextByFilePage?.compactMap { $0 }.joined(separator: "\n\n")
    var parts = [pdfText == nil ? "org.source" : "org.pdf-text", type, s.version]
    if let page = s.pdfPageIndex { parts += ["page", String(page)] }
    let id = chatID(parts)
    try db.execute(
      sql:
        "INSERT OR IGNORE INTO reference_snapshot(id,source_kind,content_version_id,document_version_id,quote_snapshot,created_at) VALUES(?,?,?,?,?,?)",
      arguments: [
        id, type, type == "content" ? s.version : nil, type == "document" ? s.version : nil, pdfText ?? (s.pdfPageIndex == nil ? s.body : ""),
        orgStamp(),
      ])
    if let page = s.pdfPageIndex {
      try db.execute(sql: """
        INSERT OR IGNORE INTO source_anchor(id,reference_id,segment_order,page_index,selector_type,geometry_json)
        VALUES (?,?,0,?,'page','{}')
        """, arguments: [chatID([id, "page"]), id, page])
    }
    return id
  }
  public func organizationReference(plan: String, placement: String) throws -> String {
    try database.write { db in
      let p = try loadOrganization(db, plan)
      guard let s = p.scope.objects.first(where: { $0.id == placement }) else {
        throw organizationError("来源超出本次整理。")
      }
      return try reference(db, s)
    }
  }
  public func organizationResultReference(plan: String, editID: String) throws -> String {
    try database.write { db in
      let p = try loadOrganization(db, plan)
      guard ["applied", "rolled_back"].contains(p.status),
        let e = p.edits.first(where: { $0.id == editID }),
        [OrganizationAction.rewrite, .relate].contains(e.action)
      else { throw organizationError("此修改没有可引用的正式结果。") }
      let content = e.action == .rewrite
      let v = key(plan, e, content ? "version" : "relationVersion")
      let ref = chatID(["org.result", v])
      let text = content ? e.body : e.reason
      let active = try remainingEdits(db, p).contains(where: { $0.id == e.id })
      try db.execute(
        sql:
          "INSERT OR IGNORE INTO reference_snapshot(id,source_kind,content_version_id,relation_version_id,quote_snapshot,source_state_at_capture,created_at) VALUES (?,?,?,?,?,?,?)",
        arguments: [
          ref, content ? "content" : "relation", content ? v : nil, content ? nil : v, text,
          active ? "available" : "historical", orgStamp(),
        ])
      return ref
    }
  }
  private func insertPlacement(
    _ db: Database, _ s: OrganizationObject, id: String, region: String?, x: Double, y: Double,
    revision: Int
  ) throws {
    try db.execute(
      sql:
        "INSERT INTO placement(id,view_id,target_kind,turn_id,content_id,document_id,parent_region_id,x,y,width,height,display_mode,reader_state_json,layout_revision) VALUES(?,'atlas',?,?,?,?,?,?,?,?,?,?,?,?)",
      arguments: [
        id, s.kind, s.kind == "turn" ? s.target : nil, s.kind == "content" ? s.target : nil,
        s.kind == "document" ? s.target : nil, region, x, y, s.width, s.height, s.display, s.reader,
        revision,
      ])
  }
  private func dirty(
    _ db: Database, _ kind: String, _ target: String, version: String? = nil,
    operation: String = "upsert"
  ) throws {
    try db.execute(
      sql:
        "INSERT INTO index_outbox(entity_kind,entity_id,version_id,operation,created_at) VALUES (?,?,?,?,?)",
      arguments: [kind, target, version, operation, orgStamp()])
  }
  private func performOrganization(
    _ db: Database, _ p: OrganizationPlan, _ e: OrganizationEdit, actor: String
  ) throws {
    let s = p.scope.objects.first { $0.id == e.target }!
    let stamp = orgStamp()
    switch e.action {
    case .move:
      try db.execute(
        sql: "UPDATE placement SET x=?,y=?,layout_revision=layout_revision+1 WHERE id=?",
        arguments: [e.x, e.y, s.id])
    case .removeEntrance: try db.execute(sql: "DELETE FROM placement WHERE id=?", arguments: [s.id])
    case .rewrite:
      let v = key(p.id, e, "version")
      let t = e.body!
      guard
        let ordinal = try Int.fetchOne(
          db, sql: "SELECT max(ordinal)+1 FROM content_version WHERE node_id=?",
          arguments: [s.target])
      else { throw organizationError("正文版本不存在。") }
      try db.execute(
        sql:
          "INSERT INTO content_version(id,node_id,ordinal,body_markdown,plain_text,body_sha256,origin_kind,actor_kind,created_at,supersedes_version_id) VALUES(?,?,?,?,?,?,?,?,?,?)",
        arguments: [
          v, s.target, ordinal, t, t, atlasHash(Data(t.utf8)), actor == "ai" ? "ai" : "user", actor, stamp, s.version,
        ])
      try db.execute(
        sql:
          "INSERT INTO node_origin(content_version_id,reference_id,origin_role) SELECT ?,reference_id,origin_role FROM node_origin WHERE content_version_id=?",
        arguments: [v, s.version])
      try db.execute(
        sql:
          "UPDATE content_node SET current_version_id=?,content_revision=content_revision+1 WHERE id=?",
        arguments: [v, s.target])
      try dirty(db, "content", s.target, version: v)
    case .addEntrance:
      let r = p.scope.regions.first { $0.id == e.region }!
      try db.execute(
        sql:
          "INSERT INTO topic_membership(id,topic_id,target_kind,turn_id,content_id,document_id) VALUES(?,?,?,?,?,?)",
        arguments: [
          key(p.id, e, "member"), r.topic, s.kind, s.kind == "turn" ? s.target : nil,
          s.kind == "content" ? s.target : nil, s.kind == "document" ? s.target : nil,
        ])
      try insertPlacement(
        db, s, id: key(p.id, e, "placement"), region: r.id, x: e.x ?? s.x + 288,
        y: e.y ?? s.y + 144, revision: 1)
    case .relate:
      let peer = p.scope.objects.first { $0.id == e.peer }!
      let type = MapRelation(rawValue: e.relation!)!
      let r = key(p.id, e, "relation")
      let v = key(p.id, e, "relationVersion")
      let a = try reference(db, s)
      let b = try reference(db, peer)
      try db.execute(
        sql: "INSERT INTO semantic_relation(id,current_version_id,created_at) VALUES (?,?,?)",
        arguments: [r, v, stamp])
      try db.execute(
        sql:
          "INSERT INTO relation_version(id,relation_id,ordinal,from_reference_id,to_reference_id,relation_type,direction,epistemic_kind,explanation,actor_kind,created_at) VALUES(?,?,1,?,?,?,?,?,?,?,?)",
        arguments: [
          v, r, a, b, type.rawValue, type.directed ? "directed" : "undirected",
          type == .related_to || type == .analogous_to ? "exploratory" : "synthesis", e.reason,
          actor, stamp,
        ])
      try Self.saveRelationEntrances(db, relation: r, from: s.id, to: peer.id, stamp: stamp)
      for ref in [a, b] {
        try db.execute(
          sql: "INSERT INTO relation_evidence VALUES(?,?,'source')", arguments: [v, ref])
      }
      try dirty(db, "relation", r, version: v)
    }
  }

  private func remainingEdits(_ db: Database, _ p: OrganizationPlan) throws -> [OrganizationEdit] {
    let done = Set(
      try String.fetchAll(
        db,
        sql:
          "SELECT o.target_id FROM change_operation o JOIN change_batch b ON b.id=o.batch_id WHERE b.rollback_of_batch_id=? AND b.status='applied' AND o.operation_type='undo_organization'",
        arguments: [p.id]))
    return p.edits.filter { !done.contains($0.id) }
  }
  private func referenced(_ db: Database, version: String) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM reference_snapshot r WHERE (r.content_version_id=? OR r.relation_version_id=?) AND (
        EXISTS(SELECT 1 FROM inquiry_reference i WHERE i.reference_id=r.id)
        OR EXISTS(SELECT 1 FROM node_origin o WHERE o.reference_id=r.id)
        OR EXISTS(SELECT 1 FROM relation_version v WHERE v.from_reference_id=r.id OR v.to_reference_id=r.id)
        OR EXISTS(SELECT 1 FROM relation_evidence e WHERE e.reference_id=r.id)
        OR EXISTS(SELECT 1 FROM annotation_version a WHERE a.source_reference_id=r.id)))
        """, arguments: [version, version]) ?? false
  }
  private func reverseIssue(_ db: Database, _ p: OrganizationPlan, _ e: OrganizationEdit) throws
    -> String?
  {
    let s = p.scope.objects.first { $0.id == e.target }!
    var issue: String?
    switch e.action {
    case .move:
      let current = try organizationObject(db, s.id)
      if current?.layoutRevision != s.layoutRevision + 1 || current?.x != e.x || current?.y != e.y {
        issue = "移动后入口有新编辑"
      }
    case .removeEntrance:
      if try organizationObject(db, s.id) != nil { issue = "原入口标识已被重新使用" }
      if let region = s.region,
        try Int.fetchOne(db, sql: "SELECT 1 FROM region WHERE id=?", arguments: [region]) == nil
      {
        issue = "原地域已经移除"
      }
    case .rewrite:
      let v = key(p.id, e, "version")
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT current_version_id,content_revision FROM content_node WHERE id=? AND deleted_at IS NULL",
        arguments: [s.target])
      if (row?["current_version_id"] as String?) != v
        || (row?["content_revision"] as Int?) != s.contentRevision + 1
      {
        issue = "正文有后续修改"
      } else if try hasDraft(db, s) {
        issue = "正文有活动草稿"
      } else if try referenced(db, version: v) {
        issue = "这个版本已被后续问题或其他内容引用"
      }
    case .relate:
      let v = key(p.id, e, "relationVersion")
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT current_version_id,revision FROM semantic_relation WHERE id=? AND deleted_at IS NULL",
        arguments: [key(p.id, e, "relation")])
      if (row?["current_version_id"] as String?) != v || (row?["revision"] as Int?) != 1 {
        issue = "关系已经更新"
      } else if try referenced(db, version: v) {
        issue = "关系版本已有后续引用"
      }
    case .addEntrance:
      let entr = try organizationObject(db, key(p.id, e, "placement"))
      let rev = try Int.fetchOne(
        db, sql: "SELECT revision FROM topic_membership WHERE id=?",
        arguments: [key(p.id, e, "member")])
      if entr?.layoutRevision != 1 || rev != 1 { issue = "新增入口或成员已被修改" }
      if let r = e.region,
        try Int.fetchOne(
          db,
          sql:
            "SELECT count(*) FROM placement WHERE id<>? AND parent_region_id=? AND target_kind=? AND coalesce(content_id,turn_id,document_id)=?",
          arguments: [key(p.id, e, "placement"), r, s.kind, s.target]) ?? 0 > 0
      {
        issue = "同一归属还有后续入口"
      }
    }
    return issue.map { s.title + " · " + $0 }
  }
  /// An explicit subset creates its own compensating batch; a blocked version and its users stay intact.
  public func undoOrganization(_ id: String, selected: Set<String>? = nil) throws
    -> OrganizationPlan
  {
    try database.write { db in
      try undoOrganizationInsideTransaction(db, id, selected: selected, actor: "user")
    }
  }

  func undoOrganizationInsideTransaction(
    _ db: Database, _ id: String, selected: Set<String>? = nil, actor: String
  ) throws -> OrganizationPlan {
    let p = try loadOrganization(db, id)
    if p.status == "rolled_back" { return p }
    guard p.status == "applied" else { throw organizationError("只能撤回已应用的整理。") }
    let pending = try remainingEdits(db, p)
    let chosen = selected ?? Set(pending.map(\.id))
    guard !chosen.isEmpty, chosen.isSubset(of: Set(p.edits.map(\.id))) else {
      throw organizationError("请选择本批次内的操作。")
    }
    let work = pending.filter { chosen.contains($0.id) }
    if work.isEmpty { return p }
    guard
      pending.filter({ !chosen.contains($0.id) }).allSatisfy({
        Set($0.requires).isDisjoint(with: chosen)
      })
    else { throw organizationError("其余修改仍依赖所选项目，请保留前置项目。") }
    let errors = try work.compactMap { try reverseIssue(db, p, $0) }
    guard errors.isEmpty else { throw organizationError(errors.joined(separator: "\n")) }
    let undo = UUID().uuidString
    let stamp = orgStamp()
    try db.execute(
      sql:
        "INSERT INTO change_batch(id,status,actor_kind,read_scope_json,write_scope_json,base_revisions_json,policy_revision_at_plan,summary,created_at,applied_at,rollback_of_batch_id) SELECT ?,'applied',?,read_scope_json,write_scope_json,base_revisions_json,(SELECT policy_revision FROM workspace WHERE singleton=1),?,?,?,id FROM change_batch WHERE id=?",
      arguments: [undo, actor, "撤回 · " + p.summary, stamp, stamp, id])
    for (i, e) in work.reversed().enumerated() {
      let s = p.scope.objects.first { $0.id == e.target }!
      switch e.action {
      case .move:
        try db.execute(
          sql: "UPDATE placement SET x=?,y=?,layout_revision=layout_revision+1 WHERE id=?",
          arguments: [s.x, s.y, s.id])
      case .removeEntrance:
        try insertPlacement(
          db, s, id: s.id, region: s.region, x: s.x, y: s.y, revision: s.layoutRevision + 1)
      case .rewrite:
        try db.execute(
          sql:
            "UPDATE content_node SET current_version_id=?,content_revision=content_revision+1 WHERE id=?",
          arguments: [s.version, s.target])
        try dirty(db, "content", s.target, version: s.version)
      case .addEntrance:
        try db.execute(
          sql: "DELETE FROM placement WHERE id=?", arguments: [key(id, e, "placement")])
        try db.execute(
          sql: "DELETE FROM topic_membership WHERE id=?", arguments: [key(id, e, "member")])
      case .relate:
        let target = key(id, e, "relation")
        try db.execute(
          sql: "UPDATE semantic_relation SET deleted_at=?,revision=revision+1 WHERE id=?",
          arguments: [stamp, target])
        try dirty(db, "relation", target, operation: "delete")
      }
      try db.execute(
        sql:
          "INSERT INTO change_operation(id,batch_id,ordinal,operation_type,target_kind,target_id,facet,expected_revision,before_json,after_json) VALUES(?,?,?,'undo_organization','operation',?,?,0,?,?)",
        arguments: [
          UUID().uuidString, undo, i, e.id, e.action.facet, try chatJSON(e), try chatJSON(s),
        ])
    }
    if work.count == pending.count {
      try db.execute(
        sql: "UPDATE change_batch SET status='rolled_back' WHERE id=?", arguments: [id])
    }
    return try loadOrganization(db, id)
  }
  public func remainingOrganizationEdits(_ id: String) throws -> [OrganizationEdit] {
    try database.read { db in try remainingEdits(db, loadOrganization(db, id)) }
  }
}
