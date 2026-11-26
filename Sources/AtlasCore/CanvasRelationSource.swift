import Foundation
import GRDB

public enum MapRelationMaterial {
  case answer(AtlasRun)
  case writing(id: String, version: String)
  case pdf(AtlasPDF, selection: PDFAnchor?)
  case markdown(documentID: String, versionID: String, selection: [WritingSelection])

  var objectID: String {
    switch self {
    case .answer(let run): return run.turnID
    case .writing(let id, _): return id
    case .pdf(let file, _): return file.id
    case .markdown(let id, _, _): return id
    }
  }

  func freeze(in db: Database) throws -> String {
    let version: String, documentKind: String
    switch self {
    case .writing(let node, let version):
      guard let body = try String.fetchOne(db, sql: """
        SELECT v.plain_text FROM content_version v JOIN content_node n ON v.node_id=n.id
        WHERE n.id=? AND v.id=? AND n.kind IN ('question','idea') AND n.deleted_at IS NULL
        """, arguments: [node, version]) else { throw AtlasStoreError.invalid("该问题或灵感的版本不可用。") }
      let ref = writingID()
      try db.execute(sql: "INSERT INTO reference_snapshot(id,source_kind,content_version_id,quote_snapshot,created_at) VALUES (?,'content',?,?,?)",
                     arguments: [ref,version,body,writingDate()])
      return ref
    case .answer(let run):
      guard let id = run.versionID, let body = try String.fetchOne(db, sql: """
        SELECT v.body_markdown FROM generation_run g JOIN content_version v ON v.id=g.answer_version_id
        WHERE g.id=? AND g.turn_id=? AND v.id=?
        """, arguments: [run.id, run.turnID, id]) else {
        throw AtlasStoreError.invalid("回答需要先生成并保存一个版本。")
      }
      let ref = UUID().uuidString
      try db.execute(sql: """
        INSERT INTO reference_snapshot(id,source_kind,content_version_id,quote_snapshot,created_at)
        VALUES (?,'content',?,?,?)
        """, arguments: [ref, id, body, Date.now.ISO8601Format()])
      return ref
    case .pdf(let file, _):
      version = file.versionID
      documentKind = "pdf"
    case .markdown(_, let id, _):
      version = id
      documentKind = "markdown"
    }
    let info = try AtlasStore.relationDocumentInfo(db, documentID: objectID, versionID: version, kind: documentKind)
    switch self {
    case .pdf(_, let anchor?):
      guard anchor.versionID == version else { throw AtlasStoreError.invalid("PDF 选区来自另一版本。") }
      return try AtlasStore.freezePDF(db, anchor: anchor)
    case .markdown(_, _, let selection) where !selection.isEmpty:
      return try AtlasStore.insertMarkdownReference(db, versionID: version, selection: selection)
    default: break
    }
    // The title identifies the document. An object-level link grants no passage to the model.
    let ref = UUID().uuidString
    try db.execute(sql: """
      INSERT INTO reference_snapshot(id,source_kind,document_version_id,created_at) VALUES (?,'document',?,?)
      """, arguments: [ref, version, Date.now.ISO8601Format()])
    try db.execute(sql: """
      INSERT INTO source_anchor(id,reference_id,segment_order,selector_type,geometry_json)
      VALUES (?,?,0,'whole',json_object('origin','relation_document','title',?))
      """, arguments: [UUID().uuidString, ref, info.title])
    return ref
  }
}

/// Both endpoint references belong to the immutable relation version, even after removal from the map.
public struct CanvasRelationSource: Identifiable, Sendable {
  public struct Endpoint: Identifiable, Sendable {
    public let id, versionID, quote: String
    public let ordinal: Int?
    public let title: String?
    public let documentKind, selector: String?
  }
  public let id, relationID, explanation, epistemicKind, actorKind: String
  public let ordinal: Int
  public let kind: MapRelation
  public let directed: Bool
  public let from, to: Endpoint
  public var title: String { kind.label + " · 版本 " + String(ordinal) }
}

extension AtlasStore {
  public func referenceWriting(_ item: WritingItem) throws -> String {
    guard let version = item.currentVersionID, item.draft == nil, item.kind != .markdown else {
      throw AtlasStoreError.invalid("请先保存问题或灵感的当前版本。")
    }
    return try database.write { db in try MapRelationMaterial.writing(id: item.id, version: version).freeze(in: db) }
  }

