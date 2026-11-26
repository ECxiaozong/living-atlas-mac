import AtlasCore
import PDFKit
import SwiftUI
import WebKit

final class QuestionText: AtlasTypingTextView {
  private let draftUndo = UndoManager()
  override var undoManager: UndoManager? { draftUndo }
  var submit: (() -> Void)?
  var afterComposition: ((String) -> Void)?
  private func finishPendingAction() {
    if afterComposition == nil { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil, !self.hasMarkedText() else { return }
      let action = self.afterComposition
      self.afterComposition = nil
      action?(self.string)
    }
  }
  override func unmarkText() {
    super.unmarkText()
    finishPendingAction()
  }
  override func insertText(_ value: Any, replacementRange: NSRange) {
    super.insertText(value, replacementRange: replacementRange)
    finishPendingAction()
  }
  private var requestedFocus: UUID?
  private var acknowledgedFocus: UUID?
  private var focusScheduled = false

  func requestFocus(_ request: UUID?) {
    requestedFocus = request
    scheduleFocus()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleFocus()
  }

  override func layout() {
    super.layout()
    scheduleFocus()
  }

  // SwiftUI can update an NSTextView while its hosting view is still detached. The
  // responder request belongs to this text view until its real window accepts it.
  private func scheduleFocus() {
    guard requestedFocus != nil, requestedFocus != acknowledgedFocus, window != nil, !focusScheduled
    else { return }
    focusScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.focusScheduled = false
      guard let request = self.requestedFocus, request != self.acknowledgedFocus,
        let window = self.window,
        self.bounds.width > 0, self.bounds.height > 0, !self.isHiddenOrHasHiddenAncestor,
        window.makeFirstResponder(self), window.firstResponder === self
      else {
        return
      }
      self.acknowledgedFocus = request
      self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36, event.modifierFlags.contains(.command), !hasMarkedText() {
      submit?()
    } else {
      super.keyDown(with: event)
    }
  }
}

struct Composer: NSViewRepresentable {
  @AppStorage("writing.smoothCaret") private var smoothCaret = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var value: String
  var focusRequest: UUID? = nil
  var changed: (String) -> Void
  var send: () -> Void
  init(value: String, focusRequest: UUID? = nil, changed: @escaping (String) -> Void, send: @escaping () -> Void) {
    self.value = value
    self.focusRequest = focusRequest
    self.changed = changed
    self.send = send
  }
  final class Delegate: NSObject, NSTextViewDelegate {
    var changed: ((String) -> Void)?
    func textDidChange(_ notification: Notification) {
      if let view = notification.object as? NSTextView, !view.hasMarkedText() {
        changed?(view.string)
      }
    }
  }
  func makeCoordinator() -> Delegate { Delegate() }
  func makeNSView(context: Context) -> NSScrollView {
    let out = NSScrollView()
    out.hasVerticalScroller = true
    out.drawsBackground = false
    let field = QuestionText()
    field.delegate = context.coordinator
    field.font = .systemFont(ofSize: 15.5)
    if let selection = AtlasTheme.current.nativeColor(.selection) {
      field.selectedTextAttributes[.backgroundColor] = selection
    }
    field.isRichText = false
    field.allowsUndo = true
    field.drawsBackground = false
    field.textColor = AtlasTheme.current.nativeColor(.ink) ?? NSColor(calibratedRed: 0.145, green: 0.173, blue: 0.192, alpha: 1)
    field.textContainerInset = NSSize(width: 8, height: 8)
    field.isVerticallyResizable = true
    field.isHorizontallyResizable = false
    field.autoresizingMask = [.width]
    field.textContainer?.widthTracksTextView = true
    field.setAccessibilityLabel("输入问题")
    out.documentView = field
    return out
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? QuestionText else { return }
    context.coordinator.changed = changed
    view.smoothTyping = smoothCaret && !reduceMotion
    view.submit = send
    if !view.hasMarkedText(), view.string != value { view.string = value }
    view.requestFocus(focusRequest)
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Delegate) {
    coordinator.changed = nil
    guard let field = scroll.documentView as? QuestionText else { return }
    field.requestFocus(nil)
    field.afterComposition = nil
    field.submit = nil
    field.delegate = nil
  }

}

