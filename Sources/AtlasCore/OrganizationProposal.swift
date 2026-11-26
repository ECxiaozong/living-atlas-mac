import Foundation
import GRDB

/// The extension deliberately accepts explicit placement/region IDs. An absent region never means all regions.
public enum OrganizationAction: String, Codable, CaseIterable, Sendable {
  case move, rewrite, addEntrance, relate, removeEntrance
  public var label: String {
    switch self {
    case .move: "移动入口"
    case .rewrite: "修订解释"
    case .addEntrance: "添加主题入口"
    case .relate: "建立关系"
    case .removeEntrance: "移除入口"
    }
  }
  var facet: String {
    switch self {
    case .move, .removeEntrance: "layout"
    case .rewrite: "content"
    case .addEntrance: "membership"
    case .relate: "relation"
    }
  }
}
public struct OrganizationObject: Identifiable, Codable, Equatable, Sendable {
  public let id, kind, target, title, body, version: String
  public let nodeKind: String?, region: String?
  public let x, y, width, height: Double
  public let layoutRevision, contentRevision: Int
  public let display, reader: String
  public var displayedRunID: String? = nil
  public internal(set) var documentKind: String?
  public internal(set) var pdfPageIndex: Int?
  /// Slots start at pdfPageIndex, or at page zero for a whole document. A nil slot has no extractable text.
  public internal(set) var pdfTextByFilePage: [String?]?
  public var mayRewrite: Bool {
    kind == "content"
      && ["interpretation", "summary", "note", "idea", "concept", "case"].contains(nodeKind ?? "")
  }
}
public struct OrganizationRegion: Identifiable, Codable, Equatable, Sendable {
  public let id, topic, title: String
  public let revision: Int
  public let x, y, width, height: Double
}
public struct OrganizationEdit: Identifiable, Codable, Equatable, Sendable {
  public var id: String
  public var action: OrganizationAction
  public var target, reason: String
  public var peer: String?, region: String?, body: String?, relation: String?
  public var x: Double?, y: Double?
  public var requires: [String]
  public init(
    id: String = UUID().uuidString, action: OrganizationAction, target: String, reason: String,
    peer: String? = nil, region: String? = nil, body: String? = nil, relation: String? = nil,
    x: Double? = nil, y: Double? = nil, requires: [String] = []
  ) {
    self.id = id
    self.action = action
    self.target = target
    self.reason = reason
    self.peer = peer
    self.region = region
    self.body = body
    self.relation = relation
    self.x = x
    self.y = y
    self.requires = requires
  }
}
public struct OrganizationLink: Identifiable, Codable, Equatable, Sendable {
  public let id, from, to, label, reason: String
  public let directed, history: Bool
}
public struct OrganizationScope: Codable, Equatable, Sendable {
  public static let maxPlacements = 64, maxRegions = 16
  public internal(set) var objects: [OrganizationObject]
  public let regions: [OrganizationRegion]
  public let links: [OrganizationLink]
  public let allowed: [OrganizationAction]
  public internal(set) var readOnlyPlacements: [String]?
  public func canEdit(_ object: OrganizationObject, action: OrganizationAction) -> Bool {
    guard let readOnlyPlacements else { return true }
    guard !readOnlyPlacements.contains(object.id) else { return false }
    switch action {
    case .move, .removeEntrance: return true
    case .rewrite, .relate, .addEntrance:
      return !objects.contains { $0.target == object.target && readOnlyPlacements.contains($0.id) }
    }
  }
  public let policy: Int
  public internal(set) var cameraX, cameraY, zoom: Double
  public internal(set) var entranceDescriptions: [String: String]?
  public internal(set) var presentationSizes: [String: CGSize]?
}
public struct OrganizationPlan: Identifiable, Sendable {
  public let id, status, summary: String
  public let scope: OrganizationScope
  public let edits: [OrganizationEdit]
  public let assessment: OrganizationAssessment?
}
func organizationError(_ s: String) -> AtlasStoreError { .invalid(s) }
func organizationDecode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(text.utf8))
}
func orgStamp() -> String {
  Date.now.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
}
let organizationTag = "图谱整理 · "
extension AtlasStore {
  // Both the range picker and the frozen scope must resolve the same entrance-specific version.
  private static let organizationSources = """
      FROM placement p
      LEFT JOIN content_node n ON n.id=p.content_id AND n.deleted_at IS NULL LEFT JOIN content_version v ON v.id=n.current_version_id
      LEFT JOIN document d ON d.id=p.document_id AND d.deleted_at IS NULL
      LEFT JOIN workspace_settings md ON d.kind='markdown' AND md.key='view.map.writing.'||p.id
      LEFT JOIN workspace_settings pdf ON d.kind='pdf' AND pdf.key='view.map.pdf-versions'
      LEFT JOIN workspace_settings legacy ON d.kind='pdf' AND pdf.key IS NULL AND legacy.key='view.map.source-highlights'
      LEFT JOIN document_version dv ON dv.document_id=d.id AND dv.id=coalesce(
        json_extract(p.reader_state_json,'$.pdf_page.version'), json_extract(md.value_json,'$.pinnedVersion'),
        (SELECT value FROM json_each(pdf.value_json) WHERE key=p.id),
        (SELECT json_extract(value,'$.versionID') FROM json_each(legacy.value_json) WHERE key=p.id),
        d.current_version_id)
      LEFT JOIN inquiry_turn t ON t.id=p.turn_id LEFT JOIN content_node q ON q.id=t.question_node_id
      LEFT JOIN content_version qv ON qv.id=t.question_version_id LEFT JOIN content_node a ON a.id=t.answer_node_id
      LEFT JOIN workspace_settings shown ON t.id IS NOT NULL AND shown.key='view.map.shown-runs'
      LEFT JOIN generation_run g ON g.turn_id=t.id AND g.id=coalesce(
        (SELECT value FROM json_each(?) WHERE key=p.id),
        (SELECT value FROM json_each(shown.value_json) WHERE key=p.id))
      LEFT JOIN content_version av ON av.id=CASE WHEN g.id IS NULL THEN a.current_version_id ELSE g.answer_version_id END
      """
  func organizationObject(_ db: Database, _ id: String, displayedRunID: String? = nil) throws -> OrganizationObject? {
    // A turn points to the actual answer version when present; unanswered questions retain their question version.
    guard
      let r = try Row.fetchOne(
        db,
        sql: """
          SELECT p.*,json_extract(p.reader_state_json,'$.pdf_page.index') AS pdf_index,g.id AS shown_run,coalesce(p.turn_id,p.document_id,p.content_id) target,
            coalesce(d.title,n.title,nullif(q.title,''),qv.plain_text,'') title,
            coalesce(dv.plain_text,dv.markdown_text,v.plain_text,av.plain_text,qv.plain_text,'') body,
            coalesce(dv.id,v.id,av.id,qv.id,'') version,
            d.kind document_kind,n.kind node_kind,coalesce(n.content_revision,d.revision,a.content_revision,1) content_rev
          \(Self.organizationSources)
          WHERE p.id=? AND p.view_id='atlas' AND (t.id IS NOT NULL OR n.id IS NOT NULL OR d.id IS NOT NULL)
          """, arguments: [try chatJSON(displayedRunID.map { [id: $0] } ?? [:]), id])
    else { return nil }
    if let displayedRunID, r["shown_run"] as String? != displayedRunID {
      throw organizationError("入口当前查看的回答记录已不可用。")
    }
    return OrganizationObject(
      id: id, kind: r["target_kind"], target: r["target"], title: r["title"], body: r["body"],
      version: r["version"], nodeKind: r["node_kind"], region: r["parent_region_id"], x: r["x"],
      y: r["y"], width: r["width"], height: r["height"], layoutRevision: r["layout_revision"],
      contentRevision: r["content_rev"], display: r["display_mode"], reader: r["reader_state_json"],
      displayedRunID: displayedRunID, documentKind: r["document_kind"], pdfPageIndex: r["pdf_index"])
  }
  public func organizationScope(
    placements: Set<String>, regions: Set<String> = [], allowed: [OrganizationAction],
    displayedRuns: [String: String] = [:], readOnlyPlacements: Set<String> = []
  ) throws -> OrganizationScope {
    guard !placements.isEmpty, placements.count <= OrganizationScope.maxPlacements, regions.count <= OrganizationScope.maxRegions else {
      throw organizationError("请明确选择 1 至 64 个入口及至多 16 个地域。")
    }
    guard readOnlyPlacements.isSubset(of: placements) else { throw organizationError("只读材料超出所选入口。") }
    return try database.read { db in
      let objects = try placements.sorted().map { id -> OrganizationObject in
        guard let o = try organizationObject(db, id, displayedRunID: displayedRuns[id]) else { throw organizationError("入口已移除：" + id) }
        return o
      }
      let areas = try regions.sorted().map { id -> OrganizationRegion in
        guard let row = try Row.fetchOne(db, sql: Self.organizationAreas + " AND r.id=?", arguments: [id])
        else { throw organizationError("找不到选定地域。") }
        return Self.organizationRegion(row)
      }
      guard
        let view = try Row.fetchOne(
          db, sql: "SELECT camera_x,camera_y,zoom FROM canvas_view WHERE id='atlas'"),
        let policy = try Int.fetchOne(
          db, sql: "SELECT policy_revision FROM workspace WHERE singleton=1")
      else { throw organizationError("请先打开图谱。") }
      struct ViewCamera: Decodable { let x, y, zoom: Double }
      let saved = try String.fetchOne(
        db, sql: "SELECT value_json FROM workspace_settings WHERE key='view.map.camera'"
      ).flatMap { try? organizationDecode(ViewCamera.self, $0) }
      return OrganizationScope(
        objects: objects, regions: areas, links: try organizationLinks(db, objects),
        allowed: Array(Set(allowed)).sorted { $0.rawValue < $1.rawValue }, readOnlyPlacements: readOnlyPlacements.isEmpty ? nil : readOnlyPlacements.sorted(), policy: policy,
        cameraX: saved?.x ?? view["camera_x"], cameraY: saved?.y ?? view["camera_y"],
        zoom: saved?.zoom ?? view["zoom"])
    }
  }

