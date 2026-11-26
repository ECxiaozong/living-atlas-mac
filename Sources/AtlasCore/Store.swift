import Darwin
import Foundation
import GRDB
import PDFKit

public struct AtlasPDF: Identifiable, Equatable, Sendable {
  public let id: String
  public let versionID: String
  public let ordinal: Int
  public let title: String
  public let sourceSHA256: String
  public let url: URL
}

public struct AtlasDraft: Codable, Equatable, Sendable {
  public let text: String
  public let anchor: PDFAnchor?
  public let referenceID: String?
  public let excerpt: AnswerExcerpt?
  public init(
    text: String = "", anchor: PDFAnchor? = nil, excerpt: AnswerExcerpt? = nil,
    referenceID: String? = nil
  ) {
    self.referenceID = referenceID
    self.excerpt = excerpt
    self.text = text
    self.anchor = anchor
  }
}

public enum AtlasRunStatus: String, Codable, Sendable {
  case queued, preparing, streaming, completed, cancelled, failed, interrupted
  public var isActive: Bool { self == .queued || self == .preparing || self == .streaming }
}

public struct AtlasRun: Identifiable, Equatable, Sendable {
  public let id: String
  public let turnID: String
  public let question: String
  public let answer: String
  public let status: AtlasRunStatus
  public let anchor: PDFAnchor?
  public let sourceReferenceID: String?
  public let sourceQuote: String?
  public let extraCitationCount: Int
  public let parentAnswer: String?
  public let parentVersionID: String?
  public let parentRunID: String?
  public let retryOf: String?
  /// Answer-version ordinal. Runs without any output have no answer version.
  public let version: Int?
  public let versionID: String?
  public let reason: String?
  public let provider: String?
  public let model: String?
}

private func uid() -> String { UUID().uuidString.lowercased() }
private func now() -> String {
  Date.now.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
}
private func json<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}
private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(text.utf8))
}

// The process that owns this directory reconciles incomplete runs on open. A second window
// must use that same store; it cannot interrupt work still owned by another process.
private final class WorkspaceLease: Sendable {
  let fd: Int32
  init(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw AtlasStoreError.invalid("项目正在另一个窗口或进程中使用。")
    }
    fd = descriptor
  }
  deinit { Darwin.close(fd) }
}

public final class AtlasStore: Sendable {
  public let directory: URL
  public let workspaceID: String
  let recoveryLock = NSRecursiveLock()
  let pdfPasswords = PDFUnlockSession()
  let database: DatabaseQueue
  private let lease: WorkspaceLease

