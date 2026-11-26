import AppKit
import PDFKit

extension AtlasStore {
  public func pdfMarkLayers(for file: AtlasPDF, in document: PDFDocument) throws -> [(
    PDFPage, PDFAnnotation
  )] {
    let records = try textMarks(documentID: file.id).filter {
      $0.versionID == file.versionID
    }
    var next = [(PDFPage, PDFAnnotation)]()
    for mark in records {
      let anchor = try pdfMarkAnchor(mark)
      let selected = try anchor.selection(in: document)
      for line in selected.selectionsByLine() {
        guard let page = line.pages.first else { continue }
        let bounds = line.bounds(for: page)
        guard !bounds.isEmpty else { continue }
        let subtype: PDFAnnotationSubtype = mark.kind == .highlight ? .highlight : .underline
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color =
          mark.kind == .highlight
          ? NSColor.systemYellow.withAlphaComponent(0.42)
          : (mark.kind == .text ? .systemPurple : .systemOrange)
        if !mark.text.isEmpty { annotation.contents = mark.text }
        next.append((page, annotation))
      }
    }
    for surface in try inkSurfaces(document: file.id)
    where surface.versionID == file.versionID {
      guard let idx = surface.page, let page = document.page(at: idx) else { continue }
      for stroke in try inkPaths(surface: surface.id) {
        guard let first = stroke.points.first else { continue }
        let rect = page.bounds(for: .cropBox)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: first.x - rect.minX, y: first.y - rect.minY))
        for point in stroke.points.dropFirst() {
          path.line(to: NSPoint(x: point.x - rect.minX, y: point.y - rect.minY))
        }
        if stroke.points.count == 1 {
          path.line(to: NSPoint(x: first.x - rect.minX + 0.01, y: first.y - rect.minY))
        }
        let annotation = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = stroke.width
        annotation.border = border
        annotation.color = .darkGray
        annotation.add(path)
        next.append((page, annotation))
      }
    }
    return next
  }
}
