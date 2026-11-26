import AppKit
import AtlasCore
import PDFKit
import SwiftUI

struct InkDesk: View {
  let store: AtlasStore
  let surface: InkSurface
  var changed: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  @ViewState private var paths = [InkPath]()
  @ViewState private var pdfPage: CGPDFPage?
  @ViewState private var image: NSImage?
  @ViewState private var erasing = false
  @ViewState private var scale = 1.0
  @ViewState private var rotation = 0
  @ViewState private var problem: String?
  private struct Edit {
    let id: String
    let removed: Bool
  }
  @ViewState private var undo = [Edit]()
  @ViewState private var redo = [Edit]()
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(
          surface.page.map { "第 \($0+1) 页 · 版本 \(surface.version)" }
            ?? "历史固定版面 · 版本 \(surface.version)"
        ).font(.headline)
        Spacer()
        Picker("工具", selection: $erasing) {
          Text("笔").tag(false)
          Text("整笔擦除").tag(true)
        }.pickerStyle(.segmented).fixedSize()
        Button("撤销") { reverse(backwards: true) }.disabled(undo.isEmpty).keyboardShortcut(
          "z", modifiers: .command)
        Button("重做") { reverse(backwards: false) }.disabled(redo.isEmpty).keyboardShortcut(
          "z", modifiers: [.command, .shift])
        Button("完成") { dismiss() }
      }
      HStack {
        Button("缩小") { scale = max(0.25, scale / 1.25) }
        Text("\(Int((scale*100).rounded()))%").monospacedDigit()
        Button("放大") { scale = min(4, scale * 1.25) }
        if surface.page != nil { Button("旋转") { rotation = (rotation + 90) % 360 } }
        if let problem { Text(problem).foregroundStyle(.red) }
      }.controlSize(.small)
      let sideways = (surface.rotation + rotation) % 180 != 0
      ScrollView([.horizontal, .vertical]) {
        if image != nil || pdfPage != nil {
          InkSurfaceView(
            surface: surface, pdfPage: pdfPage, image: image, paths: paths, rotation: rotation,
            erasing: erasing, draw: draw, erase: erase
          )
          .frame(
            width: (sideways ? surface.height : surface.width) * scale,
            height: (sideways ? surface.width : surface.height) * scale)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }.padding(14).frame(minWidth: 580, idealWidth: 780, minHeight: 420, idealHeight: 630)
      .onAppear {
        do {
          if let index = surface.page {
            pdfPage = try store.readablePDF(store.pdf(versionID: surface.versionID)).page(
              at: index)?.pageRef
            if pdfPage == nil { throw AtlasStoreError.invalid("无法显示历史 PDF 页面。") }
          } else {
            image = NSImage(data: try store.snapshotData(surface))
            if image == nil { throw AtlasStoreError.invalid("版面无法显示。") }
          }
          paths = try store.inkPaths(surface: surface.id)
        } catch { problem = error.localizedDescription }
      }
  }
  private func draw(_ points: [InkPoint]) {
    do {
      let stroke = try store.addInk(surface: surface.id, points: points)
      paths.append(stroke)
      undo.append(Edit(id: stroke.id, removed: false))
      redo = []
      changed()
    } catch { problem = error.localizedDescription }
  }
  private func erase(_ id: String) {
    do {
      try store.setInkRemoved(id, surface: surface.id, removed: true)
      paths.removeAll { $0.id == id }
      undo.append(Edit(id: id, removed: true))
      redo = []
      changed()
    } catch { problem = error.localizedDescription }
  }
  private func reverse(backwards: Bool) {
    guard let last = (backwards ? undo : redo).last else { return }
    do {
      try store.setInkRemoved(
        last.id, surface: surface.id, removed: backwards ? !last.removed : last.removed)
      paths = try store.inkPaths(surface: surface.id)
      if backwards {
        undo.removeLast()
        redo.append(last)
      } else {
        redo.removeLast()
        undo.append(last)
      }
      changed()
    } catch { problem = error.localizedDescription }
  }
}

