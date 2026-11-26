import Foundation
import GRDB

/// Offsets refer to Unicode scalars in the immutable Markdown source, including markup.
public struct AnswerExcerpt: Codable, Equatable, Sendable {
  public let runID: String
  public let body: String
  public let start: Int
  public let end: Int

  public init(runID: String, body: String, start: Int, end: Int) throws {
    self.runID = runID
    self.body = body
    self.start = start
    self.end = end
    guard quote != nil else { throw AtlasStoreError.invalid("请选择回答中的一段原文。") }
  }

  public var quote: String? {
    guard start >= 0, end > start else { return nil }
    let scalars = body.unicodeScalars
    guard
      let lower = scalars.index(scalars.startIndex, offsetBy: start, limitedBy: scalars.endIndex),
      let upper = scalars.index(lower, offsetBy: end - start, limitedBy: scalars.endIndex)
    else { return nil }
    return String(scalars[lower..<upper])
  }

  public var nativeRange: NSRange? {
    guard let quote else { return nil }
    return NSRange(
      location: String(body.unicodeScalars.prefix(start)).utf16.count, length: quote.utf16.count)
  }
}

extension AtlasStore {
  public func referenceQuote(_ id: String) throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT quote_snapshot FROM reference_snapshot WHERE id=?", arguments: [id])
    }
  }
  public func parentExcerpt(of run: AtlasRun) throws -> AnswerExcerpt? {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT v.body_markdown,a.start_offset,a.end_offset FROM inquiry_reference i
            JOIN reference_snapshot s ON s.id=i.reference_id JOIN content_version v ON v.id=s.content_version_id
            JOIN source_anchor a ON a.reference_id=s.id WHERE i.turn_id=? AND i.role='actual_trigger'
            AND a.segment_order=0 AND json_extract(a.geometry_json,'$.parentRunID') IS NOT NULL
            """, arguments: [run.turnID]), let parent = run.parentRunID
      else { return nil }
      let excerpt = try AnswerExcerpt(
        runID: parent, body: row["body_markdown"], start: row["start_offset"],
        end: row["end_offset"])
      guard excerpt.quote == run.parentAnswer else { throw AtlasStoreError.invalid("片段与历史版本不一致。") }
      return excerpt
    }
  }
}