extension Notification.Name {
  static let atlasSavePDFPlace = Notification.Name("LivingAtlasSavePDFPlace")
  static let atlasRestorePDFPlace = Notification.Name("LivingAtlasRestorePDFPlace")
}

enum PDFZoomAction { case zoomIn, zoomOut, fitWidth }

// A canvas entrance can outlive its PDFView when the reader is folded or offscreen.
final class PDFZoomRequest {
  let action: PDFZoomAction
  let versionID: String
  fileprivate(set) var applied = false

  init(action: PDFZoomAction, versionID: String) {
    self.action = action
    self.versionID = versionID
  }
}

enum PDFScaleMode: String, Codable { case automatic, fixed, fitWidth }

struct CanvasReaderFactory: EnvironmentKey {
  static let defaultValue = CanvasReaderFactory()
  var pdf: @MainActor () -> SourcePDFView = { SourcePDFView() }
  var web: @MainActor (WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: .zero, configuration: $0) }
}

extension EnvironmentValues {
  var canvasReaderFactory: CanvasReaderFactory {
    get { self[CanvasReaderFactory.self] }
    set { self[CanvasReaderFactory.self] = newValue }
  }
}

class SourcePDFView: PDFView {
  var widthChanged: (() -> Void)?
  private var oldWidth: CGFloat = 0
  override func layout() {
    super.layout()
    guard abs(bounds.width - oldWidth) > 1 else { return }
    oldWidth = bounds.width
    widthChanged?()
  }
}

struct PDFReadingPlace: Codable, Equatable {
  var page: Int
  var x: Double
  var y: Double
  var selection: PDFAnchor?
  var navigation: UUID? = nil
  var scaleMode: PDFScaleMode? = nil
  var scale: Double? = nil
  var pageTop: Bool? = nil
}

struct DocumentReader: NSViewRepresentable {
  let file: AtlasPDF
  var store: AtlasStore? = nil
  var placementID: String? = nil
  var remembersPlace = true
  var focus: PDFAnchor?
  var focusRequest: UUID? = nil
  var citation: PDFAnchor? = nil
  var zoomRequest: PDFZoomRequest? = nil
  var markChange: UUID? = nil
  var locked: ((String) -> Void)? = nil
  let selected: (PDFAnchor?) -> Void
  let failure: (String) -> Void

  final class Coordinator: NSObject {
    weak var marksDocument: PDFDocument?
    var installedMarks: [PDFAnnotation] = []
    var locked: ((String) -> Void)?
    var lastMarkChange: UUID?
    weak var view: PDFView?
    var remembersPlace = true
    var placementID: String?
    var placeKey:String { placementID.map {"map.pdf."+$0+"."+version} ?? ("pdf."+version) }
    var version = ""
    var applied: PDFAnchor?
    var requestedFocus: UUID?
    var requestedAnchor: PDFAnchor?
    var requestedCitation: PDFAnchor?
    var painted: PDFAnchor?
    // PDFKit uses this explicit color for both active and inactive text selection.
    static let citationInk = NSColor(calibratedRed: 0.97, green: 0.73, blue: 0.25, alpha: 0.46)
    func matchesCitation(_ selection: PDFAnchor?) -> Bool {
      guard let selection, let painted, selection.versionID == painted.versionID,
        selection.segments.count == painted.segments.count
      else { return false }
      return zip(selection.segments, painted.segments).allSatisfy {
        $0.pageIndex == $1.pageIndex && $0.start == $1.start && $0.end == $1.end
      }
    }
    var zoomCommand: PDFZoomRequest?
    var scaleMode: PDFScaleMode = .automatic
    private var widthFitPending = false

