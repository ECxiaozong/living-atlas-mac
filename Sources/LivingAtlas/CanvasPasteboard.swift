import AppKit
import AtlasCore

struct CanvasPasteboard: Codable {
  static let type = NSPasteboard.PasteboardType("local.livingatlas.canvas-references.v1")
  @MainActor static var board: NSPasteboard {
    if let name = ProcessInfo.processInfo.environment["LIVING_ATLAS_REVIEW_PASTEBOARD"],
      name.hasPrefix("local.livingatlas.review.") {
      return NSPasteboard(name: NSPasteboard.Name(name))
    }
    return .general
  }

  let workspace: String
  let references: [CanvasReference]

  func write(text: String, to board: NSPasteboard) throws {
    let item = NSPasteboardItem()
    guard try item.setData(JSONEncoder().encode(self), forType: Self.type),
          item.setString(text, forType: .string) else { throw AtlasStoreError.invalid("未能准备剪贴板内容。") }
    board.clearContents()
    guard board.writeObjects([item]) else { throw AtlasStoreError.invalid("无法写入剪贴板。") }
  }

  func references(in store: AtlasStore) -> [CanvasReference]? {
    workspace == store.workspaceID ? references : nil
  }
}
