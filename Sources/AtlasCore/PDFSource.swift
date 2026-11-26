import CryptoKit
import Foundation
import PDFKit

public enum AtlasStoreError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    }
  }
}

private let hexDigits = Array("0123456789abcdef".utf8)

func atlasHash(_ bytes: Data) -> String {
  let digest = SHA256.hash(data: bytes)
  var hex = [UInt8]()
  hex.reserveCapacity(64)
  for byte in digest {
    hex.append(hexDigits[Int(byte >> 4)])
    hex.append(hexDigits[Int(byte & 15)])
  }
  return String(decoding: hex, as: UTF8.self)
}

private func normalized(_ text: String) -> String {
  text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

public struct PDFAnchor: Codable, Hashable, Sendable {
  public struct Segment: Codable, Hashable, Sendable {
    public let pageIndex: Int
    public let start: Int
    public let end: Int
    public let exact: String
    public let prefix: String
    public let suffix: String
    public let textSHA256: String
    /// Each quad contains four points in PDF page coordinates, starting at the top left.
    public let quads: [[Double]]
  }

  public let versionID: String
  public let quote: String
  public let segments: [Segment]

  public static func capture(_ selection: PDFSelection, document: PDFDocument, versionID: String)
    throws -> Self
  {
    var captured: [Segment] = []
    for page in selection.pages {
      let index = document.index(for: page)
      guard index != NSNotFound, document.page(at: index) === page, let raw = page.string else {
        throw AtlasStoreError.invalid("所选页面不属于当前原件。")
      }
      let pageText = normalized(raw)
      let digest = atlasHash(Data(pageText.utf8))
      for i in 0..<selection.numberOfTextRanges(on: page) {
        let range = selection.range(at: i, on: page)
        guard range.length > 0, let swiftRange = Range(range, in: raw),
          let part = page.selection(for: range)
        else {
          throw AtlasStoreError.invalid("选区截断了字符或超出页面范围，请重新选取。")
        }
        let before = normalized(String(raw[..<swiftRange.lowerBound]))
        let after = normalized(String(raw[swiftRange.upperBound...]))
        let exact = normalized(String(raw[swiftRange]))
        let start = before.unicodeScalars.count
        let quads: [[Double]] = part.selectionsByLine().compactMap { line in
          let r = line.bounds(for: page)
          guard !r.isEmpty, !r.isInfinite else { return nil }
          return [r.minX, r.maxY, r.maxX, r.maxY, r.maxX, r.minY, r.minX, r.minY]
        }
        captured.append(
          Segment(
            pageIndex: index, start: start, end: start + exact.unicodeScalars.count,
            exact: exact, prefix: String(before.suffix(32)), suffix: String(after.prefix(32)),
            textSHA256: digest, quads: quads))
      }
    }
    guard !captured.isEmpty, let text = selection.string, !text.isEmpty else {
      throw AtlasStoreError.invalid("此处没有可选文字。")
    }
    let result = Self(versionID: versionID, quote: normalized(text), segments: captured)
    _ = try result.selection(in: document)
    return result
  }

  public func selection(in document: PDFDocument) throws -> PDFSelection {
    let result = PDFSelection(document: document)
    for segment in segments {
      guard segment.pageIndex >= 0, segment.pageIndex < document.pageCount,
        let page = document.page(at: segment.pageIndex), let raw = page.string,
        atlasHash(Data(normalized(raw).utf8)) == segment.textSHA256,
        let range = Self.utf16Range(raw, start: segment.start, end: segment.end),
        normalized((raw as NSString).substring(with: range)).utf8.elementsEqual(segment.exact.utf8),
        let part = page.selection(for: range)
      else {
        throw AtlasStoreError.invalid("这一版本未能精确定位引文，已保留历史原句。")
      }
      result.add(part)
    }
    guard !segments.isEmpty, let text = result.string,
      normalized(text).utf8.elementsEqual(quote.utf8)
    else {
      throw AtlasStoreError.invalid("选区与保存的引文不一致。")
    }
    return result
  }

  static func utf16Range(_ raw: String, start: Int, end: Int) -> NSRange? {
    raw.atlasUTF16Range(start: start, end: end, normalizedNewlines: true)
  }
}

extension String {
  /// Map stored scalar offsets to complete native characters. PDF page anchors normalize CRLF.
  func atlasUTF16Range(start: Int, end: Int, normalizedNewlines: Bool = false) -> NSRange? {
    guard start >= 0, end > start else { return nil }
    var lower: Index?
    var offset = 0
    var cursor = startIndex
    while true {
      if offset == start { lower = cursor }
      if offset == end, let lower { return NSRange(lower..<cursor, in: self) }
      if cursor == endIndex || offset > end { return nil }
      let next = index(after: cursor)
      let character = self[cursor..<next]
      offset += normalizedNewlines && character == "\r\n" ? 1 : character.unicodeScalars.count
      cursor = next
    }
  }
}