    func scheduleWidthFit() {
      guard scaleMode == .fitWidth, !restoring, !widthFitPending else { return }
      widthFitPending = true
      // PDFKit may lay out several intermediate widths within one AppKit update.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.widthFitPending = false
        if let view = self.view { self.zoom(in: view, forResize: true) }
      }
    }

    func fitScale(in view: PDFView, page: PDFPage) -> CGFloat {
      let drawn = view.convert(page.bounds(for: view.displayBox), from: page).width
      guard drawn > 0 else { return view.scaleFactorForSizeToFit }
      let available = view.documentView?.enclosingScrollView?.contentSize.width ?? view.bounds.width
      return view.scaleFactor
        * max(1, available - view.pageBreakMargins.left - view.pageBreakMargins.right) / drawn
    }
    func setScale(_ newScale: CGFloat, in view: PDFView, layoutImmediately: Bool = true) {
      guard newScale.isFinite, newScale > 0 else { return }
      let minScale = max(0.08, view.minScaleFactor)
      let maxScale = view.maxScaleFactor > minScale ? view.maxScaleFactor : max(8, minScale)
      view.autoScales = false
      view.scaleFactor = min(maxScale, max(minScale, newScale))
      if layoutImmediately { view.layoutSubtreeIfNeeded() }
    }

    func zoom(in view: PDFView, forResize: Bool = false) {
      let action: PDFZoomAction
      if forResize {
        guard scaleMode == .fitWidth, !restoring else { return }
        action = .fitWidth
      } else {
        guard let command = zoomCommand, command.versionID == version, !command.applied
        else { return }
        action = command.action
      }
      guard let doc = view.document else { return }
      let destination = view.currentDestination
      guard let page = destination?.page ?? view.currentPage ?? doc.page(at: 0) else { return }
      if !forResize { zoomCommand?.applied = true }
      let position = destination?.point
      switch action {
      case .zoomIn:
        scaleMode = .fixed
        setScale(view.scaleFactor * 1.25, in: view)
      case .zoomOut:
        scaleMode = .fixed
        setScale(view.scaleFactor / 1.25, in: view)
      case .fitWidth:
        scaleMode = .fitWidth
        setScale(fitScale(in: view, page: page), in: view, layoutImmediately: !forResize)
      }
      if let position { view.go(to: PDFDestination(page: page, at: position)) }
      scheduleSave()
    }

    func restoreScale(_ place: PDFReadingPlace, in view: PDFView, document: PDFDocument) {
      scaleMode = place.scaleMode ?? .automatic
      switch scaleMode {
      case .automatic: view.autoScales = true
      case .fixed: if let scale = place.scale { setScale(scale, in: view) }
      case .fitWidth:
        if let page = document.page(at: place.page) {
          setScale(fitScale(in: view, page: page), in: view)
        }
      }
    }

    var appliedRequest: UUID?
    var selected: ((PDFAnchor?) -> Void)?
    var failure: ((String) -> Void)?
    var store: AtlasStore?
    var selection: PDFAnchor?
    var lastSaved: PDFReadingPlace?
    var restoring = false
    var pending: DispatchWorkItem?
    var scrollObserver: NSObjectProtocol?
    var positionObserver: NSObjectProtocol?

