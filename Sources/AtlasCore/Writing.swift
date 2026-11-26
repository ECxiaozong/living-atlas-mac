import Foundation
import GRDB

extension Notification.Name {
  public static let atlasWritingChanged = Notification.Name("LivingAtlas.writingChanged")
}

public enum WritingKind: String, Sendable {
  case idea, markdown, question
  public var label: String {
    switch self { case .idea: return "灵感"; case .markdown: return "Markdown"; case .question: return "问题" }
  }
}

public struct WritingItem: Identifiable, Equatable, Sendable {
  public let id: String
  public let kind: WritingKind
  public let title: String
  public let currentVersionID: String?
  public let draft: String?
  public let editSerial: Int?
  public var displayTitle: String {
    guard title.isEmpty else { return title }
    let line = (draft ?? "").lazy.drop(while: \.isNewline).prefix(60).prefix(while: { !$0.isNewline })
    return line.isEmpty ? "未命名" + kind.label : String(line)
  }
}

public struct WritingVersion: Identifiable, Equatable, Sendable {
  public let id: String
  public let ordinal: Int
  public let supportsCallouts: Bool
  public let body: String
}

public struct WrittenBlock: Equatable, Sendable {
  public let kind: String
  public let start: Int
  public let end: Int
  public let text: String
  public let images: [String]
  public init(kind: String, start: Int, end: Int, text: String, images: [String] = []) {
    self.kind = kind
    self.images = images
    self.start = start
    self.end = end
    self.text = text
  }
}

private struct WritingSourceRange: Encodable {
  let start: Int
  let end: Int
  let unit = "unicode_code_points"
  let representation = "markdown_source_lf"
}

