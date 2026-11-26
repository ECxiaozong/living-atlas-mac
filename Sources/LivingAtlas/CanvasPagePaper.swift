import AppKit
import AtlasCore
import PDFKit
import SwiftUI

struct CanvasPagePicker: View {
  let document: PDFDocument
  let file: AtlasPDF
  let place: ([Int]) -> Void
  let book: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var picked: Set<Int> = [0]
  @ViewState private var hovered: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        AtlasKindBadge(kind: .pdf)
        Text(file.title)
          .font(AtlasTypeface.reading.font(20).weight(.medium))
          .foregroundStyle(AtlasPalette.ink)
          .lineLimit(1)
        Spacer()
        Text("共 " + String(document.pageCount) + " 页")
          .font(.system(size: 11.5))
          .foregroundStyle(AtlasPalette.umber)
      }
      PaperRule()
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12)], spacing: 12) {
          ForEach(0..<document.pageCount, id: \.self) { index in
            if let page = document.page(at: index) {
              let number = String(index + 1)
              let label = page.label.flatMap { $0 != number ? $0 : nil }
              let title = label.map { "第 " + number + " 张 · 页码 " + $0 } ?? "第 " + number + " 页"
              let selected = picked.contains(index)
              let isHovered = hovered == index
              Button {
                if NSEvent.modifierFlags.contains(.command) {
                  if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
                } else { picked = [index] }
              } label: {
                VStack(spacing: 7) {
                  ZStack(alignment: .topTrailing) {
                    Image(nsImage: page.thumbnail(of: CGSize(width: 180, height: 220), for: .cropBox))
                      .resizable()
                      .scaledToFit()
                      .frame(height: 116)
                      .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                      .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                          .strokeBorder(AtlasPalette.line.opacity(0.45), lineWidth: 0.6)
                      }
                      .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.10), radius: 3, y: 1.5)
                    if selected {
                      Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AtlasPalette.blueInk)
                        .background(Circle().fill(AtlasPalette.paper).padding(1.5))
                        .offset(x: 5, y: -5)
                    }
                  }
                  Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AtlasPalette.blueInk : AtlasPalette.ink.opacity(0.84))
                    .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                  selected
                    ? AtlasPalette.blueInk.opacity(0.07)
                    : (isHovered ? AtlasPalette.paperInset.opacity(0.95) : AtlasPalette.paperInset.opacity(0.55)),
                  in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                      selected
                        ? AtlasPalette.blueInk.opacity(0.88)
                        : AtlasPalette.line.opacity(isHovered ? 0.72 : 0.42),
                      lineWidth: selected ? 1.6 : 0.75
                    )
                }
                .animation(AtlasMotion.micro(reduceMotion), value: selected)
                .animation(AtlasMotion.micro(reduceMotion), value: isHovered)
              }
              .buttonStyle(.plain)
              .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
              .accessibilityLabel(title)
              .accessibilityValue(selected ? "已选" : "")
            }
          }
        }.padding(4)
      }
      PaperRule()
      HStack(spacing: 10) {
        Button("放整本书", action: book)
          .buttonStyle(PaperButton())
        Text("按住 ⌘ 点击可多选")
          .font(.system(size: 11.5))
          .foregroundStyle(AtlasPalette.umber.opacity(0.85))
        Spacer()
        Button("取消") { dismiss() }
          .buttonStyle(AtlasChipButtonStyle())
        Button("放到画布") { place(picked.sorted()) }
          .buttonStyle(PaperButton(primary: true))
          .disabled(picked.isEmpty)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 520, height: 392)
    .background(AtlasPalette.paper)
  }
}

/// PDFKit supplies text hit testing, system copy and accessibility. Its display
/// document contains just the selected page. Anchors are captured against the original.
struct CanvasPageSurface: NSViewRepresentable {
  let file: AtlasPDF
  let page: CanvasPDFPage
  let store: AtlasStore
  var highlight: PDFAnchor?
  var region: CGRect?
  var markRevision: Int
  var select: (PDFAnchor?) -> Void
  var selectRegion: (CGRect) -> Void
  var zoomCanvas: (CGFloat, CGPoint) -> Void
  var pan: (CGFloat, CGFloat) -> Void
  var onTextLayerDetected: ((Bool) -> Void)? = nil
  var failure: (String) -> Void

