import Foundation
import GRDB

public enum CanvasMaterial {
  case pdf(PDFAnchor)
  case answer(AnswerExcerpt)
  case markdown(version: String, selection: [WritingSelection])
}

public struct CanvasCitation: Codable, Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case pdf, answer, markdown }
  public let id, versionID, title, quote: String
  public let kind: Kind
  public let ordinal: Int
}

extension AtlasStore {
  static func citation(_ db: Database, reference: String) throws -> CanvasCitation {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT s.id,s.quote_snapshot,COALESCE(c.id,d.id) AS version, COALESCE(c.ordinal,d.ordinal) AS ordinal,
            COALESCE(q.plain_text,json_extract(d.source_metadata_json,'$.document_title'),CASE WHEN doc.kind='markdown' THEN substr(d.plain_text,1,256) ELSE doc.title END) AS title,
            CASE WHEN a.selector_type='pdf_rects' THEN 'pdf'
                 WHEN doc.kind='markdown' AND a.document_block_id IS NOT NULL THEN 'markdown'
                 WHEN g.id IS NOT NULL THEN 'answer' END AS kind
          FROM reference_snapshot s JOIN source_anchor a ON a.reference_id=s.id AND a.segment_order=0
          LEFT JOIN content_version c ON c.id=s.content_version_id LEFT JOIN document_version d ON d.id=s.document_version_id
          LEFT JOIN document doc ON doc.id=d.document_id LEFT JOIN generation_run g ON g.id=json_extract(a.geometry_json,'$.parentRunID')
          LEFT JOIN inquiry_turn t ON t.id=g.turn_id LEFT JOIN content_version q ON q.id=t.question_version_id WHERE s.id=?
          """, arguments: [reference]), let label: String = row["kind"],
      let kind = CanvasCitation.Kind(rawValue: label),
      let version: String = row["version"], let quote: String = row["quote_snapshot"],
      !quote.isEmpty
    else { throw AtlasStoreError.invalid("请选择 PDF、Markdown 或回答中的原文片段。") }
    let raw: String = row["title"] ?? "原文"
    let title = kind == .markdown ? String((raw.split(whereSeparator: \.isNewline).first ?? "Markdown").prefix(60)) : raw
    return .init(
      id: reference, versionID: version, title: title, quote: quote, kind: kind,
      ordinal: row["ordinal"])
  }

  static func sameCanvasPassage(_ db: Database, _ a: String, _ b: String) throws -> Bool {
    if a == b { return true }
    let sql = """
      SELECT s.content_version_id,s.document_version_id,s.quote_snapshot,a.selector_type,a.document_block_id,
             a.page_index,a.start_offset,a.end_offset,json_extract(a.geometry_json,'$.parentRunID') AS parent
      FROM reference_snapshot s JOIN source_anchor a ON a.reference_id=s.id WHERE s.id=? ORDER BY a.segment_order
      """
    let rows = try Row.fetchAll(db, sql: sql, arguments: [a])
    guard !rows.isEmpty else { return false }
    let other = try Row.fetchAll(db, sql: sql, arguments: [b])
    return rows == other
  }

  public func canvasCitations(forTurn turn: String) throws -> [CanvasCitation] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT reference_id FROM inquiry_reference WHERE turn_id=? AND role='explicit_reference' AND ordinal>=1 ORDER BY ordinal
          """, arguments: [turn]
      ).map { try Self.citation(db, reference: $0) }
    }
  }

  public func canvasPDFAnchor(reference: String) throws -> PDFAnchor? {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT id,quote_snapshot,document_version_id FROM reference_snapshot WHERE id=? AND EXISTS
            (SELECT 1 FROM source_anchor WHERE reference_id=? AND selector_type='pdf_rects')
            """, arguments: [reference, reference])
      else { return nil }
      return try Self.pdfAnchor(db, reference: row)
    }
  }

  public func canvasAnswerExcerpt(reference: String) throws -> AnswerExcerpt? {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT json_extract(a.geometry_json,'$.parentRunID') AS parent,v.body_markdown,a.start_offset,a.end_offset,s.quote_snapshot
            FROM reference_snapshot s JOIN content_version v ON v.id=s.content_version_id JOIN source_anchor a ON a.reference_id=s.id
            WHERE s.id=? AND a.segment_order=0 AND a.selector_type='text' AND json_extract(a.geometry_json,'$.parentRunID') IS NOT NULL
            """, arguments: [reference])
      else { return nil }
      let value = try AnswerExcerpt(
        runID: row["parent"], body: row["body_markdown"], start: row["start_offset"],
        end: row["end_offset"])
      guard value.quote == row["quote_snapshot"] as String? else {
        throw AtlasStoreError.invalid("回答选区与冻结原文不一致。")
      }
      return value
    }
  }
}
