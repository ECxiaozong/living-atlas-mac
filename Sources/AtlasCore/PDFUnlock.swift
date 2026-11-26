import Foundation
import PDFKit

public enum PDFUnlockError: LocalizedError {
  case required, incorrect
  public var errorDescription: String? {
    self == .required ? "此 PDF 需要密码。" : "密码未能解锁此 PDF，原件已保留。"
  }
}

final class PDFUnlockSession: @unchecked Sendable {
  private let lock = NSLock()
  private var values = [String: String]()
  func remember(_ password: String, for digest: String) {
    lock.withLock { values[digest] = password }
  }
  func password(for digest: String) -> String? { lock.withLock { values[digest] } }
}

extension AtlasStore {
  static func unlockedDocument(_ doc: PDFDocument?, password: String?) throws -> PDFDocument {
    guard let doc else { throw AtlasStoreError.invalid("无法解析 PDF，原件已保留。") }
    if doc.isLocked {
      guard let password else { throw PDFUnlockError.required }
      guard doc.unlock(withPassword: password), !doc.isLocked else {
        throw PDFUnlockError.incorrect
      }
    }
    guard doc.pageCount > 0 else { throw AtlasStoreError.invalid("PDF 没有可读取的页。") }
    return doc
  }

  public func readablePDF(_ file: AtlasPDF, password: String? = nil) throws -> PDFDocument {
    let digest = file.url.lastPathComponent
    let doc = try Self.unlockedDocument(
      PDFDocument(url: file.url), password: password ?? pdfPasswords.password(for: digest))
    if doc.isEncrypted, let password { pdfPasswords.remember(password, for: digest) }
    return doc
  }
}