  final class Surface: PDFView {
    var source: PDFDocument?
    var pinned: PDFPage? {
      didSet { hasText = !(pinned?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var hasText = false
    var metadata: CanvasPDFPage?
    var selectionChanged: ((PDFAnchor?) -> Void)?
    var regionChanged: ((CGRect) -> Void)?
    var panCanvas: ((CGFloat, CGFloat) -> Void)?
    var magnifyCanvas: ((CGFloat, CGPoint) -> Void)?
    var gestures: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let gestures { NSEvent.removeMonitor(gestures); self.gestures = nil }
      guard window != nil else { return }
      // PDFKit's private scroll view receives these events before PDFView does.
      gestures = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
        guard let self, let window = self.window, event.window === window,
          let root = window.contentView,
          let hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
          hit === self || hit.isDescendant(of: self) else { return event }
        self.magnify(with: event)
        return nil
      }
    }
    var start: CGPoint?
    var regionMark: PDFAnnotation?
    var shownRegion: CGRect?
    var revision = -1
    var appMarks: [PDFAnnotation] = []
    var lastHighlight: PDFAnchor?
    var observer: NSObjectProtocol?
    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      if let gestures { NSEvent.removeMonitor(gestures) }
    }
    override func layout() {
      super.layout()
      guard let meta = metadata, bounds.width > 1, bounds.height > 1 else { return }
      let fit = min(bounds.width / meta.width, bounds.height / meta.height)
      if abs(scaleFactor - fit) > 0.0001 { scaleFactor = fit }
      if let scroll = documentView?.enclosingScrollView {
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
      }
    }
    override func scrollWheel(with event: NSEvent) { panCanvas?(event.scrollingDeltaX, event.scrollingDeltaY) }
    override func magnify(with event: NSEvent) { magnifyCanvas?(1 + event.magnification, event.locationInWindow) }
    override func hitTest(_ point: NSPoint) -> NSView? {
      let hit = super.hitTest(point)
      if hit != nil, pinned != nil, !hasText { return self }
      return hit
    }
    override func mouseDown(with event: NSEvent) {
      guard let pinned, !hasText else { super.mouseDown(with: event); return }
      start = convert(convert(event.locationInWindow, from: nil), to: pinned)
    }
    override func mouseDragged(with event: NSEvent) {
      if let start, let pinned {
        let end = convert(convert(event.locationInWindow, from: nil), to: pinned)
        paintRegion(CGRect(x: min(start.x,end.x), y: min(start.y,end.y), width: abs(end.x-start.x), height: abs(end.y-start.y)).intersection(pinned.bounds(for: .cropBox)))
      } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
      if start != nil { mouseDragged(with: event); start = nil; if let shownRegion, !shownRegion.isEmpty { regionChanged?(shownRegion) } }
      else { super.mouseUp(with: event) }
    }
    func paintRegion(_ rect: CGRect?) {
      guard let pinned, rect != shownRegion else { return }
      if let regionMark { pinned.removeAnnotation(regionMark) }
      regionMark = nil; shownRegion = rect
      if let rect, !rect.isEmpty {
        let mark = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        let amber = NSColor(red: 0.773, green: 0.620, blue: 0.373, alpha: 1)
        mark.color = amber; mark.interiorColor = amber.withAlphaComponent(0.14)
        pinned.addAnnotation(mark); regionMark = mark
      }
      needsDisplay = true
    }
    func publish() {
      guard let meta = metadata, let source, let original = source.page(at: meta.index), let pinned,
            let selected = currentSelection, selected.numberOfTextRanges(on: pinned) > 0 else { selectionChanged?(nil); return }
      let combined = PDFSelection(document: source)
      for n in 0..<selected.numberOfTextRanges(on: pinned) {
        if let part = original.selection(for: selected.range(at: n, on: pinned)) { combined.add(part) }
      }
      selectionChanged?(try? PDFAnchor.capture(combined, document: source, versionID: meta.version))
    }
  }
  func makeNSView(context: Context) -> Surface {
    let view = Surface()
    view.setAccessibilityIdentifier("canvas.reader.pdf")
    view.displayMode = .singlePage; view.displayBox = .cropBox; view.displaysPageBreaks = false
    view.pageShadowsEnabled = false; view.autoScales = false; view.backgroundColor = .white
    view.minScaleFactor = 0.01; view.maxScaleFactor = 8
    view.setAccessibilityLabel(file.title + " · " + page.caption)
    do {
      let source = try store.readablePDF(file)
      guard let original = source.page(at: page.index), let copy = original.copy() as? PDFPage else {
        throw AtlasStoreError.invalid("无法显示冻结的 PDF 页。")
      }
      let display = PDFDocument(); display.insert(copy, at: 0)
      view.source = source; view.pinned = copy; view.metadata = page; view.document = display
      let hasText = !(copy.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let reportText = onTextLayerDetected
      DispatchQueue.main.async { reportText?(hasText) }
      view.observer = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak view] _ in
        DispatchQueue.main.async { view?.publish() }
      }
    } catch { DispatchQueue.main.async { failure(error.localizedDescription) } }
    return view
  }
  func updateNSView(_ view: Surface, context: Context) {
    view.selectionChanged = select; view.regionChanged = selectRegion; view.panCanvas = pan; view.magnifyCanvas = zoomCanvas
    guard let source = view.source, let pinned = view.pinned else { return }
    if view.start == nil { view.paintRegion(region) }
    if view.revision != markRevision {
      view.appMarks.forEach { pinned.removeAnnotation($0) }; view.appMarks.removeAll()
      do {
        for (p, mark) in try store.pdfMarkLayers(for: file, in: source) where source.index(for: p) == page.index {
          pinned.addAnnotation(mark); view.appMarks.append(mark)
        }
      } catch { DispatchQueue.main.async { failure(error.localizedDescription) } }
      view.revision = markRevision
    }
    if view.lastHighlight != highlight {
      view.lastHighlight = highlight
      if let highlight, let original = source.page(at: page.index), let native = try? highlight.selection(in: source),
        native.numberOfTextRanges(on: original) > 0 {
        view.setCurrentSelection(pinned.selection(for: native.range(at: 0, on: original)), animate: false)
      }
    }
  }
}