  private func organizationLinks(_ db: Database, _ objects: [OrganizationObject]) throws
    -> [OrganizationLink]
  {
    let versions = objects.map(\.version).filter { !$0.isEmpty }
    guard !versions.isEmpty else { return [] }
    let list = versions.map { _ in "?" }.joined(separator: ",")
    var links: [OrganizationLink] = []
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT r.id,v.relation_type,v.direction,v.explanation,
          coalesce(a.content_version_id,a.document_version_id) AS lhs,
          coalesce(b.content_version_id,b.document_version_id) AS rhs,
          json_extract(w.value_json,'$.lhs') AS from_entrance, json_extract(w.value_json,'$.rhs') AS to_entrance
        FROM semantic_relation r JOIN relation_version v ON v.id=r.current_version_id
        JOIN reference_snapshot a ON a.id=v.from_reference_id JOIN reference_snapshot b ON b.id=v.to_reference_id
        LEFT JOIN workspace_settings w ON w.key='view.map.relation-pair.'||r.id
        WHERE r.deleted_at IS NULL AND coalesce(a.content_version_id,a.document_version_id) IN (\(list))
          AND coalesce(b.content_version_id,b.document_version_id) IN (\(list)) ORDER BY r.rowid
        """,
      arguments: StatementArguments(versions + versions))
    func endpoint(version: String, preferred: String?) -> OrganizationObject? {
      objects.first { $0.version == version && (preferred == nil || $0.id == preferred) }
    }
    for row in rows {
      guard let a = endpoint(version: row["lhs"], preferred: row["from_entrance"]),
            let b = endpoint(version: row["rhs"], preferred: row["to_entrance"]) else { continue }
      links.append(
        .init(
          id: row["id"], from: a.id, to: b.id,
          label: MapRelation(rawValue: row["relation_type"])?.label ?? "关系",
          reason: row["explanation"], directed: (row["direction"] as String) == "directed",
          history: false))
    }
    for child in objects where child.kind == "turn" {
      if let parent = try String.fetchOne(
        db,
        sql:
          "SELECT g.turn_id FROM inquiry_reference i JOIN source_anchor a ON a.reference_id=i.reference_id JOIN generation_run g ON g.id=json_extract(a.geometry_json,'$.parentRunID') WHERE i.turn_id=? AND i.role='actual_trigger' LIMIT 1",
        arguments: [child.target]),
        let p = objects.first(where: { $0.kind == "turn" && $0.target == parent })
      {
        links.append(
          .init(
            id: "history." + child.id, from: p.id, to: child.id, label: "追问", reason: "由当时选取的回答继续",
            directed: true, history: true))
      }
    }
    return links
  }
  public func previewOrganization(
    _ scope: OrganizationScope, edits: [OrganizationEdit], title: String,
    requestID: String = UUID().uuidString, actor: String = "user",
    assessment: OrganizationAssessment? = nil
  ) throws -> OrganizationPlan {
    guard ["user", "ai"].contains(actor),
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw organizationError("需要提案来源与名称。") }
    try verifyOrganization(scope, edits)
    return try database.write { db in
      let digest = chatDigest([
        try chatJSON(scope), try chatJSON(edits), title, actor, try chatJSON(assessment),
      ])
      if let receipt = try Row.fetchOne(
        db, sql: "SELECT payload_sha256,result_json FROM command_receipt WHERE request_id=?",
        arguments: [requestID])
      {
        guard (receipt["payload_sha256"] as String) == digest else {
          throw organizationError("同一请求标识已对应其他修改。")
        }
        return try loadOrganization(db, organizationDecode(String.self, receipt["result_json"]))
      }
      let id = UUID().uuidString
      try recordOrganization(db, id: id, scope: scope, edits: edits, title: title, actor: actor)
      try db.execute(
        sql: "INSERT INTO command_receipt VALUES (?,'organization.preview',?,?,?)",
        arguments: [requestID, digest, try chatJSON(id), orgStamp()])
      if let assessment {
        try db.execute(
          sql: "INSERT INTO command_receipt VALUES (?,'organization.model-evidence',?,?,?)",
          arguments: ["organization.evidence." + id, digest, try chatJSON(assessment), orgStamp()])
      }
      return try loadOrganization(db, id)
    }
  }
  /// Manual changes to a proposal produce a new auditable batch; both the version and scope stay frozen.
  public func reviseOrganization(_ id: String, edits: [OrganizationEdit]) throws -> OrganizationPlan
  {
    try database.write { db in
      let p = try loadOrganization(db, id)
      guard p.status == "reviewable" else { throw organizationError("只能调整待决定的提案。") }
      try verifyOrganization(p.scope, edits)
      let next = UUID().uuidString
      try recordOrganization(
        db, id: next, scope: p.scope, edits: edits, title: p.summary + "（修订）", actor: "user")
      try db.execute(sql: "UPDATE change_batch SET status='cancelled' WHERE id=?", arguments: [id])
      return try loadOrganization(db, next)
    }
  }
  public func organizationPlans() throws -> [OrganizationPlan] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql:
          "SELECT id FROM change_batch WHERE substr(summary,1,length(?))=? AND rollback_of_batch_id IS NULL ORDER BY rowid DESC",
        arguments: [organizationTag, organizationTag]
      ).map { try loadOrganization(db, $0) }
    }
  }
  public func abandonOrganization(_ id: String) throws {
    try database.write { db in
      let p = try loadOrganization(db, id)
      guard ["reviewable", "stale"].contains(p.status) else { throw organizationError("当前状态无法放弃。") }
      try db.execute(sql: "UPDATE change_batch SET status='cancelled' WHERE id=?", arguments: [id])
    }
  }
  func verifyOrganization(_ scope: OrganizationScope, _ edits: [OrganizationEdit]) throws {
    guard !edits.isEmpty, edits.count <= 64 else { throw organizationError("请选择 1 至 64 项修改。") }
    var seen = Set<String>()
    var facets = Set<String>()
    guard Set(scope.objects.map(\.id)).count == scope.objects.count else {
      throw organizationError("选定范围含重复入口。")
    }
    let objects = Dictionary(uniqueKeysWithValues: scope.objects.map { ($0.id, $0) })
    for e in edits {
      guard !e.id.isEmpty, !seen.contains(e.id), Set(e.requires).isSubset(of: seen),
        let s = objects[e.target], scope.allowed.contains(e.action), scope.canEdit(s, action: e.action),
        !e.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw organizationError("修改越界、缺少依据、授权或前置项目。") }
      var facet = e.target + ":" + e.action.facet
      switch e.action {
      case .move:
        guard let x = e.x, let y = e.y, x.isFinite, y.isFinite, abs(x) < 1e9, abs(y) < 1e9,
          x != s.x || y != s.y
        else { throw organizationError("移动需要有效的新位置。") }
      case .rewrite:
        guard s.mayRewrite, let t = e.body,
          !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, t != s.body,
          t.utf8.count <= 262_144
        else { throw organizationError("仅能修订已选解释或笔记，须保留原始版本。") }
        facet = s.target + ":content"
      case .relate:
        guard let peer = e.peer, let p = objects[peer], scope.canEdit(p, action: .relate), p.target != s.target, !s.version.isEmpty,
          !p.version.isEmpty, let rel = e.relation, MapRelation(rawValue: rel) != nil
        else { throw organizationError("关系需选定范围内两个不同版本、类型和说明。") }
        facet += ":" + peer + ":" + (e.relation ?? "")
      case .addEntrance:
        guard (e.x ?? s.x + 288).isFinite, (e.y ?? s.y + 144).isFinite, abs(e.x ?? s.x + 288) < 1e9,
          abs(e.y ?? s.y + 144) < 1e9
        else { throw organizationError("主题入口位置无效。") }
        guard let r = e.region, scope.regions.contains(where: { $0.id == r }) else {
          throw organizationError("新入口必须在已选主题中。")
        }
        facet = s.target + ":membership:" + (e.region ?? "")
      case .removeEntrance: break
      }
      guard facets.insert(facet).inserted else { throw organizationError("同一对象的同一项修改出现多次。") }
      seen.insert(e.id)
    }
  }
  func recordOrganization(
    _ db: Database, id: String, scope: OrganizationScope, edits: [OrganizationEdit], title: String,
    actor: String
  ) throws {
    try db.execute(
      sql:
        "INSERT INTO change_batch(id,status,actor_kind,read_scope_json,write_scope_json,base_revisions_json,policy_revision_at_plan,summary,created_at) VALUES (?,'reviewable',?,?,?,?,?,?,?)",
      arguments: [
        id, actor, try chatJSON(scope), try chatJSON(scope.allowed),
        try chatJSON(
          Dictionary(
            uniqueKeysWithValues: scope.objects.map {
              ($0.id, [$0.layoutRevision, $0.contentRevision])
            })), scope.policy, organizationTag + title, orgStamp(),
      ])
    for (index, e) in edits.enumerated() {
      let s = scope.objects.first { $0.id == e.target }!
      try db.execute(
        sql:
          "INSERT INTO change_operation(id,batch_id,ordinal,operation_type,target_kind,target_id,facet,expected_revision,before_json,after_json,dependencies_json) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        arguments: [
          chatID([id, e.id]), id, index, e.action.rawValue, s.kind, s.target, e.action.facet,
          e.action == .rewrite ? s.contentRevision : s.layoutRevision, try chatJSON(s),
          try chatJSON(e), try chatJSON(e.requires),
        ])
    }
  }
  func loadOrganization(_ db: Database, _ id: String) throws -> OrganizationPlan {
    guard
      let r = try Row.fetchOne(
        db,
        sql:
          "SELECT summary,status,read_scope_json FROM change_batch WHERE id=? AND rollback_of_batch_id IS NULL",
        arguments: [id]), (r["summary"] as String).hasPrefix(organizationTag)
    else { throw organizationError("整理提案不存在。") }
    let evidence = try String.fetchOne(
      db, sql: "SELECT result_json FROM command_receipt WHERE request_id=?",
      arguments: ["organization.evidence." + id]
    ).map { try organizationDecode(OrganizationAssessment.self, $0) }
    return OrganizationPlan(
      id: id, status: r["status"],
      summary: String((r["summary"] as String).dropFirst(organizationTag.count)),
      scope: try organizationDecode(OrganizationScope.self, r["read_scope_json"]),
      edits: try String.fetchAll(
        db, sql: "SELECT after_json FROM change_operation WHERE batch_id=? ORDER BY ordinal",
        arguments: [id]
      ).map { try organizationDecode(OrganizationEdit.self, $0) }, assessment: evidence)
  }
}

extension AtlasStore {
  public struct OrganizationChoice: Identifiable, Sendable {
    public let id, title, kind: String
    public let regionID: String?
    public let materialKind, targetID: String
    public let versionID: String?
    public let versionOrdinal: Int?
    public var physicalPageIndex: Int? = nil
  }
  private static let organizationAreas = """
    SELECT r.*,coalesce(json_extract(s.value_json,'$'),t.title) AS title
    FROM region r JOIN topic t ON t.id=r.topic_id
    LEFT JOIN workspace_settings s ON s.key='region.title.'||r.id
    WHERE r.view_id='atlas' AND t.deleted_at IS NULL
    """
  private static func organizationRegion(_ row: Row) -> OrganizationRegion {
    .init(id: row["id"], topic: row["topic_id"], title: row["title"], revision: row["revision"],
          x: row["x"], y: row["y"], width: row["width"], height: row["height"])
  }
  public func organizationRegions() throws -> [OrganizationRegion] {
    try database.read { db in
      try Row.fetchAll(db, sql: Self.organizationAreas + " ORDER BY title,r.id").map(Self.organizationRegion)
    }
  }
  public func organizationChoices(displayedRuns: [String: String] = [:]) throws -> [OrganizationChoice] {
    // Opening the range picker reads titles only. Full texts are loaded after explicit selection.
    _ = try atlasMap()
    return try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT p.id,p.parent_region_id,p.target_kind,json_extract(p.reader_state_json,'$.pdf_page.index') AS page_index,coalesce(n.title,d.title,nullif(q.title,''),qv.plain_text,'') title,
            coalesce(dv.ordinal,v.ordinal,av.ordinal,qv.ordinal) AS version_ordinal,
            coalesce(d.kind,n.kind,p.target_kind) AS material_kind, coalesce(dv.id,v.id,av.id,qv.id) AS version_id,
            coalesce(p.document_id,p.turn_id,p.content_id) AS target_id
          \(Self.organizationSources)
          WHERE p.view_id='atlas' AND (t.id IS NOT NULL OR n.id IS NOT NULL OR d.id IS NOT NULL)
          ORDER BY p.y,p.x,p.id
          """, arguments: [try chatJSON(displayedRuns)]
      ).map {
        .init(id: $0["id"], title: $0["title"], kind: $0["target_kind"], regionID: $0["parent_region_id"],
              materialKind: $0["material_kind"], targetID: $0["target_id"], versionID: $0["version_id"], versionOrdinal: $0["version_ordinal"], physicalPageIndex: $0["page_index"])
      }
    }
  }
}
