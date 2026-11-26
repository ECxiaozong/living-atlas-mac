import Foundation
import GRDB
import PDFKit

public enum AtlasSearchKind: String, CaseIterable, Codable, Sendable {
  case content, pdf, markdown, web, message, annotation, relation, topic
  public var label: String {
    switch self {
    case .content: "问答与灵感"
    case .pdf: "PDF"
    case .markdown: "Markdown"
    case .web: "网页来源"
    case .message: "档案消息"
    case .annotation: "文字批注"
    case .relation: "知识关系"
    case .topic: "主题"
    }
  }
}

public struct AtlasSearchScope: Equatable, Sendable {
  public var kinds = Set(AtlasSearchKind.allCases)
  public var includeHistory = false
  public var includeTrash = false
  public var permittedObjects: Set<String>?
  public init(permittedObjects: Set<String>? = nil) { self.permittedObjects = permittedObjects }
}

struct SearchEntity {
  let kind: AtlasSearchKind
  let object, version, title, detail: String
  let ordinal: Int
  let current, deleted: Bool
  let asset: String?
  var key: String { kind.rawValue + "|" + version }
  var fingerprint: String { atlasHash(Data((key + "|" + title + "|" + detail).utf8)) }
}

public struct AtlasSearchHit: Identifiable, Sendable, Equatable {
  public let workspaceID: String
  public let kind: AtlasSearchKind
  public let objectID, versionID, locator, title, detail, text, sourceSHA: String
  public let start, end, ordinal: Int
  public var matchStart: Int? = nil
  public var matchEnd: Int? = nil
  public var reason: String
  public var preview: String {
    guard let a = matchStart, let b = matchEnd,
      let ns = text.atlasUTF16Range(start: a - start, end: b - start),
      let r = Range(ns, in: text)
    else { return text }
    let near =
      text.index(r.lowerBound, offsetBy: -32, limitedBy: text.startIndex) ?? text.startIndex
    let begin = text[near..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? near
    return String(text[begin...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public var id: String { kind.rawValue + "|" + objectID + "|" + versionID }
}

public struct AtlasSearchSource: Sendable {
  public let hit: AtlasSearchHit
  public let fullText: String
  public let pdfAnchor: PDFAnchor?
  public let markdownSelection: WritingSelection?
  public let runID: String?
  public var matchRange: NSRange? {
    guard let a = hit.matchStart, let b = hit.matchEnd else { return nil }
    return fullText.atlasUTF16Range(start: a, end: b)
  }
  public var range: NSRange? { fullText.atlasUTF16Range(start: hit.start, end: hit.end) }
}

extension AtlasStore {
  static let searchMetadata = """
    SELECT 'content' k,n.id obj,v.id ver,n.title,n.kind detail,v.ordinal,v.id=n.current_version_id cur,n.deleted_at IS NOT NULL trash,NULL asset
      FROM content_node n JOIN content_version v ON v.node_id=n.id
    UNION ALL SELECT CASE d.kind WHEN 'web_snapshot' THEN 'web' ELSE d.kind END,d.id,v.id,d.title,d.kind,v.ordinal,v.id=d.current_version_id,d.deleted_at IS NOT NULL,v.original_asset_sha256
      FROM document d JOIN document_version v ON v.document_id=d.id WHERE d.kind<>'web_snapshot' OR v.extraction_status IN ('complete','partial')
    UNION ALL SELECT 'message',m.id,v.id,c.title,coalesce(v.role,'unknown'),v.ordinal,v.id=m.current_version_id,a.deleted_at IS NOT NULL,a.raw_asset_sha256
      FROM import_message m JOIN import_message_version v ON v.message_id=m.id JOIN import_conversation c ON c.id=m.conversation_id JOIN import_archive a ON a.id=v.source_archive_id
    UNION ALL SELECT 'annotation',a.id,v.id,d.title,v.kind,v.ordinal,v.id=a.current_version_id,(a.deleted_at IS NOT NULL OR d.deleted_at IS NOT NULL),NULL
      FROM annotation a JOIN annotation_version v ON v.annotation_id=a.id JOIN document d ON d.id=a.document_id WHERE v.kind<>'ink' AND v.text IS NOT NULL
    UNION ALL SELECT 'relation',r.id,v.id,'',v.relation_type,v.ordinal,v.id=r.current_version_id,r.deleted_at IS NOT NULL,NULL
      FROM semantic_relation r JOIN relation_version v ON v.relation_id=r.id
    UNION ALL SELECT 'topic',id,id||':'||revision,title,'topic',revision,1,deleted_at IS NOT NULL,NULL FROM topic
    """

  func searchEntities(_ db: Database, scope: AtlasSearchScope, version: String? = nil) throws
    -> [SearchEntity]
  {
    let kinds = String(
      decoding: try JSONEncoder().encode(scope.kinds.map(\.rawValue)), as: UTF8.self)
    let permitted = try scope.permittedObjects.map {
      String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
    }
    let query = """
      SELECT * FROM (\(Self.searchMetadata)) WHERE (? OR cur) AND (? OR NOT trash)
      AND k IN (SELECT value FROM json_each(?)) AND (? IS NULL OR obj IN (SELECT value FROM json_each(?)))
      AND (? IS NULL OR ver=?) AND obj NOT IN (
        SELECT value FROM json_each(coalesce((SELECT value_json FROM workspace_settings WHERE key='search.excluded'),'[]')))
      """
    let rows = try Row.fetchCursor(
      db, sql: query,
      arguments: [
        scope.includeHistory, scope.includeTrash, kinds, permitted, permitted, version, version,
      ])
    // Thousands of imported messages can share one archive. Recheck each file once per read.
    var availableAssets: [String: Bool] = [:]
    var entities: [SearchEntity] = []
    while let r = try rows.next() {
      guard let kind = AtlasSearchKind(rawValue: r["k"]) else { continue }
      let asset: String? = r["asset"]
      if let asset {
        if availableAssets[asset] == nil {
          availableAssets[asset] = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("assets/\(asset.prefix(2))/\(asset)").path)
        }
        if availableAssets[asset] == false { continue }
      }
      entities.append(SearchEntity(
        kind: kind, object: r["obj"], version: r["ver"], title: r["title"], detail: r["detail"],
        ordinal: r["ordinal"], current: r["cur"], deleted: r["trash"], asset: asset))
    }
    return entities
  }

  func searchParts(_ db: Database, _ entity: SearchEntity, locator: String? = nil) throws -> [(
    String, String
  )] {
    func single(_ sql: String) throws -> [(String, String)] {
      guard locator == nil || locator == "body",
        let text = try String.fetchOne(db, sql: sql, arguments: [entity.version])
      else { return [] }
      return [("body", text)]
    }
    switch entity.kind {
    case .content: return try single("SELECT plain_text FROM content_version WHERE id=?")
    case .message: return try single("SELECT body_text FROM import_message_version WHERE id=?")
    case .annotation: return try single("SELECT text FROM annotation_version WHERE id=?")
    case .relation: return try single("SELECT explanation FROM relation_version WHERE id=?")
    case .topic:
      return [
        (
          "body",
          try String.fetchOne(
            db,
            sql:
              "SELECT CASE WHEN description='' THEN title ELSE description END FROM topic WHERE id=?",
            arguments: [entity.object]) ?? ""
        )
      ]
    case .web: return try single("SELECT plain_text FROM document_version WHERE id=?")
    case .markdown:
      let rows = try Row.fetchAll(
        db,
        sql:
          "SELECT id,plain_text FROM document_block WHERE document_version_id=? AND (? IS NULL OR id=?) ORDER BY ordinal",
        arguments: [entity.version, locator, locator])
      if !rows.isEmpty { return rows.map { ($0["id"], $0["plain_text"]) } }
      return try single("SELECT plain_text FROM document_version WHERE id=?")
    case .pdf:
      guard let hash = entity.asset else { return [] }
      let url = directory.appendingPathComponent("assets/\(hash.prefix(2))/\(hash)")
      guard let pdf = PDFDocument(url: url), !pdf.isEncrypted else { return [] }
      func page(_ i: Int) -> (String, String)? {
        guard i >= 0, i < pdf.pageCount, let s = pdf.page(at: i)?.string, !s.isEmpty else {
          return nil
        }
        return (
          "p\(i)",
          s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        )
      }
      if let locator { return Int(locator.dropFirst()).flatMap(page).map { [$0] } ?? [] }
      return (0..<pdf.pageCount).compactMap(page)
    }
  }

  public func excludeSearchObject(_ object: String?) throws {
    try database.write { db in
      let saved =
        try String.fetchOne(
          db, sql: "SELECT value_json FROM workspace_settings WHERE key='search.excluded'") ?? "[]"
      var ids = try JSONDecoder().decode(Set<String>.self, from: Data(saved.utf8))
      if let object { ids.insert(object) } else { ids.removeAll() }
      try db.execute(
        sql:
          "INSERT INTO workspace_settings VALUES ('search.excluded',?,1,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at",
        arguments: [
          String(decoding: try JSONEncoder().encode(ids.sorted()), as: UTF8.self),
          Date.now.ISO8601Format(),
        ])
    }
  }

  public func searchSource(_ hit: AtlasSearchHit, scope: AtlasSearchScope) throws
    -> AtlasSearchSource
  {
    guard hit.workspaceID == workspaceID else { throw AtlasStoreError.invalid("该结果属于另一个 Atlas。") }
    return try database.read { db in
      guard
        let entity = try searchEntities(db, scope: scope, version: hit.versionID).first(where: {
          $0.object == hit.objectID && $0.kind == hit.kind
        }),
        let (_, text) = try searchParts(db, entity, locator: hit.locator).first,
        atlasHash(Data(text.utf8)) == hit.sourceSHA,
        let range = text.atlasUTF16Range(start: hit.start, end: hit.end),
        (text as NSString).substring(with: range).utf8.elementsEqual(hit.text.utf8)
      else { throw AtlasStoreError.invalid("来源已变化、不可用或超出当前范围，请重新搜索。") }
      var anchor: PDFAnchor?
      if hit.kind == .pdf, let hash = entity.asset, let p = Int(hit.locator.dropFirst()),
        let pdf = PDFDocument(
          url: directory.appendingPathComponent("assets/\(hash.prefix(2))/\(hash)")),
        let page = pdf.page(at: p), let raw = page.string,
        let pageRange = PDFAnchor.utf16Range(raw, start: hit.matchStart ?? hit.start, end: hit.matchEnd ?? hit.end),
        let selection = page.selection(for: pageRange)
      {
        anchor = try PDFAnchor.capture(selection, document: pdf, versionID: hit.versionID)
      }
      let run: String? =
        hit.kind == .content
        ? try String.fetchOne(
          db,
          sql:
            "SELECT g.id FROM generation_run g JOIN inquiry_turn t ON t.id=g.turn_id WHERE g.answer_version_id=? OR t.question_version_id=? ORDER BY g.rowid DESC LIMIT 1",
          arguments: [hit.versionID, hit.versionID]) : nil
      var selection: WritingSelection?
      if hit.kind == .markdown && !entity.deleted,
        let ordinal = try Int.fetchOne(db, sql: "SELECT ordinal FROM document_block WHERE id=? AND document_version_id=?",
                                     arguments: [hit.locator, hit.versionID]) {
        let start = hit.matchStart ?? hit.start, end = hit.matchEnd ?? hit.end
        if start >= hit.start, end <= hit.end, start < end, let range = text.atlasUTF16Range(start: start, end: end) {
          selection = WritingSelection(block: ordinal, start: start, end: end, quote: (text as NSString).substring(with: range))
        }
      }
      return AtlasSearchSource(hit: hit, fullText: text, pdfAnchor: anchor, markdownSelection: selection, runID: run)
    }
  }

  /// The kind picker filters hits. The independent object allow-list still applies to each endpoint.
  public func searchRelationReference(_ hit: AtlasSearchHit, scope: AtlasSearchScope) throws -> String {
    guard hit.kind == .relation, hit.workspaceID == workspaceID else {
      throw AtlasStoreError.invalid("请选择当前图谱中的知识关系。")
    }
    return try database.write { db in
      guard let relation = try searchEntities(db, scope: scope, version: hit.versionID).first,
        relation.kind == .relation, relation.object == hit.objectID,
        let (_, original) = try searchParts(db, relation, locator: hit.locator).first,
        atlasHash(Data(original.utf8)) == hit.sourceSHA,
        let range = original.atlasUTF16Range(start: hit.start, end: hit.end),
        (original as NSString).substring(with: range).utf8.elementsEqual(hit.text.utf8)
      else { throw AtlasStoreError.invalid("关系已变化或超出当前搜索范围，请重新搜索。") }
      var access = scope
      access.kinds = Set(AtlasSearchKind.allCases)
      access.includeHistory = true
      let source = try Self.canvasRelation(db, version: relation.version)
      for endpoint in [source.from, source.to] {
        guard try !searchEntities(db, scope: access, version: endpoint.versionID).isEmpty else {
          throw AtlasStoreError.invalid("有端点超出可读范围。仍可单独引用关系说明。")
        }
      }
      return try Self.freezeCanvasRelation(db, version: relation.version)
    }
  }

  public func searchReference(_ hit: AtlasSearchHit, scope: AtlasSearchScope) throws -> String {
    guard hit.kind != .topic else { throw AtlasStoreError.invalid("主题可以打开；请选择有正文的对象追问。") }
    _ = try searchSource(hit, scope: scope)
    return try database.write { db in
      guard
        let permitted = try searchEntities(db, scope: scope, version: hit.versionID).first(where: {
          $0.object == hit.objectID
        }),
        let (_, text) = try searchParts(db, permitted, locator: hit.locator).first,
        atlasHash(Data(text.utf8)) == hit.sourceSHA
      else { throw AtlasStoreError.invalid("来源范围已变化。") }
      let kind = ([.pdf, .web, .markdown].contains(hit.kind) ? "document" : hit.kind.rawValue)
      let id = UUID().uuidString.lowercased()
      try db.execute(
        sql:
          "INSERT INTO reference_snapshot(id,source_kind,\(kind)_version_id,quote_snapshot,source_state_at_capture,created_at) VALUES (?,?,?,?,?,?)",
        arguments: [
          id, kind, hit.versionID, hit.text,
          permitted.deleted ? "deleted" : permitted.current ? "available" : "historical",
          Date.now.ISO8601Format(),
        ])
      try db.execute(
        sql:
          "INSERT INTO source_anchor(id,reference_id,segment_order,document_block_id,page_index,selector_type,offset_unit,start_offset,end_offset,text_sha256,geometry_json) VALUES (?,?,0,?,?,'text','unicode_code_points',?,?,?,json_object('origin','search','matchStart',?,'matchEnd',?))",
        arguments: [
          UUID().uuidString.lowercased(), id,
          hit.kind == .markdown && hit.locator != "body" ? hit.locator : nil,
          hit.kind == .pdf ? Int(hit.locator.dropFirst()) : nil, hit.start, hit.end, hit.sourceSHA, hit.matchStart, hit.matchEnd,
        ])
      return id
    }
  }
}

extension AtlasStore {
  /// Resolve an explicit historical search citation using its original block/page and scalar range.
  public func searchSource(referenceID: String, scope: AtlasSearchScope = .init()) throws
    -> AtlasSearchSource?
  {
    var access = scope
    access.includeHistory = true
    guard
      let hit: AtlasSearchHit = try database.read({ db in
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT s.*,a.document_block_id,a.page_index,a.start_offset,a.end_offset,a.text_sha256,
                json_extract(a.geometry_json,'$.matchStart') matchStart,json_extract(a.geometry_json,'$.matchEnd') matchEnd,
              coalesce(s.content_version_id,s.document_version_id,s.message_version_id,s.relation_version_id,s.annotation_version_id) version
              FROM reference_snapshot s JOIN source_anchor a ON a.reference_id=s.id WHERE s.id=? AND a.selector_type='text'
              AND json_extract(a.geometry_json,'$.origin')='search' ORDER BY a.segment_order LIMIT 1
              """, arguments: [referenceID])
        else { return nil }
        let version: String = row["version"]
        guard let e = try searchEntities(db, scope: access, version: version).first else {
          throw AtlasStoreError.invalid("原版本已不可用或超出范围。")
        }
        let loc =
          (row["document_block_id"] as String?) ?? (row["page_index"] as Int?).map {
            "p" + String($0)
          } ?? "body"
        return AtlasSearchHit(
          workspaceID: workspaceID, kind: e.kind, objectID: e.object, versionID: version,
          locator: loc, title: e.title, detail: e.detail, text: row["quote_snapshot"],
          sourceSHA: row["text_sha256"], start: row["start_offset"], end: row["end_offset"],
          ordinal: e.ordinal, matchStart: row["matchStart"], matchEnd: row["matchEnd"], reason: "提交时的搜索引文")
      })
    else { return nil }
    return try searchSource(hit, scope: access)
  }
}

extension AtlasStore {
  private func snippetPermissionKey(_ profile: ProviderProfile) -> String {
    "search.snippets."
      + atlasHash(
        Data((profile.endpoint.absoluteString + "|" + (profile.subscriptionAccount ?? "")).utf8))
  }
  public func maySendSearchSnippets(to profile: ProviderProfile) throws -> Bool {
    try database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT json_extract(value_json,'$') FROM workspace_settings WHERE key=?",
        arguments: [snippetPermissionKey(profile)]) == 1
    }
  }
  public func permitSearchSnippets(_ permitted: Bool, to profile: ProviderProfile) throws {
    try database.write { db in
      try db.execute(
        sql:
          "INSERT INTO workspace_settings VALUES (?,?,1,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at",
        arguments: [
          snippetPermissionKey(profile), permitted ? "true" : "false", Date.now.ISO8601Format(),
        ])
    }
  }
}
