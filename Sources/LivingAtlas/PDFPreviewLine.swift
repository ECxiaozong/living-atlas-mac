import AtlasCore
import PDFKit
import SwiftUI

/// Overview cards only decode a visible version's first page. The reader keeps its own PDFDocument.
struct PDFPreviewLine: View {
  let file: AtlasPDF
  @ViewState private var text = ""
  private static let cache: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 128
    return cache
  }()

  var body: some View {
    Text(text).lineLimit(2).font(.system(size: 13))
      .task(id: file.versionID) {
        let key = file.versionID as NSString
        if let saved = Self.cache.object(forKey: key) { text = saved as String; return }
        text = ""
        let url = file.url
        let line = await Task.detached(priority: .utility) {
          guard let doc = PDFDocument(url: url) else { return "" }
          let first = doc.page(at: 0)?.string?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
          return first.isEmpty ? "第 1 页 · 共 " + String(doc.pageCount) + " 页" : String(first.prefix(160))
        }.value
        guard !Task.isCancelled else { return }
        Self.cache.setObject(line as NSString, forKey: key)
        text = line
      }
  }
}
