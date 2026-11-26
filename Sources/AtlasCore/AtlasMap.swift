import Foundation
import GRDB
import PDFKit

public struct CanvasPDFPage: Codable, Equatable, Sendable {
  public let version: String
  public let index: Int
  public let label: String
  public let width, height: CGFloat
  // Older saved page entrances have the pinned version and display size only.
  public var cropBox: CGRect?
  public var rotation: Int?
  public var sourceSHA256: String?
  public static let header: CGFloat = 36
  public var caption: String {
    let number = String(index + 1)
    return label.isEmpty || label == number ? "第 " + number + " 页" : "第 " + number + " 张 · 页码 " + label
  }
}

public enum AtlasRelativePosition: String, Codable, Sendable, CaseIterable {
  case above, below, left, right
  public var label: String {
    switch self { case .above: "上方"; case .below: "下方"; case .left: "左侧"; case .right: "右侧" }
  }
}

public struct MapEntry: Codable, Identifiable, Equatable, Sendable {
  public let id, kind, target: String
  public var topic: String?
  public var x, y: Double
  public var readingWidth: Double? = nil
  public var readingHeight: Double? = nil
  public var page: CanvasPDFPage? = nil
  public var expanded: Bool
}
public struct CanvasReference: Codable, Sendable {
  public let entry: MapEntry
  public let pin: String?
  public init(entry: MapEntry, pin: String?) { self.entry = entry; self.pin = pin }
}

public struct MapEdge: Identifiable, Sendable {
  public let id, from, to, label, explanation: String
  public var relationVersion: String? = nil
  public var fromVersion: String? = nil
  public var toVersion: String? = nil
  public var evidence: [String] = []
  final class EntrancePair: Sendable {
    let from, to: MapEntry?
    init(from: MapEntry?, to: MapEntry?) { self.from = from; self.to = to }
  }
  var pinnedEntrances: EntrancePair? = nil
  public var fromEntrance: MapEntry? { pinnedEntrances?.from }
  public var toEntrance: MapEntry? { pinnedEntrances?.to }
  public func resolvedEntrances(defaults: [String: MapEntry]) -> (from: MapEntry?, to: MapEntry?) {
    if let pinnedEntrances { return (pinnedEntrances.from, pinnedEntrances.to) }
    return (defaults[from], defaults[to])
  }
  public func entrances(defaults: [String: MapEntry]) -> (MapEntry, MapEntry)? {
    let pair = resolvedEntrances(defaults: defaults)
    guard let left = pair.from, let right = pair.to else { return nil }
    return (left, right)
  }
  public let directed, history: Bool
}
public struct MapTopic: Identifiable { public let id, title: String }
public struct AtlasMap {
  public let entries: [MapEntry]
  public let edges: [MapEdge]
  public let topics: [MapTopic]
}
public enum MapRelation: String, CaseIterable, Identifiable, Sendable {
  case compares, depends_on, related_to, supports, critiques, analogous_to, reinterprets
  public var id: Self { self }
  public var directed: Bool { ![Self.compares, .related_to, .analogous_to].contains(self) }
  public var label: String {
    switch self {
    case .compares: "比较"
    case .depends_on: "依赖"
    case .related_to: "弱关联"
    case .supports: "支持"
    case .critiques: "质疑"
    case .analogous_to: "类比"
    case .reinterprets: "重新解释"
    }
  }
}
private func encoded<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

