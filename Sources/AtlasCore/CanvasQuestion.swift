import Foundation
import GRDB

/// The question, frozen source and intended world position belong to the same draft.
public struct CanvasQuestionDraft: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let sourcePlacementID, referenceID, quote: String?
  public fileprivate(set) var regionID: String?
  public fileprivate(set) var topicID: String?
  public let x, y: Double
  fileprivate var extraCitations: [CanvasCitation]? = nil
  public var citations: [CanvasCitation] { extraCitations ?? [] }
  public fileprivate(set) var text: String
  fileprivate var key: String { "canvas.question." + id }

  fileprivate func payload() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return atlasHash(try encoder.encode(self))
  }
  func previousRun(_ db: Database) throws -> String? {
    guard
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT command_type,payload_sha256,result_json FROM command_receipt WHERE request_id=?",
        arguments: [id])
    else { return nil }
    guard row["command_type"] as String == "canvas_question",
      try payload() == row["payload_sha256"] as String
    else { throw AtlasStoreError.invalid("同一草稿已使用不同内容提交。") }
    return try JSONDecoder().decode(String.self, from: Data((row["result_json"] as String).utf8))
  }
  func placeQuestion(_ db: Database, turn: String, run: String) throws {
    let placement = "map.turn." + turn
    let dimension = CanvasFootprint.question
    // A draft may have been left open while another entrance was created or moved.
    let occupied = try AtlasStore.mapEntries(db).map { CanvasFootprint.reserved($0) }
    let point = CanvasFootprint.available(near: CGPoint(x: x, y: y), size: dimension,
      obstacles: occupied, viewport: dimension)
    let row = MapEntry(
      id: placement, kind: "turn", target: turn, topic: regionID, x: point.x, y: point.y,
      readingWidth: dimension.width, readingHeight: dimension.height, expanded: true)
    try db.execute(sql: "INSERT OR IGNORE INTO canvas_view(id,title) VALUES ('atlas','图谱')")
    try AtlasStore.place(db, row)
    let stamp = Date.now.ISO8601Format()
    try db.execute(
      sql: "INSERT INTO workspace_settings VALUES (?,'true',1,?)",
      arguments: ["map.seed." + placement, stamp])
    if let sourcePlacementID {
      try db.execute(sql: "INSERT INTO workspace_settings VALUES (?,json_quote(?),1,?)", arguments: ["view.map.source." + turn, sourcePlacementID, stamp])
    }
    if let topicID {
      try db.execute(
        sql: "INSERT INTO topic_membership(id,topic_id,target_kind,turn_id) VALUES (?,?,'turn',?)",
        arguments: [UUID().uuidString, topicID, turn])
    }
    let result = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
    try db.execute(
      sql: "INSERT INTO command_receipt VALUES (?,'canvas_question',?,?,?)",
      arguments: [id, try payload(), result, stamp])
    try db.execute(sql: "DELETE FROM workspace_settings WHERE key=?", arguments: [key])
  }
}
extension AtlasStore {
  static func readCanvasDraft(_ db: Database, id: String) throws -> CanvasQuestionDraft? {
    guard
      let raw = try String.fetchOne(
        db, sql: "SELECT value_json FROM workspace_settings WHERE key=?",
        arguments: ["canvas.question." + id])
    else { return nil }
    return try JSONDecoder().decode(CanvasQuestionDraft.self, from: Data(raw.utf8))
  }
  public func canvasDrafts() throws -> [CanvasQuestionDraft] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql:
          "SELECT value_json FROM workspace_settings WHERE key LIKE 'canvas.question.%' ORDER BY updated_at DESC,rowid DESC"
      ).map { try JSONDecoder().decode(CanvasQuestionDraft.self, from: Data($0.utf8)) }
    }
  }
  /// Capture at the user's ask gesture, including a still-streaming selection.
  public func beginCanvasQuestion(
    x: Double, y: Double, sourcePlacementID: String? = nil, regionID: String? = nil,
    anchor: PDFAnchor? = nil, excerpt: AnswerExcerpt? = nil, reference: String? = nil,
    relationVersion: String? = nil, markdown: (version: String, selection: [WritingSelection])? = nil
  ) throws -> CanvasQuestionDraft {
    guard x.isFinite, y.isFinite, abs(x) < 1e12, abs(y) < 1e12,
      [anchor != nil, excerpt != nil, reference != nil, relationVersion != nil, markdown != nil].filter({ $0 }).count
        <= 1
    else { throw AtlasStoreError.invalid("画布位置或来源无效。") }
    if let anchor { try validate(anchor) }
    return try database.write { db in
      var frozen = reference
      if let relationVersion {
        frozen = try Self.freezeCanvasRelation(db, version: relationVersion)
      }
      if let excerpt { frozen = try Self.freezeAnswer(db, run: excerpt.runID, excerpt: excerpt) }
      if let anchor { frozen = try Self.freezePDF(db, anchor: anchor) }
      if let markdown { frozen = try Self.insertMarkdownReference(db, versionID: markdown.version, selection: markdown.selection) }
      var quote: String?
      if let frozen {
        guard
          let row = try Row.fetchOne(
            db, sql: "SELECT quote_snapshot FROM reference_snapshot WHERE id=?", arguments: [frozen]
          )
        else { throw AtlasStoreError.invalid("找不到引用。") }
        quote = row["quote_snapshot"]
      }
      var topic: String?
      if let regionID {
        topic = try String.fetchOne(
          db, sql: "SELECT topic_id FROM region WHERE id=? AND view_id='atlas'",
          arguments: [regionID])
      }
      let value = CanvasQuestionDraft(
        id: UUID().uuidString, sourcePlacementID: sourcePlacementID, referenceID: frozen,
        quote: quote, regionID: regionID, topicID: topic, x: x, y: y, text: "")
      try db.execute(
        sql: "INSERT INTO workspace_settings VALUES (?,?,1,?)",
        arguments: [
          value.key, String(decoding: try JSONEncoder().encode(value), as: UTF8.self),
          Date.now.ISO8601Format(),
        ])
      return value
    }
  }
  public func addCanvasMaterial(_ material: CanvasMaterial, to draft: CanvasQuestionDraft) throws
    -> CanvasQuestionDraft
  {
    if case .pdf(let anchor) = material { try validate(anchor) }
    return try database.write { db in
      let ref: String
      switch material {
      case .pdf(let anchor): ref = try Self.freezePDF(db, anchor: anchor)
      case .answer(let excerpt):
        ref = try Self.freezeAnswer(db, run: excerpt.runID, excerpt: excerpt)
      case let .markdown(version, selection): ref = try Self.insertMarkdownReference(db, versionID: version, selection: selection)
      }
      let citation = try Self.citation(db, reference: ref)
      for existing in draft.citations.map(\.id) + [draft.referenceID].compactMap({ $0 }) {
        if try Self.sameCanvasPassage(db, existing, ref) {
          throw AtlasStoreError.invalid("本题已引用这段原文。")
        }
      }
      var next = draft
      next.extraCitations = draft.citations + [citation]
      return try Self.updateCanvasDraft(db, draft, to: next)
    }
  }
  public func removeCanvasMaterial(_ reference: String, from draft: CanvasQuestionDraft) throws
    -> CanvasQuestionDraft
  {
    var next = draft
    let kept = draft.citations.filter { $0.id != reference }
    next.extraCitations = kept.isEmpty ? nil : kept
    return try updateCanvasDraft(draft, to: next)
  }
  public func editCanvasQuestion(_ draft: CanvasQuestionDraft, text: String) throws
    -> CanvasQuestionDraft
  {
    var next = draft
    next.text = text
    return try updateCanvasDraft(draft, to: next)
  }
  public func setCanvasTopic(_ draft: CanvasQuestionDraft, topicID: String?) throws
    -> CanvasQuestionDraft
  {
    var next = draft
    next.topicID = topicID
    if topicID != draft.topicID { next.regionID = nil }
    return try updateCanvasDraft(draft, to: next)
  }
  /// A local question has its own editable versions, without starting a generation run.
  public func keepCanvasQuestion(_ draft: CanvasQuestionDraft) throws -> WritingItem {
    try database.write { db in
      let stamp = writingDate(), checksum = try draft.payload()
      if let receipt = try Row.fetchOne(db, sql: "SELECT * FROM command_receipt WHERE request_id=?", arguments: [draft.id]) {
        guard receipt["command_type"] as String == "manual_question", receipt["payload_sha256"] as String == checksum else {
          throw AtlasStoreError.invalid("这份草稿已另行提交。")
        }
        let id = try JSONDecoder().decode(String.self, from: Data((receipt["result_json"] as String).utf8))
        return try Self.writing(id, db: db)
      }
      guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            try Self.readCanvasDraft(db, id: draft.id) == draft else {
        throw AtlasStoreError.invalid("问题为空或草稿已改变。")
      }
      let id = writingID()
      try db.execute(sql: "INSERT INTO content_node(id,kind,title,created_at) VALUES (?,'question',?,?)",
                     arguments: [id, String(draft.text.prefix(60)), stamp])
      let version = try Self.addVersion(db, node: id, text: draft.text, isUser: true, complete: true)
      for ref in Set(draft.citations.map(\.id) + [draft.referenceID].compactMap { $0 }) {
        try db.execute(sql: "INSERT INTO node_origin VALUES (?,?,'interpretation')", arguments: [version, ref])
      }
      let entries = try Self.mapEntries(db)
      let dimension = CanvasFootprint.question
      let point = CanvasFootprint.available(near: .init(x: draft.x, y: draft.y), size: dimension,
                                             obstacles: entries.map { CanvasFootprint.reserved($0) }, viewport: dimension)
      try Self.placeNewMaterial(db, kind: "content", target: id, at: point)
      let placement = "map.content." + id
      try db.execute(sql: "UPDATE placement SET parent_region_id=? WHERE id=?", arguments: [draft.regionID, placement])
      if let topic = draft.topicID {
        try db.execute(sql: "INSERT INTO topic_membership(id,topic_id,target_kind,content_id) VALUES (?,?,'content',?)", arguments: [writingID(), topic, id])
      }
      if let parent = draft.sourcePlacementID, let ref = draft.referenceID,
         let source = entries.first(where: { $0.id == parent }) {
        let trace = ["parent": parent, "parentTarget": source.target, "child": placement, "target": id, "reference": ref]
        try db.execute(sql: "INSERT INTO workspace_settings VALUES (?,?,1,?)",
                       arguments: ["manual.question.source." + id, try writingJSON(trace), stamp])
      }
      try db.execute(sql: "INSERT INTO command_receipt VALUES (?,'manual_question',?,?,?)",
                     arguments: [draft.id, checksum, try writingJSON(id), stamp])
      try db.execute(sql: "INSERT INTO index_outbox(entity_kind,entity_id,version_id,operation,created_at) VALUES ('content',?,?,'upsert',?)",
                     arguments: [id,version,stamp])
      try db.execute(sql: "DELETE FROM workspace_settings WHERE key=?", arguments: [draft.key])
      return try Self.writing(id, db: db)
    }
  }
  public func discardCanvasDraft(_ draft: CanvasQuestionDraft) throws {
    try database.write { db in
      guard try Self.readCanvasDraft(db, id: draft.id) == draft else {
        throw AtlasStoreError.invalid("草稿已改变。")
      }
      try db.execute(sql: "DELETE FROM workspace_settings WHERE key=?", arguments: [draft.key])
    }
  }
  private func updateCanvasDraft(_ draft: CanvasQuestionDraft, to next: CanvasQuestionDraft) throws
    -> CanvasQuestionDraft
  {
    try database.write { db in try Self.updateCanvasDraft(db, draft, to: next) }
  }
  private static func updateCanvasDraft(
    _ db: Database, _ draft: CanvasQuestionDraft, to next: CanvasQuestionDraft
  ) throws -> CanvasQuestionDraft {
    guard try Self.readCanvasDraft(db, id: draft.id) == draft else {
      throw AtlasStoreError.invalid("草稿已改变，请重新打开。")
    }
    try db.execute(
      sql:
        "UPDATE workspace_settings SET value_json=?,revision=revision+1,updated_at=? WHERE key=?",
      arguments: [
        String(decoding: try JSONEncoder().encode(next), as: UTF8.self), Date.now.ISO8601Format(),
        draft.key,
      ])
    return next
  }
}