  public init(directory: URL, title: String = "未命名 Atlas") throws {
    let root = directory.standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lease = try WorkspaceLease(root)
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.prepareDatabase { db in
      try db.execute(
        sql: "PRAGMA synchronous = FULL; PRAGMA recursive_triggers = ON; PRAGMA busy_timeout = 5000"
      )
    }
    let queue = try DatabaseQueue(
      path: root.appendingPathComponent("workspace.sqlite").path, configuration: config)
    try queue.writeWithoutTransaction { db in
      if !(try db.tableExists("schema_meta")) {
        guard
          try Int.fetchOne(
            db, sql: "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0,
          let schema = Bundle.module.url(forResource: "schema", withExtension: "sql")
        else {
          throw AtlasStoreError.invalid("该数据库无法识别，现有内容已保留。")
        }
        try db.execute(sql: String(contentsOf: schema, encoding: .utf8))
      }
      guard
        try Int.fetchOne(
          db,
          sql:
            "SELECT schema_version FROM schema_meta WHERE singleton=1 AND application_id='living-atlas'"
        ) == 1
      else {
        throw AtlasStoreError.invalid("此项目版本不兼容。")
      }
    }
    let id = try queue.write { db in
      if let existing = try String.fetchOne(db, sql: "SELECT id FROM workspace WHERE singleton=1") {
        return existing
      }
      let id = uid()
      try db.execute(
        sql: "INSERT INTO workspace(id,title,created_at,updated_at) VALUES (?,?,?,?)",
        arguments: [id, title, now(), now()])
      return id
    }
    for folder in ["assets", "tmp", "cache"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    self.directory = root
    self.workspaceID = id
    self.database = queue
    self.lease = lease
    try queue.write { db in
      try Self.restoreOrganizationRelationEntrances(db)
      for id in try String.fetchAll(
        db, sql: "SELECT id FROM generation_run WHERE status IN ('queued','preparing','streaming')")
      {
        try Self.finalize(db, id: id, status: .interrupted, reason: "interrupted")
      }
    }
  }

  // Saving an unattached composer must never create a question node.
  public func saveDraft(
    _ text: String, anchor: PDFAnchor? = nil, excerpt: AnswerExcerpt? = nil,
    referenceID: String? = nil
  ) throws {
    if let anchor, try loadDraft().anchor != anchor { try validate(anchor) }
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO workspace_settings(key,value_json,revision,updated_at) VALUES ('question_composer',?,1,?)
          ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, revision=revision+1, updated_at=excluded.updated_at
          """,
        arguments: [
          try json(
            AtlasDraft(text: text, anchor: anchor, excerpt: excerpt, referenceID: referenceID)),
          now(),
        ])
    }
  }

  public func loadDraft() throws -> AtlasDraft {
    try database.read { db in
      guard
        let raw = try String.fetchOne(
          db, sql: "SELECT value_json FROM workspace_settings WHERE key='question_composer'")
      else { return AtlasDraft() }
      return try decode(AtlasDraft.self, raw)
    }
  }

  public func start(
    question: String, anchor: PDFAnchor? = nil, following: String? = nil,
    excerpt: AnswerExcerpt? = nil, referenceID: String? = nil, provider: String? = nil,
    model: String? = nil, requestProfile: ProviderProfile? = nil, canvas: CanvasQuestionDraft? = nil
  ) throws -> AtlasRun {
    guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AtlasStoreError.invalid("请先输入问题。")
    }
    if let anchor { try validate(anchor) }
    return try database.write { db in
      if let canvas {
        guard question == canvas.text, anchor == nil, following == nil, excerpt == nil,
          referenceID == canvas.referenceID else { throw AtlasStoreError.invalid("画布草稿和提交内容不一致。") }
        if let prior = try canvas.previousRun(db) { return try Self.readRun(db, id:prior) }
        guard try Self.readCanvasDraft(db, id:canvas.id) == canvas else {
          throw AtlasStoreError.invalid("画布草稿已改变，请重新打开后提交。")
        }
      }
      let questionNode = uid()
      let answerNode = uid()
      let turn = uid()
      let stamp = now()
      try db.execute(
        sql: "INSERT INTO content_node(id,kind,created_at) VALUES (?,'question',?),(?,'answer',?)",
        arguments: [questionNode, stamp, answerNode, stamp])
      let version = try Self.addVersion(
        db, node: questionNode, text: question, isUser: true, complete: true)
      try db.execute(
        sql:
          "INSERT INTO inquiry_turn(id,question_node_id,question_version_id,answer_node_id,created_at) VALUES (?,?,?,?,?)",
        arguments: [turn, questionNode, version, answerNode, stamp])
      if let excerpt, let following, following != excerpt.runID {
        throw AtlasStoreError.invalid("追问选区与父回答不符。")
      }
      let parent = excerpt?.runID ?? following
      if let parent {
        let ref = try Self.freezeAnswer(db, run:parent, excerpt:excerpt)
        try db.execute(sql:"INSERT INTO inquiry_reference VALUES (?,?,'actual_trigger',0)",arguments:[turn,ref])
      }
      if let anchor {
        try Self.bind(
          db, anchor: anchor, turn: turn,
          role: parent == nil ? "actual_trigger" : "explicit_reference")
      }
      if let referenceID {
        guard anchor == nil,
          try String.fetchOne(
            db,
            sql:
              "SELECT id FROM reference_snapshot WHERE id=? AND (quote_snapshot IS NOT NULL OR EXISTS(SELECT 1 FROM source_anchor WHERE reference_id=reference_snapshot.id AND selector_type='page'))",
            arguments: [referenceID]) != nil
        else { throw AtlasStoreError.invalid("引用的材料不可读。") }
        try db.execute(
          sql: "INSERT INTO inquiry_reference(turn_id,reference_id,role,ordinal) VALUES (?,?,?,0)",
          arguments: [turn, referenceID, parent == nil ? "actual_trigger" : "explicit_reference"])
      }
      // Ordinal zero is reserved for the single-source paths in existing workspaces.
      for (index, material) in (canvas?.citations ?? []).enumerated() {
        try db.execute(sql: "INSERT INTO inquiry_reference VALUES (?,?,'explicit_reference',?)",
          arguments: [turn, material.id, index + 1])
      }
      let run = try Self.createRun(
        db, turn: turn, node: answerNode, previous: nil, provider: provider, model: model)
      if let requestProfile { try Self.freezeRequest(db, run: run, profile: requestProfile) }
      if let canvas {
        try canvas.placeQuestion(db, turn:turn, run:run)
        return try Self.readRun(db, id:run)
      }
      try db.execute(
        sql: "DELETE FROM workspace_settings WHERE key='question_composer' AND value_json=?",
        arguments: [
          try json(
            AtlasDraft(text: question, anchor: anchor, excerpt: excerpt, referenceID: referenceID))
        ])
      return try Self.readRun(db, id: run)
    }
  }

  public func retry(
    _ runID: String, provider: String? = nil, model: String? = nil,
    requestProfile: ProviderProfile? = nil, reusingContext: Bool = true
  ) throws
    -> AtlasRun
  {
    try database.write { db in
      let old = try Self.readRun(db, id: runID)
      if old.status.isActive { return old }
      if let existing = try String.fetchOne(
        db,
        sql: """
          SELECT id FROM generation_run WHERE turn_id=? AND status IN ('queued','preparing','streaming') ORDER BY rowid DESC LIMIT 1
          """,
        arguments: [old.turnID])
      {
        return try Self.readRun(db, id: existing)
      }
      guard
        let node = try String.fetchOne(
          db, sql: "SELECT answer_node_id FROM inquiry_turn WHERE id=?", arguments: [old.turnID])
      else { throw AtlasStoreError.invalid("问题不存在。") }
      let id = try Self.createRun(
        db, turn: old.turnID, node: node, previous: runID, provider: provider ?? old.provider,
        model: model ?? old.model)
      if let requestProfile {
        let prior = try Row.fetchOne(db, sql: """
          SELECT config_json,material_manifest_json,policy_revision_at_start,
            json_extract(config_json,'$.profile') AS profile, json_type(config_json,'$.request_body') AS frozen,
            json_type(config_json,'$.cli_input') AS cli FROM generation_run WHERE id=?
          """, arguments: [old.id])
        if reusingContext {
          guard let prior, let raw: String = prior["profile"], let manifest: String = prior["material_manifest_json"],
            prior["frozen"] as String? == "text", !requestProfile.isCodexCLI || prior["cli"] as String? == "object"
          else { throw AtlasStoreError.invalid("这次历史运行未保存完整的模型输入，请选择「按当前范围重新回答」。") }
          guard try JSONDecoder().decode(ProviderProfile.self, from: Data(raw.utf8)) == requestProfile,
            try Int.fetchOne(db, sql: "SELECT policy_revision_at_start FROM generation_run WHERE id=?", arguments: [id]) == prior["policy_revision_at_start"] as Int
          else { throw AtlasStoreError.invalid("模型或材料权限已变更，请选择「按当前范围重新回答」。") }
          try db.execute(sql: """
            UPDATE generation_run SET config_json=json_remove(?,'$.metrics'),material_manifest_json=json_set(?, '$.run_id',id,
              '$.request_attempt_id',request_id,'$.manifest_id',?,'$.created_at',started_at) WHERE id=?
            """, arguments: [prior["config_json"] as String, manifest, uid(), id])
        } else { try Self.freezeRequest(db, run: id, profile: requestProfile) }
      }
      return try Self.readRun(db, id: id)
    }
  }

  private static func createRun(
    _ db: Database, turn: String, node: String, previous: String?, provider: String?, model: String?
  ) throws -> String {
    let id = uid()
    try db.execute(
      sql: """
        INSERT INTO generation_run(id,turn_id,answer_node_id,request_id,retry_of_run_id,status,stage,provider_id,model_id,started_at,policy_revision_at_start)
        SELECT ?,?,?,?,?,'preparing','waiting',?,?,?,policy_revision FROM workspace WHERE singleton=1
        """, arguments: [id, turn, node, uid(), previous, provider, model, now()])
    try db.execute(
      sql:
        "INSERT INTO draft(id,owner_kind,generation_run_id,edit_serial,body_text,saved_at) VALUES (?,'generation',?,0,'',?)",
      arguments: [uid(), id, now()])
    return id
  }

  @discardableResult public func append(_ delta: String, to runID: String) throws -> Bool {
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE draft SET body_text=body_text||?,edit_serial=edit_serial+1,saved_at=?
          WHERE generation_run_id=? AND EXISTS (SELECT 1 FROM generation_run WHERE id=? AND status IN ('queued','preparing','streaming'))
          """, arguments: [delta, now(), runID, runID])
      guard db.changesCount == 1 else { return false }
      if !delta.isEmpty {
        try db.execute(
          sql:
            """
            UPDATE generation_run SET status='streaming',stage='receiving',output_completeness='partial',
              config_json=CASE WHEN stage='receiving' THEN config_json ELSE json_set(config_json,'$.metrics.first_content_latency_ms',
                max(0,round((julianday('now')-julianday(started_at))*86400000))) END WHERE id=?
            """,
          arguments: [runID])
      }
      return true
    }
  }

