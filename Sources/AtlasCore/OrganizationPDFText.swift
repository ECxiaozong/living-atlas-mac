import Foundation
import PDFKit

extension OrganizationModelEnvelope {
  public static let requestByteLimit = 32_000
}

extension AtlasStore {
  /// Only explicit model analysis needs the PDF text. Manual layout, grants and conflict checks
  /// remain available offline, including when a selected original is missing or password-locked.
  public func organizationScopeWithPDFText(_ scope: OrganizationScope) async throws -> OrganizationScope {
    var captured = scope
    struct PageRange: Hashable { let version: String; let page: Int? }
    var cached: [PageRange: [String?]] = [:]
    var remaining = OrganizationModelEnvelope.requestByteLimit
    for (index, item) in scope.objects.enumerated() where item.documentKind == "pdf" {
      try Task.checkCancellation()
      let pages: [String?]
      let range = PageRange(version: item.version, page: item.pdfPageIndex)
      if let saved = cached[range] {
        pages = saved
      } else {
        do {
          let file = try pdfInfo(versionID: item.version)
          guard file.id == item.target else { throw organizationError("原件与入口的文档身份不一致。") }
          let bytes = try verifiedPDFBytes(file)
          let document = try Self.unlockedDocument(PDFDocument(data: bytes),
            password: pdfPasswords.password(for: file.url.lastPathComponent))
          var extracted: [String?] = []
          var textBytes = 0
          let indices: Range<Int>
          if let index = item.pdfPageIndex {
            guard (0..<document.pageCount).contains(index) else { throw organizationError("所选物理页超出原件。") }
            indices = index..<(index + 1)
          } else {
            indices = 0..<document.pageCount
          }
          for index in indices {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw organizationError("无法打开文件第 " + String(index + 1) + " 页。") }
            let raw = page.string ?? ""
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
            textBytes += text?.utf8.count ?? 4
            guard textBytes <= remaining else { throw organizationError("PDF 文字超过本次整理输入预算。请缩小材料范围。") }
            extracted.append(text)
          }
          guard item.pdfPageIndex != nil || extracted.contains(where: { $0 != nil }) else { throw organizationError("所选版本没有可提取的 PDF 文字。") }
          pages = extracted
          cached[range] = pages
        } catch is CancellationError { throw CancellationError() }
        catch { throw organizationError("《" + item.title + "》：" + error.localizedDescription) }
      }
      remaining -= pages.reduce(0) { $0 + ($1?.utf8.count ?? 4) }
      guard remaining >= 0 else { throw organizationError("所选 PDF 文字超过本次整理输入预算。请减少选择。") }
      captured.objects[index].pdfTextByFilePage = pages
    }
    return captured
  }
}
