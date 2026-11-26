import Foundation
import GRDB
import PDFKit

public enum TextMarkKind: String, CaseIterable, Sendable {
  case highlight, underline, text
  public var label: String {
    switch self {
    case .highlight: "高亮"
    case .underline: "划线"
    case .text: "文字批注"
    }
  }
}

public struct WritingSelection: Codable, Equatable, Sendable {
  public let block: Int
  public let start: Int
  public let end: Int
  public let quote: String
  public init(block: Int, start: Int, end: Int, quote: String) {
    self.block = block
    self.start = start
    self.end = end
    self.quote = quote
  }
}

public struct AtlasTextMark: Identifiable, Equatable, Sendable {
  public let id: String
  public let revisionID: String
  public let referenceID: String
  public let versionID: String
  public let ordinal: Int
  public let kind: TextMarkKind
  public let quote: String
  public let text: String
}

extension AtlasStore {
  static func insertMarkdownReference(
    _ db: Database, versionID: String, selection: [WritingSelection]
  ) throws -> String {
    guard !selection.isEmpty else { throw AtlasStoreError.invalid("请先选择正式版本中的文字。") }
    let ref = writingID()
    try db.execute(
      sql: """
        INSERT INTO reference_snapshot(id,source_kind,document_version_id,quote_snapshot,created_at) VALUES (?,'document',?,?,?)
        """,
      arguments: [ref, versionID, selection.map(\.quote).joined(separator: "\n"), writingDate()])
    var previous = -1
    for (i, s) in selection.enumerated() {
      guard s.block > previous,
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT b.id,b.plain_text,b.text_sha256 FROM document_block b
            JOIN document_version v ON v.id=b.document_version_id JOIN document d ON d.id=v.document_id
            WHERE b.document_version_id=? AND b.ordinal=? AND d.kind='markdown'
            """, arguments: [versionID, s.block])
      else { throw AtlasStoreError.invalid("这个选区与文档版本不一致。") }
      previous = s.block
      let plain: String = row["plain_text"]
      guard let range = plain.atlasUTF16Range(start: s.start, end: s.end),
        let indices = Range(range, in: plain), plain[indices].utf8.elementsEqual(s.quote.utf8)
      else {
        throw AtlasStoreError.invalid("选区无法逐字对应当前版面，已保留原文。")
      }
      try db.execute(
        sql: """
          INSERT INTO source_anchor(id,reference_id,segment_order,document_block_id,selector_type,offset_unit,start_offset,end_offset,prefix,suffix,text_sha256)
          VALUES (?,?,?,?,'text','unicode_code_points',?,?,?,?,?)
          """,
        arguments: [
          writingID(), ref, i, row["id"] as String, s.start, s.end,
          String(plain[..<indices.lowerBound].suffix(32)),
          String(plain[indices.upperBound...].prefix(32)), row["text_sha256"] as String,
        ])
    }
    return ref
  }

  public func writingSourceTarget(_ reference: String) throws -> (
    documentID: String, versionID: String
  )? {
    try writingSourceInfo(reference).map { ($0.documentID, $0.versionID) }
  }

  public func writingSourceInfo(_ reference: String) throws -> (
    documentID: String, versionID: String, title: String, ordinal: Int
  )? {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT d.id, v.id AS version, coalesce(nullif(d.title,''),'Markdown') AS title, v.ordinal
        FROM reference_snapshot r JOIN document_version v ON r.document_version_id=v.id
        JOIN document d ON d.id=v.document_id WHERE r.id=? AND d.kind='markdown'
        """, arguments: [reference]) else { return nil }
      return (row["id"], row["version"], row["title"], row["ordinal"])
    }
  }

  public func captureWritingSource(versionID: String, selection: [WritingSelection]) throws
    -> String
  {
    try database.write { db in
      try Self.insertMarkdownReference(db, versionID: versionID, selection: selection)
    }
  }

  private static func addMark(_ db: Database, reference: String, kind: TextMarkKind, text: String)
    throws -> String
  {
    guard kind != .text || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AtlasStoreError.invalid("请填写批注内容。")
    }
    guard
      let doc = try String.fetchOne(
        db,
        sql: """
          SELECT v.document_id FROM reference_snapshot s JOIN document_version v ON v.id=s.document_version_id WHERE s.id=?
          """, arguments: [reference])
    else { throw AtlasStoreError.invalid("无法确定批注的文档。") }
    let id = writingID()
    let version = writingID()
    let date = writingDate()
    try db.execute(
      sql: "INSERT INTO annotation(id,document_id,current_version_id,created_at) VALUES (?,?,?,?)",
      arguments: [id, doc, version, date])
    try db.execute(
      sql: """
        INSERT INTO annotation_version(id,annotation_id,ordinal,source_reference_id,kind,text,created_at) VALUES (?,?,1,?,?,?,?)
        """, arguments: [version, id, reference, kind.rawValue, kind == .text ? text : nil, date])
    return id
  }

  @discardableResult
  public func markWriting(
    versionID: String, selection: [WritingSelection], kind: TextMarkKind, text: String = ""
  ) throws -> String {
    try database.write { db in
      let ref = try Self.insertMarkdownReference(db, versionID: versionID, selection: selection)
      return try Self.addMark(db, reference: ref, kind: kind, text: text)
    }
  }

  @discardableResult
  public func markPDF(_ anchor: PDFAnchor, kind: TextMarkKind, text: String = "") throws -> String {
    let document = try readablePDF(pdf(versionID: anchor.versionID))
    _ = try anchor.selection(in: document)
    return try database.write { db in
      let ref = writingID()
      try db.execute(
        sql: """
          INSERT INTO reference_snapshot(id,source_kind,document_version_id,quote_snapshot,created_at) VALUES (?,'document',?,?,?)
          """, arguments: [ref, anchor.versionID, anchor.quote, writingDate()])
      for (i, s) in anchor.segments.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO source_anchor(id,reference_id,segment_order,page_index,selector_type,offset_unit,start_offset,end_offset,prefix,suffix,geometry_json,text_sha256)
            VALUES (?,?,?,?,'pdf_rects','unicode_code_points',?,?,?,?,?,?)
            """,
          arguments: [
            writingID(), ref, i, s.pageIndex, s.start, s.end, s.prefix, s.suffix,
            try writingJSON(s), s.textSHA256,
          ])
      }
      return try Self.addMark(db, reference: ref, kind: kind, text: text)
    }
  }

  public func pdfMarkAnchor(_ mark: AtlasTextMark) throws -> PDFAnchor {
    let segments = try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT geometry_json FROM source_anchor WHERE reference_id=? AND selector_type='pdf_rects' ORDER BY segment_order
          """, arguments: [mark.referenceID])
    }
    guard !segments.isEmpty else { throw AtlasStoreError.invalid("此批注没有文字选区。") }
    return PDFAnchor(
      versionID: mark.versionID, quote: mark.quote,
      segments: try segments.map {
        try JSONDecoder().decode(PDFAnchor.Segment.self, from: Data($0.utf8))
      })
  }

  public func textMarks(documentID: String) throws -> [AtlasTextMark] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT a.id,av.id AS revision,av.source_reference_id AS ref,av.kind,av.text,s.quote_snapshot,v.id AS vid,v.ordinal
          FROM annotation a JOIN annotation_version av ON av.id=a.current_version_id
          JOIN reference_snapshot s ON s.id=av.source_reference_id JOIN document_version v ON v.id=s.document_version_id
          WHERE a.document_id=? AND a.deleted_at IS NULL AND av.kind IN ('highlight','underline','text') ORDER BY a.rowid DESC
          """, arguments: [documentID]
      ).map {
        AtlasTextMark(
          id: $0["id"], revisionID: $0["revision"], referenceID: $0["ref"], versionID: $0["vid"],
          ordinal: $0["ordinal"],
          kind: TextMarkKind(rawValue: $0["kind"])!, quote: $0["quote_snapshot"] ?? "",
          text: $0["text"] ?? "")
      }
    }
  }

  public func editComment(_ mark: AtlasTextMark, text: String) throws {
    guard mark.kind == .text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AtlasStoreError.invalid("请填写批注内容。")
    }
    try database.write { db in
      let id = writingID()
      try db.execute(
        sql: """
          INSERT INTO annotation_version(id,annotation_id,ordinal,source_reference_id,kind,text,created_at)
          SELECT ?,a.id,av.ordinal+1,av.source_reference_id,'text',?,? FROM annotation a
          JOIN annotation_version av ON av.id=a.current_version_id WHERE a.id=? AND av.id=? AND av.kind='text' AND a.deleted_at IS NULL
          """, arguments: [id, text, writingDate(), mark.id, mark.revisionID])
      guard db.changesCount == 1 else { throw AtlasStoreError.invalid("批注已经改变，请重新打开。") }
      try db.execute(
        sql: "UPDATE annotation SET current_version_id=?,revision=revision+1 WHERE id=?",
        arguments: [id, mark.id])
    }
  }

  public func reanchorWritingSource(
    _ reference: String, to versionID: String, selection: [WritingSelection]
  ) throws {
    try database.write { db in
      guard
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(SELECT 1 FROM reference_snapshot s JOIN document_version old ON old.id=s.document_version_id
            JOIN document d ON d.id=old.document_id WHERE s.id=? AND d.kind='markdown' AND d.current_version_id=? AND old.id<>?)
            """, arguments: [reference, versionID, versionID]) == true
      else { throw AtlasStoreError.invalid("请在该文档的当前正式版本中重新选择。") }
      let newReference = try Self.insertMarkdownReference(
        db, versionID: versionID, selection: selection)
      let anchors = try String.fetchAll(
        db, sql: "SELECT id FROM source_anchor WHERE reference_id=? AND selector_type='text'",
        arguments: [reference])
      guard !anchors.isEmpty else { throw AtlasStoreError.invalid("旧文字来源不可用。") }
      for anchor in anchors {
        try db.execute(
          sql: """
            INSERT INTO anchor_resolution(anchor_id,state,current_document_version_id,resolved_selector_json,checked_at)
            VALUES (?,'migrated',?,?,?) ON CONFLICT(anchor_id) DO UPDATE SET state='migrated',
            current_document_version_id=excluded.current_document_version_id,resolved_selector_json=excluded.resolved_selector_json,checked_at=excluded.checked_at
            """,
          arguments: [
            anchor, versionID, try writingJSON(["manual_reference_id": newReference]),
            writingDate(),
          ])
      }
    }
  }

  /// Resolving never mutates the recorded quote. Repeated, removed and rewritten blocks require an explicit reanchor.
  public func resolveWritingSource(_ reference: String, in versionID: String) throws
    -> [WritingSelection]?
  {
    try database.read { db in
      let manual = try String.fetchOne(
        db,
        sql: """
          SELECT json_extract(r.resolved_selector_json,'$.manual_reference_id') FROM anchor_resolution r
          JOIN source_anchor a ON a.id=r.anchor_id JOIN document_version mapped ON mapped.id=r.current_document_version_id
          JOIN document_version dest ON dest.document_id=mapped.document_id
          WHERE a.reference_id=? AND dest.id=? AND dest.ordinal>=mapped.ordinal AND r.state='migrated' LIMIT 1
          """, arguments: [reference, versionID])
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT b.document_version_id,b.lineage_block_id,b.plain_text,b.text_sha256,a.start_offset,a.end_offset
          FROM source_anchor a JOIN document_block b ON b.id=a.document_block_id WHERE a.reference_id=? ORDER BY a.segment_order
          """, arguments: [manual ?? reference])
      guard !rows.isEmpty else { return nil }
      var result = [WritingSelection]()
      for row in rows {
        guard
          let block = try Row.fetchOne(
            db,
            sql: """
              SELECT b.ordinal,b.plain_text FROM document_block b JOIN document_version v ON v.id=b.document_version_id
              JOIN document_version old ON old.document_id=v.document_id
              WHERE b.document_version_id=? AND old.id=? AND b.lineage_block_id=? AND b.text_sha256=?
              """,
            arguments: [
              versionID, row["document_version_id"] as String, row["lineage_block_id"] as String,
              row["text_sha256"] as String,
            ])
        else { return nil }
        let text: String = block["plain_text"]
        let start: Int = row["start_offset"]
        let end: Int = row["end_offset"]
        let ordinal: Int = block["ordinal"]
        guard let range = text.atlasUTF16Range(start: start, end: end),
          ordinal > (result.last?.block ?? -1)
        else { return nil }
        result.append(
          WritingSelection(
            block: ordinal, start: start, end: end, quote: (text as NSString).substring(with: range)
          ))
      }
      return result
    }
  }
}

extension AtlasStore {
  public func capturePDFPage(versionID: String, page: Int, region: CGRect? = nil, includePageText: Bool = false) throws -> String {
    let file = try pdf(versionID: versionID)
    let document = try readablePDF(file)
    guard page >= 0, page < document.pageCount else { throw AtlasStoreError.invalid("页码超出原件范围。") }
    guard let sheet = document.page(at: page) else { throw AtlasStoreError.invalid("未能打开这一页。") }
    let geometry: String?
    let quote: String?
    if let region {
      let rect = region.intersection(sheet.bounds(for: .cropBox))
      guard !rect.isEmpty else { throw AtlasStoreError.invalid("所选区域不在原页。") }
      geometry = String(decoding: try JSONEncoder().encode(rect), as: UTF8.self)
      quote = "物理第 " + String(page + 1) + " 页的圈选区域（仅保存位置，未识别图像内容）。"
    } else {
      geometry = nil
      let text = sheet.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      quote = includePageText && !text.isEmpty ? text : nil
    }
    return try database.write { db in
      let ref = writingID()
      try db.execute(
        sql:
          "INSERT INTO reference_snapshot(id,source_kind,document_version_id,created_at,quote_snapshot) VALUES (?,'document',?,?,?)",
        arguments: [ref, versionID, writingDate(), quote])
      try db.execute(
        sql:
          "INSERT INTO source_anchor(id,reference_id,segment_order,page_index,selector_type,geometry_json) VALUES (?,?,0,?,'page',?)",
        arguments: [writingID(), ref, page, geometry])
      return ref
    }
  }

  /// A whole-document reference has no passage to highlight. Older organization batches stored
  /// just the immutable document version and quote, without a source_anchor row.
  public func wholePDFSourceInfo(_ reference: String) throws -> AtlasPDF? {
    let version = try database.read { db in
      try String.fetchOne(db, sql: """
        SELECT v.id FROM reference_snapshot r JOIN document_version v ON v.id=r.document_version_id
        JOIN document d ON d.id=v.document_id WHERE r.id=? AND d.kind='pdf' AND r.source_kind='document'
        AND NOT EXISTS (SELECT 1 FROM source_anchor a WHERE a.reference_id=r.id AND a.selector_type<>'whole')
        """, arguments: [reference])
    }
    return try version.map { try pdfInfo(versionID: $0) }
  }

  public func canvasRegionRect(_ reference: String) throws -> CGRect? {
    try database.read { db in
      let raw = try String.fetchOne(db, sql: "SELECT geometry_json FROM source_anchor WHERE reference_id=? AND selector_type='page'", arguments: [reference])
      return try raw.map { try JSONDecoder().decode(CGRect.self, from: Data($0.utf8)) }
    }
  }
  public func pdfPageSourceTarget(_ reference: String) throws -> (file: AtlasPDF, page: Int)? {
    let target: (String, Int)? = try database.read { db in
      guard
        let r = try Row.fetchOne(
          db,
          sql: """
            SELECT s.document_version_id,a.page_index FROM reference_snapshot s JOIN source_anchor a ON a.reference_id=s.id
            JOIN document_version v ON v.id=s.document_version_id JOIN document d ON v.document_id=d.id
            WHERE s.id=? AND a.selector_type='page' AND d.kind='pdf' ORDER BY a.segment_order LIMIT 1
            """, arguments: [reference])
      else { return nil }
      return (r["document_version_id"], r["page_index"])
    }
    guard let target else { return nil }
    return (try pdf(versionID: target.0), target.1)
  }
}