    @objc func selectionChanged() {
      guard !restoring, let view, let doc = view.document else { return }
      do {
        if let current = view.currentSelection, !(current.string ?? "").isEmpty {
          selection = try PDFAnchor.capture(current, document: doc, versionID: version)
          current.color = matchesCitation(selection) ? Self.citationInk : nil
        } else {
          selection = nil
        }
        selected?(selection)
        scheduleSave()
      } catch {
        selected?(nil)
        // PDFKit may expose an intermediate mouse-drag selection without text coordinates.
        selection = nil
      }
    }
    func scheduleSave() {
      guard !restoring else { return }
      pending?.cancel()
      let item = DispatchWorkItem { [weak self] in self?.save() }
      pending = item
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }
    func save() {
      guard remembersPlace, !restoring, let view, let doc = view.document, let target = view.currentDestination,
        let page = target.page, !version.isEmpty, let store
      else { return }
      let index = doc.index(for: page)
      guard index != NSNotFound, target.point.x.isFinite, target.point.y.isFinite else { return }
      let place = PDFReadingPlace(
        page: index, x: target.point.x, y: target.point.y, selection: selection,
        navigation: appliedRequest, scaleMode: scaleMode,
        scale: scaleMode == .fixed ? view.scaleFactor : nil)
      guard place != lastSaved else { return }
      do {
        try store.saveViewState(place, key: placeKey)
        lastSaved = place
      } catch { failure?(error.localizedDescription) }
    }
    func detachObservers() {
      for token in [scrollObserver, positionObserver].compactMap({ $0 }) {
        NotificationCenter.default.removeObserver(token)
      }
      scrollObserver = nil
      positionObserver = nil
    }
    func observeScroll(_ view: PDFView) {
      detachObservers()
      if let clip = view.documentView?.enclosingScrollView?.contentView {
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
          forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in self?.scheduleSave() }
      }
      positionObserver = NotificationCenter.default.addObserver(
        forName: .PDFViewPageChanged, object: view, queue: .main
      ) { [weak self] _ in self?.scheduleSave() }
    }
    func paint(in view: PDFView, document: PDFDocument) {
      let anchor = [requestedAnchor, requestedCitation].compactMap { $0 }.first {
        $0.versionID == version
      }
      guard anchor != painted else { return }
      painted = anchor
      if let anchor, let hit = try? anchor.selection(in: document) {
        hit.color = Self.citationInk
        view.highlightedSelections = [hit]
      } else {
        view.highlightedSelections = []
      }
      if let active = view.currentSelection {
        active.color = matchesCitation(selection) ? Self.citationInk : nil
        view.documentView?.needsDisplay = true
      }
    }

    func restore(_ place: PDFReadingPlace, in view: PDFView, document: PDFDocument) {
      guard let page = document.page(at: place.page) else { return }
      if let selectedAnchor = place.selection, let hit = try? selectedAnchor.selection(in: document)
      {
        hit.color = matchesCitation(selectedAnchor) ? Self.citationInk : nil
        view.setCurrentSelection(hit, animate: false)
        selection = selectedAnchor
      } else {
        view.clearSelection()
        selection = nil
      }
      if place.pageTop == true { view.go(to:page) }
      else { view.go(to: PDFDestination(page: page, at: NSPoint(x: place.x, y: place.y))) }
      appliedRequest = place.navigation
    }

    // PDFKit can replace its internal scroll view after mounting a document.
    // Resolve the owner when the live gesture arrives.
    @objc func liveMagnification(_ note: Notification) {
      guard let scroll = note.object as? NSScrollView, let view,
        scroll === view.documentView?.enclosingScrollView else { return }
      scaleMode = .fixed
      scheduleSave()
    }
    @objc func flushPlace(_ note: Notification) {
      guard let owner = note.object as? AtlasStore, owner === store else { return }
      pending?.cancel()
      save()
    }
    @objc func restorePlace(_ note: Notification) {
      guard placementID == nil, let owner = note.object as? AtlasStore, owner === store,
        note.userInfo?["version"] as? String == version,
        let place = note.userInfo?["place"] as? PDFReadingPlace,
        let view, let doc = view.document
      else { return }
      restoring = true
      pending?.cancel()
      restoreScale(place, in: view, document: doc)
      restore(place, in: view, document: doc)
      restoring = false
      selected?(selection)
      lastSaved = place
      applied = note.userInfo?["focus"] as? PDFAnchor
      appliedRequest = nil
    }

    func open(_ file: AtlasPDF, store: AtlasStore?, placementID:String?, view: PDFView) {
      pending?.cancel()
      save()
      detachObservers()
      restoring = true
      self.placementID=placementID
      version = file.versionID
      scaleMode = .automatic
      self.store = store
      applied = nil
      appliedRequest = nil
      selection = nil
      painted = nil
      lastSaved = nil
      do {view.document = try store?.readablePDF(file) ?? PDFDocument(url:file.url)}
      catch PDFUnlockError.required {
        view.document=nil;restoring=false
        DispatchQueue.main.async { [weak self] in self?.locked?(file.versionID) };return
      }catch {
        view.document=nil;restoring=false;failure?(error.localizedDescription);return
      }
      view.autoScales = true
      guard let doc = view.document else {
        restoring = false
        selected?(nil)
        failure?("无法打开这份 PDF 的原件。")
        return
      }
      do { lastSaved = remembersPlace ? try store?.readViewState(PDFReadingPlace.self, key: placeKey) : nil } catch
      { failure?(error.localizedDescription) }
      let expected = version
      DispatchQueue.main.async { [weak self, weak view] in
        guard let self, let view, self.view === view, self.version == expected, self.placementID == placementID else { return }
        view.layoutSubtreeIfNeeded()
        defer {
          self.observeScroll(view)
          self.restoring = false
          self.selected?(self.selection)
        }
        if let place = self.lastSaved { self.restoreScale(place, in: view, document: doc) }
        self.paint(in: view, document: doc)
        defer { self.zoom(in: view) }
        if let anchor = self.requestedAnchor, anchor.versionID == self.version,
          self.lastSaved == nil
            || (self.requestedFocus != nil && self.requestedFocus != self.lastSaved?.navigation)
        {
          self.apply(anchor, to: view, document: doc)
        } else if let place = self.lastSaved {
          self.restore(place, in: view, document: doc)
          self.applied = self.requestedAnchor
          self.appliedRequest = self.requestedFocus
        }
      }
    }
    func apply(_ anchor: PDFAnchor, to view: PDFView, document: PDFDocument) {
      applied = anchor
      appliedRequest = requestedFocus
      do {
        let hit = try anchor.selection(in: document)
        hit.color = Self.citationInk
        view.go(to: hit)
        view.setCurrentSelection(hit, animate: false)
        selection = anchor
        selected?(anchor)
      } catch { failure?(error.localizedDescription) }
    }
    deinit {
      pending?.cancel()
      detachObservers()
      NotificationCenter.default.removeObserver(self)
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> PDFView {
    let view = context.environment.canvasReaderFactory.pdf()
    view.setAccessibilityIdentifier("canvas.reader.pdf")
    let coordinator = context.coordinator
    view.widthChanged = { [weak coordinator] in coordinator?.scheduleWidthFit() }
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displaysPageBreaks = true
    view.backgroundColor = NSColor(
      calibratedRed: 247 / 255, green: 242 / 255, blue: 233 / 255, alpha: 1)
    view.pageBreakMargins = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
    NotificationCenter.default.addObserver(
      context.coordinator, selector: #selector(Coordinator.flushPlace(_:)),
      name: .atlasSavePDFPlace, object: nil)
    NotificationCenter.default.addObserver(
      context.coordinator, selector: #selector(Coordinator.restorePlace(_:)),
      name: .atlasRestorePDFPlace, object: nil)
    for name in [NSScrollView.willStartLiveMagnifyNotification, NSScrollView.didEndLiveMagnifyNotification] {
      NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.liveMagnification(_:)),
        name: name, object: nil)
    }
    view.setAccessibilityLabel("PDF 阅读区")
    context.coordinator.view = view
    NotificationCenter.default.addObserver(
      context.coordinator, selector: #selector(Coordinator.selectionChanged),
      name: .PDFViewSelectionChanged, object: view)
    return view
  }
  func updateNSView(_ view: PDFView, context: Context) {
    let c = context.coordinator
    c.selected = { [weak c, weak view] anchor in
      DispatchQueue.main.async { [weak c, weak view] in
        guard let c, let view, c.view === view, c.version == file.versionID,
          c.placementID == placementID, c.selection == anchor else { return }
        selected(anchor)
      }
    }
    c.failure = { msg in DispatchQueue.main.async { failure(msg) } }
    c.remembersPlace = remembersPlace
    c.requestedFocus = focusRequest
    c.locked = locked
    c.requestedAnchor = focus
    c.requestedCitation = citation
    c.zoomCommand = zoomRequest
    if c.version != file.versionID || c.placementID != placementID {
      c.open(file, store: store, placementID:placementID, view: view)
    } else if !c.restoring, let doc = view.document {
      c.paint(in: view, document: doc)
      c.zoom(in: view)
      if let focus, focus.versionID == file.versionID,
        c.applied != focus || c.appliedRequest != focusRequest
      {
        c.apply(focus, to: view, document: doc)
      } else if focus == nil {
        c.applied = nil
        c.appliedRequest = nil
      }
    }
    c.displayTextMarks(file,change:markChange,in:view)
  }
  static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
    coordinator.pending?.cancel()
    coordinator.save()
    coordinator.detachObservers()
    NotificationCenter.default.removeObserver(coordinator)
    coordinator.selected = nil
    coordinator.failure = nil
    coordinator.store = nil
    coordinator.view = nil
    view.document = nil
  }
}

