import Foundation
import GRDB

/// A region is a placement container. Several independent regions can display one topic.
public struct CanvasRegion: Identifiable, Equatable, Sendable {
  public let id, viewID, title: String
  public let topicID, parentID: String?
  public let frame: CGRect
  public var collapsed: Bool
  public let revision: Int
}

extension MapEntry {
  /// Stored under the historical Codable key "topic" by early builds.
  public var regionID: String? { topic }
}

private typealias Fields = [String: Any]

private func json(_ value: Any) throws -> String {
  String(
    decoding: try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
}

private enum RegionTable: String {
  case region, placement, topic, topic_membership, workspace_settings, semantic_relation

  var idKey: String { self == .workspace_settings ? "key" : "id" }
  var revision: String { self == .placement ? "layout_revision" : "revision" }
  var columns: Set<String> {
    switch self {
    case .semantic_relation: ["current_version_id", "deleted_at"]
    case .region:
      ["id", "view_id", "topic_id", "parent_region_id", "x", "y", "width", "height", "collapsed"]
    case .placement:
      [
        "id", "view_id", "target_kind", "turn_id", "content_id", "document_id", "parent_region_id",
        "x", "y", "width", "height", "display_mode", "reader_state_json",
      ]
    case .topic: ["id", "title", "description", "created_at", "deleted_at"]
    case .topic_membership:
      ["id", "topic_id", "target_kind", "turn_id", "content_id", "document_id"]
    case .workspace_settings: ["key", "value_json", "updated_at"]
    }
  }

  var facet: String {
    switch self {
    case .semantic_relation: "relation"
    case .region, .placement: "layout"
    case .topic_membership: "membership"
    case .workspace_settings, .topic: "metadata"
    }
  }

  func image(_ db: Database, id: String, keys: Set<String>) throws -> Fields? {
    guard keys.isSubset(of: columns), !keys.isEmpty else {
      throw AtlasStoreError.invalid("地域操作字段无效。")
    }
    let expr = keys.sorted().map { "'\($0)',\($0)" }.joined(separator: ",")
    guard
      let data = try String.fetchOne(
        db, sql: "SELECT json_object(\(expr)) FROM \(rawValue) WHERE \(idKey)=?", arguments: [id])
    else { return nil }
    return try JSONSerialization.jsonObject(with: Data(data.utf8)) as? Fields
  }
}

private struct RegionEdit {
  let table: RegionTable
  let id: String
  let before, after: Fields?

  init(_ table: RegionTable, _ id: String, _ before: Fields?, _ after: Fields?) {
    self.table = table
    self.id = id
    self.before = before
    self.after = after
  }

  static func patch(_ db: Database, _ table: RegionTable, _ id: String, _ values: Fields) throws
    -> Self
  {
    guard let old = try table.image(db, id: id, keys: Set(values.keys)) else {
      throw AtlasStoreError.invalid("画布对象已移除。")
    }
    return Self(table, id, old, values)
  }

  func apply(_ db: Database, reverse: Bool = false) throws {
    let previous = reverse ? after : before
    let next = reverse ? before : after
    guard let keys = (previous ?? next)?.keys else { throw AtlasStoreError.invalid("地域操作为空。") }
    let actual = try table.image(db, id: id, keys: Set(keys))
    guard (actual as NSDictionary?) == (previous as NSDictionary?) else {
      throw AtlasStoreError.invalid("相关对象已变更，整批操作已取消。")
    }
    if let next {
      if table == .region, let parentID = next["parent_region_id"] as? String {
        let cycle = try Bool.fetchOne(
          db,
          sql: """
            WITH RECURSIVE ancestry(id) AS (SELECT ? UNION SELECT r.parent_region_id FROM region r JOIN ancestry a ON a.id=r.id WHERE r.parent_region_id IS NOT NULL)
            SELECT EXISTS(SELECT 1 FROM ancestry WHERE id=?)
            """, arguments: [parentID, id])
        guard cycle != true else { throw AtlasStoreError.invalid("地域不能包含自己或祖先。") }
      }
      let names = next.keys.sorted()
      guard Set(names).isSubset(of: table.columns) else {
        throw AtlasStoreError.invalid("地域操作字段无效。")
      }
      let value = try json(next)
      if previous == nil {
        guard next[table.idKey] as? String == id else { throw AtlasStoreError.invalid("地域操作标识无效。") }
        try db.execute(
          sql:
            "INSERT INTO \(table.rawValue)(\(table.revision),\(names.joined(separator:","))) VALUES (1,\(names.map { "json_extract(:image,'$.\($0)')" }.joined(separator:",")))",
          arguments: ["image": value])
      } else {
        guard Set(names) == Set(keys), !names.contains(table.idKey) else {
          throw AtlasStoreError.invalid("地域操作更新范围无效。")
        }
        let assign = names.map { "\($0)=json_extract(:image,'$.\($0)')" }.joined(separator: ",")
        try db.execute(
          sql:
            "UPDATE \(table.rawValue) SET \(assign),\(table.revision)=\(table.revision)+1 WHERE \(table.idKey)=:id",
          arguments: ["image": value, "id": id])
      }
    } else {
      try db.execute(sql: "DELETE FROM \(table.rawValue) WHERE \(table.idKey)=?", arguments: [id])
    }
  }
}

private func saveRegionBatch(_ db: Database, _ edits: [RegionEdit], title: String, id: String = UUID().uuidString) throws {
  let changes = edits.filter { ($0.before as NSDictionary?) != ($0.after as NSDictionary?) }
  guard !changes.isEmpty else { return }
  var history = try MapHistory.read(db)
  let stamp = Date.now.ISO8601Format()
  let scope = try json(changes.map { ["kind": $0.table.rawValue, "id": $0.id] })
  var revisions = [String: Int]()
  for c in changes {
    revisions[c.id] =
      try Int.fetchOne(
        db, sql: "SELECT \(c.table.revision) FROM \(c.table.rawValue) WHERE \(c.table.idKey)=?",
        arguments: [c.id]) ?? 0
  }
  try db.execute(
    sql: """
      INSERT INTO change_batch(id,status,actor_kind,read_scope_json,write_scope_json,base_revisions_json,policy_revision_at_plan,summary,created_at,applied_at)
      SELECT ?,'applied','user',?,?,?,policy_revision,?,?,? FROM workspace WHERE singleton=1
      """, arguments: [id, scope, scope, try json(revisions), title, stamp, stamp])
  for (i, c) in changes.enumerated() {
    try c.apply(db)
    try db.execute(
      sql: """
        INSERT INTO change_operation(id,batch_id,ordinal,operation_type,target_kind,target_id,facet,expected_revision,before_json,after_json)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """,
      arguments: [
        UUID().uuidString, id, i, c.table == .semantic_relation ? "canvas_relation_edit" : "canvas_region_edit", c.table.rawValue, c.id, c.table.facet, revisions[c.id] ?? 0,
        try c.before.map(json), try c.after.map(json),
      ])
  }
  history.applied.append(id)
  history.undone.removeAll()
  try history.save(db)
}

extension AtlasStore {
  /// Only the visible relation head changes. Evidence, version rows and past questions remain addressable.
  static func changeRelationHead(_ db: Database, id: String, from old: String, to next: String,
                                 wasArchived: String? = nil, archived: String? = nil, title: String) throws {
    let before: Fields = ["current_version_id": old, "deleted_at": wasArchived as Any? ?? NSNull()]
    let after: Fields = ["current_version_id": next, "deleted_at": archived as Any? ?? NSNull()]
    try saveRegionBatch(db, [RegionEdit(.semantic_relation, id, before, after)], title: title)
  }

  static func replayRegionOperation(_ db: Database, row: Row, redo: Bool) throws {
    guard let table = RegionTable(rawValue: row["target_kind"]) else {
      throw AtlasStoreError.invalid("地域操作类型无效。")
    }
    func fields(_ key: String) throws -> Fields? {
      guard let value: String = row[key] else { return nil }
      guard let fields = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? Fields else {
        throw AtlasStoreError.invalid("地域操作快照无效。")
      }
      return fields
    }
    try RegionEdit(table, row["target_id"], fields("before_json"), fields("after_json")).apply(
      db, reverse: !redo)
  }

  public func canvasRegions(viewID: String = "atlas") throws -> [CanvasRegion] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT r.*,coalesce(json_extract(s.value_json,'$'),t.title,'未命名地域') AS region_title
          FROM region r LEFT JOIN topic t ON t.id=r.topic_id LEFT JOIN workspace_settings s ON s.key='region.title.' || r.id
          WHERE r.view_id=? ORDER BY r.rowid
          """, arguments: [viewID]
      ).map { r in
        .init(
          id: r["id"], viewID: viewID, title: r["region_title"], topicID: r["topic_id"],
          parentID: r["parent_region_id"],
          frame: CGRect(
            x: r["x"] as Double, y: r["y"] as Double, width: r["width"] as Double,
            height: r["height"] as Double),
          collapsed: r["collapsed"], revision: r["revision"])
      }
    }
  }

  /// A nil topic creates a topic with its first region. Supplying a topic creates another instance.
  @discardableResult public func createMapRegion(
    title: String, topicID: String? = nil, parentID: String? = nil, frame: CGRect,
    viewID: String = "atlas"
  ) throws -> String {
    try insertMapRegion(title: title, topicID: topicID, parentID: parentID, frame: frame, viewID: viewID)
  }

  func insertMapRegion(title: String, topicID: String?, parentID: String?, frame: CGRect?, viewID: String) throws -> String {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw AtlasStoreError.invalid("请输入地域名。") }
    return try database.write { db in
      let bounds: CGRect
      if let frame { bounds = frame }
      else {
        let occupied = try Row.fetchAll(db, sql: "SELECT x,y,width,height FROM region WHERE view_id=?", arguments: [viewID]).map {
          CGRect(x: $0["x"] as Double, y: $0["y"] as Double, width: $0["width"] as Double, height: $0["height"] as Double)
        }
        let size = CGSize(width: 600, height: 400)
        bounds = CGRect(origin: CanvasFootprint.available(near: .zero, size: size, obstacles: occupied, viewport: size), size: size)
      }
      let geom = try Self.regionGeometry(bounds)
      if viewID == "atlas" {
        try db.execute(sql: "INSERT OR IGNORE INTO canvas_view(id,title) VALUES ('atlas','图谱')")
      }
      guard
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS(SELECT 1 FROM canvas_view WHERE id=?)", arguments: [viewID])
          == true
      else { throw AtlasStoreError.invalid("画布视图不存在。") }
      if let parentID { try Self.requireRegion(db, parentID, in: viewID) }
      let id = UUID().uuidString
      let topic = topicID ?? UUID().uuidString
      let now = Date.now.ISO8601Format()
      var edits = [RegionEdit]()
      if topicID == nil {
        edits.append(
          .init(
            .topic, topic, nil,
            [
              "id": topic, "title": name, "description": "", "created_at": now,
              "deleted_at": NSNull(),
            ]))
      } else if try Bool.fetchOne(
        db, sql: "SELECT EXISTS(SELECT 1 FROM topic WHERE id=? AND deleted_at IS NULL)",
        arguments: [topic]) != true
      {
        throw AtlasStoreError.invalid("主题不存在。")
      }
      var state: Fields = [
        "id": id, "view_id": viewID, "topic_id": topic,
        "parent_region_id": parentID as Any? ?? NSNull(), "collapsed": 0,
      ]
      state.merge(geom) { _, value in value }
      edits.append(.init(.region, id, nil, state))
      let key = "region.title." + id
      edits.append(
        .init(
          .workspace_settings, key, nil,
          ["key": key, "value_json": try json(name), "updated_at": now]))
      try saveRegionBatch(db, edits, title: "创建地域「\(name)」")
      return id
    }
  }

  private static func requireRegion(_ db: Database, _ id: String, in view: String) throws {
    guard
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS(SELECT 1 FROM region WHERE id=? AND view_id=?)",
        arguments: [id, view]) == true
    else { throw AtlasStoreError.invalid("地域与画布不匹配。") }
  }

  private static func regionGeometry(_ frame: CGRect) throws -> Fields {
    guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.size.width.isFinite,
      frame.size.height.isFinite, frame.size.width > 0, frame.size.height > 0
    else { throw AtlasStoreError.invalid("地域边界无效。") }
    return [
      "x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width),
      "height": Double(frame.height),
    ]
  }

  public func renameMapRegion(_ id: String, title: String) throws {
    try editMapRegion(id, title: title, frame: nil)
  }

  public func editMapRegion(_ id: String, title: String, frame: CGRect?) throws {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw AtlasStoreError.invalid("请输入地域名。") }
    try database.write { db in
      guard try String.fetchOne(db, sql: "SELECT id FROM region WHERE id=?", arguments: [id]) != nil
      else { throw AtlasStoreError.invalid("地域不存在。") }
      let key = "region.title." + id
      let edit: RegionEdit
      if try RegionTable.workspace_settings.image(db, id: key, keys: ["key"]) != nil {
        edit = try .patch(db, .workspace_settings, key, ["value_json": try json(name)])
      } else {
        edit = .init(
          .workspace_settings, key, nil,
          ["key": key, "value_json": try json(name), "updated_at": Date.now.ISO8601Format()])
      }
      var edits = [edit]
      if let frame { edits.append(try .patch(db, .region, id, Self.regionGeometry(frame))) }
      try saveRegionBatch(db, edits, title: "编辑地域名称与边界")
    }
  }

  public func resizeMapRegion(_ id: String, frame: CGRect) throws {
    let fields = try Self.regionGeometry(frame)
    try database.write { db in
      try saveRegionBatch(db, [.patch(db, .region, id, fields)], title: "调整地域边界")
    }
  }

  public func setRegionCollapsed(_ id: String, collapsed: Bool) throws {
    try database.write { db in
      try saveRegionBatch(
        db, [.patch(db, .region, id, ["collapsed": collapsed ? 1 : 0])],
        title: collapsed ? "折叠地域" : "展开地域")
    }
  }

  public func setRegionParent(_ id: String, parentID: String?) throws {
    try database.write { db in
      guard
        let view = try String.fetchOne(
          db, sql: "SELECT view_id FROM region WHERE id=?", arguments: [id])
      else { throw AtlasStoreError.invalid("地域不存在。") }
      if let parentID {
        try Self.requireRegion(db, parentID, in: view)

      }
      try saveRegionBatch(
        db, [.patch(db, .region, id, ["parent_region_id": parentID as Any? ?? NSNull()])],
        title: "改变地域嵌套")
    }
  }

  public func moveCanvasSelection(
    regionIDs: Set<String>, placementIDs: Set<String>, dx: Double, dy: Double,
    viewID: String = "atlas", batchID: String = UUID().uuidString
  ) throws {
    guard dx.isFinite, dy.isFinite else { throw AtlasStoreError.invalid("画布位移无效。") }
    guard dx != 0 || dy != 0 else { return }
    try database.write { db in
      let selected = try json(regionIDs.sorted())
      let placements = try json(placementIDs.sorted())
      let regions = try Row.fetchAll(
        db,
        sql: """
          WITH RECURSIVE owned(id) AS (SELECT r.id FROM region r JOIN json_each(?) j ON j.value=r.id WHERE view_id=?
            UNION SELECT r.id FROM region r JOIN owned o ON r.parent_region_id=o.id WHERE r.view_id=?)
          SELECT r.id,r.x,r.y FROM owned JOIN region r USING(id)
          """, arguments: [selected, viewID, viewID])
      let ids = Set(regions.map { $0["id"] as String })
      let members = try Row.fetchAll(
        db,
        sql:
          "SELECT id,x,y FROM placement WHERE view_id=? AND (id IN (SELECT value FROM json_each(?)) OR parent_region_id IN (SELECT value FROM json_each(?)))",
        arguments: [viewID, placements, try json(ids.sorted())])
      guard regionIDs.isSubset(of: ids),
        placementIDs.isSubset(of: Set(members.map { $0["id"] as String }))
      else { throw AtlasStoreError.invalid("选中的地域或入口已改变。") }
      var edits = [RegionEdit]()
      for (table, rows) in [(RegionTable.region, regions), (.placement, members)] {
        for row in rows {
          let x: Double = row["x"]
          let y: Double = row["y"]
          edits.append(.init(table, row["id"], ["x": x, "y": y], ["x": x + dx, "y": y + dy]))
        }
      }
      try saveRegionBatch(db, edits, title: "整体移动地域与入口", id: batchID)
    }
  }
}

extension AtlasStore {
  private static func placementState(_ db: Database, _ id: String) throws -> Fields {
    guard
      let state = try RegionTable.placement.image(db, id: id, keys: RegionTable.placement.columns)
    else { throw AtlasStoreError.invalid("画布入口不存在。") }
    return state
  }

  private static func targetOf(_ p: Fields) throws -> (kind: String, id: String) {
    guard let kind = p["target_kind"] as? String, ["turn", "content", "document"].contains(kind),
      let id = p[kind + "_id"] as? String
    else { throw AtlasStoreError.invalid("入口引用无效。") }
    return (kind, id)
  }

  private static func joinEdits(_ db: Database, placement p: Fields, region: String) throws
    -> [RegionEdit]
  {
    guard let view = p["view_id"] as? String else { throw AtlasStoreError.invalid("入口视图无效。") }
    try requireRegion(db, region, in: view)
    guard
      let topic = try String.fetchOne(
        db, sql: "SELECT topic_id FROM region WHERE id=?", arguments: [region])
    else { throw AtlasStoreError.invalid("此地域尚未关联主题。") }
    let t = try targetOf(p)
    if try String.fetchOne(
      db,
      sql: "SELECT id FROM topic_membership WHERE topic_id=? AND target_kind=? AND \(t.kind)_id=?",
      arguments: [topic, t.kind, t.id]) != nil
    {
      return []
    }
    let id = UUID().uuidString
    var values: Fields = [
      "id": id, "topic_id": topic, "target_kind": t.kind, "turn_id": NSNull(),
      "content_id": NSNull(), "document_id": NSNull(),
    ]
    values[t.kind + "_id"] = t.id
    return [.init(.topic_membership, id, nil, values)]
  }

  public func joinMapRegion(placementID: String, regionID: String, x: Double, y: Double, batchID: String = UUID().uuidString) throws {
    guard x.isFinite, y.isFinite else { throw AtlasStoreError.invalid("入口位置无效。") }
    try database.write { db in
      let p = try Self.placementState(db, placementID)
      var changes = try Self.joinEdits(db, placement: p, region: regionID)
      changes.append(
        try .patch(db, .placement, placementID, ["parent_region_id": regionID, "x": x, "y": y]))
      try saveRegionBatch(db, changes, title: "加入主题并移入地域", id: batchID)
    }
  }

  public func leaveMapRegion(placementID: String) throws {
    try database.write { db in
      try saveRegionBatch(
        db, [.patch(db, .placement, placementID, ["parent_region_id": NSNull()])],
        title: "移出地域，保留主题")
    }
  }

  public func topicIDsForPlacement(_ id: String) throws -> Set<String> {
    try database.read { db in
      let t = try Self.targetOf(Self.placementState(db, id))
      return Set(
        try String.fetchAll(
          db, sql: "SELECT topic_id FROM topic_membership WHERE target_kind=? AND \(t.kind)_id=?",
          arguments: [t.kind, t.id]))
    }
  }

  public func departurePlacements(placementID: String, topicID: String) throws -> [String] {
    try database.read { db in try Self.departures(db, placementID, topicID).entrances }
  }

  private static func departures(_ db: Database, _ placement: String, _ topic: String) throws -> (
    member: String?, entrances: [String]
  ) {
    let t = try targetOf(placementState(db, placement))
    let m = try String.fetchOne(
      db, sql: "SELECT id FROM topic_membership WHERE topic_id=? AND \(t.kind)_id=?",
      arguments: [topic, t.id])
    let entries = try String.fetchAll(
      db,
      sql:
        "SELECT p.id FROM placement p JOIN region r ON r.id=p.parent_region_id AND r.view_id=p.view_id WHERE p.\(t.kind)_id=? AND r.topic_id=? ORDER BY p.view_id,p.id",
      arguments: [t.id, topic])
    return (m, entries)
  }

  public func leaveMapTopic(
    placementID: String, topicID: String, expectedEntrances: Set<String>? = nil
  ) throws {
    try database.write { db in
      let (member, ids) = try Self.departures(db, placementID, topicID)
      if let expectedEntrances, Set(ids) != expectedEntrances {
        throw AtlasStoreError.invalid("入口范围已发生变化，请重新核对。")
      }
      var edits = try ids.map {
        try RegionEdit.patch(db, .placement, $0, ["parent_region_id": NSNull()])
      }
      if let member,
        let old = try RegionTable.topic_membership.image(
          db, id: member, keys: RegionTable.topic_membership.columns)
      {
        edits.append(.init(.topic_membership, member, old, nil))
      }
      try saveRegionBatch(db, edits, title: "退出主题，保留内容及入口")
    }
  }

  @discardableResult public func copyMapEntrance(placementID: String, regionID: String) throws
    -> String
  {
    try database.write { db in try Self.copyEntrance(db, placementID, regionID, existing: nil) }
  }

  static func copyEntrance(_ db: Database, _ entry: String, _ region: String, existing: MapEntry?)
    throws -> String
  {
    var state = try placementState(db, entry)
    let target = try targetOf(state)
    if let existing {
      guard existing.target == target.id, existing.kind == target.kind,
        (state["parent_region_id"] as? String) == existing.regionID,
        (state["x"] as? Double) == existing.x, (state["y"] as? Double) == existing.y,
        (state["display_mode"] as? String == "reading") == existing.expanded
      else { throw AtlasStoreError.invalid("原入口已变更。") }
    }
    var edits = try joinEdits(db, placement: state, region: region)
    let id = UUID().uuidString
    guard let r = try RegionTable.region.image(db, id: region, keys: ["x", "y"]) else {
      throw AtlasStoreError.invalid("目标地域不存在。")
    }
    let entries = try mapEntries(db)
    guard let source = entries.first(where: { $0.id == entry }) else { throw AtlasStoreError.invalid("找不到原入口。") }
    let point = CanvasFootprint.available(near: CGPoint(x: (r["x"] as? Double ?? 0) + 24, y: (r["y"] as? Double ?? 0) + 48),
      size: CanvasFootprint.reserved(source).size, obstacles: entries.map { CanvasFootprint.reserved($0) },
      viewport: CGSize(width: 1200, height: 800))
    state["id"] = id
    state["parent_region_id"] = region
    state["x"] = Double(point.x)
    state["y"] = Double(point.y)
    // Each entrance starts with its own reader, while preserving the user's chosen card size.
    state["display_mode"] = "overview"
    state["reader_state_json"] = "{}"
    edits.append(.init(.placement, id, nil, state))
    try saveRegionBatch(db, edits, title: "为同一内容创建主题入口")
    return id
  }

  /// Paste placements at the destination without assigning topic membership by geometry.
  public func pasteCanvasReferences(_ references: [CanvasReference], at origin: CGPoint) throws -> [String] {
    guard let first = references.first else { return [] }
    return try database.write { db in
      var edits: [RegionEdit] = []
      var ids: [String] = []
      let group = references.reduce(CGRect.null) { $0.union(CanvasFootprint.reserved($1.entry)) }
      let firstOffset = CGPoint(x: first.entry.x - group.minX, y: first.entry.y - group.minY)
      let requested = CGPoint(x: origin.x - firstOffset.x, y: origin.y - firstOffset.y)
      let destination = CanvasFootprint.available(near: requested, size: group.size,
        obstacles: try Self.mapEntries(db).map { CanvasFootprint.reserved($0) }, viewport: CGSize(width: 1200, height: 800))
      for ref in references {
        let entry = ref.entry
        let id = writingID()
        let x = destination.x + (entry.x - group.minX), y = destination.y + (entry.y - group.minY)
        guard abs(x) < 1e12, abs(y) < 1e12 else { throw AtlasStoreError.invalid("粘贴位置超出画布。") }
        let table: String
        switch entry.kind {
        case "document": table = "document"
        case "content": table = "content_node"
        case "turn": table = "inquiry_turn"
        default: throw AtlasStoreError.invalid("未知的画布对象。")
        }
        let query = entry.kind == "turn"
          ? "SELECT 1 FROM inquiry_turn t JOIN content_node q ON q.id=t.question_node_id WHERE t.id=? AND q.deleted_at IS NULL"
          : "SELECT 1 FROM " + table + " WHERE id=? AND deleted_at IS NULL"
        guard try Int.fetchOne(db, sql: query, arguments: [entry.target]) != nil else {
          throw AtlasStoreError.invalid("引用的材料已移除。")
        }
        if let pin = ref.pin {
          let setting: String?
          switch entry.kind {
          case "turn":
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM generation_run WHERE id=? AND turn_id=?", arguments: [pin, entry.target]) != nil
            else { throw AtlasStoreError.invalid("引用的回答版本不可用。") }
            setting = "map.shown-runs"
          default:
            let sql = entry.kind == "document"
              ? "SELECT d.kind FROM document_version v JOIN document d ON d.id=v.document_id WHERE v.id=? AND d.id=?"
              : "SELECT 'idea' FROM content_version WHERE id=? AND node_id=?"
            guard let kind = try String.fetchOne(db, sql: sql, arguments: [pin, entry.target]) else {
              throw AtlasStoreError.invalid("引用的材料版本不可用。")
            }
            setting = kind == "pdf" ? "map.pdf-versions" : nil
          }
          if let setting {
            let raw = try String.fetchOne(db, sql: "SELECT value_json FROM workspace_settings WHERE key=?", arguments: ["view." + setting]) ?? "{}"
            var pins = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
            pins[id] = pin
            try Self.writeViewState(db, key: setting, json: writingJSON(pins))
          } else {
            try Self.writeViewState(db, key: "map.writing." + id, json: json(["pinnedVersion": pin, "editing": false] as Fields))
          }
        }
        var readerState = "{}"
        if let page = entry.page {
          guard try String.fetchOne(db, sql: "SELECT document_id FROM document_version WHERE id=?", arguments: [page.version]) == entry.target
          else { throw AtlasStoreError.invalid("无法复制这一页的来源版本。") }
          readerState = String(decoding: try JSONEncoder().encode(["pdf_page": page]), as: UTF8.self)
        }
        let state: Fields = ["id": id, "view_id": "atlas", "target_kind": entry.kind, entry.kind + "_id": entry.target,
          "parent_region_id": NSNull(), "x": x, "y": y, "width": entry.readingWidth ?? 248,
          "height": entry.readingHeight ?? 116, "display_mode": entry.page == nil ? "overview" : "reading", "reader_state_json": readerState]
        edits.append(.init(.placement, id, nil, state))
        ids.append(id)
      }
      try saveRegionBatch(db, edits, title: "粘贴引用入口")
      return ids
    }
  }

  static func removeCanvasEntrances(_ db: Database, _ entries: [MapEntry]) throws {
    var changes = [RegionEdit]()
    for e in entries {
      let full = try placementState(db, e.id)
      guard (full["x"] as? Double) == e.x, (full["y"] as? Double) == e.y,
        (full["parent_region_id"] as? String) == e.regionID
      else { throw AtlasStoreError.invalid("入口布局已发生变化。") }
      changes.append(.init(.placement, e.id, full, nil))
    }
    try saveRegionBatch(db, changes, title: "移除画布入口")
  }
}

/// Presentation only. Proxy endpoints are region IDs; semantic edges keep their original IDs.
public struct CanvasRegionTree: Sendable {
  public let regions: [String: CanvasRegion]
  private let parents: [String: String]
  private let proxyParents: [String: String]
  public init(_ source: [CanvasRegion]) {
    regions = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
    let byID = regions
    parents = Dictionary(
      uniqueKeysWithValues: source.compactMap { r in r.parentID.map { (r.id, $0) } })
    var proxies = [String: String]()
    for r in source {
      var cursor = Optional(r.id)
      var visited = Set<String>()
      var visibleCollapsed: String?
      while let id = cursor, visited.insert(id).inserted, let region = byID[id] {
        if region.collapsed { visibleCollapsed = id }
        cursor = region.parentID
      }
      proxies[r.id] = visibleCollapsed
    }
    proxyParents = proxies
  }
  public func collapsedOwner(of regionID: String?) -> String? {
    regionID.flatMap { proxyParents[$0] }
  }
  public func hides(_ region: CanvasRegion) -> Bool { collapsedOwner(of: region.parentID) != nil }
  public func path(to regionID: String?, naming: (CanvasRegion) -> String) -> String {
    var names: [String] = [], seen = Set<String>(), next = regionID
    while let id = next, seen.insert(id).inserted, let region = regions[id] {
      names.append(naming(region))
      next = region.parentID
    }
    return names.isEmpty ? "画布根层" : names.reversed().joined(separator: " › ")
  }
  public func belongsToSelection(_ regionID: String?, selected: Set<String>) -> Bool {
    guard !selected.isEmpty else { return false }
    var id = regionID
    var seen = Set<String>()
    while let current = id, seen.insert(current).inserted {
      if selected.contains(current) { return true }
      id = parents[current]
    }
    return false
  }
}

public struct RegionDepartureEntry: Identifiable, Sendable {
  public let id, viewTitle, regionTitle: String
  public let x, y: Double
}
extension AtlasStore {
  public func previewTopicDeparture(placementID: String, topicID: String) throws
    -> [RegionDepartureEntry]
  {
    try database.read { db in
      let ids = try Self.departures(db, placementID, topicID).entrances
      return try Row.fetchAll(
        db,
        sql: """
          SELECT p.id,v.title AS view_title,coalesce(json_extract(s.value_json,'$'),t.title,'未命名地域') AS region_title,p.x,p.y
          FROM placement p JOIN canvas_view v ON v.id=p.view_id JOIN region r ON r.id=p.parent_region_id
          LEFT JOIN topic t ON t.id=r.topic_id LEFT JOIN workspace_settings s ON s.key='region.title.' || r.id
          WHERE p.id IN (SELECT value FROM json_each(?)) ORDER BY p.view_id,p.id
          """, arguments: [try json(ids)]
      ).map { row in
        RegionDepartureEntry(
          id: row["id"], viewTitle: row["view_title"], regionTitle: row["region_title"],
          x: row["x"], y: row["y"])
      }
    }
  }
}