func writingID() -> String { UUID().uuidString.lowercased() }
func writingDate() -> String {
  Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
}
func writingJSON<T: Encodable>(_ value: T) throws -> String {
  String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

extension AtlasStore {
  private func notifyWritingChange(_ id: String, savedDraft: WritingItem? = nil) {
    var info: [String: Any] = ["itemID": id]
    if let savedDraft {
      info["editSerial"] = savedDraft.editSerial
      info["versionID"] = savedDraft.currentVersionID
    }
    NotificationCenter.default.post(
      name: .atlasWritingChanged, object: workspaceID, userInfo: info)
  }

  private static let writingRows = """
    SELECT n.id,n.kind AS kind,n.title,n.current_version_id,d.body_text,d.edit_serial,n.created_at
    FROM content_node n LEFT JOIN draft d ON d.content_id=n.id WHERE (n.kind='idea' OR (n.kind='question' AND NOT EXISTS (SELECT 1 FROM inquiry_turn t WHERE t.question_node_id=n.id))) AND n.deleted_at IS NULL
    UNION ALL
    SELECT n.id,'markdown',n.title,n.current_version_id,d.body_text,d.edit_serial,n.created_at
    FROM document n LEFT JOIN draft d ON d.document_id=n.id WHERE n.kind='markdown' AND n.deleted_at IS NULL
    """
  private static func writingItem(_ row: Row) -> WritingItem {
    WritingItem(
      id: row["id"], kind: WritingKind(rawValue: row["kind"])!,
      title: row["title"], currentVersionID: row["current_version_id"], draft: row["body_text"],
      editSerial: row["edit_serial"])
  }

  /// Version identity without loading document bodies into collapsed canvas cards.
  /// Read one short fragment per canvas entrance from the version that entrance displays.
  public func writingFragments(document: String? = nil) throws -> [String: String] {
    try database.read { db in
      var sql = """
        SELECT p.id, substr(coalesce(
          (SELECT b.plain_text FROM document_block b WHERE b.document_version_id =
            coalesce(json_extract(w.value_json,'$.pinnedVersion'),d.current_version_id)
            AND b.block_kind <> 'heading' ORDER BY b.ordinal LIMIT 1),
          v.plain_text),1,200) AS fragment
        FROM placement p
        LEFT JOIN document d ON p.document_id=d.id
        LEFT JOIN content_node n ON p.content_id=n.id
        LEFT JOIN content_version v ON n.current_version_id=v.id
        LEFT JOIN workspace_settings w ON w.key='view.map.writing.'||p.id
        WHERE p.view_id='atlas' AND (d.kind='markdown' OR n.id IS NOT NULL)
        """
      var arguments = StatementArguments()
      if let document { sql += " AND coalesce(d.id,n.id)=?"; arguments = [document] }
      var result = [String: String]()
      for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
        if let fragment: String = row["fragment"] { result[row["id"]] = fragment }
      }
      return result
    }
  }

  public func markdownEntranceLabels(document: String? = nil) throws -> [String: String] {
    try database.read { db in
      var sql = """
        SELECT p.id, v.ordinal, d.current_version_id, v.id AS version,
          json_extract(w.value_json,'$.pinnedVersion') AS pin, draft.id AS draft,
          json_extract(first.source_metadata_json,'$.derived_from.ordinal') AS originOrdinal
        FROM placement p JOIN document d ON d.id=p.document_id
        LEFT JOIN workspace_settings w ON w.key='view.map.writing.'||p.id
        LEFT JOIN document_version v ON v.id=coalesce(json_extract(w.value_json,'$.pinnedVersion'),d.current_version_id)
          AND v.document_id=d.id
        LEFT JOIN document_version first ON first.document_id=d.id AND first.ordinal=1
        LEFT JOIN draft ON draft.document_id=d.id
        WHERE p.view_id='atlas' AND d.kind='markdown' AND d.deleted_at IS NULL
        """
      var args = StatementArguments()
      if let document { sql += " AND d.id=?"; args = [document] }
      var labels = [String: String]()
      for row in try Row.fetchAll(db, sql: sql, arguments: args) {
        let pin: String? = row["pin"], ordinal: Int? = row["ordinal"]
        let label: String
        if let pin {
          let current: String? = row["current_version_id"]
          label = ordinal.map { (pin == current ? "固定 · v" : "历史 · v") + String($0) } ?? "固定版本不可用"
        } else {
          let draft: String? = row["draft"]
          label = ordinal.map { "跟随当前 · v" + String($0) + (draft == nil ? "" : " · 草稿") } ?? "草稿"
        }
        let origin: Int? = row["originOrdinal"]
        labels[row["id"]] = label + (origin.map { " · 独立副本 · 派生自 v" + String($0) } ?? "")
      }
      return labels
    }
  }

  /// Start a new Markdown document from the published version displayed at this entrance.
  public func deriveMarkdown(placement: String, at point: CGPoint) throws -> WritingItem {
    try database.write { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT d.id AS document, v.id AS version, v.ordinal, coalesce(
          (SELECT plain_text FROM document_block WHERE document_version_id=v.id
           AND block_kind='heading' ORDER BY ordinal LIMIT 1),d.title) AS title
        FROM placement p JOIN document d ON d.id=p.document_id
        LEFT JOIN workspace_settings w ON w.key='view.map.writing.'||p.id
        JOIN document_version v ON v.document_id=d.id AND v.id=coalesce(json_extract(w.value_json,'$.pinnedVersion'),d.current_version_id)
        WHERE p.id=? AND p.view_id='atlas' AND d.kind='markdown' AND d.deleted_at IS NULL
          AND (json_extract(w.value_json,'$.pinnedVersion') IS NOT NULL OR NOT EXISTS(SELECT 1 FROM draft WHERE document_id=d.id))
        """, arguments: [placement]) else {
        throw AtlasStoreError.invalid("请先保存 Markdown 草稿，或选择已保存的版本创建独立副本。")
      }
      let doc = writingID(), version = writingID(), stamp = writingDate()
      let source: String = row["version"]
      try db.execute(sql: "INSERT INTO document(id,kind,title,created_at) VALUES (?,'markdown',?,?)",
                     arguments: [doc, row["title"] as String, stamp])
      try db.execute(sql: """
        INSERT INTO document_version(id,document_id,ordinal,markdown_text,plain_text,text_sha256,renderer_version,
          original_asset_sha256,source_metadata_json,created_at)
        SELECT ?,?,1,markdown_text,plain_text,text_sha256,renderer_version,original_asset_sha256,
          json_set(source_metadata_json,'$.derived_from',json_object('document',document_id,'version',id,'ordinal',ordinal)),?
        FROM document_version WHERE id=?
        """, arguments: [version, doc, stamp, source])
      try db.execute(sql: """
        INSERT INTO document_block(id,document_version_id,lineage_block_id,block_kind,ordinal,source_range_json,plain_text,text_sha256)
        SELECT lower(hex(randomblob(16))),?,lower(hex(randomblob(16))),block_kind,ordinal,source_range_json,plain_text,text_sha256
        FROM document_block WHERE document_version_id=?
        """, arguments: [version, source])
      try db.execute(sql: """
        INSERT INTO document_asset SELECT ?,asset_sha256,role,original_reference FROM document_asset WHERE document_version_id=?
        """, arguments: [version, source])
      try db.execute(sql: "UPDATE document SET current_version_id=? WHERE id=?", arguments: [version, doc])
      try Self.placeNewMaterial(db, kind: "document", target: doc, at: point)
      return try Self.writing(doc, db: db)
    }
  }

  public func writings() throws -> [WritingItem] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM (" + Self.writingRows + ") ORDER BY created_at DESC, id"
      ).map(Self.writingItem)
    }
  }

  static func writing(_ id: String, db: Database) throws -> WritingItem {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM (\(writingRows)) WHERE id=?", arguments: [id])
    else {
      throw AtlasStoreError.invalid("写作材料已不可用。")
    }
    return writingItem(row)
  }

  public func createWriting(_ kind: WritingKind, canvasOrigin: CGPoint? = nil, initialText: String = "") throws -> WritingItem {
    try database.write { db in
      let id = writingID()
      let stamp = writingDate()
      let isDoc = kind == .markdown
      try db.execute(
        sql: isDoc
          ? "INSERT INTO document(id,kind,created_at) VALUES (?,'markdown',?)"
          : "INSERT INTO content_node(id,kind,created_at) VALUES (?,?,?)",
        arguments: isDoc ? [id, stamp] : [id, kind.rawValue, stamp])
      try db.execute(
        sql: isDoc
          ? "INSERT INTO draft(id,owner_kind,document_id,edit_serial,body_text,saved_at) VALUES (?,'document',?,0,?,?)"
          : "INSERT INTO draft(id,owner_kind,content_id,edit_serial,body_text,saved_at) VALUES (?,'content',?,0,?,?)",
        arguments: [writingID(), id, initialText, stamp])
      if let canvasOrigin {
        try Self.placeNewMaterial(db, kind: isDoc ? "document" : "content", target: id, at: canvasOrigin)
      }
      return try Self.writing(id, db: db)
    }
  }

  public func writing(id: String) throws -> WritingItem {
    try database.read { try Self.writing(id, db: $0) }
  }

  public func saveWritingDraft(_ item: WritingItem, body: String) throws -> WritingItem {
    let saved = try database.write { db in
      let actual = try Self.writing(item.id, db: db)
      guard actual.currentVersionID == item.currentVersionID, actual.editSerial == item.editSerial
      else {
        throw AtlasStoreError.invalid("这份草稿或正式版本已在别处修改。请保留当前文字，再重新打开材料。")
      }
      // AppKit supplies an NSString-backed draft. Search its native representation
      // before allocating a normalized copy of the full note.
      var normalized = (body as NSString).range(of: "\r", options: .literal).location != NSNotFound
        ? body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        : body
      // Reuse one UTF-8 representation for the database and other entrances observing this edit.
      normalized.makeContiguousUTF8()
      if normalized == actual.draft { return actual }
      let doc = actual.kind == .markdown
      let column = doc ? "document" : "content"
      if let serial = actual.editSerial {
        try db.execute(
          sql: "UPDATE draft SET body_text=?,edit_serial=?,saved_at=? WHERE \(column)_id=?",
          arguments: [normalized, serial + 1, writingDate(), item.id])
      } else {
        try db.execute(
          sql: """
            INSERT INTO draft(id,owner_kind,\(column)_id,base_\(column)_version_id,edit_serial,body_text,saved_at) VALUES (?,?,?,?,1,?,?)
            """,
          arguments: [
            writingID(), column, item.id, item.currentVersionID, normalized, writingDate(),
          ])
      }
      return WritingItem(id: actual.id, kind: actual.kind, title: actual.title,
        currentVersionID: actual.currentVersionID, draft: normalized, editSerial: (actual.editSerial ?? 0) + 1)
    }
    if saved.editSerial != item.editSerial { notifyWritingChange(saved.id, savedDraft: saved) }
    return saved
  }

  public func markdownVersion(_ id: String, documentID: String) throws -> WritingVersion {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT v.ordinal,v.markdown_text,v.renderer_version FROM document_version v JOIN document d ON d.id=v.document_id
        WHERE v.id=? AND d.id=? AND d.kind='markdown' AND d.deleted_at IS NULL
        """, arguments: [id, documentID]) else { throw AtlasStoreError.invalid("此 Markdown 版本不可用。") }
      return WritingVersion(id: id, ordinal: row["ordinal"], supportsCallouts: (row["renderer_version"] as String?) == "atlas-markdown-it-2", body: row["markdown_text"])
    }
  }

  public func writingVersions(_ item: WritingItem) throws -> [WritingVersion] {
    try database.read { db in
      let sql =
        item.kind == .markdown
        ? "SELECT id,ordinal,renderer_version,markdown_text AS body FROM document_version WHERE document_id=? ORDER BY ordinal DESC"
        : "SELECT id,ordinal,NULL AS renderer_version,body_markdown AS body FROM content_version WHERE node_id=? ORDER BY ordinal DESC"
      return try Row.fetchAll(db, sql: sql, arguments: [item.id]).map {
        WritingVersion(id: $0["id"], ordinal: $0["ordinal"], supportsCallouts: ($0["renderer_version"] as String?) == "atlas-markdown-it-2", body: $0["body"])
      }
    }
  }

  public func publishWriting(_ item: WritingItem, blocks: [WrittenBlock]) throws -> WritingItem {
    let saved = try database.write { db in try Self.publishWriting(item, blocks: blocks, db: db) }
    notifyWritingChange(saved.id)
    return saved
  }

  public func importMarkdown(from url: URL, original: Data, blocks: [WrittenBlock], canvasOrigin: CGPoint? = nil) throws
    -> WritingItem
  {
    guard let raw = String(data: original, encoding: .utf8) else {
      throw AtlasStoreError.invalid("该文件不是 UTF-8 Markdown。")
    }
    let body = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n")
    let asset = try stageAsset(original, mime: "text/markdown")
    let images = try stageMarkdownImages(Set(blocks.flatMap(\.images)), beside: url)
    return try database.write { db in
      let id = writingID()
      let stamp = writingDate()
      try db.execute(
        sql: "INSERT INTO document(id,kind,title,created_at) VALUES (?,'markdown',?,?)",
        arguments: [id, url.lastPathComponent, stamp])
      try db.execute(
        sql:
          "INSERT INTO draft(id,owner_kind,document_id,edit_serial,body_text,saved_at) VALUES (?,'document',?,0,?,?)",
        arguments: [writingID(), id, body, stamp])
      if let canvasOrigin { try Self.placeNewMaterial(db, kind: "document", target: id, at: canvasOrigin) }
      return try Self.publishWriting(
        Self.writing(id, db: db), blocks: blocks, db: db, original: asset, incoming: images)
    }
  }

  func createAgentIdea(_ body: String, db: Database) throws -> WritingItem {
    let id = writingID()
    let now = writingDate()
    try db.execute(
      sql: "INSERT INTO content_node(id,kind,created_at) VALUES (?,'idea',?)", arguments: [id, now])
    try db.execute(
      sql:
        "INSERT INTO draft(id,owner_kind,content_id,edit_serial,body_text,saved_at) VALUES (?,'content',?,1,?,?)",
      arguments: [writingID(), id, body, now])
    let item = try Self.publishWriting(
      Self.writing(id, db: db),
      blocks: [.init(kind: "paragraph", start: 0, end: body.unicodeScalars.count, text: body)],
      db: db, actor: "cli")
    try db.execute(sql: "INSERT OR IGNORE INTO canvas_view(id,title) VALUES ('atlas','图谱')")
    var entries = try Self.mapEntries(db)
    try Self.seedEntry(
      db, id: "map.content." + id, kind: "content", target: id, parent: nil, entries: &entries)
    try db.execute(
      sql:
        "INSERT INTO index_outbox(entity_kind,entity_id,version_id,operation,created_at) VALUES ('content',?,?,'upsert',?)",
      arguments: [id, item.currentVersionID, now])
    return item
  }

  private static func publishWriting(
    _ item: WritingItem, blocks: [WrittenBlock], db: Database, original: StagedAsset? = nil,
    incoming: [String: StagedAsset] = [:], actor: String = "user"
  ) throws -> WritingItem {
    let actual = try Self.writing(item.id, db: db)
    guard actual.currentVersionID == item.currentVersionID, actual.editSerial == item.editSerial,
      let body = actual.draft, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AtlasStoreError.invalid("草稿为空或已改变，请重新检查后保存版本。")
    }
    let length = body.unicodeScalars.count
    var previousEnd = 0
    for block in blocks {
      guard block.start >= previousEnd, block.end > block.start, block.end <= length else {
        throw AtlasStoreError.invalid("Markdown 块范围与当前草稿不一致。")
      }
      previousEnd = block.end
    }
    let id = writingID()
    let stamp = writingDate()
    let plain = blocks.map(\.text).joined(separator: "\n\n")
    let title = String((plain.split(whereSeparator: \.isNewline).first ?? "").prefix(60))
    if actual.kind == .markdown {
      try original?.register(db)
      var images = incoming.mapValues(\.hash)
      let refs = Set(blocks.flatMap(\.images))
      if let oldVersion = actual.currentVersionID {
        let raw = try String.fetchOne(
          db,
          sql:
            "SELECT json_extract(source_metadata_json,'$.image_aliases') FROM document_version WHERE id=?",
          arguments: [oldVersion])
        let old =
          try raw.map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
          ?? [:]
        for (ref, digest) in old where refs.contains(ref) && images[ref] == nil {
          images[ref] = digest
        }
      }
      for asset in incoming.values { try asset.register(db) }
      let metadata = try writingJSON(["image_aliases": images])
      try db.execute(
        sql: """
          INSERT INTO document_version(id,document_id,ordinal,markdown_text,plain_text,text_sha256,renderer_version,original_asset_sha256,source_metadata_json,created_at)
          VALUES (?,?,1+COALESCE((SELECT MAX(ordinal) FROM document_version WHERE document_id=?),0),?,?,?,'atlas-markdown-it-2',?,?,?)
          """,
        arguments: [
          id, item.id, item.id, body, plain, atlasHash(Data(plain.utf8)), original?.hash, metadata,
          stamp,
        ])
      for (ref, hash) in images.sorted(by: { $0.key < $1.key }) {
        try db.execute(
          sql:
            "INSERT OR IGNORE INTO document_asset(document_version_id,asset_sha256,role,original_reference) VALUES (?,?,'image',?)",
          arguments: [id, hash, ref])
      }
      let old = try Row.fetchAll(
        db,
        sql:
          "SELECT lineage_block_id,block_kind,plain_text FROM document_block WHERE document_version_id=?",
        arguments: [actual.currentVersionID])
      // Only unique, unchanged blocks retain their lineage. Identical copies deliberately need reanchoring.
      struct Identity: Hashable {
        let kind: String
        let bytes: Data
      }
      let oldGroups = Dictionary(grouping: old) {
        Identity(kind: $0["block_kind"], bytes: Data(($0["plain_text"] as String).utf8))
      }
      let groups = Dictionary(grouping: blocks) {
        Identity(kind: $0.kind, bytes: Data($0.text.utf8))
      }
      for (i, block) in blocks.enumerated() {
        let key = Identity(kind: block.kind, bytes: Data(block.text.utf8))
        let prior = oldGroups[key]
        let lineage: String =
          groups[key]?.count == 1 && prior?.count == 1 ? prior![0]["lineage_block_id"] : writingID()
        try db.execute(
          sql: """
            INSERT INTO document_block(id,document_version_id,lineage_block_id,block_kind,ordinal,source_range_json,plain_text,text_sha256)
            VALUES (?,?,?,?,?,?,?,?)
            """,
          arguments: [
            writingID(), id, lineage, block.kind, i,
            try writingJSON(WritingSourceRange(start: block.start, end: block.end)), block.text,
            atlasHash(Data(block.text.utf8)),
          ])
      }
      try db.execute(
        sql: "UPDATE document SET current_version_id=?,revision=revision+1,title=? WHERE id=?",
        arguments: [id, title, item.id])
      try db.execute(sql: "DELETE FROM draft WHERE document_id=?", arguments: [item.id])
    } else {
      try db.execute(
        sql: """
          INSERT INTO content_version(id,node_id,ordinal,body_markdown,plain_text,body_sha256,origin_kind,actor_kind,supersedes_version_id,created_at)
          VALUES (?,?,1+COALESCE((SELECT MAX(ordinal) FROM content_version WHERE node_id=?),0),?,?,?,'user',?,?,?)
          """,
        arguments: [
          id, item.id, item.id, body, plain, atlasHash(Data(body.utf8)), actor,
          actual.currentVersionID,
          stamp,
        ])
      try db.execute(
        sql:
          "UPDATE content_node SET current_version_id=?,content_revision=content_revision+1,title=? WHERE id=?",
        arguments: [id, title, item.id])
      try db.execute(sql: "DELETE FROM draft WHERE content_id=?", arguments: [item.id])
    }
    return try Self.writing(item.id, db: db)
  }
}
