import AtlasCore
import PDFKit
import SwiftUI

struct CitationPin: NSViewRepresentable {
  let anchor: PDFAnchor
  final class Marker: NSView {
    var anchor: PDFAnchor?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  func makeNSView(context: Context) -> Marker { Marker() }
  func updateNSView(_ marker: Marker, context: Context) { marker.anchor = anchor }
}

/// Draw only across the gutter, at the actual visible PDF line and its frozen citation.
struct CitationThread: NSViewRepresentable {
  let anchor: PDFAnchor
  final class Layer: NSView {
    var anchor: PDFAnchor?
    private var observers: [NSObjectProtocol] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard window != nil else { return }
      let names: [Notification.Name] = [
        NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification,
        .PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewSelectionChanged,
      ]
      for name in names {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] event in
            guard let self, let v = event.object as? NSView, v.window === self.window, v !== self
            else { return }
            self.needsDisplay = true
          })
      }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    private func find<T: NSView>(
      _ parent: NSView, _ type: T.Type, where accept: (T) -> Bool = { _ in true }
    ) -> T? {
      guard !parent.isHidden else { return nil }
      if let item = parent as? T, accept(item) { return item }
      for child in parent.subviews {
        if let hit = find(child, type, where: accept) { return hit }
      }
      return nil
    }
    override func draw(_ dirtyRect: NSRect) {
      guard let anchor, let root = window?.contentView, let pdf = find(root, PDFView.self),
        let marker = find(root, CitationPin.Marker.self, where: { $0.anchor == anchor }),
        !marker.visibleRect.isEmpty
      else { return }
      let matching =
        (pdf.highlightedSelections ?? []).first { $0.string == anchor.quote }
        ?? (pdf.currentSelection?.string == anchor.quote ? pdf.currentSelection : nil)
      guard let selection = matching else { return }
      var line: CGRect?
      for page in selection.pages {
        for part in selection.selectionsByLine() {
          let rect = pdf.convert(part.bounds(for: page), from: page).intersection(pdf.visibleRect)
          if !rect.isNull, rect.width > 1, rect.height > 2 {
            line = rect
            break
          }
        }
        if line != nil { break }
      }
      guard let line else { return }
      let start = convert(NSPoint(x: pdf.bounds.maxX + 10, y: line.midY), from: pdf)
      let end = convert(NSPoint(x: marker.bounds.minX - 22, y: marker.bounds.midY), from: marker)
      let gap = end.x - start.x
      guard bounds.contains(start), bounds.contains(end), gap > 10, gap < 210 else { return }
      let curve = NSBezierPath()
      curve.move(to: start)
      curve.curve(
        to: end, controlPoint1: NSPoint(x: start.x + gap * 0.55, y: start.y),
        controlPoint2: NSPoint(x: end.x - gap * 0.55, y: end.y))
      NSColor(red: 0.55, green: 0.39, blue: 0.24, alpha: 0.84).set()
      curve.lineWidth = 1.1
      curve.stroke()
      for endpoint in [start, end] {
        NSBezierPath(
          ovalIn: NSRect(x: endpoint.x - 1.8, y: endpoint.y - 1.8, width: 3.6, height: 3.6)
        ).fill()
      }
    }
  }
  func makeNSView(context: Context) -> Layer { Layer() }
  func updateNSView(_ layer: Layer, context: Context) {
    layer.anchor = anchor
    layer.needsDisplay = true
  }
}