extension AtlasStore {
  static func mapEntries(_ db: Database) throws -> [MapEntry] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT id,target_kind,coalesce(turn_id,document_id,content_id) AS target,
        parent_region_id,x,y,CASE WHEN json_type(reader_state_json,'$.pdf_page')='object' THEN width ELSE NULLIF(width,248) END AS rw,
        CASE WHEN json_type(reader_state_json,'$.pdf_page')='object' THEN height ELSE NULLIF(height,116) END AS rh,json_extract(reader_state_json,'$.pdf_page') AS pdf_page,display_mode FROM placement p WHERE view_id='atlas'
        AND (p.document_id IS NULL OR EXISTS(SELECT 1 FROM document d WHERE d.id=p.document_id AND d.deleted_at IS NULL))
        AND (p.content_id IS NULL OR EXISTS(SELECT 1 FROM content_node n WHERE n.id=p.content_id AND n.deleted_at IS NULL))
        AND (p.turn_id IS NULL OR EXISTS(SELECT 1 FROM inquiry_turn t JOIN content_node n ON t.question_node_id=n.id WHERE t.id=p.turn_id AND n.deleted_at IS NULL))
        ORDER BY p.rowid
        """
    ).map { r in
      MapEntry(
        id: r["id"], kind: r["target_kind"], target: r["target"], topic: r["parent_region_id"],
        x: r["x"], y: r["y"], readingWidth: r["rw"], readingHeight: r["rh"], page: try (r["pdf_page"] as String?).map { try JSONDecoder().decode(CanvasPDFPage.self, from: Data($0.utf8)) }, expanded: (r["display_mode"] as String) == "reading")
    }
  }

  static func place(_ db: Database, _ e: MapEntry) throws {
    guard e.x.isFinite, e.y.isFinite else { throw AtlasStoreError.invalid("画布位置无效。") }
    try db.execute(
      sql: """
        INSERT INTO placement(id,view_id,target_kind,turn_id,document_id,content_id,parent_region_id,x,y,width,height,display_mode)
        VALUES (?,'atlas',?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET x=excluded.x,y=excluded.y,parent_region_id=excluded.parent_region_id,
        width=excluded.width,height=excluded.height,display_mode=excluded.display_mode,layout_revision=layout_revision+1
        """,
      arguments: [
        e.id, e.kind, e.kind == "turn" ? e.target : nil, e.kind == "document" ? e.target : nil,
        e.kind == "content" ? e.target : nil, e.topic, e.x, e.y, e.readingWidth ?? 248, e.readingHeight ?? 116,
        e.expanded ? "reading" : "overview",
      ])
    if let page = e.page {
      try db.execute(sql: "UPDATE placement SET reader_state_json=json_set(reader_state_json,'$.pdf_page',json(?)) WHERE id=?",
        arguments: [try encoded(page), e.id])
    }
  }

  public func canvasPage(_ file: AtlasPDF, index: Int, at origin: CGPoint) throws -> MapEntry {
    let doc = try readablePDF(file)
    guard index >= 0, index < doc.pageCount, let pg = doc.page(at: index) else {
      throw AtlasStoreError.invalid("页码超出原件范围。")
    }
    let box = pg.bounds(for: .cropBox)
    let sideways = abs(pg.rotation) % 180 == 90
    let width = sideways ? box.height : box.width, height = sideways ? box.width : box.height
    guard width > 0, height > 0 else { throw AtlasStoreError.invalid("无法取得纸页尺寸。") }
    let page = CanvasPDFPage(version: file.versionID, index: index, label: pg.label ?? "", width: width, height: height,
                             cropBox: box, rotation: (pg.rotation % 360 + 360) % 360, sourceSHA256: file.sourceSHA256)
    return MapEntry(id: UUID().uuidString, kind: "document", target: file.id, x: origin.x, y: origin.y,
      readingWidth: width, readingHeight: height + CanvasPDFPage.header, page: page, expanded: true)
  }

  public func putCanvasEntries(_ entries: [MapEntry]) throws {
    try database.write { db in
      try db.execute(sql: "INSERT OR IGNORE INTO canvas_view(id,title) VALUES ('atlas','图谱')")
      for entry in entries {
        if let page = entry.page {
          guard try String.fetchOne(db, sql: "SELECT document_id FROM document_version WHERE id=?", arguments: [page.version]) == entry.target
          else { throw AtlasStoreError.invalid("来源版本与文档不符。") }
        }
      }
      try Self.changeMap(db, changes: entries.map { EntryChange(before: nil, after: $0) }, title: "放到画布")
    }
  }

  public func canvasBook(_ file: AtlasPDF, at point: CGPoint) -> MapEntry {
    MapEntry(id: UUID().uuidString, kind: "document", target: file.id, x: point.x, y: point.y, expanded: true)
  }
  static func seedEntry(
    _ db: Database, id: String, kind: String, target: String, parent: String?, entries: inout [MapEntry]
  ) throws {
    let parentEntry = parent.flatMap { parentID in entries.first { $0.target == parentID } }
    var x = parentEntry.map { $0.x + 310 } ?? 64
    var y = parentEntry?.y ?? 72
    while entries.contains(where: { abs($0.x - x) < 260 && abs($0.y - y) < 138 }) {
      y += 156
      if parentEntry == nil, y > 72 + 156 * 3 {
        x += 310
        y = 72
      }
    }
    let e = MapEntry(
      id: id, kind: kind, target: target, topic: nil, x: x, y: y, expanded: false)
    try recordFirstEntrance(db, e)
    entries.append(e)
  }

  /// Place new canvas materials in the same transaction as their content and initial draft/version.
  static func placeNewMaterial(_ db: Database, kind: String, target: String, at origin: CGPoint) throws {
    try db.execute(sql: "INSERT OR IGNORE INTO canvas_view(id,title) VALUES ('atlas','图谱')")
    let entry = MapEntry(id: "map." + kind + "." + target, kind: kind, target: target,
      topic: nil, x: origin.x, y: origin.y, expanded: true)
    try recordFirstEntrance(db, entry)
  }

  private static func recordFirstEntrance(_ db: Database, _ entry: MapEntry) throws {
    try place(db, entry)
    let key = "map.seed." + entry.id
    try db.execute(
      sql:
        "INSERT INTO workspace_settings(key,value_json,revision,updated_at) VALUES (?,'true',1,?)",
      arguments: [key, Date.now.ISO8601Format()])
  }
  /// Seed each existing object exactly once, including Atlases created before the shared canvas.
  /// Removing an entrance never makes a later open recreate it.
  public func atlasMap() throws -> AtlasMap {
    try database.write { db in
      try db.execute(sql: "INSERT OR IGNORE INTO canvas_view(id,title) VALUES ('atlas','图谱')")
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT 'turn' kind,t.id, (SELECT g.turn_id FROM inquiry_reference i JOIN source_anchor a ON a.reference_id=i.reference_id
          JOIN generation_run g ON g.id=json_extract(a.geometry_json,'$.parentRunID') WHERE i.turn_id=t.id AND i.role='actual_trigger' LIMIT 1) parent,0 AS sequence_group,t.rowid AS sequence_no FROM inquiry_turn t JOIN content_node q ON q.id=t.question_node_id WHERE q.deleted_at IS NULL
          UNION ALL SELECT 'document',id,NULL,1,rowid FROM document WHERE deleted_at IS NULL AND source_only=0
          UNION ALL SELECT 'content',id,NULL,2,rowid FROM content_node WHERE kind='idea' AND deleted_at IS NULL ORDER BY sequence_group,sequence_no
          """)
      var entries = try Self.mapEntries(db)
      var seeded = Set(
        try String.fetchAll(
          db, sql: "SELECT key FROM workspace_settings WHERE key LIKE 'map.seed.%'"))
      for row in rows {
        let target: String = row["id"]
        let kind: String = row["kind"]
        let parent: String? = row["parent"]
        let id = "map." + kind + "." + target
        let key = "map.seed." + id
        guard seeded.insert(key).inserted else { continue }
        try Self.seedEntry(db, id: id, kind: kind, target: target, parent: parent, entries: &entries)
      }
      let branches = try rows.compactMap { row -> MapEdge? in
        guard let parent: String = row["parent"] else { return nil }
        let child: String = row["id"]
        let source = try Row.fetchOne(
          db,
          sql:
            "SELECT s.content_version_id,s.quote_snapshot FROM inquiry_reference i JOIN reference_snapshot s ON s.id=i.reference_id WHERE i.turn_id=? AND i.role='actual_trigger'",
          arguments: [child])
        return MapEdge(
          id: "history." + child, from: parent, to: child, label: "追问", explanation: "从当时的回答继续提问",
          fromVersion: source?["content_version_id"],
          evidence: [source?["quote_snapshot"] as String?].compactMap { $0 }, directed: true,
          history: true)
      }
      let materialEdges = try Row.fetchAll(db,sql:"""
        SELECT i.turn_id,d.document_id,d.id AS version,s.quote_snapshot,
          (SELECT page_index FROM source_anchor WHERE reference_id=s.id ORDER BY segment_order LIMIT 1) AS page_index,
          json_extract(w.value_json,'$') AS origin
        FROM inquiry_reference i
        JOIN reference_snapshot s ON s.id=i.reference_id JOIN document_version d ON d.id=s.document_version_id
        LEFT JOIN workspace_settings w ON w.key='view.map.source.' || i.turn_id
        WHERE i.role='actual_trigger'
        """).map { row in
          let child: String = row["turn_id"], document: String = row["document_id"], version: String = row["version"]
          let index: Int? = row["page_index"], origin: String? = row["origin"]
          let destination = entries.first { $0.target == child }
          let materials = entries.filter { $0.target == document }
          let pages = materials.filter { $0.page?.version == version && $0.page?.index == index }
          let nearest = pages.min { lhs,rhs in
            let x = destination?.x ?? 0, y = destination?.y ?? 0
            return hypot(lhs.x-x,lhs.y-y) < hypot(rhs.x-x,rhs.y-y)
          }
          let source = materials.first { $0.id == origin && ($0.page == nil || pages.contains($0)) }
            ?? nearest ?? materials.first { $0.page == nil }
          return MapEdge(id: "material."+child, from: document, to: child, label: "引自", explanation: "提问时绑定的原文版本",
            fromVersion: version, evidence: [row["quote_snapshot"] as String?].compactMap { $0 },
            pinnedEntrances: .init(from: source, to: destination), directed: true, history: true)
        }
      let pins = try Row.fetchAll(db, sql: """
        SELECT json_extract(value_json,'$.relation') AS relation,json_extract(value_json,'$.lhs') AS lhs,
          json_extract(value_json,'$.rhs') AS rhs FROM workspace_settings WHERE key GLOB 'view.map.relation-pair.*'
        """)
      var pairs = [String: MapEdge.EntrancePair]()
      if !pins.isEmpty {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for pin in pins {
          if let id: String = pin["relation"], let lhs: String = pin["lhs"], let rhs: String = pin["rhs"] {
            pairs[id] = .init(from: byID[lhs], to: byID[rhs])
          }
        }
      }
      let relations = try Row.fetchAll(
        db,
        sql: """
          SELECT r.id,v.id AS relation_version,v.relation_type,v.direction,v.explanation,coalesce(x.id,dx.id) AS lversion,coalesce(y.id,dy.id) AS rversion,a.quote_snapshot AS levidence,b.quote_snapshot AS revidence,coalesce(l.turn_id,x.node_id,dx.document_id) AS lhs,coalesce(h.turn_id,y.node_id,dy.document_id) AS rhs
          FROM semantic_relation r JOIN relation_version v ON v.id=r.current_version_id
          JOIN reference_snapshot a ON a.id=v.from_reference_id LEFT JOIN content_version x ON x.id=a.content_version_id LEFT JOIN document_version dx ON dx.id=a.document_version_id
          LEFT JOIN generation_run l ON l.answer_version_id=x.id
          JOIN reference_snapshot b ON b.id=v.to_reference_id LEFT JOIN content_version y ON y.id=b.content_version_id LEFT JOIN document_version dy ON dy.id=b.document_version_id
          LEFT JOIN generation_run h ON h.answer_version_id=y.id WHERE r.deleted_at IS NULL AND coalesce(l.turn_id,x.node_id,dx.document_id) IS NOT NULL AND coalesce(h.turn_id,y.node_id,dy.document_id) IS NOT NULL
          """
      ).map { r in
        let pair = pairs[r["id"]]
        return MapEdge(
          id: r["id"], from: r["lhs"], to: r["rhs"],
          label: MapRelation(rawValue: r["relation_type"])?.label ?? "关系",
          explanation: r["explanation"], relationVersion: r["relation_version"], fromVersion: r["lversion"], toVersion: r["rversion"],
          evidence: [r["levidence"] as String?, r["revidence"] as String?].compactMap { $0 },
          pinnedEntrances: pair, directed: (r["direction"] as String) == "directed", history: false)
      }
      let topics = try Row.fetchAll(
        db, sql: "SELECT id,title FROM topic WHERE deleted_at IS NULL ORDER BY rowid"
      ).map { MapTopic(id: $0["id"], title: $0["title"]) }
      let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
      let manual = try Row.fetchAll(db, sql: """
        SELECT w.value_json, s.quote_snapshot, coalesce(s.content_version_id,s.document_version_id,s.relation_version_id) AS version
        FROM workspace_settings w JOIN reference_snapshot s ON s.id=json_extract(w.value_json,'$.reference')
        WHERE w.key LIKE 'manual.question.source.%'
        """).compactMap { row -> MapEdge? in
          let trace = try JSONDecoder().decode([String:String].self, from: Data((row["value_json"] as String).utf8))
          guard let parent = trace["parentTarget"], let child = trace["target"],
                let from = trace["parent"], let to = trace["child"] else { return nil }
          return MapEdge(id: "manual.history." + child, from: parent, to: child, label: "追问",
            explanation: "从所选版本手动留下问题", fromVersion: row["version"],
            evidence: [row["quote_snapshot"] as String?].compactMap { $0 },
            pinnedEntrances: .init(from: byID[from], to: byID[to]), directed: true, history: true)
      }
      return AtlasMap(entries: entries, edges: branches + materialEdges + manual + relations, topics: topics)
    }
  }

  public func relate(_ lhs: AtlasRun, _ rhs: AtlasRun, as kind: MapRelation, reason: String) throws
  {
    try relate(.answer(lhs), .answer(rhs), as: kind, reason: reason)
  }

  public func relate(_ lhs: MapRelationMaterial, _ rhs: MapRelationMaterial, as kind: MapRelation, reason: String,
                     entrances: (from: String, to: String)? = nil, requestID: UUID = UUID()) throws {
    guard lhs.objectID != rhs.objectID else { throw AtlasStoreError.invalid("请选择两份不同的材料。") }
    func identity(_ material: MapRelationMaterial) throws -> [String] {
      switch material {
      case .writing(let id, let version): return ["writing",id,version]
      case .answer(let run): return ["answer", run.turnID, run.id, run.versionID ?? ""]
      case .pdf(let file, let selection): return ["pdf", file.id, file.versionID, try encoded(selection)]
      case .markdown(let document, let version, let selection): return ["markdown", document, version, try encoded(selection)]
      }
    }
    for material in [lhs, rhs] {
      if case .pdf(_, let anchor?) = material { try validate(anchor) }
    }
    let fields = try identity(lhs) + identity(rhs) + [kind.rawValue, reason, entrances?.from ?? "", entrances?.to ?? ""]
    let digest = atlasHash(Data(try encoded(fields).utf8))
    try database.write { db in
      if let receipt = try Row.fetchOne(db, sql: "SELECT command_type,payload_sha256 FROM command_receipt WHERE request_id=?",
                                       arguments: [requestID.uuidString]) {
        guard receipt["command_type"] as String == "canvas_relation", receipt["payload_sha256"] as String == digest else {
          throw AtlasStoreError.invalid("这次建立关系的操作已用不同材料或说明提交。")
        }
        return
      }
      let a = try lhs.freeze(in: db)
      let b = try rhs.freeze(in: db)
      let id = UUID().uuidString
      let v = UUID().uuidString
      let stamp = Date.now.ISO8601Format()
      try db.execute(
        sql: "INSERT INTO semantic_relation(id,current_version_id,created_at,deleted_at) VALUES (?,?,?,?)",
        arguments: [id, v, stamp, stamp])
      try db.execute(
        sql:
          "INSERT INTO relation_version(id,relation_id,ordinal,from_reference_id,to_reference_id,relation_type,direction,epistemic_kind,explanation,actor_kind,created_at) VALUES (?,?,1,?,?,?,?,?,?,'user',?)",
        arguments: [
          v, id, a, b, kind.rawValue, kind.directed ? "directed" : "undirected",
          kind == .related_to ? "exploratory" : "synthesis", reason, stamp,
        ])
      if let entrances {
        for (entrance, target) in [(entrances.from, lhs.objectID), (entrances.to, rhs.objectID)] {
          guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM placement WHERE id=? AND view_id='atlas' AND coalesce(turn_id,document_id,content_id)=?)
            """, arguments: [entrance, target]) == true else { throw AtlasStoreError.invalid("选中的画布入口已改变。") }
        }
        try Self.saveRelationEntrances(db, relation: id, from: entrances.from, to: entrances.to, stamp: stamp)
      }
      for source in [a, b] {
        try db.execute(
          sql: "INSERT INTO relation_evidence VALUES (?,?,'context')", arguments: [v, source])
      }
      try Self.changeRelationHead(db, id: id, from: v, to: v, wasArchived: stamp, title: "建立知识关系")
      try db.execute(sql: "INSERT INTO command_receipt VALUES (?,'canvas_relation',?,?,?)",
                     arguments: [requestID.uuidString, digest, try encoded(id), stamp])
    }
  }

  static func saveRelationEntrances(_ db: Database, relation: String, from: String, to: String, stamp: String) throws {
    try db.execute(sql: """
      INSERT INTO workspace_settings(key,value_json,revision,updated_at)
      VALUES (?,json_object('relation',?,'lhs',?,'rhs',?),1,?)
      """, arguments: ["view.map.relation-pair." + relation, relation, from, to, stamp])
  }

  public func addMapTopic(_ title: String) throws -> String {
    // Historical callers use this handle as a placement's layout parent.
    return try insertMapRegion(title: title, topicID: nil, parentID: nil, frame: nil, viewID: "atlas")
  }
}

private struct EntryChange: Codable {
  let before, after: MapEntry?
  var id: String { (before ?? after!).id }
}
struct MapHistory: Codable {
  var applied: [String] = []
  var undone: [String] = []
  static func read(_ db: Database) throws -> Self {
    guard
      let text = try String.fetchOne(
        db, sql: "SELECT value_json FROM workspace_settings WHERE key='map.history'")
    else { return Self() }
    return try JSONDecoder().decode(Self.self, from: Data(text.utf8))
  }
  func save(_ db: Database) throws {
    try db.execute(
      sql:
        "INSERT INTO workspace_settings VALUES ('map.history',?,1,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at",
      arguments: [try encoded(self), Date.now.ISO8601Format()])
  }
}

extension AtlasStore {
  private static func changeMap(_ db: Database, changes: [EntryChange], title: String, id: String = UUID().uuidString) throws {
    guard !changes.isEmpty else { return }
    var history = try MapHistory.read(db)
    let timestamp = Date.now.ISO8601Format()
    let scope = try encoded(changes.map(\.id))
    let entries = Dictionary(uniqueKeysWithValues: try mapEntries(db).map { ($0.id, $0) })
    let revisions = try changes.reduce(into: [String: Int]()) { values, c in
      values[c.id] =
        try Int.fetchOne(
          db, sql: "SELECT layout_revision FROM placement WHERE id=?", arguments: [c.id]) ?? 0
    }
    try db.execute(
      sql: """
        INSERT INTO change_batch(id,status,actor_kind,read_scope_json,write_scope_json,base_revisions_json,policy_revision_at_plan,summary,created_at,applied_at)
        SELECT ?,'applied','user',?,?,?,policy_revision,?,?,? FROM workspace WHERE singleton=1
        """, arguments: [id, scope, scope, try encoded(revisions), title, timestamp, timestamp])
    for (index, c) in changes.enumerated() {
      guard c.before == entries[c.id] else { throw AtlasStoreError.invalid("画布入口已改变，请刷新后再操作。") }
      try db.execute(
        sql:
          "INSERT INTO change_operation(id,batch_id,ordinal,operation_type,target_kind,target_id,facet,expected_revision,before_json,after_json) VALUES (?,?,?,'map_placement','placement',?,'layout',?,?,?)",
        arguments: [
          UUID().uuidString, id, index, c.id, revisions[c.id] ?? 0, try c.before.map(encoded),
          try c.after.map(encoded),
        ])
      try applyEntry(db, c.id, c.after)
    }
    history.applied.append(id)
    history.undone = []
    try history.save(db)
  }
  private static func applyEntry(_ db: Database, _ id: String, _ value: MapEntry?) throws {
    if let value {
      try place(db, value)
    } else {
      try db.execute(sql: "DELETE FROM placement WHERE id=? AND view_id='atlas'", arguments: [id])
    }
  }
  /// Resolve both entrances and record one ordinary canvas undo command in the same transaction.
  public func moveEntrance(_ sourceID: String, relativeTo otherID: String, position: AtlasRelativePosition) throws -> String? {
    try database.write { db in
      let entries = try Self.mapEntries(db)
      guard sourceID != otherID, let source = entries.first(where: { $0.id == sourceID }),
        let peer = entries.first(where: { $0.id == otherID }) else {
        throw AtlasStoreError.invalid("请选择两个仍在画布上的不同入口。")
      }
      let anchor = CanvasFootprint.reserved(peer), size = CanvasFootprint.reserved(source).size
      var next = source
      next.x = anchor.minX
      next.y = anchor.minY
      switch position {
      case .below: next.y = anchor.maxY + CanvasFootprint.rowGap
      case .above: next.y = anchor.minY - CanvasFootprint.rowGap - size.height
      case .right: next.x = anchor.maxX + CanvasFootprint.columnGap
      case .left: next.x = anchor.minX - CanvasFootprint.columnGap - size.width
      }
      guard next.x != source.x || next.y != source.y else { return nil }
      let target = CGRect(origin: CGPoint(x: next.x, y: next.y), size: size)
      guard !entries.contains(where: { $0.id != sourceID && CanvasFootprint.reserved($0).intersects(target) }) else {
        throw AtlasStoreError.invalid("这个位置已有图版。可以换一个方向，或在画布上手动放置。")
      }
      let batch = UUID().uuidString
      try Self.changeMap(db, changes: [EntryChange(before: source, after: next)], title: "移动入口", id: batch)
      return batch
    }
  }
  public func moveMapEntries(_ entries: [MapEntry], dx: Double, dy: Double, batchID: String = UUID().uuidString) throws {
    guard dx != 0 || dy != 0 else { return }
    try database.write { db in
      try Self.changeMap(
        db,
        changes: entries.map { e in
          var next = e
          next.x += dx
          next.y += dy
          return EntryChange(before: e, after: next)
        }, title: "移动入口", id: batchID)
    }
  }
  public func removeMapEntries(_ entries: [MapEntry]) throws {
    try database.write { db in try Self.removeCanvasEntrances(db, entries) }
  }
  public func growMapAnswer(_ entry: MapEntry) throws {
    guard entry.kind == "turn" else {throw AtlasStoreError.invalid("请选择问答入口。")}
    var next=entry
    next.readingHeight=nil
    try database.write { db in
      try Self.changeMap(db,changes:[EntryChange(before:entry,after:next)],title:"随回答长高")
    }
  }
  /// Pin the existing entrance in one undoable operation, rechecking its location at commit.
  public func pinMapReader(_ entry: MapEntry, size: CGSize, near origin: CGPoint) throws {
    guard size.width.isFinite, size.height.isFinite, origin.x.isFinite, origin.y.isFinite else {
      throw AtlasStoreError.invalid("阅读窗的位置或尺寸无效。")
    }
    try database.write { db in
      let obstacles = try Self.mapEntries(db).filter { $0.id != entry.id }.map { CanvasFootprint.reserved($0) }
      var next = entry
      let point = CanvasFootprint.available(near: origin, size: size, obstacles: obstacles,
        viewport: CGSize(width: 1200, height: 800))
      next.x = point.x
      next.y = point.y
      next.readingWidth = size.width
      next.readingHeight = size.height
      next.expanded = true
      try Self.changeMap(db, changes: [EntryChange(before: entry, after: next)], title: "固定阅读窗")
    }
  }
  public func resizeMapEntry(_ entry: MapEntry, width: Double, height: Double) throws {
    guard width.isFinite, height.isFinite else { throw AtlasStoreError.invalid("入口尺寸无效。") }
    var next = entry
    next.readingWidth = min(2400, max(320, width))
    next.readingHeight = min(6000, max(220, height))
    try database.write { db in
      try Self.changeMap(db, changes: [EntryChange(before: entry, after: next)], title: "调整阅读窗")
    }
  }
  public func toggleMapEntry(_ entry: MapEntry) throws {
    try database.write { db in
      var next = entry
      next.expanded.toggle()
      try Self.changeMap(db, changes: [EntryChange(before: entry, after: next)], title: "切换阅读")
    }
  }
  public func addMapEntrance(_ entry: MapEntry, to topic: String) throws {
    try database.write { db in
      // Legacy callers pass either the first region's handle or a topic chosen from the menu.
      let region = try String.fetchOne(db, sql: """
        SELECT id FROM region WHERE view_id='atlas' AND (id=:handle OR topic_id=:handle)
        ORDER BY (id=:handle) DESC,rowid LIMIT 1
        """, arguments: ["handle":topic])
      guard let region else { throw AtlasStoreError.invalid("请先选择目标地域。") }
      if try Self.mapEntries(db).contains(where: { $0.target == entry.target && $0.kind == entry.kind && $0.regionID == region }) { return }
      _ = try Self.copyEntrance(db, entry.id, region, existing: entry)
    }
  }
  public func latestCanvasEditID() throws -> String? {
    try database.read { try MapHistory.read($0).applied.last }
  }

  @discardableResult public func replayMapEdit(redo: Bool, expectedBatchID: String? = nil) throws -> Bool {
    try database.write { db in
      var history = try MapHistory.read(db)
      if let expectedBatchID, expectedBatchID != (redo ? history.undone.last : history.applied.last) { return false }
      guard let id = (redo ? history.undone.popLast() : history.applied.popLast()) else { return false }
      var legacyEntries: [String:MapEntry]?
      for row in try Row.fetchAll(
        db, sql: "SELECT * FROM change_operation WHERE batch_id=? ORDER BY ordinal " + (redo ? "ASC" : "DESC"), arguments: [id]
      ) {
        if ["canvas_region_edit", "canvas_relation_edit"].contains(row["operation_type"] as String) {
          try Self.replayRegionOperation(db, row: row, redo: redo)
          continue
        }
        func entry(_ key: String) throws -> MapEntry? {
          guard let text: String = row[key] else { return nil }
          return try JSONDecoder().decode(MapEntry.self, from: Data(text.utf8))
        }
        let target: String = row["target_id"]
        if legacyEntries == nil {
          legacyEntries = Dictionary(uniqueKeysWithValues: try Self.mapEntries(db).map { ($0.id, $0) })
        }
        guard try entry(redo ? "before_json" : "after_json") == legacyEntries?[target] else {
          throw AtlasStoreError.invalid("有入口已发生其他变更，整批操作已取消。")
        }
        try Self.applyEntry(db, target, entry(redo ? "after_json" : "before_json"))
      }
      try db.execute(
        sql: "UPDATE change_batch SET status=? WHERE id=?",
        arguments: [redo ? "applied" : "rolled_back", id])
      if redo { history.applied.append(id) } else { history.undone.append(id) }
      try history.save(db)
      return true
    }
  }
}