  @discardableResult public func finish(
    _ runID: String, status: AtlasRunStatus, reason: String? = nil
  ) throws -> AtlasRun {
    guard !status.isActive else { throw AtlasStoreError.invalid("结束生成时必须提供终止状态。") }
    return try database.write { db in
      try Self.finalize(db, id: runID, status: status, reason: reason)
      return try Self.readRun(db, id: runID)
    }
  }

  private static func finalize(_ db: Database, id: String, status: AtlasRunStatus, reason: String?)
    throws
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT r.status,r.answer_node_id,d.body_text FROM generation_run r LEFT JOIN draft d ON d.generation_run_id=r.id WHERE r.id=?",
        arguments: [id]),
      let existing = AtlasRunStatus(rawValue: row["status"])
    else { throw AtlasStoreError.invalid("没有这次生成记录。") }
    guard existing.isActive else { return }
    let text: String = row["body_text"] ?? ""
    let final: AtlasRunStatus = text.isEmpty && status == .completed ? .failed : status
    let why =
      reason
      ?? ([
        AtlasRunStatus.cancelled: "user_cancel", .completed: "stop", .interrupted: "interrupted",
        .failed: text.isEmpty ? "no_output" : "stream_error",
      ][final])
    let complete = final == .completed && why != "output_limit" && why != "length"
    let version =
      text.isEmpty
      ? nil
      : try Self.addVersion(
        db, node: row["answer_node_id"], text: text, isUser: false, complete: complete)
    try db.execute(
      sql: """
        UPDATE generation_run SET status=?,output_completeness=?,terminal_reason=?,stage='ended',answer_version_id=?,ended_at=?,
        config_json=json_set(config_json,'$.metrics.total_latency_ms',max(0,round((julianday('now')-julianday(started_at))*86400000))) WHERE id=?
        """,
      arguments: [
        final.rawValue, text.isEmpty ? "none" : complete ? "complete" : "partial", why, version,
        now(), id,
      ])
    try db.execute(sql: "DELETE FROM draft WHERE generation_run_id=?", arguments: [id])
  }

  static func addVersion(
    _ db: Database, node: String, text: String, isUser: Bool, complete: Bool,
    makeCurrent: Bool = true
  ) throws -> String {
    let id = uid()
    try db.execute(
      sql: """
        INSERT INTO content_version(id,node_id,ordinal,body_markdown,plain_text,body_sha256,origin_kind,completion,actor_kind,created_at,supersedes_version_id)
        SELECT ?,n.id,1+COALESCE((SELECT max(ordinal) FROM content_version WHERE node_id=n.id),0),?,?,?,?,?,?,?,n.current_version_id
        FROM content_node n WHERE n.id=?
        """,
      arguments: [
        id, text, text, atlasHash(Data(text.utf8)), isUser ? "user" : "ai",
        complete ? "complete" : "partial", isUser ? "user" : "ai", now(), node,
      ])
    guard makeCurrent else { return id }
    try db.execute(
      sql:
        "UPDATE content_node SET current_version_id=?,content_revision=content_revision+1 WHERE id=?",
      arguments: [id, node])
    return id
  }

  public func runs() throws -> [AtlasRun] {
    try database.read { db in
      try String.fetchAll(db, sql: "SELECT g.id FROM generation_run g JOIN inquiry_turn t ON t.id=g.turn_id JOIN content_node q ON q.id=t.question_node_id WHERE q.deleted_at IS NULL ORDER BY g.rowid DESC").map {
        try Self.readRun(db, id: $0)
      }
    }
  }

  public func run(_ id: String) throws -> AtlasRun {
    try database.read { db in try Self.readRun(db, id: id) }
  }

  private static func readRun(_ db: Database, id: String) throws -> AtlasRun {
    guard
      let r = try Row.fetchOne(
        db,
        sql: """
          SELECT r.*,(SELECT count(*) FROM inquiry_reference i WHERE i.turn_id=t.id AND i.role='explicit_reference' AND i.ordinal>=1) AS additional_count,q.body_markdown AS question, COALESCE(v.body_markdown,d.body_text,'') AS answer,v.ordinal AS ordinal
          FROM generation_run r JOIN inquiry_turn t ON t.id=r.turn_id JOIN content_version q ON q.id=t.question_version_id
          LEFT JOIN content_version v ON v.id=r.answer_version_id LEFT JOIN draft d ON d.generation_run_id=r.id WHERE r.id=?
          """, arguments: [id]), let status = AtlasRunStatus(rawValue: r["status"])
    else { throw AtlasStoreError.invalid("无法读取这次生成。") }
    let turn: String = r["turn_id"]
    let source = try Row.fetchOne(
      db,
      sql: """
        SELECT s.quote_snapshot,s.content_version_id,json_extract(a.geometry_json,'$.parentRunID') AS parent_run
        FROM inquiry_reference i JOIN reference_snapshot s ON s.id=i.reference_id
        JOIN source_anchor a ON a.reference_id=s.id WHERE i.turn_id=? AND i.role='actual_trigger' AND s.source_kind='content'
        """, arguments: [turn])
    let explicit = try Row.fetchOne(
      db,
      sql: """
        SELECT s.id,s.quote_snapshot FROM inquiry_reference i JOIN reference_snapshot s ON s.id=i.reference_id
        WHERE i.turn_id=? AND i.ordinal=0 AND NOT EXISTS (SELECT 1 FROM source_anchor a WHERE a.reference_id=s.id AND
        (a.selector_type='pdf_rects' OR json_extract(a.geometry_json,'$.parentRunID') IS NOT NULL)) ORDER BY i.ordinal LIMIT 1
        """, arguments: [turn])
    return AtlasRun(
      id: id, turnID: r["turn_id"], question: r["question"], answer: r["answer"], status: status,
      anchor: try readAnchor(db, turn: turn), sourceReferenceID: explicit?["id"],
      sourceQuote: explicit?["quote_snapshot"], extraCitationCount: r["additional_count"], parentAnswer: source?["quote_snapshot"],
      parentVersionID: source?["content_version_id"], parentRunID: source?["parent_run"],
      retryOf: r["retry_of_run_id"], version: r["ordinal"],
      versionID: r["answer_version_id"], reason: r["terminal_reason"], provider: r["provider_id"],
      model: r["model_id"])
  }

  static func freezeAnswer(
    _ db: Database, run: String, excerpt: AnswerExcerpt?
  ) throws -> String {
    let parent = try readRun(db, id: run)
    guard !parent.answer.isEmpty else { throw AtlasStoreError.invalid("原回答尚无文字，无法作为追问依据。") }
    let body = excerpt?.body ?? parent.answer
    guard parent.answer.utf8.starts(with: body.utf8), !body.isEmpty,
      excerpt == nil || excerpt?.quote != nil
    else {
      throw AtlasStoreError.invalid("选区不属于这次回答，请重新选择。")
    }
    let quote = excerpt?.quote ?? body
    let digest = atlasHash(Data(body.utf8))
    var version = body.utf8.elementsEqual(parent.answer.utf8) ? parent.versionID : nil
    if version == nil {
      // Freeze only what was visible at submission. A later checkpoint or retry has a separate identity.
      version = try String.fetchOne(
        db,
        sql: """
          SELECT s.content_version_id FROM reference_snapshot s JOIN source_anchor a ON a.reference_id=s.id
          JOIN content_version v ON v.id=s.content_version_id WHERE v.body_sha256=? AND json_extract(a.geometry_json,'$.parentRunID')=? LIMIT 1
          """, arguments: [digest, run])
      if version == nil {
        guard
          let node = try String.fetchOne(
            db, sql: "SELECT answer_node_id FROM generation_run WHERE id=?", arguments: [run])
        else {
          throw AtlasStoreError.invalid("原运行不存在。")
        }
        version = try addVersion(
          db, node: node, text: body, isUser: false, complete: false, makeCurrent: false)
      }
    }
    let ref = uid()
    try db.execute(
      sql:
        "INSERT INTO reference_snapshot(id,source_kind,content_version_id,quote_snapshot,created_at) VALUES (?,'content',?,?,?)",
      arguments: [ref, version, quote, now()])
    try db.execute(
      sql: """
        INSERT INTO source_anchor(id,reference_id,segment_order,selector_type,offset_unit,start_offset,end_offset,geometry_json,text_sha256)
        VALUES (?,?,0,?,'unicode_code_points',?,?,?,?)
        """,
      arguments: [
        uid(), ref, excerpt == nil ? "whole" : "text", excerpt?.start ?? 0,
        excerpt?.end ?? body.unicodeScalars.count, try json(["parentRunID": run]),
        atlasHash(Data(quote.utf8)),
      ])
    return ref
  }

  private static func bind(_ db: Database, anchor: PDFAnchor, turn: String, role: String) throws {
    let ref = try freezePDF(db, anchor:anchor)
    try db.execute(sql:"INSERT INTO inquiry_reference VALUES (?,?,?,0)",arguments:[turn,ref,role])
  }
  static func freezePDF(_ db: Database, anchor:PDFAnchor) throws -> String {
    let ref = uid()
    try db.execute(
      sql:
        "INSERT INTO reference_snapshot(id,source_kind,document_version_id,quote_snapshot,created_at) VALUES (?,'document',?,?,?)",
      arguments: [ref, anchor.versionID, anchor.quote, now()])
    for (i, s) in anchor.segments.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO source_anchor(id,reference_id,segment_order,page_index,selector_type,offset_unit,start_offset,end_offset,prefix,suffix,geometry_json,text_sha256)
          VALUES (?,?,?,?,'pdf_rects','unicode_code_points',?,?,?,?,?,?)
          """,
        arguments: [
          uid(), ref, i, s.pageIndex, s.start, s.end, s.prefix, s.suffix, try json(s), s.textSHA256,
        ])
    }
    return ref
  }

  private static func readAnchor(_ db: Database, turn: String) throws -> PDFAnchor? {
    guard
      let r = try Row.fetchOne(
        db,
        sql: """
          SELECT s.id,s.quote_snapshot,s.document_version_id FROM inquiry_reference i JOIN reference_snapshot s ON s.id=i.reference_id
          WHERE i.turn_id=? AND s.source_kind='document' AND EXISTS(SELECT 1 FROM source_anchor a WHERE a.reference_id=s.id AND a.selector_type='pdf_rects') AND i.ordinal=0 AND i.role IN ('actual_trigger','explicit_reference') ORDER BY i.role='actual_trigger' DESC LIMIT 1
          """, arguments: [turn])
    else { return nil }
    return try pdfAnchor(db, reference: r)
  }
  static func pdfAnchor(_ db: Database, reference r: Row) throws -> PDFAnchor {
    let ref: String = r["id"]
    let data = try String.fetchAll(
      db,
      sql: "SELECT geometry_json FROM source_anchor WHERE reference_id=? ORDER BY segment_order",
      arguments: [ref])
    return PDFAnchor(
      versionID: r["document_version_id"], quote: r["quote_snapshot"],
      segments: try data.map { try decode(PDFAnchor.Segment.self, $0) })
  }

  public func importPDF(at source: URL, updating documentID: String? = nil, password: String? = nil,
    canvasOrigin: CGPoint? = nil, deferPlacement: Bool = false)
    throws -> AtlasPDF
  {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let bytes = try Data(contentsOf: source)
    let hash = atlasHash(bytes)
    let parsed = try Self.unlockedDocument(
      PDFDocument(data: bytes), password: password ?? pdfPasswords.password(for: hash))
    let asset = try stageAsset(bytes, mime: "application/pdf", digest: hash)
    let versionID = try database.write { db -> String in
      let doc = documentID ?? uid()
      let version = uid()
      let stamp = now()
      if let documentID {
        guard
          let existing = try Row.fetchOne(
            db,
            sql: """
              SELECT v.id,v.original_asset_sha256 FROM document d JOIN document_version v ON d.current_version_id=v.id
              WHERE d.id=? AND d.kind='pdf' AND d.deleted_at IS NULL
              """, arguments: [documentID])
        else { throw AtlasStoreError.invalid("待更新的 PDF 不存在。") }
        let oldHash: String = existing["original_asset_sha256"]
        if oldHash == hash { return existing["id"] }
      } else {
        try db.execute(
          sql: "INSERT INTO document(id,kind,title,created_at) VALUES (?,'pdf',?,?)",
          arguments: [doc, source.lastPathComponent, stamp])
        if deferPlacement {
          try db.execute(sql: "INSERT INTO workspace_settings VALUES (?, 'true', 1, ?)", arguments: ["map.seed.map.document." + doc, stamp])
        }
        if let canvasOrigin, !deferPlacement { try Self.placeNewMaterial(db, kind: "document", target: doc, at: canvasOrigin) }
      }
      try asset.register(db)
      let ordinal =
        (try Int.fetchOne(
          db, sql: "SELECT MAX(ordinal) FROM document_version WHERE document_id=?", arguments: [doc]
        ) ?? 0) + 1
      let title =
        try String.fetchOne(db, sql: "SELECT title FROM document WHERE id=?", arguments: [doc])
        ?? source.lastPathComponent
      let metadata = try json([
        "document_title": title, "original_filename": source.lastPathComponent,
        "extractor": "PDFKit", "normalization": "lf-v1", "offset_unit": "unicode_code_points",
      ])
      try db.execute(
        sql:
          "INSERT INTO document_version(id,document_id,ordinal,original_asset_sha256,renderer_version,source_metadata_json,created_at) VALUES (?,?,?,?,'PDFKit',?,?)",
        arguments: [version, doc, ordinal, hash, metadata, stamp])
      try db.execute(
        sql: "UPDATE document SET current_version_id=?, revision=? WHERE id=?",
        arguments: [version, ordinal, doc])
      return version
    }
    if parsed.isEncrypted, let password { pdfPasswords.remember(password, for: hash) }
    return try pdf(versionID: versionID)
  }

  public func pdfs() throws -> [AtlasPDF] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT d.id,d.title,v.id AS vid,v.ordinal,v.original_asset_sha256 AS digest FROM document d
          JOIN document_version v ON v.id=d.current_version_id WHERE d.kind='pdf' AND d.deleted_at IS NULL ORDER BY d.rowid DESC
          """
      ).map { try pdfRow($0) }
    }
  }

  public func pdfVersions(documentID: String) throws -> [AtlasPDF] {
    try database.read { db in
      try Row.fetchAll(db, sql: """
        SELECT d.id, COALESCE(json_extract(v.source_metadata_json,'$.document_title'),d.title) AS title,
               v.id AS vid, v.ordinal, v.original_asset_sha256 AS digest
        FROM document_version v JOIN document d ON d.id=v.document_id
        WHERE d.id=? AND d.kind='pdf' AND d.deleted_at IS NULL ORDER BY v.ordinal DESC
        """, arguments: [documentID]).map { try pdfRow($0) }
    }
  }

  public func pdfInfo(versionID: String) throws -> AtlasPDF {
    try database.read { db -> AtlasPDF in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT d.id,COALESCE(json_extract(v.source_metadata_json,'$.document_title'),d.title) AS title,
                   v.id AS vid,v.ordinal,v.original_asset_sha256 AS digest FROM document_version v
            JOIN document d ON d.id=v.document_id WHERE v.id=? AND d.kind='pdf'
            """, arguments: [versionID])
      else { throw AtlasStoreError.invalid("找不到这份 PDF 的历史版本。") }
      return try pdfRow(row)
    }
  }

  public func pdf(versionID: String) throws -> AtlasPDF {
    let result = try pdfInfo(versionID: versionID)
    _ = try verifiedPDFBytes(result)
    return result
  }

  func verifiedPDFBytes(_ file: AtlasPDF) throws -> Data {
    let data: Data
    do { data = try Data(contentsOf: file.url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      throw AtlasStoreError.invalid("找不到此版本保存的 PDF 原件。")
    }
    guard atlasHash(data) == file.url.lastPathComponent else {
      throw AtlasStoreError.invalid("历史原件实际内容与记录不一致。")
    }
    return data
  }

  private func pdfRow(_ row: Row) throws -> AtlasPDF {
    let hash: String = row["digest"]
    guard hash.utf8.count == 64,
      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      throw AtlasStoreError.invalid("资产记录缺少合法的 SHA-256。")
    }
    return AtlasPDF(
      id: row["id"], versionID: row["vid"], ordinal: row["ordinal"], title: row["title"], sourceSHA256: hash,
      url: directory.appendingPathComponent("assets/\(hash.prefix(2))/\(hash)"))
  }

  func validate(_ anchor: PDFAnchor) throws {
    let pdf = try pdf(versionID: anchor.versionID)
    let document = try readablePDF(pdf)
    _ = try anchor.selection(in: document)
  }
}
