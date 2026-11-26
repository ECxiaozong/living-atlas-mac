import Darwin
import Foundation
import GRDB
import PDFKit

public struct ExportVersion: Identifiable, Sendable {
  public enum Kind: String, Sendable { case document, content, answer }
  public let id: String
  public let kind: Kind
  public let title: String
  public let ordinal: Int
  public let isPDF: Bool
}
extension AtlasStore {
  public func exportVersions() throws -> [ExportVersion] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT v.id,'document' kind,d.title,v.ordinal,d.kind='pdf' pdf,v.created_at AS created_at FROM document_version v
          JOIN document d ON d.id=v.document_id WHERE d.kind IN ('markdown','pdf') AND d.deleted_at IS NULL
          UNION ALL SELECT v.id,'content',n.title,v.ordinal,0,v.created_at FROM content_version v JOIN content_node n ON v.node_id=n.id
          WHERE n.kind NOT IN ('question','answer') AND n.deleted_at IS NULL
          UNION ALL SELECT v.id,'answer',q.plain_text,v.ordinal,0,v.created_at FROM content_version v
          JOIN inquiry_turn t ON t.answer_node_id=v.node_id JOIN content_version q ON q.id=t.question_version_id
          JOIN content_node n ON n.id=t.question_node_id WHERE n.deleted_at IS NULL ORDER BY 6 DESC
          """
      ).map {
        ExportVersion(
          id: $0["id"], kind: ExportVersion.Kind(rawValue: $0["kind"])!, title: $0["title"],
          ordinal: $0["ordinal"], isPDF: $0["pdf"])
      }
    }
  }
  public func exportImageCount(_ choice: ExportVersion) throws -> Int {
    guard choice.kind == .document, !choice.isPDF else { return 0 }
    return try writingImageLinks(version: choice.id).count
  }

  /// A new directory preserves relative image links and the selected Markdown verbatim.
  /// Nothing outside the directory is created or replaced.
  public func exportMarkdownFolder(_ choice: ExportVersion, to destination: URL) throws {
    guard choice.kind == .document, !choice.isPDF,
      !FileManager.default.fileExists(atPath: destination.path)
    else { throw AtlasStoreError.invalid("请选择新的 Markdown 导出目录。") }
    let links = try writingImageLinks(version: choice.id)
    try withTemporarySibling(destination) { tmp in
      let folder = tmp.appendingPathComponent("document")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      let main = folder.appendingPathComponent("正文.md")
      try exportContent(choice, to: main)
      var installed = [String: String]()
      for (ref, digest) in links {
        guard let parts = URLComponents(string: ref), parts.scheme == nil, parts.host == nil,
          !parts.path.hasPrefix("/"),
          !parts.path.unicodeScalars.contains(where: { $0.value < 32 }),
          !parts.path.split(separator: "/").contains("..")
        else { throw AtlasStoreError.invalid("无法在导出目录中重现图片路径：" + ref) }
        let asset = folder.appendingPathComponent(parts.path).standardizedFileURL
        guard asset.pathComponents.starts(with: folder.standardizedFileURL.pathComponents),
          asset != main, asset.pathComponents.count > folder.pathComponents.count
        else { throw AtlasStoreError.invalid("图片路径与正文冲突。") }
        if let hash = installed[asset.path] {
          guard hash == digest else { throw AtlasStoreError.invalid("两张图片使用了相同的文件名。") }
          continue
        }
        let data = try readWritingImage(hash: digest, version: choice.id).0
        try FileManager.default.createDirectory(
          at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: asset, options: .withoutOverwriting)
        installed[asset.path] = digest
      }
      guard Darwin.renamex_np(folder.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
    }
  }
  public func exportContent(_ choice: ExportVersion, to destination: URL) throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw AtlasStoreError.invalid("为保留现有文件，请选择新的文件名。")
    }
    if choice.isPDF {
      let file = try pdf(versionID: choice.id)
      let doc = try readablePDF(file)
      let oldCount = doc.pageCount
      for (page, mark) in try pdfMarkLayers(for: file, in: doc) { page.addAnnotation(mark) }
      try withTemporarySibling(destination) { tmp in
        let created = tmp.appendingPathComponent("copy.pdf")
        guard doc.write(to: created) else { throw AtlasStoreError.invalid("PDF 副本写入失败。") }
        let verified = try Self.unlockedDocument(
          PDFDocument(url: created),
          password: pdfPasswords.password(for: file.url.lastPathComponent))
        guard verified.pageCount == oldCount else {
          throw AtlasStoreError.invalid("导出 PDF 页数校验失败。")
        }
        try publishFile(created, to: destination, replacing: false)
      }
    } else {
      let text = try database.read { db in
        let sql =
          choice.kind == .document
          ? "SELECT markdown_text FROM document_version WHERE id=?"
          : "SELECT body_markdown FROM content_version WHERE id=?"
        guard let body = try String.fetchOne(db, sql: sql, arguments: [choice.id]) else {
          throw AtlasStoreError.invalid("所选历史版本不可用。")
        }
        var result = body + "\n"
        let origins: [Row]
        if choice.kind == .answer {
          origins = try Row.fetchAll(
            db,
            sql: """
              SELECT s.*,a.page_index,v.ordinal doc_version,d.title doc_title,c.ordinal content_version,m.ordinal message_version
              FROM content_version ans JOIN inquiry_turn t ON t.answer_node_id=ans.node_id JOIN inquiry_reference ir ON ir.turn_id=t.id
              JOIN reference_snapshot s ON s.id=ir.reference_id LEFT JOIN source_anchor a ON a.reference_id=s.id AND a.segment_order=0
              LEFT JOIN document_version v ON v.id=s.document_version_id LEFT JOIN document d ON d.id=v.document_id
              LEFT JOIN content_version c ON c.id=s.content_version_id LEFT JOIN import_message_version m ON m.id=s.message_version_id
              WHERE ans.id=? ORDER BY ir.ordinal
              """, arguments: [choice.id])
          result = "# " + choice.title + "\n\n" + result
        } else if choice.kind == .content {
          origins = try Row.fetchAll(
            db,
            sql: """
              SELECT s.*,a.page_index,v.ordinal doc_version,d.title doc_title,c.ordinal content_version,m.ordinal message_version
              FROM node_origin n JOIN reference_snapshot s ON s.id=n.reference_id LEFT JOIN source_anchor a ON a.reference_id=s.id AND a.segment_order=0
              LEFT JOIN document_version v ON v.id=s.document_version_id LEFT JOIN document d ON d.id=v.document_id
              LEFT JOIN content_version c ON c.id=s.content_version_id LEFT JOIN import_message_version m ON m.id=s.message_version_id
              WHERE n.content_version_id=?
              """, arguments: [choice.id])
        } else {
          origins = []
        }
        result +=
          "\n---\n\n导出自 Living Atlas · " + choice.title + " · 版本 " + String(choice.ordinal) + "\n"
        for r in origins {
          let label =
            (r["doc_title"] as String?)
            ?? ((r["source_kind"] as String) == "message" ? "原聊天消息" : "来源内容")
          let version =
            (r["doc_version"] as Int?) ?? (r["content_version"] as Int?)
            ?? (r["message_version"] as Int?)
          let page: Int? = r["page_index"]
          result +=
            "\n" + label + (version.map { " · 版本 " + String($0) } ?? "")
            + (page.map { " · 第 " + String($0 + 1) + " 页" } ?? "") + "\n"
          if let quote: String = r["quote_snapshot"] {
            result +=
              "\n" + quote.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
              + "\n"
          }
        }
        return result
      }
      try withTemporarySibling(destination) { tmp in
        let created = tmp.appendingPathComponent("selected.md")
        try Data(text.utf8).write(to: created, options: .withoutOverwriting)
        try publishFile(created, to: destination, replacing: false)
      }
    }
  }
}