struct CanvasPageThumbnail: View {
  let file: AtlasPDF
  let meta: CanvasPDFPage
  let store: AtlasStore
  let revision: Int
  @Environment(\.displayScale) private var scale
  @ViewState private var image: NSImage?
  private static let cache: NSCache<NSString, NSImage> = {
    let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 24*1024*1024; return c
  }()
  var body: some View {
    GeometryReader { proxy in
      let pixels = max(64, min(1200, Int(ceil(proxy.size.width*scale/64))*64))
      let key = file.versionID + "." + String(meta.index) + "." + String(pixels) + "." + String(revision)
      Group {
        if let image { Image(nsImage: image).resizable().scaledToFit() } else { Color.white }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).task(id: key) {
        if let cached = Self.cache.object(forKey: key as NSString) { image = cached; return }
        guard let doc = try? store.readablePDF(file), let pg = doc.page(at: meta.index) else { return }
        if let marks = try? store.pdfMarkLayers(for: file, in: doc) { for (p,m) in marks where p === pg { pg.addAnnotation(m) } }
        let width = min(CGFloat(pixels), 1200 * meta.width/meta.height)
        let height = width*meta.height/meta.width
        let rendered = pg.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
        Self.cache.setObject(rendered, forKey: key as NSString, cost: Int(width*height*4))
        image = rendered
      }
    }
  }
}