struct CanvasAnswerReading {
  let store: AtlasStore
  let placementID: String
  let runID: String
  let onFailure: (String) -> Void
  var key: String { "map.answer-place." + placementID + "." + runID }

  struct Place: Codable, Equatable {
    struct Scroll: Codable, Equatable { let block: Int; let offset: Double; let following: Bool }
    struct Point: Codable, Equatable { let block, offset: Int }
    struct TextRange: Codable, Equatable { let start, end: Point; let text: String; let backward: Bool }
    let scroll: Scroll?
    let range: TextRange?
  }
}
extension Notification.Name {
  static let atlasSaveAnswerPlace = Notification.Name("LivingAtlasSaveAnswerPlace")
}

struct AnswerReader: NSViewRepresentable {
  let text: String
  var streaming = false
  var zoom:Double = 1
  var reading: CanvasAnswerReading?
  var measured: ((Double) -> Void)?
  var naturalCanvasHeight = false
  var onReaderScroll: (() -> Void)?
  var canvasWheelEnabled = false
  var collecting = false
  var onInteraction: ((Bool) -> Void)?
  var onSelectText: (() -> Void)?
  var selectedSource: ((String,NSRange?,CGPoint?) -> Void)?

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var measured: ((Double) -> Void)?
    var onSelectText: (() -> Void)?
    var selectedSource: ((String,NSRange?,CGPoint?) -> Void)?
    var naturalCanvasHeight = false
    var onReaderScroll: (() -> Void)?
    var renderedWheelMode: Int?
    private(set) var wheelLayoutReady = false
    private var scrollAbove = false, scrollBelow = false
    private struct HorizontalArea { let bounds: CGRect; let left, right: Bool }
    private var horizontalScrollAreas: [HorizontalArea] = []