struct InkSurfaceView: NSViewRepresentable {
  let surface: InkSurface
  let pdfPage: CGPDFPage?
  let image: NSImage?
  let paths: [InkPath]
  let rotation: Int
  let erasing: Bool
  let draw: ([InkPoint]) -> Void
  let erase: (String) -> Void
  func makeNSView(context: Context) -> InkPad { InkPad() }
  func updateNSView(_ view: InkPad, context: Context) {
    if view.surface?.id != surface.id {
      view.page = pdfPage
      view.image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    view.surface = surface
    view.paths = paths
    view.rotation = rotation
    view.erasing = erasing
    view.commit = draw
    view.erase = erase
    view.needsDisplay = true
  }
}

final class InkPad: NSView {
  var surface: InkSurface?
  var page: CGPDFPage?
  var image: CGImage?
  var paths = [InkPath]()
  var rotation = 0, erasing = false
  var commit: (([InkPoint]) -> Void)?
  var erase: ((String) -> Void)?
  private var pending = [InkPoint]()
  var transform: CGAffineTransform {
    guard let s = surface, s.width > 0, s.height > 0 else { return .identity }
    if let page {
      return page.getDrawingTransform(
        .cropBox, rect: bounds, rotate: Int32(rotation), preserveAspectRatio: true)
    }
    return CGAffineTransform(
      a: bounds.width / s.width, b: 0, c: 0, d: -bounds.height / s.height, tx: 0, ty: bounds.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let g = NSGraphicsContext.current?.cgContext else { return }
    g.setFillColor(NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.92, alpha: 1).cgColor)
    g.fill(bounds)
    if let image { g.draw(image, in: bounds) }
    g.saveGState()
    defer { g.restoreGState() }
    g.concatenate(transform)
    if let page { g.drawPDFPage(page) }
    g.setStrokeColor(NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.31, alpha: 1).cgColor)
    g.setFillColor(NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.31, alpha: 1).cgColor)
    g.setLineCap(.round)
    g.setLineJoin(.round)
    for stroke in paths { strokePath(stroke.points, width: stroke.width, in: g) }
    strokePath(pending, width: 2.2, in: g)
  }
  private func strokePath(_ points: [InkPoint], width: Double, in g: CGContext) {
    guard let first = points.first else { return }
    if points.count == 1 {
      g.fillEllipse(
        in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
      return
    }
    g.beginPath()
    g.move(to: CGPoint(x: first.x, y: first.y))
    for p in points.dropFirst() { g.addLine(to: CGPoint(x: p.x, y: p.y)) }
    g.setLineWidth(width)
    g.strokePath()
  }
  func paperPoint(_ local: CGPoint) -> InkPoint? {
    guard let s = surface, bounds.width > 0, bounds.height > 0 else { return nil }
    let p = local.applying(transform.inverted())
    return InkPoint(
      x: min(s.minX + s.width, max(s.minX, p.x)), y: min(s.minY + s.height, max(s.minY, p.y)))
  }
  private func append(_ event: NSEvent) {
    guard let p = paperPoint(convert(event.locationInWindow, from: nil)), p != pending.last else {
      return
    }
    pending.append(p)
    needsDisplay = true
  }
  override func mouseDown(with event: NSEvent) {
    if erasing {
      hitErase(event)
      return
    }
    pending = []
    append(event)
  }
  override func mouseDragged(with event: NSEvent) {
    if !erasing && !pending.isEmpty { append(event) }
  }
  override func mouseUp(with event: NSEvent) {
    guard !erasing, !pending.isEmpty else { return }
    append(event)
    let complete = pending
    pending = []
    commit?(complete)
    needsDisplay = true
  }
  private func hitErase(_ event: NSEvent) {
    guard let whereAt = paperPoint(convert(event.locationInWindow, from: nil)) else { return }
    let t = transform
    let tolerance = 7 / max(0.01, hypot(t.a, t.b))
    for path in paths.reversed() {
      for (i, b) in path.points.enumerated() {
        let a = path.points[max(0, i - 1)]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let denom = dx * dx + dy * dy
        let u =
          denom == 0 ? 0 : min(1, max(0, ((whereAt.x - a.x) * dx + (whereAt.y - a.y) * dy) / denom))
        if hypot(whereAt.x - a.x - u * dx, whereAt.y - a.y - u * dy) <= tolerance + path.width / 2 {
          erase?(path.id)
          return
        }
      }
    }
  }
}