  static func relationDocumentInfo(_ db: Database, documentID: String, versionID: String, kind: String) throws
    -> (title: String, ordinal: Int)
  {
    guard let row = try Row.fetchOne(db, sql: """
      SELECT v.ordinal, CASE WHEN d.kind='pdf' THEN
        coalesce(json_extract(v.source_metadata_json,'$.document_title'),d.title)
        ELSE (SELECT substr(plain_text,1,60) FROM document_block WHERE document_version_id=v.id
          AND block_kind='heading' ORDER BY ordinal LIMIT 1) END AS title
      FROM document_version v JOIN document d ON d.id=v.document_id
      WHERE v.id=? AND d.id=? AND d.kind=? AND d.deleted_at IS NULL
      """, arguments: [versionID, documentID, kind]) else {
      throw AtlasStoreError.invalid("这份材料的指定版本已不可用。")
    }
    let title: String = row["title"] ?? ""
    return (title.isEmpty ? (kind == "markdown" ? "未命名 Markdown" : "PDF") : title, row["ordinal"])
  }

  public func markdownRelationInfo(documentID: String, versionID: String) throws -> (title: String, ordinal: Int) {
    try database.read { try Self.relationDocumentInfo($0, documentID: documentID, versionID: versionID, kind: "markdown") }
  }