    func scrollsInside(_ web: WKWebView, at windowPoint: CGPoint, dx: CGFloat, dy: CGFloat) -> Bool {
      guard canvasWheelEnabled, wheelLayoutReady else { return true }
      if abs(dx) <= abs(dy) { return dy < 0 ? scrollBelow : scrollAbove }
      let local = web.convert(windowPoint, from: nil)
      let y = web.isFlipped ? local.y - web.bounds.minY : web.bounds.maxY - local.y
      let css = CGPoint(x: (local.x - web.bounds.minX) / web.pageZoom, y: y / web.pageZoom)
      return horizontalScrollAreas.contains { $0.bounds.contains(css) && (dx < 0 ? $0.right : $0.left) }
    }
    var canvasWheelEnabled = false
    var onInteraction: ((Bool) -> Void)?
    var reading: CanvasAnswerReading?
    var place: CanvasAnswerReading.Place?
    var pendingSave: DispatchWorkItem?
    var navigation: WKNavigation?

    func remember(_ next: CanvasAnswerReading.Place) {
      guard next != place else { return }
      place = next
      // Coalesce scroll events, including a final flush when the reader leaves the canvas.
      if pendingSave == nil {
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
      }
    }
    func flush() {
      guard let pendingSave, let reading, let place else { return }
      pendingSave.cancel()
      do {
        try reading.store.saveViewState(place, key: reading.key)
        self.pendingSave = nil
      } catch {
        self.pendingSave = nil
        reading.onFailure(error.localizedDescription)
      }
    }
    @objc func closing(_ notification: Notification) {
      if let store = notification.object as? AtlasStore, store === reading?.store { flush() }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message:WKScriptMessage){
      guard ready, message.frameInfo.isMainFrame else { return }
      if message.name == "atlasAnswerPlace" {
        if let raw = message.body as? String,
          let next = try? JSONDecoder().decode(CanvasAnswerReading.Place.self, from: Data(raw.utf8)) {
          remember(next)
        }
        return
      }
      if message.name == "atlasTextSelected" { onSelectText?(); return }
      if message.name == "atlasActivity", let active = message.body as? Bool {
        onInteraction?(active)
        return
      }
      if message.name == "atlasPan", message.body as? String == "reader-scroll" { onReaderScroll?(); return }
      if message.name == "atlasPan", let layout = message.body as? [String: Any],
         let above = layout["above"] as? Bool, let below = layout["below"] as? Bool,
         let rows = layout["horizontal"] as? [[Double]] {
        scrollAbove = above
        scrollBelow = below
        horizontalScrollAreas = rows.compactMap { row in
          guard row.count == 6, row.allSatisfy(\.isFinite) else { return nil }
          return HorizontalArea(bounds: CGRect(x: row[0], y: row[1], width: row[2], height: row[3]),
                                left: row[4] != 0, right: row[5] != 0)
        }
        wheelLayoutReady = true
        return
      }
      if message.name == "atlasHeight",let height=message.body as? Double,height.isFinite,height>=0 {
        measured?(height)
        return
      }
      guard message.name == "atlasExcerpt", let values=message.body as? [String:Any],let body=values["body"] as? String else {return}
      var range:NSRange?
      if let start=values["start"] as? Int,let end=values["end"] as? Int,start>=0,end>start,end<=body.utf16.count { range=NSRange(location:start,length:end-start) }
      var screenPoint:CGPoint?
      if let web=message.webView, let window=web.window,
        let x=values["x"] as? Double, let y=values["y"] as? Double, x.isFinite, y.isFinite {
        let local = CGPoint(x:x * web.pageZoom, y:web.isFlipped ? y * web.pageZoom : web.bounds.height - y * web.pageZoom)
        screenPoint=window.convertPoint(toScreen:web.convert(local,to:nil))
      }
      selectedSource?(body,range,screenPoint)
    }
    var collecting = false
    var renderedCollecting: Bool?
    var streaming = false
    var latest = ""
    var rendered: String?
    var renderedNatural: Bool?
    var renderedStreaming: Bool?
    var ready = false
    var rendering = false

    func display(in view: WKWebView) {
      let natural = naturalCanvasHeight
      let wheelMode = canvasWheelEnabled ? (onReaderScroll == nil ? 1 : 2) : 0
      let live = streaming
      let picking = collecting
      guard ready, !rendering, rendered != latest || renderedNatural != natural || renderedWheelMode != wheelMode || renderedStreaming != live || renderedCollecting != picking else { return }
      let value = latest
      rendering = true
      var args: [String: Any] = ["value": value, "streaming": live, "natural": natural, "picking": picking, "wheelMode": wheelMode,
        "place": NSNull()]
      if rendered == nil, let place, let data = try? JSONEncoder().encode(place) {
        args["place"] = try? JSONSerialization.jsonObject(with: data)
      }
      let expectedNavigation = navigation
      view.callAsyncJavaScript(
        "window.renderAnswer(value, streaming, natural, picking, place, wheelMode)", arguments: args, in: nil, in: .defaultClient
      ) { [weak self, weak view] result in
        guard let self, let view, self.ready, self.navigation === expectedNavigation else { return }
        self.rendering = false
        self.renderedCollecting = picking
        self.renderedNatural = natural
        self.renderedWheelMode = wheelMode
        self.renderedStreaming = live
        switch result {
        case .success: self.rendered = value
        case .failure:
          // Keep a readable, inert answer if the isolated script fails.
          view.callAsyncJavaScript(
            "document.getElementById('answer').textContent=value", arguments: ["value": value],
            in: nil, in: .defaultClient, completionHandler: nil)
          self.rendered = value
        }
        self.display(in: view)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard let navigation, self.navigation === navigation else { return }
      ready = true
      display(in: webView)
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(
        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      ready = false
      wheelLayoutReady = false
      rendering = false
      rendered = nil
      navigation = webView.loadHTMLString(AnswerMarkdown.document, baseURL: nil)
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    AtlasFontScheme.install(in: config)
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    if let reading {
      let coordinator = context.coordinator
      coordinator.reading = reading
      do { coordinator.place = try reading.store.readViewState(CanvasAnswerReading.Place.self, key: reading.key) }
      catch { reading.onFailure(error.localizedDescription) }
      config.userContentController.add(coordinator, contentWorld: .defaultClient, name: "atlasAnswerPlace")
      NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.closing(_:)),
        name: .atlasSaveAnswerPlace, object: reading.store)
    }
    if measured != nil {
      config.userContentController.add(context.coordinator,contentWorld:.defaultClient,name:"atlasPan")
      config.userContentController.add(context.coordinator,contentWorld:.defaultClient,name:"atlasHeight")
    }
    if onSelectText != nil {
      config.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "atlasTextSelected")
    }
    if onInteraction != nil {
      config.userContentController.add(context.coordinator,contentWorld:.defaultClient,name:"atlasActivity")
    }
    if selectedSource != nil {
      config.userContentController.add(context.coordinator,contentWorld:.defaultClient,name:"atlasExcerpt")
    }
    config.userContentController.addUserScript(
      WKUserScript(
        source: AnswerMarkdown.install,
        injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    let view = context.environment.canvasReaderFactory.web(config)
    view.setAccessibilityIdentifier("canvas.reader.web")
    context.environment.canvasTextCoordinates?.installPinch(on: view)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    context.coordinator.navigation = view.loadHTMLString(AnswerMarkdown.document, baseURL: nil)
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    if abs(view.pageZoom-zoom)>0.001 {view.pageZoom=zoom}
    context.coordinator.collecting=collecting
    context.coordinator.onInteraction=onInteraction
    context.coordinator.onSelectText = onSelectText
    context.coordinator.naturalCanvasHeight = naturalCanvasHeight
    context.coordinator.onReaderScroll = onReaderScroll
    context.coordinator.canvasWheelEnabled = canvasWheelEnabled
    context.coordinator.measured=measured
    context.coordinator.selectedSource=selectedSource
    context.coordinator.streaming = streaming
    context.coordinator.latest = text
    context.coordinator.display(in: view)
  }
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.flush()
    coordinator.reading = nil
    NotificationCenter.default.removeObserver(coordinator)
    coordinator.navigation = nil
    coordinator.ready = false
    coordinator.measured = nil
    coordinator.onSelectText = nil
    coordinator.onInteraction = nil
    coordinator.canvasWheelEnabled = false
    coordinator.selectedSource = nil
    let controller = view.configuration.userContentController
    for name in ["atlasPan", "atlasHeight", "atlasExcerpt", "atlasTextSelected", "atlasActivity", "atlasAnswerPlace"] {
      controller.removeScriptMessageHandler(forName: name, contentWorld: .defaultClient)
    }
    view.navigationDelegate = nil
  }

}