  private static func relationEndpoint(_ db: Database, _ id: String) throws
    -> CanvasRelationSource.Endpoint
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT s.quote_snapshot, COALESCE(s.content_version_id,s.document_version_id,s.message_version_id,
            s.relation_version_id,s.annotation_version_id) AS version, COALESCE(c.ordinal,d.ordinal) AS ordinal,
            COALESCE(NULLIF(q.plain_text,''),json_extract(a.geometry_json,'$.title'),json_extract(d.source_metadata_json,'$.document_title'),CASE WHEN doc.kind='pdf' THEN doc.title END,
              (SELECT substr(plain_text,1,60) FROM document_block WHERE document_version_id=d.id ORDER BY ordinal LIMIT 1)) AS title,
            doc.kind AS document_kind, a.selector_type, json_extract(a.geometry_json,'$.origin') AS origin,
            a.page_index
          FROM reference_snapshot s LEFT JOIN content_version c ON c.id=s.content_version_id
          LEFT JOIN document_version d ON d.id=s.document_version_id
          LEFT JOIN document doc ON doc.id=d.document_id
          LEFT JOIN generation_run g ON g.answer_version_id=s.content_version_id
          LEFT JOIN inquiry_turn t ON t.id=g.turn_id LEFT JOIN content_version q ON q.id=t.question_version_id
          LEFT JOIN source_anchor a ON a.reference_id=s.id AND a.segment_order=0 WHERE s.id=?
          """, arguments: [id])
    else { throw AtlasStoreError.invalid("找不到当时的端点依据。") }
    let quote: String
    if let text: String = row["quote_snapshot"], !text.isEmpty {
      quote = text
    } else if row["origin"] as String? == "relation_document" {
      quote = "关联整份文档，仅引用题名与版本。"
    } else if let page: Int = row["page_index"] {
      quote = "第 " + String(page + 1) + " 页（页码引用）"
    } else {
      throw AtlasStoreError.invalid("端点引用缺少可读的快照。")
    }
    return .init(
      id: id, versionID: row["version"], quote: quote, ordinal: row["ordinal"], title: row["title"], documentKind: row["document_kind"], selector: row["selector_type"])
  }

  static func canvasRelation(_ db: Database, version: String) throws -> CanvasRelationSource {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM relation_version WHERE id=?", arguments: [version]),
      let kind = MapRelation(rawValue: row["relation_type"])
    else { throw AtlasStoreError.invalid("找不到此版本的关系。") }
    return try .init(
      id: version, relationID: row["relation_id"], explanation: row["explanation"],
      epistemicKind: row["epistemic_kind"], actorKind: row["actor_kind"],
      ordinal: row["ordinal"], kind: kind, directed: (row["direction"] as String) == "directed",
      from: relationEndpoint(db, row["from_reference_id"]),
      to: relationEndpoint(db, row["to_reference_id"]))
  }

  static func freezeCanvasRelation(_ db: Database, version: String) throws -> String {
    let source = try canvasRelation(db, version: version)
    let id = UUID().uuidString.lowercased()
    try db.execute(
      sql: """
        INSERT INTO reference_snapshot(id,source_kind,relation_version_id,quote_snapshot,created_at)
        VALUES (?,'relation',?,?,?)
        """,
      arguments: [id, version, source.title + " · " + source.explanation, Date.now.ISO8601Format()])
    try db.execute(
      sql: """
        INSERT INTO source_anchor(id,reference_id,segment_order,selector_type,geometry_json)
        VALUES (?,?,0,'whole',json_object('origin','canvas_relation'))
        """, arguments: [UUID().uuidString, id])
    return id
  }

  public func canvasRelationSource(version: String) throws -> CanvasRelationSource {
    try database.read { try Self.canvasRelation($0, version: version) }
  }

  /// Resolve the current layout separately from the historical evidence. A removed explicit
  /// entrance stays missing even when the same document has another placement.
  public func relationEntrances(_ source: CanvasRelationSource) throws -> [String: String] {
    try database.read { db in
      let rows = try Row.fetchAll(db, sql: """
        WITH RECURSIVE hidden(id) AS (
          SELECT id FROM region WHERE view_id='atlas' AND collapsed=1
          UNION SELECT r.id FROM region r JOIN hidden h ON r.parent_region_id=h.id WHERE r.view_id='atlas'
        ), sides(ref,preferred) AS (
          SELECT v.from_reference_id,json_extract(w.value_json,'$.lhs')
          FROM relation_version v LEFT JOIN workspace_settings w ON w.key='view.map.relation-pair.'||v.relation_id WHERE v.id=?
          UNION ALL SELECT v.to_reference_id,json_extract(w.value_json,'$.rhs')
          FROM relation_version v LEFT JOIN workspace_settings w ON w.key='view.map.relation-pair.'||v.relation_id WHERE v.id=?
        )
        SELECT sides.ref,(SELECT p.id FROM placement p WHERE p.view_id='atlas'
          AND (sides.preferred IS NULL OR p.id=sides.preferred)
          AND coalesce(p.turn_id,p.content_id,p.document_id)=coalesce(g.turn_id,c.node_id,d.document_id)
          ORDER BY EXISTS(SELECT 1 FROM hidden h WHERE h.id=p.parent_region_id), p.rowid LIMIT 1) AS entrance
        FROM sides JOIN reference_snapshot s ON s.id=sides.ref
        LEFT JOIN content_version c ON c.id=s.content_version_id
        LEFT JOIN generation_run g ON g.answer_version_id=c.id
        LEFT JOIN document_version d ON d.id=s.document_version_id
        LEFT JOIN document doc ON doc.id=d.document_id LEFT JOIN content_node n ON n.id=c.node_id
        LEFT JOIN inquiry_turn t ON t.id=g.turn_id LEFT JOIN content_node q ON q.id=t.question_node_id
        WHERE doc.deleted_at IS NULL AND n.deleted_at IS NULL AND q.deleted_at IS NULL
        """, arguments: [source.id, source.id])
      var locations = [String: String]()
      for row in rows { locations[row["ref"]] = row["entrance"] as String? }
      return locations
    }
  }

  public func canvasRelationSource(reference: String) throws -> CanvasRelationSource? {
    try database.read { db in
      guard
        let version = try String.fetchOne(
          db,
          sql: """
            SELECT s.relation_version_id FROM reference_snapshot s JOIN source_anchor a ON a.reference_id=s.id
            WHERE s.id=? AND a.segment_order=0 AND json_extract(a.geometry_json,'$.origin')='canvas_relation'
            """, arguments: [reference])
      else { return nil }
      return try Self.canvasRelation(db, version: version)
    }
  }

  public func reviseMapRelation(_ edge: MapEdge, kind: MapRelation, explanation: String) throws {
    let note = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let old = edge.relationVersion else {
      throw AtlasStoreError.invalid("这条关系没有可修改的版本。")
    }
    try database.write { db in
      let next = UUID().uuidString.lowercased()
      try db.execute(
        sql: """
          INSERT INTO relation_version(id,relation_id,ordinal,from_reference_id,to_reference_id,relation_type,
            direction,epistemic_kind,explanation,actor_kind,created_at)
          SELECT ?,v.relation_id,(SELECT MAX(ordinal)+1 FROM relation_version WHERE relation_id=v.relation_id),v.from_reference_id,v.to_reference_id,?,?,
            CASE WHEN v.relation_type=? THEN v.epistemic_kind WHEN ?='related_to' THEN 'exploratory' ELSE 'synthesis' END,
            ?,'user',? FROM semantic_relation r JOIN relation_version v ON v.id=r.current_version_id
          WHERE r.id=? AND v.id=? AND r.deleted_at IS NULL
          """,
        arguments: [
          next, kind.rawValue, kind.directed ? "directed" : "undirected", kind.rawValue,
          kind.rawValue,
          note, Date.now.ISO8601Format(), edge.id, old,
        ])
      guard db.changesCount == 1 else { throw AtlasStoreError.invalid("关系已改变，请重新打开再修改。") }
      try db.execute(
        sql: """
          INSERT INTO relation_evidence SELECT ?, reference_id,evidence_role FROM relation_evidence WHERE relation_version_id=?
          """, arguments: [next, old])
      try Self.changeRelationHead(db, id: edge.id, from: old, to: next, title: "修改知识关系")
    }
  }

  public func removeMapRelation(_ edge: MapEdge) throws {
    guard let version = edge.relationVersion else { throw AtlasStoreError.invalid("只能移除知识关系。") }
    try database.write { db in
      try Self.changeRelationHead(db, id: edge.id, from: version, to: version,
                                  archived: Date.now.ISO8601Format(), title: "移除知识关系")
    }
  }
}
