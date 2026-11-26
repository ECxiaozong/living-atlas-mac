import AppKit
import AtlasCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private struct MapCamera: Codable {
  static let minimumZoom = 0.15
  var x = 16.0, y = 24.0, zoom = 0.82
  struct ReadingPlace: Codable {
    let x, y, zoom: Double
    let viewport: CGSize
    let selection: [String]
    let regions: Set<String>
    let focus: String?
    var worldRect: CGRect {
      CGRect(x: -x / zoom, y: -y / zoom, width: viewport.width / zoom, height: viewport.height / zoom)
    }
  }
  var readingPlace: ReadingPlace?
  var overviewFloor: Double?
  var distant: Bool { overview && zoom < 0.38 }
  var overview = true {
    didSet { if !overview { readingPlace = nil; overviewFloor = nil } }
  }
  mutating func scale(_ factor: Double, at p: CGPoint) {
    let next = min(2, max(overviewFloor ?? Self.minimumZoom, zoom * factor))
    x = p.x - (p.x - x) * next / zoom
    y = p.y - (p.y - y) * next / zoom
    zoom = next
  }
}

final class MapSurface: NSView {
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  var copyObjects: (() -> Void)?
  var pasteObjects: (() -> Void)?
  var replayLayout: ((Bool) -> Void)?
  private var historyKeys: Any?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { wheelRouting.attach(self) } else { wheelRouting.detach() }
    if let historyKeys { NSEvent.removeMonitor(historyKeys); self.historyKeys = nil }
    guard window != nil else { return }
    // AppKit dispatches menu equivalents before keyDown. The titled paper can leave
    // focus on PDFKit, WebKit or a hosting view after the drag commits.
    historyKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let window = self.window, window.isKeyWindow,
        event.window == nil || event.window === window,
        event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }
      let modifiers = event.modifierFlags.intersection([.command,.shift,.control,.option])
      guard modifiers == .command || modifiers == [.command,.shift],
        CanvasHistoryRoute.canvas(in: window) === self, let replay = self.replayLayout else { return event }
      replay(modifiers.contains(.shift))
      return nil
    }
  }
  @objc func copy(_ sender: Any?) { copyObjects?() }
  @objc func paste(_ sender: Any?) { pasteObjects?() }
  var nudge: ((CGFloat, CGFloat) -> Bool)?
  var removeSelected: (() -> Bool)?
  var escapeReturn: (() -> Bool)?
  var pan: ((CGFloat, CGFloat) -> Void)?
  var magnify: ((CGFloat, CGPoint) -> Void)?
  var box: ((CGRect?, Bool, Bool) -> Void)?
  var askAt: ((CGPoint) -> Void)?
  var persist: (() -> Void)?
  private var start: CGPoint = .zero, last: CGPoint = .zero
  private let wheelRouting = CanvasWheelRouting()
  var observeWheel: ((NSEvent) -> Void)?
  var trialArea: ((CGPoint) -> String)?
  var panTool = false {
    didSet { if oldValue != panTool { window?.invalidateCursorRects(for: self) } }
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    let cursor: NSCursor = moving ? .closedHand : (panTool || space ? .openHand : .crosshair)
    addCursorRect(visibleRect, cursor: cursor)
  }
  private var space = false, moving = false
  var temporaryPan: ((Bool) -> Void)?
  private var spaceEvents: Any?
  private var resignKey: NSObjectProtocol?

  private func setSpace(_ held: Bool) {
    guard space != held else { return }
    space = held
    temporaryPan?(held || moving)
    window?.invalidateCursorRects(for: self)
  }

  func watchSpace() {
    spaceEvents = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard event.keyCode == 49, let self, let window = self.window,
            event.window == nil || event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return event }
      if event.type == .keyUp {
        guard self.space else { return event }
        self.setSpace(false)
        return nil
      }
      if self.space { return nil }
      let p = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
      guard self.visibleRect.contains(p), !self.isHiddenOrHasHiddenAncestor,
            NSEvent.pressedMouseButtons == 0,
            event.modifierFlags.intersection([.command,.option,.control]).isEmpty,
            (window.firstResponder as? NSTextView)?.isEditable != true,
            (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
            !(window.firstResponder is NSControl) else { return event }
      self.setSpace(true)
      return nil
    }
    resignKey = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
      guard let self, let window = self.window, (note.object as? NSWindow) === window else { return }
      self.moving = false
      self.space = false
      self.temporaryPan?(false)
      window.invalidateCursorRects(for: self)
    }
  }

  func stopWatchingSpace() {
    if let spaceEvents { NSEvent.removeMonitor(spaceEvents); self.spaceEvents = nil }
    if let resignKey { NotificationCenter.default.removeObserver(resignKey); self.resignKey = nil }
  }
  override func scrollWheel(with e: NSEvent) {
    guard e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0 else { return }
    let step = e.hasPreciseScrollingDeltas ? 1.0 : 12.0
    pan?(e.scrollingDeltaX * step, e.scrollingDeltaY * step)
    persist?()
  }
  override func magnify(with e: NSEvent) {
    magnify?(1 + e.magnification, convert(e.locationInWindow, from: nil))
    persist?()
  }
  // SwiftUI may disable its text-edit menu while the canvas owns focus.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self,
      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "c": copy(nil); return true
      case "v": paste(nil); return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }
  override func keyDown(with e: NSEvent) {
    if e.keyCode == 49, e.modifierFlags.intersection([.command,.option,.control]).isEmpty {
      setSpace(true); return
    }
    if window?.firstResponder === self, e.modifierFlags.intersection([.command, .option, .control]).isEmpty {
      if e.keyCode == 51 || e.keyCode == 117 {
        if removeSelected?() == true { return }
      }
      if e.keyCode == 53 {
        if escapeReturn?() == true { return }
      }
      let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
      let delta: CGPoint
      switch e.keyCode {
      case 123: delta = CGPoint(x: -step, y: 0)
      case 124: delta = CGPoint(x: step, y: 0)
      case 125: delta = CGPoint(x: 0, y: step)
      case 126: delta = CGPoint(x: 0, y: -step)
      default: super.keyDown(with: e); return
      }
      if nudge?(delta.x, delta.y) == true { return }
    }
    super.keyDown(with: e)
  }
  override func keyUp(with e: NSEvent) {
    if e.keyCode == 49 { setSpace(false) } else { super.keyUp(with: e) }
  }
  override func mouseDown(with e: NSEvent) {
    window?.makeFirstResponder(self)
    start = convert(e.locationInWindow, from: nil)
    last = start
    moving = panTool || space || e.modifierFlags.contains(.option)
    if moving { NSCursor.closedHand.set() }
    else if e.clickCount == 2 { askAt?(start) }
  }
  override func mouseDragged(with e: NSEvent) {
    let p = convert(e.locationInWindow, from: nil)
    if moving {
      pan?(p.x - last.x, p.y - last.y)
    } else {
      box?(rect(p), e.modifierFlags.contains(.shift), false)
    }
    last = p
  }
  private func rect(_ p: CGPoint) -> CGRect {
    CGRect(
      x: min(p.x, start.x), y: min(p.y, start.y), width: abs(p.x - start.x),
      height: abs(p.y - start.y))
  }
  override func mouseUp(with e: NSEvent) {
    if moving {
      moving = false
      temporaryPan?(space)
      window?.invalidateCursorRects(for: self)
      persist?()
    } else if e.clickCount != 2 {
      box?(rect(convert(e.locationInWindow, from: nil)), e.modifierFlags.contains(.shift), true)
    }
  }
}
private struct CanvasTextCoordinatesKey: EnvironmentKey {
  static let defaultValue: MapCoordinates? = nil
}
extension EnvironmentValues {
  var canvasTextCoordinates: MapCoordinates? {
    get { self[CanvasTextCoordinatesKey.self] }
    set { self[CanvasTextCoordinatesKey.self] = newValue }
  }
}

@MainActor final class MapCoordinates: NSObject, NSGestureRecognizerDelegate {
  weak var surface: MapSurface?
  func installPinch(on reader: NSView) {
    let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(scaleFromText(_:)))
    pinch.delegate = self
    pinch.delaysMagnificationEvents = true
    reader.addGestureRecognizer(pinch)
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
    guard let window = surface?.window, gestureRecognizer.view?.window === window,
      window.attachedSheet == nil else { return false }
    return (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
  }

  @objc private func scaleFromText(_ pinch: NSMagnificationGestureRecognizer) {
    guard let surface, let window = surface.window, pinch.view?.window === window,
      pinch.state == .began || pinch.state == .changed || pinch.state == .ended else { return }
    let delta = pinch.magnification
    pinch.magnification = 0
    guard delta.isFinite, delta != 0, delta > -1 else { return }
    surface.magnify?(1 + delta, pinch.location(in: surface))
    surface.persist?()
  }
  func point(fromScreen point: CGPoint) -> CGPoint? {
    guard let surface, let window = surface.window else { return nil }
    return surface.convert(window.convertPoint(fromScreen: point), from: nil)
  }
}
private struct MapInput: NSViewRepresentable {
  let configure: (MapSurface) -> Void
  func makeNSView(context: Context) -> MapSurface {
    let v = MapSurface()
    v.watchSpace()
    configure(v)
    return v
  }
  func updateNSView(_ view: MapSurface, context: Context) { configure(view) }
  static func dismantleNSView(_ view: MapSurface, coordinator: ()) { view.stopWatchingSpace() }
}

enum CanvasAction { case ask, material, markdown, idea, region }

struct MapOverview: View {
  @ObservedObject var s: Session
  let store: AtlasStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var cameraGlide = CanvasCameraGlide()
  @ViewState private var pendingGlideTarget: MapCamera?
  @ViewState private var arrivalPulseID: String?
  @ViewState private var arrivalTask: Task<Void, Never>?
  @ViewState private var emergingBranchTarget: String?
  @ViewState private var branchReveal: CGFloat = 1
  @ViewState private var branchRevealTask: Task<Void, Never>?
  @ViewState private var scannedPages: Set<String> = []
  @ViewState private var trackedActiveRuns: Set<String> = []
  @ViewState private var newlyCompletedEntries: Set<String> = []
  var action: Binding<CanvasAction?> = .constant(nil)
  var clipboard: NSPasteboard = CanvasPasteboard.board
  var importChat: () -> Void = {}
  var canvasSearch: Binding<Bool> = .constant(false)
  var canvasOrganization: Binding<Bool> = .constant(false)
  @ViewState private var organizationQuestion: (reference: String, source: OrganizationObject?)?
  @ViewState private var returnToFocusedAnswer: MapEntry?
  @ViewState private var focusSheet: MapEntry?
  @ViewState private var overlapPlan: OrganizationPlan?
  @ViewState private var appliedLayout: String?
  @ViewState private var canvasDiffPreview: CanvasOrganizationPreview?
  @ViewState private var reopenOrganizationPlanID: String?
  private var showingOrganization: Binding<Bool> {
    canvasOrganization
  }
  @ViewState private var organizationLocation: Set<String>?
  var requestedRun: Binding<String?> = .constant(nil)
  var relationVisit: Binding<RelationEntranceVisit?> = .constant(nil)
  private struct RelationReturn {
    let origin: CanvasLocation
    let unfolded: Set<String>
    let source: CanvasRelationSource
  }
  @ViewState private var relationReturn: RelationReturn?
  private struct CanvasLocation {
    let camera: MapCamera
    let selection: [String]
    let regions: Set<String>
    let focus: String?
  }
  private struct OrganizationVisit {
    let origin: CanvasLocation
    let unfolded: Set<String>
    let located: String?
    let run: String?
  }
  @ViewState private var organizationVisit: OrganizationVisit?
  private struct TaskPreview: Identifiable { let id: String }
  @ViewState private var navigationReturn: CanvasLocation?
  private struct DirectoryListing: Identifiable {
    let id = UUID()
    let rows: [CanvasDirectory.Row]
  }
  @ViewState private var directory: DirectoryListing?
  @ViewState private var directorySelection: CanvasDirectory.Destination?
  @ViewState private var directoryUnfolded: Set<String> = []
  @ViewState private var navigationReturnLabel = "返回任务定位前"
  @ViewState private var taskPreview: TaskPreview?
  @ViewState private var locatedEntryID: String?
  @ViewState private var taskRunID: String?
  @ViewState private var compactCards = false
  private func readingEntry(_ entry: MapEntry) -> Bool {
    !camera.overview && (entry.expanded || locatedEntryID == entry.id)
      && (!compactCards || interactingReaders.contains(entry.id))
  }

  private enum SearchAction {
    case read(AtlasSearchSource)
    case ask(String)
  }
  @ViewState private var searchAction: SearchAction?
  private struct SearchVisit {
    let camera: MapCamera
    let unfolded: Set<String>
    let selection: [String]
    var pdf: CanvasPDFSource?
    var markdown: CanvasMarkdownSource?
  }
  @ViewState private var searchVisit: SearchVisit?
  @ViewState private var searchPDFSheet: CanvasPDFSource?
  @ViewState private var searchMarkdownSheet: CanvasMarkdownSource?
  private var inlineMarkdown: CanvasMarkdownSource? { searchVisit == nil ? markdownVisit : searchVisit?.markdown }
  @ViewState private var map: AtlasMap?
  @ViewState private var snapshotID = UUID()
  @ViewState private var camera = MapCamera()
  @ViewState private var selection: [String] = []
  @ViewState private var drag: CGSize = .zero
  @ViewState private var panTool = false
  @ViewState private var holdingSpace = false
  @ViewState private var hoveredEntry: String?
  @ViewState private var hoveredConnectEntry: String?
  @ViewState private var directConnectDrag: CanvasDirectConnectDrag?
  @ViewState private var directConnectPending: CanvasDirectConnectPending?
  @ViewState private var showMiniMap = false
  @ViewState private var marquee: CGRect?
  @ViewState private var inspected: MapEdge?
  @ViewState private var editingRelation: MapEdge?
  @ViewState private var removingRelation: MapEdge?
  private struct DraftMarkdownSource {
    let label: String
    let version: String
    let selection: [WritingSelection]?
  }
  @ViewState private var draftWholePDF: AtlasPDF?
  @ViewState private var draftMarkdownSource: DraftMarkdownSource?
  @ViewState private var draftRelation: CanvasRelationSource?
  @ViewState private var topicName = ""
  @ViewState private var addingTopic = false
  @ViewState private var regions: [CanvasRegion] = []
  @ViewState private var regionTree = CanvasRegionTree([])
  @ViewState private var externalEdgeCounts: [String: Int] = [:]
  @ViewState private var selectedRegions: Set<String> = []
  @ViewState private var regionDrag: CGSize = .zero
  @ViewState private var activeDrop: String?
  @ViewState private var editingRegion: CanvasRegion?
  @ViewState private var instanceTopic: String?
  @ViewState private var selectedTopics: Set<String> = []
  @ViewState private var departure: TopicDeparturePreview?
  @ViewState private var relationPair: CanvasRelationPair?
  @ViewState private var writingFragments: [String: String] = [:]
  @ViewState private var writingLabels: [String: String] = [:]
  @ViewState private var regionCounts: [String: Int] = [:]
  @ViewState private var entranceCounts: [String: Int] = [:]
  @ViewState private var writings: [String: WritingItem] = [:]
  @ViewState private var visibility = CanvasVisibility()
  @ViewState private var webPages: [String: FrozenWebPage] = [:]
  @ViewState private var endpoint: [String: MapEntry] = [:]
  @ViewState private var projections: [String: ChatProjectionNode] = [:]
  @ViewState private var openProjection: ChatProjectionNode?
  @ViewState private var paintSave: Task<Void, Never>?
  private var entries: [MapEntry] { map?.entries ?? [] }
  private var chosen: [MapEntry] { selection.compactMap { id in entries.first { $0.id == id } } }
  private func run(_ e: MapEntry) -> AtlasRun? {
    if locatedEntryID == e.id, let taskRunID {
      return s.runs.first { $0.id == taskRunID && $0.turnID == e.target }
    }
    return storedRun(e)
  }
  private func storedRun(_ e: MapEntry) -> AtlasRun? {
    (shownRuns[e.id].flatMap { id in s.runs.first { $0.id == id && $0.turnID == e.target } })
      ?? s.runs.first { $0.turnID == e.target }
  }
  @ViewState private var pageFiles: [String: AtlasPDF] = [:]
  @ViewState private var pagePicker: AtlasPDF?
  @ViewState private var pickerDocument: PDFDocument?
  @ViewState private var visitingPage: MapEntry?
  @ViewState private var regionSelections: [String: CGRect] = [:]
  @ViewState private var markRevision = 0
  private func file(_ e: MapEntry) -> AtlasPDF? {
    if let page = e.page { return pageFiles[page.version] }
    return pinnedPDFs[e.id] ?? s.docs.first { $0.id == e.target }
  }
  @ViewState private var pinnedPDFs: [String: AtlasPDF] = [:]
  @ViewState private var pdfZoom: [String: PDFZoomRequest] = [:]
  @ViewState private var sourceHighlights: [String: PDFAnchor] = [:]
  private struct SourceReturn {
    let camera: MapCamera
    let entry: MapEntry
    let runID: String
    let selection: [String]
    let focus: String?
    let unfolded: Set<String>
  }
  @ViewState private var sourceReturn: SourceReturn?
  @ViewState private var changedOrigin: SourceReturn?
  @ViewState private var inlineWholePDF: CanvasPDFSource?
  @ViewState private var temporaryPDF: CanvasPDFSource?
  @ViewState private var markdownVisit: CanvasMarkdownSource?
  @ViewState private var temporaryMarkdown: CanvasMarkdownSource?
  @ViewState private var sourceRequests: [String: UUID] = [:]
  @ViewState private var documentVisits: [String] = []
  private struct VersionChoice: Identifiable {
    let id: String
    let versions: [AtlasPDF]
  }
  @ViewState private var versionChoice: VersionChoice?
  private func changePDF(_ id: String, to file: AtlasPDF?) {
    s.perform {
      if let file { _ = try store.pdf(versionID: file.versionID) }
      pinnedPDFs[id] = file
      sourceHighlights[id] = nil
      mapPDFSelection[id] = nil
      try store.saveViewState(pinnedPDFs.mapValues(\.versionID), key: "map.pdf-versions")
      try store.saveViewState(sourceHighlights, key: "map.source-highlights")
    }
    versionChoice = nil
  }
  private func visitPage(_ file: AtlasPDF, index: Int, anchor: PDFAnchor?, region: CGRect?, from entry: MapEntry, run: AtlasRun) throws {
    rememberSourceOrigin(entry, run: run)
    let origin = try store.readViewState(String.self, key: "map.source."+run.turnID)
    let matches = entries.filter { $0.page?.version == file.versionID && $0.page?.index == index }
    let target: MapEntry
    if let existing = matches.first(where: { $0.id == origin }) ?? matches.min(by: { hypot($0.x-entry.x,$0.y-entry.y) < hypot($1.x-entry.x,$1.y-entry.y) }) {
      target = existing
      revealAncestors(of: target.regionID)
    } else {
      var paper = try store.canvasPage(file, index: index, at: CGPoint(x: entry.x, y: entry.y))
      let point = available(at: CGPoint(x: entry.x - reserved(paper).width - 52, y: entry.y), size: reserved(paper).size)
      paper.x = point.x; paper.y = point.y; target = paper; visitingPage = paper
    }
    pageFiles[file.versionID] = file
    sourceHighlights[target.id] = anchor; regionSelections[target.id] = region
    selection = [target.id]; focusedReader = target.id; revealWork(reserved(target)); pulseArrival(target.id)
  }
  private func returnFromSource() {
    guard let back = sourceReturn else { return }
    visitingPage = nil
    markdownVisit = nil
    inlineWholePDF = nil
    directoryUnfolded = back.unfolded
    update()
    selection = back.selection.filter { id in entries.contains { $0.id == id } }
    focusedReader = entries.contains { $0.id == back.focus } ? back.focus : nil
    changedOrigin = CanvasReturnLocation.locate(back.entry, in: entries) == .unchanged ? nil : back
    sourceReturn = nil
    if let moved = entries.first(where: { $0.id == back.entry.id }), (moved.x != back.entry.x || moved.y != back.entry.y) {
      camera = back.camera
      revealWork(reserved(moved))
      pulseArrival(moved.id)
      persist()
    } else {
      glideCamera(to: back.camera, persistTarget: true)
      if let focus = focusedReader { pulseArrival(focus) }
    }
  }
  private func rememberSourceOrigin(_ entry: MapEntry, run: AtlasRun) {
    changedOrigin = nil
    markdownVisit = nil
    inlineWholePDF = nil
    sourceReturn = SourceReturn(camera: camera, entry: entry, runID: run.id,
      selection: selection, focus: focusedReader, unfolded: directoryUnfolded)
  }
  private func sourceNeedsFocus(_ target: MapEntry) -> Bool {
    let pane = sourcePageSize(in: canvasSize)
    let zoom = max(0.75, camera.zoom)
    return obstructed(target, size: CGSize(width: max(reserved(target).width, pane.width / zoom),
      height: max(reserved(target).height, pane.height / zoom)))
  }
  private func revealOrigin(_ run: AtlasRun, from entry: MapEntry) {
    returnFromSearch()
    s.perform {
      if let excerpt = try store.parentExcerpt(of: run) {
        let parentID = s.runs.first { $0.id == excerpt.runID }?.turnID
        let parents = entries.filter { $0.target == parentID }
        answerOrigin = (parents.first { $0.regionID == entry.regionID } ?? parents.first)?.id
        answerPage = AnswerSourcePage(
          runID: excerpt.runID, body: excerpt.body, title: "历史回答", initial: excerpt.nativeRange,
          historical: true)
      } else if let anchor = run.anchor {
        if let page = anchor.segments.first?.pageIndex {
          try visitPage(store.pdf(versionID: anchor.versionID), index: page, anchor: anchor, region: nil, from: entry, run: run)
        }
      } else if let ref = run.sourceReferenceID {
        if let target = try store.pdfPageSourceTarget(ref) {
          try visitPage(target.file, index: target.page, anchor: nil, region: store.canvasRegionRect(ref), from: entry, run: run)
          return
        }
        if let pdf = try store.wholePDFSourceInfo(ref) {
          let source = CanvasPDFSource.resolve(version: pdf.versionID, frozenQuote: run.sourceQuote, store: store, from: entry,
            entries: entries, regions: regions, visits: documentVisits, displayed: file)
          rememberSourceOrigin(entry, run: run)
          if let target = source.entrance, !sourceNeedsFocus(target) {
            revealAncestors(of: target.regionID)
            inlineWholePDF = source
            revealSourcePage(at: target)
            rememberDocumentVisit(target.id)
          } else {
            temporaryPDF = source
          }
          return
        }
        guard let source = try CanvasMarkdownSource.resolve(reference: ref, quote: run.sourceQuote ?? "",
          store: store, from: entry, entries: entries, regions: regions, visits: documentVisits) else {
          s.openReference(ref)
          return
        }
        rememberSourceOrigin(entry, run: run)
        if let target = source.entrance, !sourceNeedsFocus(target) {
          revealAncestors(of: target.regionID)
          markdownVisit = source
          revealSourcePage(at: target)
          rememberDocumentVisit(target.id)
        } else {
          temporaryMarkdown = source
        }
      }
    }
  }
  private func item(_ e: MapEntry) -> WritingItem? { writings[e.target] }
  private func title(_ e: MapEntry) -> String {
    if let page = e.page { return (file(e)?.title ?? "PDF") + " · " + page.caption }
    return run(e)?.question ?? file(e)?.title ?? item(e)?.displayTitle ?? webPages[e.target]?.title
      ?? projections[e.target]?.title
      ?? "材料"
  }
  private func update(_ action: () throws -> Void = {}) {
    s.perform {
      try action()
      if let movedBatch, try store.latestCanvasEditID() != movedBatch { self.movedBatch = nil }
      let snapshot = try store.atlasMap()
      var files = pageFiles
      for version in Set(snapshot.entries.compactMap { $0.page?.version }) where files[version] == nil {
        files[version] = try? store.pdfInfo(versionID: version)
      }
      pageFiles = files
      snapshotID = UUID()
      map = snapshot
      naturalAnswers = Set(snapshot.entries.lazy.filter { $0.kind == "turn" && $0.readingHeight == nil }.map(\.id))
      if let shown = inspected { inspected = snapshot.edges.first { $0.id == shown.id } }
      if !answerHeights.isEmpty {
        let natural = Set(snapshot.entries.lazy.filter { $0.kind == "turn" }.map(\.id))
        answerHeights = answerHeights.filter { natural.contains($0.key) }
      }
      regions = try store.canvasRegions().map { saved in
        var region = saved
        if directoryUnfolded.contains(region.id) { region.collapsed = false }
        return region
      }
      regionTree = CanvasRegionTree(regions)
      selectedRegions.formIntersection(Set(regions.map(\.id)))
      endpoint = Dictionary(
        entries.map { ($0.target, $0) },
        uniquingKeysWith: { first, other in
          regionTree.collapsedOwner(of: first.regionID) != nil
            && regionTree.collapsedOwner(of: other.regionID) == nil ? other : first
        })
      visibility = CanvasVisibility(map: snapshot, regions: regions, tree: regionTree, endpoints: endpoint, minimumZoom: MapCamera.minimumZoom)
      var neighbours = [String: [MapEntry]]()
      var counts = [String: Int]()
      for edge in map?.edges ?? [] {
        guard let (from, to) = edge.entrances(defaults: endpoint) else { continue }
        neighbours[from.id, default: []].append(to)
        neighbours[to.id, default: []].append(from)
        let l = regionTree.collapsedOwner(of: from.regionID)
        let r = regionTree.collapsedOwner(of: to.regionID)
        if l != r {
          if let l { counts[l, default: 0] += 1 }
          if let r { counts[r, default: 0] += 1 }
        }
      }
      connectedEntrances = neighbours
      externalEdgeCounts = counts
      drafts = try store.canvasDrafts()
      writings = Dictionary(uniqueKeysWithValues: try store.writings().map { ($0.id, $0) })
      writingLabels = try store.markdownEntranceLabels()
      writingFragments = try store.writingFragments()
      regionCounts = entries.reduce(into: [:]) { counts, entry in
        if let id = entry.regionID { counts[id, default: 0] += 1 }
      }
      entranceCounts = Dictionary(grouping: entries, by: \.target).mapValues(\.count)
      let pdfIDs = Set(s.docs.map(\.id))
      for e in entries where e.kind == "document" && pinnedPDFs[e.id] == nil
        && !pdfIDs.contains(e.target) && writings[e.target] == nil {
        if let page = try store.frozenWeb(document: e.target) { webPages[e.target] = page }
      }
      for e in entries where e.kind == "content" && writings[e.target] == nil && projections[e.target] == nil {
        if let projection = try store.chatProjection(nodeID: e.target) {
          projections[e.target] = projection
        }
      }
      selection = selection.filter { id in
        entries.contains { $0.id == id && regionTree.collapsedOwner(of: $0.regionID) == nil }
      }
      selectedTopics =
        (selection.count == 1 ? (try? store.topicIDsForPlacement(selection[0])) : nil) ?? []
      selectedRegions = selectedRegions.filter { id in
        regionTree.regions[id].map { !regionTree.hides($0) } ?? false
      }
    }
  }
  private func interruptCameraGlide() {
    if cameraGlide.isRunning {
      cameraGlide.cancel()
      pendingGlideTarget = nil
    }
  }

  private func glideCamera(to target: MapCamera, persistTarget: Bool = false) {
    let start = CameraPose(x: camera.x, y: camera.y, zoom: camera.zoom)
    let dest = CameraPose(x: target.x, y: target.y, zoom: target.zoom)
    camera.overview = target.overview
    camera.readingPlace = target.readingPlace
    camera.overviewFloor = target.overviewFloor
    pendingGlideTarget = target
    if persistTarget { persist() }
    cameraGlide.glide(
      from: start,
      to: dest,
      duration: 0.21,
      reduceMotion: reduceMotion,
      step: { pose in
        camera.x = pose.x
        camera.y = pose.y
        camera.zoom = pose.zoom
      },
      finish: {
        pendingGlideTarget = nil
        if persistTarget { persist() }
      }
    )
  }

  private func pulseArrival(_ id: String) {
    arrivalTask?.cancel()
    arrivalPulseID = id
    arrivalTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(720))
      guard !Task.isCancelled else { return }
      if arrivalPulseID == id { arrivalPulseID = nil }
    }
  }

  private func triggerBranchDrawIn(targetID: String) {
    branchRevealTask?.cancel()
    guard !reduceMotion else {
      emergingBranchTarget = nil
      branchReveal = 1
      return
    }
    emergingBranchTarget = targetID
    branchReveal = 0
    withAnimation(.easeOut(duration: 0.24)) {
      branchReveal = 1
    }
    branchRevealTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(320))
      guard !Task.isCancelled else { return }
      emergingBranchTarget = nil
      branchReveal = 1
    }
  }

  private var focusAnchorID: String? {
    focusedReader ?? (selection.count == 1 ? selection.first : nil)
  }

  /// Principle 3: directly connected sources and branches of the currently focused subject.
  private func connectedToFocus(_ entryID: String) -> Bool {
    guard let anchor = focusAnchorID else { return false }
    return connectedEntrances[anchor]?.contains { $0.id == entryID } == true
  }

  /// Principle 6: returns radians pointing from viewport center to the atlas content centroid
  /// when the user has panned completely away from all visible entries and regions.
  private func offscreenContentAngle(in available: CGSize) -> Double? {
    guard available.width > 40, available.height > 40 else { return nil }
    let viewport = CGRect(origin: .zero, size: available)
    let world = worldViewport(viewport, extraHeight: answerGrowth)
    if visibility.firstEntrance(in: world, matching: { frame($0).intersects(viewport) }) != nil {
      return nil
    }
    let nearby = camera.zoom < MapCamera.minimumZoom ? regions : visibility.regionCandidates(in: world)
    if nearby.contains(where: { !regionTree.hides($0) && regionFrame($0).intersects(viewport) }) { return nil }

    let bounds = visibility.worldBounds
    guard !bounds.isNull else { return nil }
    let dx = camera.x + bounds.midX * camera.zoom - available.width / 2
    let dy = camera.y + bounds.midY * camera.zoom - available.height / 2
    guard hypot(dx, dy) > 20 else { return nil }
    return atan2(dy, dx)
  }

  private func syncBackgroundCompletions() {
    let activeNow = Set(s.runs.filter(\.status.isActive).map(\.id))
    let finishedIDs = trackedActiveRuns.subtracting(activeNow)
    for id in finishedIDs {
      if let run = s.runs.first(where: { $0.id == id && $0.status == .completed }),
        let placed = entries.first(where: { $0.kind == "turn" && $0.target == run.turnID }),
        focusedReader != placed.id
      {
        newlyCompletedEntries.insert(placed.id)
      }
    }
    trackedActiveRuns = activeNow
  }

  @ViewState private var paletteItems: [CanvasCommandPalette.Item] = []

  private func commandPaletteItems() -> [CanvasCommandPalette.Item] {
    var items: [CanvasCommandPalette.Item] = [
      .init(
        id: "cmd.ask", group: .command, title: "新建独立提问", subtitle: "在当前画布空白处展开问题面板",
        icon: "sparkles", shortcut: nil, keywords: "提问 ask question 新建",
        run: { if entries.isEmpty && regions.isEmpty { questionFocus = UUID() } else { compose() } }
      ),
      .init(id: "cmd.assistant", group: .command, title: "噗噗助手", subtitle: "用一句话打开、整理或移动材料",
        icon: "sparkles", shortcut: "⌥⌘K", keywords: "助手 自然语言 噗噗", run: { s.assistantShown = true }),
      .init(
        id: "cmd.material", group: .command, title: "放入 PDF / Markdown 资料…", subtitle: "将文献单页或 Markdown 放到当前画布",
        icon: "doc.badge.plus", shortcut: nil, keywords: "导入 资料 pdf markdown material",
        run: { chooseMaterial() }
      ),
      .init(
        id: "cmd.markdown", group: .command, title: "新建 Markdown 文档", subtitle: "在画布上创建一篇可引用、可版本化的笔记",
        icon: "doc.richtext", shortcut: nil, keywords: "markdown 文档 笔记 note",
        run: { createWriting(.markdown) }
      ),
      .init(
        id: "cmd.idea", group: .command, title: "新建灵感卡片", subtitle: "随时记录一个未成形的念头",
        icon: "lightbulb", shortcut: nil, keywords: "灵感 idea 想法",
        run: { createWriting(.idea) }
      ),
      .init(
        id: "cmd.region", group: .command, title: "新建主题地域…", subtitle: "为相关探索划定一块可折叠的地图地域",
        icon: "map", shortcut: nil, keywords: "主题 地域 region 分组",
        run: { addingTopic = true }
      ),
      .init(
        id: "cmd.toggleOverview", group: .command,
        title: camera.overview ? "切换到阅读视图" : "切换到概览视图",
        subtitle: camera.overview ? "回到可阅读与选句的近景尺度" : "拉远查看整张图谱的地域与脉络",
        icon: camera.overview ? "text.book.closed" : "rectangle.3.group",
        shortcut: nil, keywords: "概览 阅读 视图 overview reading",
        run: { changePresentation(hiding: { _ in !camera.overview }, apply: toggleOverview) }
      ),
      .init(
        id: "cmd.fit", group: .command, title: "适合全图", subtitle: "平滑缩放以纵览全部画布内容",
        icon: "arrow.up.left.and.down.right.magnifyingglass", shortcut: "⌘0", keywords: "全图 适配 fit zoom",
        run: { fit(canvasSize) }
      ),
      .init(
        id: "cmd.minimap", group: .command,
        title: showMiniMap ? "收起阅读缩略图" : "显示阅读缩略图",
        subtitle: "在画布右下角开关羊皮纸缩略俯瞰框",
        icon: "map", shortcut: nil, keywords: "缩略图 迷你地图 minimap 导航 小地图",
        run: { toggleMiniMap() }
      ),
      .init(
        id: "cmd.search", group: .command, title: "搜索本图谱…", subtitle: "全文检索问题、回答、PDF 与笔记",
        icon: "magnifyingglass", shortcut: "⇧⌘F", keywords: "搜索 检索 search find",
        run: { canvasSearch.wrappedValue = true }
      ),
      .init(
        id: "cmd.directory", group: .command, title: "打开画布目录", subtitle: "按主题地域浏览与跳转",
        icon: "list.bullet.indent", shortcut: nil, keywords: "目录 directory 列表",
        run: { showDirectory() }
      ),
    ]
    if !selection.isEmpty || !selectedRegions.isEmpty {
      items.append(.init(
        id: "cmd.organize", group: .command, title: "整理所选材料…", subtitle: "预览并审定布局或语义关系提案",
        icon: "wand.and.stars", shortcut: nil, keywords: "整理 organize diff 布局",
        run: { canvasOrganization.wrappedValue = true }
      ))
    }
    if !chosen.isEmpty {
      items.append(.init(
        id: "cmd.remove", group: .command, title: "移除选中画布入口", subtitle: "仅移出当前画布，底层资料保留且可 ⌘Z 撤销",
        icon: "minus.circle", shortcut: "⌫", keywords: "移除 删除 remove delete",
        run: { _ = coordinates.surface?.removeSelected?() }
      ))
    }
    items.append(.init(
      id: "cmd.help", group: .command, title: "画布操作帮助", subtitle: "查看基础手势与常用快捷键",
      icon: "questionmark.circle", shortcut: nil, keywords: "帮助 help 快捷键 指南",
      run: { s.canvasHelp = true }
    ))
    items.append(.init(
      id: "cmd.trial", group: .command,
      title: trial.active ? "停止试用诊断" : "开启试用诊断",
      subtitle: "记录本地手势与出帧性能日志",
      icon: trial.active ? "record.circle.fill" : "waveform.path.ecg",
      shortcut: nil, keywords: "诊断 性能 试用 diagnostics",
      run: {
        if trial.active { trial.stop() }
        else if let surface = coordinates.surface { trial.start(on: surface) }
      }
    ))

    for row in directoryRows(writingItems: Array(writings.values)) {
      let id: String
      let group: CanvasCommandPalette.Item.Group
      switch row.id {
      case .entry(let key): id = "entry." + key; group = .entry
      case .region(let key): id = "region." + key; group = .region
      }
      items.append(.init(id: id, group: group, title: row.title, subtitle: row.detail + " · " + row.path,
                         icon: row.icon, shortcut: nil, keywords: row.label,
                         run: { locateDirectoryDestination(row.id) }))
    }
    return items
  }

  private func startCanvasDiffPreview(_ plan: OrganizationPlan, picked: Set<String>) {
    reopenOrganizationPlanID = nil
    let preview = CanvasOrganizationPreview(plan: plan, selectedEditIDs: picked, showingAfter: true)
    let affected = Set(plan.edits.flatMap { [$0.target, $0.peer].compactMap { $0 } })
    for entry in entries where affected.contains(entry.id) {
      if regionTree.collapsedOwner(of: entry.regionID) != nil {
        revealAncestors(of: entry.regionID)
      }
    }
    let bounds = preview.worldBounds(entries: entries, entrySize: size)
    if !bounds.isNull, canvasSize.width > 120, canvasSize.height > 140 {
      rememberLocation("返回整理前视口")
      var next = camera
      let fitted = min(1.0, max(MapCamera.minimumZoom, min(
        (canvasSize.width - 96) / max(240, bounds.width),
        (canvasSize.height - 160) / max(160, bounds.height)
      )))
      next.overview = false
      next.zoom = fitted
      next.x = (canvasSize.width - bounds.width * fitted) / 2 - bounds.minX * fitted
      next.y = (canvasSize.height - 84 - bounds.height * fitted) / 2 - bounds.minY * fitted
      glideCamera(to: next)
    }
    withAnimation(AtlasMotion.layout(reduceMotion)) {
      canvasDiffPreview = preview
    }
  }

  private func applyCanvasDiffPreview() {
    guard let preview = canvasDiffPreview else { return }
    s.perform {
      let subset = preview.plan.edits.filter { preview.selectedEditIDs.contains($0.id) }
      guard !subset.isEmpty else { return }
      let approved = try subset.count == preview.plan.edits.count
        ? preview.plan
        : store.reviseOrganization(preview.plan.id, edits: subset)
      _ = try store.applyOrganization(approved.id)
      withAnimation(AtlasMotion.layout(reduceMotion)) {
        canvasDiffPreview = nil
        appliedLayout = approved.id
        update()
      }
    }
  }

  private func abandonCanvasDiffPreview() {
    withAnimation(AtlasMotion.surface(reduceMotion)) {
      canvasDiffPreview = nil
    }
  }

  private func toggleMiniMap() {
    withAnimation(AtlasMotion.surface(reduceMotion)) {
      showMiniMap.toggle()
    }
    let next = showMiniMap
    s.perform { try store.saveViewState(next, key: "map.minimap") }
  }

  private func panFromMiniMap(to worldPoint: CGPoint, persistNow: Bool) {
    interruptCameraGlide()
    let origin = CanvasMiniMapProjection.cameraOrigin(
      centering: worldPoint,
      viewportSize: canvasSize,
      zoom: camera.zoom
    )
    camera.x = origin.x
    camera.y = origin.y
    if persistNow { persist() }
  }

  private func miniMapView(_ available: CGSize) -> some View {
    let visibleEntries = entries.filter { regionTree.collapsedOwner(of: $0.regionID) == nil }
    let visibleRegions = regions.filter { !regionTree.hides($0) }
    let entryRectMap = Dictionary(uniqueKeysWithValues: visibleEntries.map { entry in
      (entry.id, CGRect(origin: CGPoint(x: entry.x, y: entry.y), size: size(entry)))
    })
    let nodes: [CanvasMiniMap.Node] = visibleEntries.map { entry in
      let tone: CanvasMiniMap.Node.Tone =
        entry.kind == "turn" || item(entry)?.kind == .question ? .question
        : (file(entry) != nil ? .pdf : .writing)
      return CanvasMiniMap.Node(
        id: entry.id,
        worldRect: entryRectMap[entry.id] ?? CGRect(x: entry.x, y: entry.y, width: 248, height: 116),
        tone: tone,
        selected: selection.contains(entry.id),
        focused: focusedReader == entry.id
      )
    }
    let miniEdges: [CanvasMiniMap.Edge] = (map?.edges ?? []).compactMap { edge in
      guard let a = entryRectMap[edge.from], let b = entryRectMap[edge.to] else { return nil }
      return CanvasMiniMap.Edge(
        id: edge.id,
        from: CGPoint(x: a.midX, y: a.midY),
        to: CGPoint(x: b.midX, y: b.midY)
      )
    }
    let viewportWorld = CGRect(
      x: -camera.x / max(0.01, camera.zoom),
      y: -camera.y / max(0.01, camera.zoom),
      width: Double(available.width) / max(0.01, camera.zoom),
      height: Double(available.height) / max(0.01, camera.zoom)
    )
    return CanvasMiniMap(
      nodes: nodes,
      regions: visibleRegions.map(\.frame),
      edges: miniEdges,
      viewportWorldRect: viewportWorld,
      onPanToWorldPoint: { point, persistNow in
        panFromMiniMap(to: point, persistNow: persistNow)
      },
      onFitAll: { fit(canvasSize) },
      onCollapse: { toggleMiniMap() }
    )
  }

  private func handleDirectConnectChanged(
    source: MapEntry,
    side: ConnectAnchorSide,
    point: CGPoint,
    onScreen: [MapEntry]
  ) {
    let target = CanvasDirectConnectGeometry.magneticTarget(
      at: point,
      excluding: source.id,
      entries: onScreen,
      frameForEntry: frame
    )
    directConnectDrag = CanvasDirectConnectDrag(
      sourceEntryID: source.id,
      anchorSide: side,
      currentPoint: point,
      hoveredTargetEntryID: target?.id
    )
  }

  private func handleDirectConnectEnded(source: MapEntry, point: CGPoint, onScreen: [MapEntry]) {
    let target = CanvasDirectConnectGeometry.magneticTarget(
      at: point,
      excluding: source.id,
      entries: onScreen,
      frameForEntry: frame
    )
    directConnectDrag = nil
    hoveredConnectEntry = nil
    guard let target else { return }
    withAnimation(AtlasMotion.surface(reduceMotion)) {
      directConnectPending = CanvasDirectConnectPending(
        id: UUID(),
        sourceEntryID: source.id,
        targetEntryID: target.id
      )
    }
  }

  private func commitDirectConnect() {
    guard let pending = directConnectPending,
      let fromEntry = entries.first(where: { $0.id == pending.effectiveSourceID }),
      let toEntry = entries.first(where: { $0.id == pending.effectiveTargetID })
    else {
      directConnectPending = nil
      return
    }
    do {
      let first = try relationInput(fromEntry)
      let second = try relationInput(toEntry)
      try store.relate(
        first.material,
        second.material,
        as: pending.kind,
        reason: pending.reason,
        entrances: (first.placement, second.placement),
        requestID: pending.id
      )
      withAnimation(AtlasMotion.surface(reduceMotion)) {
        directConnectPending = nil
        update()
      }
      pulseArrival(toEntry.id)
    } catch {
      directConnectPending?.error = error.localizedDescription
    }
  }

  private func persist() { s.perform { try store.saveViewState(navigationReturn?.camera ?? sourceReturn?.camera ?? searchVisit?.camera ?? relationReturn?.origin.camera ?? organizationVisit?.origin.camera ?? pendingGlideTarget ?? camera, key: "map.camera") } }
  private func queueSave() {
    paintSave?.cancel()
    paintSave = Task {
      try? await Task.sleep(for: .milliseconds(180))
      if !Task.isCancelled { persist() }
    }
  }
  private func focusLayout() {
    guard let surface = coordinates.surface, let window = surface.window,
      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
    if window.firstResponder !== surface { window.makeFirstResponder(surface) }
  }
  private func select(_ e: MapEntry) {
    if NSEvent.modifierFlags.contains(.shift) {
      if selection.contains(e.id) {
        selection.removeAll { $0 == e.id }
      } else {
        selection.append(e.id)
      }
    } else {
      selection = [e.id]
      selectedRegions.removeAll()
    }
    inspected = nil
  }
  @ViewState private var waitingForQuestionInput = false
  @ViewState private var collectingFor: String?
  @ViewState private var showsDraftCitations = false
  @ViewState private var composerHeight: CGFloat = 246
  private var collecting: Bool { collectingFor != nil && collectingFor == question?.id }
  @ViewState private var question: CanvasQuestionDraft?
  @ViewState private var drafts: [CanvasQuestionDraft] = []
  @ViewState private var questionFocus: UUID?
  @ViewState private var canvasSize: CGSize = .zero
  @StateObject private var trial = CanvasTrialDiagnostics()
  @ViewState private var coordinates = MapCoordinates()
  @ViewState private var answerOrigin: String?
  @ViewState private var resizeID: String?
  @ViewState private var resizeDelta: CGSize = .zero
  @ViewState private var naturalAnswers = Set<String>()
  @ViewState private var connectedEntrances = [String: [MapEntry]]()
  @ViewState private var answerHeights: [String: Double] = [:]
  @ViewState private var latestBranch: String?
  @ViewState private var shownRuns: [String: String] = [:]
  private func addMaterial(_ material: CanvasMaterial) {
    guard collecting, let current = question else { return }
    s.perform {
      question = try store.addCanvasMaterial(material, to: current)
      collectingFor = nil
      questionFocus = UUID()
      drafts = try store.canvasDrafts()
    }
  }
  private func compose(
    at point: CGPoint? = nil, from entry: MapEntry? = nil, anchor: PDFAnchor? = nil,
    excerpt: AnswerExcerpt? = nil, reference: String? = nil, relationVersion: String? = nil,
    markdown: (version: String, selection: [WritingSelection])? = nil
  ) {
    returnToFocusedAnswer = nil
    if collecting {
      if let anchor { addMaterial(.pdf(anchor)) }
      else if let excerpt { addMaterial(.answer(excerpt)) }
      else if let markdown { addMaterial(.markdown(version: markdown.version, selection: markdown.selection)) }
      else { s.error = "请在 PDF、Markdown 或回答中选择要加入本题的原句。" }
      return
    }
    let viewPoint = point ?? CGPoint(x: canvasSize.width * 0.40, y: canvasSize.height * 0.28)
    let world = CGPoint(x: (viewPoint.x - camera.x) / camera.zoom, y: (viewPoint.y - camera.y) / camera.zoom)
    var start = world
    if let entry {
      let source = reserved(entry)
      start = CGPoint(x: source.maxX + CanvasFootprint.columnGap, y: source.minY)
      if inlineMarkdown?.entrance?.id == entry.id {
        start.x = max(start.x, entry.x + sourcePageSize(in: canvasSize).width / camera.zoom + CanvasFootprint.columnGap)
      }
    }
    let next: CGPoint
    if let entry {
      let source = reserved(entry)
      next = CanvasFootprint.nearSource(source, preferred: start, size: CanvasFootprint.question,
        obstacles: entries.map(reserved) + drafts.map { CGRect(origin: CGPoint(x: $0.x, y: $0.y), size: CanvasFootprint.question) })
    } else {
      next = available(at: start, size: CanvasFootprint.question)
    }
    inspected = nil
    s.perform {
      let selectedRegion = selectedRegions.count == 1 ? selectedRegions.first : nil
      let destination: String?
      if let entry {
        destination = entry.regionID ?? selectedRegion
      } else if let point {
        // Region interiors pass through to MapSurface. Use the visible drawing order at the click.
        destination = regions.reversed().first {
          !$0.collapsed && !regionTree.hides($0) && regionFrame($0).contains(point)
        }?.id
      } else {
        destination = selectedRegion
      }
      let new = try store.beginCanvasQuestion(
        x: next.x, y: next.y, sourcePlacementID: entry?.id, regionID: destination, anchor: anchor,
        excerpt: excerpt, reference: reference, relationVersion: relationVersion, markdown: markdown)
      var destinationCamera = camera
      if camera.overview { destinationCamera.zoom = max(0.85, camera.zoom) }
      destinationCamera.overview = false
      let pose = CameraPose(x: camera.x, y: camera.y, zoom: camera.zoom)
        .revealingComposer(at: next, in: canvasSize, height: composerHeight, zoom: destinationCamera.zoom)
      destinationCamera.x = pose.x
      destinationCamera.y = pose.y
      glideCamera(to: destinationCamera, persistTarget: true)
      question = new
      questionFocus = UUID()
      drafts = try store.canvasDrafts()
    }
  }
  private func markdownSourceView(_ source: CanvasMarkdownSource, returnLabel: String = "返回提问处", close: (() -> Void)? = nil) -> some View {
    CanvasMarkdownSourceView(source: source, store: store, collecting: collecting,
      draftSelection: draftMarkdownSource?.version == source.version.id ? draftMarkdownSource?.selection : nil,
      ask: question == nil || collecting ? { parts in
        guard inlineMarkdown?.id == source.id || temporaryMarkdown?.id == source.id || searchMarkdownSheet?.id == source.id else { return }
        let previous = question?.id
        let adding = collecting
        compose(from: source.entrance, markdown: (source.version.id, parts))
        if adding ? !collecting : question?.id != previous {
          // The explicit follow-up owns the camera after the temporary source sheet closes.
          if temporaryMarkdown?.id == source.id && !adding { sourceReturn = nil }
          close?()
        }
      } : nil, returnLabel: returnLabel, close: close)
  }
  private func finishSearch() {
    let action = searchAction
    searchAction = nil
    switch action {
    case .ask(let reference):
      returnFromSearch()
      collectingFor = nil
      compose(reference: reference)
    case .read(let source):
      guard source.pdfAnchor != nil || source.markdownSelection != nil else { s.revealSearch(source); return }
      returnFromSearch()
      let origin = chosen.first ?? entries.first { $0.id == focusedReader }
      var visit = SearchVisit(camera: camera, unfolded: directoryUnfolded, selection: selection)
      if let anchor = source.pdfAnchor {
        let visible = entries.filter { regionTree.collapsedOwner(of: $0.regionID) == nil }
        let pdf = CanvasPDFSource.resolve(anchor: anchor, store: store, from: origin,
          entries: visible, regions: regions, visits: documentVisits, displayed: file)
        guard let target = pdf.entrance else { searchPDFSheet = pdf; return }
        visit.pdf = pdf
        openSearchVisit(visit, at: target)
      } else {
        s.perform {
          guard let page = try CanvasMarkdownSource.resolve(search: source, store: store, from: origin,
            entries: entries, regions: regions, visits: documentVisits) else { s.revealSearch(source); return }
          guard let target = page.entrance else { searchMarkdownSheet = page; return }
          visit.markdown = page
          openSearchVisit(visit, at: target)
        }
      }
    case nil: break
    }
  }
  private func openSearchVisit(_ visit: SearchVisit, at target: MapEntry) {
    searchVisit = visit
    if regionTree.collapsedOwner(of: target.regionID) != nil { revealAncestors(of: target.regionID) }
    rememberDocumentVisit(target.id)
    revealSourcePage(at: target)
  }
  private func revealSourcePage(at entry: MapEntry) {
    var next = camera
    if camera.overview { next.zoom = max(0.75, next.zoom) }
    next.overview = false
    let pose = CameraPose(x: camera.x, y: camera.y, zoom: camera.zoom)
      .revealing(at: CGPoint(x: entry.x, y: entry.y), size: sourcePageSize(in: canvasSize),
        within: CGRect(origin: .zero, size: canvasSize).insetBy(dx: 16, dy: 16), zoom: next.zoom)
    next.x = pose.x
    next.y = pose.y
    glideCamera(to: next)
    pulseArrival(entry.id)
  }
  private func rememberDocumentVisit(_ id: String) {
    let available = Set(entries.map(\.id))
    documentVisits = [id] + documentVisits.filter { $0 != id && available.contains($0) }
    s.perform { try store.saveViewState(documentVisits, key: "map.document-visits") }
  }

  private func returnFromSearch() {
    guard let visit = searchVisit else { return }
    if directoryUnfolded != visit.unfolded {
      directoryUnfolded = visit.unfolded
      update()
    }
    selection = visit.selection.filter { id in entries.contains { $0.id == id } }
    searchVisit = nil
    glideCamera(to: visit.camera, persistTarget: true)
  }
  private func locateRequestedRun() {
    guard let id = requestedRun.wrappedValue else { return }
    requestedRun.wrappedValue = nil
    guard let task = s.runs.first(where: { $0.id == id }) else {
      s.error = "这次生成已不在当前项目中。"
      return
    }
    returnFromSearch()
    if sourceReturn != nil { returnFromSource() }
    let matches = entries.filter { $0.kind == "turn" && $0.target == task.turnID && (storedRun($0)?.id == id || ($0.id == locatedEntryID && taskRunID == id)) }
    let origin = chosen.first ?? entries.first { $0.id == focusedReader }
    let visible = matches.filter { regionTree.collapsedOwner(of: $0.regionID) == nil }
    let entrance = visible.first { $0.id == origin?.id }
      ?? visible.first { $0.regionID == origin?.regionID }
      ?? visible.first
    guard let entrance else {
      taskPreview = TaskPreview(id: id)
      return
    }
    rememberLocation("返回任务定位前")
    focusEntry(entrance, runID: task.id)
  }
  private func locateRelationEntrance() {
    guard let visit = relationVisit.wrappedValue else { return }
    relationVisit.wrappedValue = nil
    update()
    guard let entry = entries.first(where: { $0.id == visit.entrance }) else {
      s.error = "这处画布入口已移除。"
      return
    }
    if relationReturn == nil {
      let origin = CanvasLocation(camera: camera, selection: selection, regions: selectedRegions, focus: focusedReader)
      relationReturn = RelationReturn(origin: origin, unfolded: directoryUnfolded, source: visit.source)
    }
    if regionTree.collapsedOwner(of: entry.regionID) != nil { revealAncestors(of: entry.regionID) }
    positionAtEntrance(entry)
  }

  private func returnToRelation() {
    guard let back = relationReturn else { return }
    directoryUnfolded = back.unfolded
    update()
    let ids = Set(entries.map(\.id))
    selection = back.origin.selection.filter(ids.contains)
    focusedReader = back.origin.focus.flatMap { ids.contains($0) ? $0 : nil }
    selectedRegions = back.origin.regions.intersection(regions.map(\.id))
    relationReturn = nil
    s.relationSource = back.source
    glideCamera(to: back.origin.camera, persistTarget: true)
  }

  private func rememberLocation(_ label: String) {
    if navigationReturn == nil {
      navigationReturn = CanvasLocation(camera: camera, selection: selection, regions: selectedRegions, focus: focusedReader)
    }
    navigationReturnLabel = label
  }
  private func focusEntry(_ entrance: MapEntry, runID: String? = nil) {
    locatedEntryID = entrance.id
    taskRunID = runID
    positionAtEntrance(entrance)
  }
  private func positionAtEntrance(_ entrance: MapEntry) {
    selectedRegions.removeAll()
    selection = [entrance.id]
    focusedReader = entrance.id
    var next = camera
    next.overview = false
    next.zoom = max(0.75, next.zoom)
    next.x = 32 - entrance.x * next.zoom
    next.y = 62 - entrance.y * next.zoom
    glideCamera(to: next)
    pulseArrival(entrance.id)
  }
  private func returnFromLocation() {
    guard let back = navigationReturn else { return }
    navigationReturn = nil
    taskRunID = nil
    locatedEntryID = nil
    if !directoryUnfolded.isEmpty {
      directoryUnfolded.removeAll()
      update()
    }
    selectedRegions = back.regions.intersection(regions.map(\.id))
    selection = back.selection.filter { id in entries.contains { $0.id == id && regionTree.collapsedOwner(of: $0.regionID) == nil } }
    focusedReader = entries.contains { $0.id == back.focus } ? back.focus : nil
    glideCamera(to: back.camera, persistTarget: true)
  }
  private func showDirectory() {
    // List the entrances in the current map. Edges do not participate in directory filtering.
    // Inline editors can rename a document without changing the layout snapshot.
    let writingItems: [WritingItem]
    do { writingItems = try store.writings() }
    catch { s.error = error.localizedDescription; return }
    directorySelection = nil
    directory = DirectoryListing(rows: directoryRows(writingItems: writingItems))
  }
  private func directoryRows(writingItems: [WritingItem]) -> [CanvasDirectory.Row] {
    let runs = Dictionary(s.runs.map { ($0.turnID, $0) }, uniquingKeysWith: { first, _ in first })
    let documents = Dictionary(uniqueKeysWithValues: s.docs.map { ($0.id, $0) })
    let written = Dictionary(uniqueKeysWithValues: writingItems.map { ($0.id, $0) })
    let topics = Dictionary(uniqueKeysWithValues: (map?.topics ?? []).map { ($0.id, $0.title) })
    func regionName(_ region: CanvasRegion) -> String {
      guard let topicID = region.topicID, let topic = topics[topicID], topic != region.title
      else { return region.title }
      return region.title + "（主题：" + topic + "）"
    }
    let paths = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, regionTree.path(to: $0.id, naming: regionName)) })
    func parentPath(_ id: String?) -> String { id.flatMap { paths[$0] } ?? "画布根层" }
    var rows = regions.map { region in
      CanvasDirectory.Row(id: .region(region.id), title: regionName(region),
        detail: region.collapsed ? "地域（已折叠）" : "地域", path: parentPath(region.parentID), icon: "map")
    }
    for entry in entries {
      let title: String, kind: String, icon: String
      if let turn = runs[entry.target] { (title, kind, icon) = (turn.question, "问答", "bubble.left") }
      else if let page = entry.page {
        title = documents[entry.target]?.title ?? "PDF"
        let version = pageFiles[page.version].map { "版本 " + String($0.ordinal) } ?? "版本不可用"
        kind = "PDF · " + page.caption + " · " + version
        icon = "doc.richtext"
      } else if let pdf = pinnedPDFs[entry.id] ?? documents[entry.target] {
        (title, kind, icon) = (pdf.title, "PDF · 版本 " + String(pdf.ordinal), "doc.richtext")
      } else if let item = written[entry.target] {
        let identity = writingLabels[entry.id].map { " · " + $0 } ?? ""
        (title, kind, icon) = (item.displayTitle, item.kind.label + identity, "pencil")
      } else if let page = webPages[entry.target] { (title, kind, icon) = (page.title, "网页", "globe") }
      else if let node = projections[entry.target] { (title, kind, icon) = (node.title, "聊天", "bubble.left") }
      else { (title, kind, icon) = ("材料", "入口", "doc") }
      rows.append(.init(id: .entry(entry.id), title: title, detail: kind, path: parentPath(entry.regionID), icon: icon))
    }
    // Two copies can even share a title and region. Keep both independently addressable.
    let counts = Dictionary(grouping: rows, by: \.label).mapValues(\.count)
    var indices: [String: Int] = [:]
    let labeled: [CanvasDirectory.Row] = rows.map { row in
      guard counts[row.label, default: 0] > 1 else { return row }
      let index = indices[row.label, default: 0] + 1
      indices[row.label] = index
      return .init(id: row.id, title: row.title, detail: row.detail + " · 第 " + String(index) + " 处",
        path: row.path, icon: row.icon)
    }
    return labeled
  }
  private func consumeAssistantDestination() {
    guard let id = s.assistantDestination else { return }
    s.assistantDestination = nil
    locateDirectoryDestination(.entry(id))
  }
  private func locateFromDirectory() {
    guard let destination = directorySelection else { return }
    directorySelection = nil
    locateDirectoryDestination(destination)
  }
  private func locateDirectoryDestination(_ destination: CanvasDirectory.Destination) {
    returnFromSearch()
    if sourceReturn != nil { returnFromSource() }
    update()
    let parent: String?
    switch destination {
    case .entry(let id):
      guard let entry = entries.first(where: { $0.id == id }) else { s.error = "这个画布入口已移除。"; return }
      parent = entry.regionID
    case .region(let id):
      guard let region = regionTree.regions[id] else { s.error = "这个地域已移除。"; return }
      parent = region.parentID
    }
    rememberLocation("返回出发位置")
    revealAncestors(of: parent)
    switch destination {
    case .entry(let id):
      if let entry = entries.first(where: { $0.id == id }) { focusEntry(entry) }
    case .region(let id):
      guard let region = regionTree.regions[id] else { return }
      focusRegion(region)
    }
  }
  private func revealAncestors(of parent: String?) {
    // Reveal only the target's ancestors for this visit. No layout command or membership change.
    var next = parent, seen = Set<String>(), unfold = Set<String>()
    while let id = next, seen.insert(id).inserted, let region = regionTree.regions[id] {
      if region.collapsed || directoryUnfolded.contains(id) { unfold.insert(id) }
      next = region.parentID
    }
    directoryUnfolded = unfold
    update()
  }
  private func focusRegion(_ region: CanvasRegion) {
    locatedEntryID = nil
    taskRunID = nil
    focusedReader = nil
    selection = []
    selectedRegions = [region.id]
    var next = camera
    if region.collapsed && next.distant { next.zoom = 0.75 }
    if !region.collapsed {
      next.zoom = min(1.25, max(MapCamera.minimumZoom, min((canvasSize.width - 64) / max(1, region.frame.width),
        (canvasSize.height - 64) / max(1, region.frame.height))))
    }
    let size = CanvasRegionChrome.displaySize(region, zoom: next.zoom)
    next.x = (canvasSize.width - size.width) / 2 - region.frame.minX * next.zoom
    next.y = (canvasSize.height - size.height) / 2 - region.frame.minY * next.zoom
    glideCamera(to: next)
  }
  private func openOnMap(_ target: String, preferred: String? = nil, center: Bool = false) {
    update()
    guard
      let e = entries.first(where: { $0.target == target && $0.id == preferred })
        ?? entries.first(where: { $0.target == target })
    else { return }
    update {
      var parent = e.regionID
      while let id = parent, let region = regions.first(where: { $0.id == id }) {
        if region.collapsed { try store.setRegionCollapsed(id, collapsed: false) }
        parent = region.parentID
      }
      if !e.expanded { try store.toggleMapEntry(e) }
      if camera.distant { camera.zoom = 0.75 }
      camera.overview = false
      resumeReader(e)
      selection = [e.id]
      if center || !frame(e).intersects(CGRect(origin: .zero, size: canvasSize)) {
        camera.x = 32 - e.x * camera.zoom
        camera.y = 32 - e.y * camera.zoom
      }
      persist()
    }
  }
  private func materialOrigin() -> CGPoint {
    // Pick a visible spot with the smallest overlap. Existing objects keep their world coordinates.
    let width = 400 * camera.zoom, height = 340 * camera.zoom
    let xs = [0.0, 0.5, 1.0].map { 16 + $0 * max(0, canvasSize.width - width - 32) }
    let ys = [0.0, 0.5, 1.0].map { 62 + $0 * max(0, canvasSize.height - height - 78) }
    let occupied = entries.filter { regionTree.collapsedOwner(of: $0.regionID) == nil }.map(frame)
    var best = CGPoint(x: xs[0], y: ys[0])
    var leastOverlap = CGFloat.infinity
    for y in ys {
      for x in xs {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let overlap = occupied.reduce(CGFloat.zero) { sum, other in
          let covered = rect.intersection(other)
          return sum + (covered.isNull ? 0 : covered.width * covered.height)
        }
        if overlap < leastOverlap { best = rect.origin; leastOverlap = overlap }
      }
    }
    return available(at: CGPoint(x: (best.x - camera.x) / camera.zoom, y: (best.y - camera.y) / camera.zoom), size: CGSize(width: 400, height: 340))
  }
  @ViewState private var pasteNotice: String?
  @ViewState private var movedBatch: String?

  private func recordMove(_ move: (String) throws -> Void) {
    let batch = UUID().uuidString
    update {
      try move(batch)
      withAnimation(AtlasMotion.surface(reduceMotion)) {
        movedBatch = batch
      }
    }
  }
  private func entranceReference(_ entry: MapEntry) throws -> CanvasReference {
    let pin: String?
    if entry.kind == "turn" {
      pin = entry.id == locatedEntryID ? taskRunID ?? shownRuns[entry.id] : shownRuns[entry.id]
    } else if item(entry) != nil {
      pin = try store.readViewState(CanvasWritingState.self, key: CanvasWritingState.key(entry.id))?.pinnedVersion
    } else { pin = pinnedPDFs[entry.id]?.versionID }
    return CanvasReference(entry: entry, pin: pin)
  }

  private func copySelectedEntrances() {
    guard selectedRegions.isEmpty, !chosen.isEmpty else { return }
    s.perform {
      var references: [CanvasReference] = []
      var texts: [String] = []
      for entry in chosen {
        let reference = try entranceReference(entry)
        let text: String
        if let run = run(entry) {
          text = [run.question, run.answer].filter { !$0.isEmpty }.joined(separator: "\n\n")
        } else if let file = file(entry) {
          let pdf = try? store.readablePDF(store.pdf(versionID: file.versionID))
          let body = pdf?.allowsCopying == true ? pdf?.string : nil
          text = [file.title, body].compactMap { $0 }.joined(separator: "\n\n")
        } else if let writing = item(entry) {
          let live = try store.writing(id: writing.id)
          if reference.pin == nil, let draft = live.draft {
            text = draft
          } else if let version = reference.pin ?? live.currentVersionID {
            guard let source = try store.writingVersions(live).first(where: { $0.id == version }) else {
              throw AtlasStoreError.invalid("找不到要复制的正文版本。")
            }
            text = source.body
          } else { text = live.displayTitle }
        } else {
          text = webPages[entry.target]?.body ?? projections[entry.target]?.body ?? title(entry)
        }
        references.append(reference)
        texts.append(text.isEmpty ? title(entry) : text)
      }
      try CanvasPasteboard(workspace: store.workspaceID, references: references)
        .write(text: texts.joined(separator: "\n\n"), to: clipboard)
    }
  }
  private func insertReferences(_ references: [CanvasReference], at origin: CGPoint) throws {
    let ids = try store.pasteCanvasReferences(references, at: origin)
    let pins = try store.readViewState([String: String].self, key: "map.pdf-versions") ?? [:]
    pinnedPDFs = pins.compactMapValues { try? store.pdfInfo(versionID: $0) }
    shownRuns = try store.readViewState([String: String].self, key: "map.shown-runs") ?? [:]
    update()
    selection = ids
    selectedRegions = []
    pasteNotice = "已添加引用入口，共享原正文"
  }
  private func pasteOnCanvas() {
    let origin = materialOrigin()
    s.perform {
      if let data = clipboard.data(forType: CanvasPasteboard.type),
        let payload = try? JSONDecoder().decode(CanvasPasteboard.self, from: data),
        let refs = payload.references(in: store), !refs.isEmpty {
        try insertReferences(refs, at: origin)
      } else if let text = clipboard.string(forType: .string), !text.isEmpty {
        let writing = try store.createWriting(.markdown, canvasOrigin: origin, initialText: text)
        openOnMap(writing.id)
        pasteNotice = "已粘贴文本快照"
      }
    }
  }
  private func chooseMaterial() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    addFile(url)
  }
  private func addFile(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    if url.pathExtension.lowercased() == "pdf" {
      s.importPDF(at: url, canvasOrigin: nil, deferPlacement: true, onMap: choosePage)
    } else {
      s.perform {
        guard ["md","markdown"].contains(url.pathExtension.lowercased()) else {
          throw AtlasStoreError.invalid("可以在画布中放入 PDF 或 Markdown。")
        }
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) else { throw AtlasStoreError.invalid("请选择 UTF-8 Markdown。") }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let page = try WrittenMarkdown.parse(normalized)
        let item = try store.importMarkdown(from: url, original: data, blocks: page.blocks.map(\.content), canvasOrigin: materialOrigin())
        openOnMap(item.id)
      }
    }
  }
  private func consumePageRequest() {
    guard let request = s.pageToPlace, canvasSize.width > 0, map != nil else { return }
    s.pageToPlace = nil
    if let index = request.index { putPages(request.file, indices: [index]) }
    else { choosePage(request.file) }
  }
  private func choosePage(_ file: AtlasPDF) {
    s.perform { pickerDocument = try store.readablePDF(file); pagePicker = file }
  }
  private func putPages(_ file: AtlasPDF, indices: [Int], near: CGPoint? = nil) {
    s.perform {
      var point = near ?? materialOrigin()
      var result = [MapEntry]()
      var obstacles = entries.map(reserved) + drafts.map { CGRect(origin: CGPoint(x: $0.x, y: $0.y), size: CanvasFootprint.question) }
      for index in indices {
        var entry = try store.canvasPage(file, index: index, at: point)
        let size = reserved(entry).size
        point = CanvasFootprint.available(near: point, size: size, obstacles: obstacles, viewport: canvasSize)
        entry.x = point.x; entry.y = point.y
        obstacles.append(reserved(entry)); result.append(entry)
        point.x += size.width + CanvasFootprint.columnGap
      }
      if indices.isEmpty { result = [store.canvasBook(file, at: available(at: point, size: CGSize(width: 400, height: 340)))] }
      try store.putCanvasEntries(result)
      pagePicker = nil; pickerDocument = nil
      update()
      if let first = result.first { select(first); focusedReader = first.id; revealWork(reserved(first)); persist() }
    }
  }
  private func revealWork(_ world: CGRect) {
    var next = camera
    next.overview = false
    next.zoom = max(0.85, next.zoom)
    let safe = CGRect(x: 20, y: 52, width: max(100,canvasSize.width-40), height: max(100,canvasSize.height-110))
    let box = CGRect(x: next.x + world.minX*next.zoom, y: next.y + world.minY*next.zoom,
      width: world.width*next.zoom, height: world.height*next.zoom)
    func correction(_ lo: CGFloat, _ hi: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
      if hi-lo > end-start || lo < start { return start-lo }
      return min(0, end-hi)
    }
    next.x += correction(box.minX,box.maxX,safe.minX,safe.maxX)
    next.y += correction(box.minY,box.maxY,safe.minY,safe.maxY)
    glideCamera(to: next)
  }
  private func importCanvasPDF() {
    s.importDocument(update: false, deferPlacement: true, onMap: choosePage)
  }
  private func createWriting(_ kind: WritingKind) {
    s.perform {
      let item = try store.createWriting(kind, canvasOrigin: materialOrigin())
      openOnMap(item.id)
    }
  }
  private func changeTopic(_ draft: CanvasQuestionDraft, _ topic: String?) {
    s.perform {
      question = try store.setCanvasTopic(draft, topicID: topic)
      drafts = try store.canvasDrafts()
    }
  }
  private func saveQuestionText(_ text: String, in draft: CanvasQuestionDraft) throws {
    let saved = try store.editCanvasQuestion(draft, text: text)
    question = saved
    // Only this draft changed. Keep it at the front of the menu without fetching every draft.
    if drafts.first?.id == saved.id { drafts[0] = saved }
    else {
      drafts.removeAll { $0.id == saved.id }
      drafts.insert(saved, at: 0)
    }
  }
  private func keepQuestion(_ draft: CanvasQuestionDraft) {
    update {
      let saved = try store.keepCanvasQuestion(draft)
      question = nil
      collectingFor = nil
      drafts = try store.canvasDrafts()
      selection = ["map.content." + saved.id]
    }
  }
  private func composerOrigin(_ draft: CanvasQuestionDraft, in pane: CGSize) -> CGPoint {
    let origin = CGPoint(x: camera.x + draft.x * camera.zoom, y: camera.y + draft.y * camera.zoom)
    let width = CameraPose.composerWidth(in: pane)
    let paper = CGRect(origin: origin, size: CGSize(width: width, height: composerHeight))
    guard paper.intersects(CGRect(origin: .zero, size: pane)) else { return origin }
    return CGPoint(x: min(max(12, origin.x), max(12, pane.width - width - 12)),
                   y: min(max(12, origin.y), max(12, pane.height - composerHeight - 52)))
  }
  private func questionPanel(_ draft: CanvasQuestionDraft) -> some View {
    let topicTitle = draft.topicID.flatMap { id in map?.topics.first { $0.id == id }?.title } ?? "未归类"
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        TaskCompanion(pose: .exploring)
        VStack(alignment: .leading, spacing: 3) {
          Text(draft.citations.isEmpty ? (draft.referenceID == nil ? "独立提问" : "继续探索") : "结合材料提问")
            .font(AtlasTypeface.reading.font(17).weight(.medium))
          HStack(spacing: 5) {
            Text("放入主题").font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
            Menu {
              Button("未归类") { changeTopic(draft, nil) }
              ForEach(map?.topics ?? []) { topic in
                Button(topic.title) { changeTopic(draft, topic.id) }
              }
            } label: {
              AtlasMenuPillLabel(title: topicTitle, compact: true)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(AtlasMenuButtonStyle(compact: true))
            .fixedSize()
            .accessibilityLabel(topicTitle)
          }
        }
        Spacer()
        Button("收起草稿") { question = nil }
          .buttonStyle(AtlasChipButtonStyle())
          .keyboardShortcut(.cancelAction)
      }
      if let pdf = draftWholePDF {
        let detail = draft.quote?.isEmpty == false ? "整份文档" : "仅引用版本，未附正文"
        Text("引自 " + pdf.title + " · 版本 " + String(pdf.ordinal) + " · " + detail)
          .font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
      }
      if let draftMarkdownSource {
        Text(draftMarkdownSource.label).font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
      }
      if let quote = draft.quote, !quote.isEmpty {
        AtlasQuoteCallout(text: quote)
          .textSelection(.enabled)
      }
      if let draftRelation {
        Button("本次引用 · 查看关系与两端依据") { s.relationSource = draftRelation }
          .buttonStyle(AtlasChipButtonStyle(emphasized: true))
      }
      HStack(spacing: 6) {
        Button(waitingForQuestionInput ? "确认候选文字后添加" : "添加引用材料") {
          if let field = coordinates.surface?.window?.firstResponder as? QuestionText, field.hasMarkedText() {
            waitingForQuestionInput = true
            field.afterComposition = { text in
              waitingForQuestionInput = false
              guard let current = question, current.id == draft.id else { return }
              s.perform {
                if current.text != text { question = try store.editCanvasQuestion(current, text: text) }
                collectingFor = draft.id
              }
            }
          } else { collectingFor = draft.id }
        }
        .buttonStyle(AtlasChipButtonStyle())
        if !draft.citations.isEmpty {
          Button("查看材料（" + String(draft.citations.count) + "）") { showsDraftCitations = true }
            .buttonStyle(AtlasChipButtonStyle(emphasized: true))
        }
      }
      ZStack(alignment: .topLeading) {
        if draft.text.isEmpty {
          Text("写下你的追问，⌘↵ 提交…")
            .font(.system(size: 14.5))
            .foregroundStyle(AtlasPalette.umber.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .allowsHitTesting(false)
        }
        Composer(
          value: draft.text, focusRequest: questionFocus,
          changed: { text in
            guard let current = question, current.id == draft.id, current.text != text else { return }
            s.perform { try saveQuestionText(text, in: current) }
          }, send: { if let current = question { s.send(canvas: current) } }
        ).id(draft.id)
      }
      .frame(height: 76)
      .background(AtlasPalette.paperInset.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(AtlasPalette.line.opacity(0.45), lineWidth: 0.8)
      }
      HStack {
        Button("丢弃草稿") {
          s.perform {
            try store.discardCanvasDraft(draft)
            question = nil
            drafts = try store.canvasDrafts()
          }
        }
        .buttonStyle(AtlasChipButtonStyle())
        Spacer()
        Button("只保存问题") { if let current = question { keepQuestion(current) } }
          .buttonStyle(AtlasChipButtonStyle()).disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("提交问题") { if let current = question { s.send(canvas: current) } }
          .buttonStyle(PaperButton(primary: true, compact: true))
          .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .frame(width: CameraPose.composerWidth(in: canvasSize))
    .paperSheet(cornerRadius: 14, elevated: true)
  }
  @ViewState private var answerPage: AnswerSourcePage?
  @ViewState private var materialReview: AtlasRun?
  @ViewState private var mapPDFSelection: [String: PDFAnchor] = [:]
  @ViewState private var editorFocus = CanvasEditorFocus()
  @ViewState private var awaitingComposition = false
  private func changePresentation(hiding: (String) -> Bool, apply: @escaping () -> Void) {
    guard let field = coordinates.surface?.window?.firstResponder as? CanvasTextView,
      hiding(field.placementID)
    else { apply(); return }
    let change = { [weak field] in
      awaitingComposition = false
      guard let field, field.saveBeforeHiding?(field.string) != false else { return }
      editorFocus.returningTo = field.placementID
      apply()
    }
    if field.hasMarkedText() {
      awaitingComposition = true
      field.afterComposition = change
    } else {
      change()
    }
  }
  @ViewState private var editingPlacements: Set<String> = []
  @ViewState private var streamingReaders: [String: String] = [:]
  @ViewState private var selectingReaders: [String: String] = [:]
  private func holdReader(_ id: String, run: String, active: Bool, in readers: Binding<[String: String]>) {
    if active { readers.wrappedValue[id] = run }
    else if readers.wrappedValue[id] == run { readers.wrappedValue[id] = nil }
  }
  @ViewState private var focusedReader: String?
  @ViewState private var resumedReaders: Set<String> = []
  private var interactingReaders: Set<String> {
    var held = editingPlacements.union(streamingReaders.keys).union(selectingReaders.keys).union(mapPDFSelection.keys)
    if let original = sourceReturn?.entry.id { held.insert(original) }
    return held
  }
  private func resumeReader(_ entry: MapEntry) {
    let viewport = CGRect(origin: .zero, size: canvasSize)
    let onScreen = visible(viewport)
    let visibleIDs = onScreen.filter { frame($0).intersects(viewport) }.map(\.id)
    var resumed = readers(onScreen).intersection(visibleIDs)
    resumed.insert(entry.id)
    rememberResumedReaders(resumed)
    focusedReader = entry.id
  }
  private func rememberResumedReaders(_ ids: Set<String>) {
    guard ids != resumedReaders else { return }
    resumedReaders = ids
    s.perform { try store.saveViewState(ids.sorted(), key: "map.resumed-readers") }
  }
  private var answerGrowth: Double {
    guard !camera.overview else { return 0 }
    let tallest = answerHeights.compactMap { naturalAnswers.contains($0.key) ? $0.value : nil }.max() ?? 200
    return max(0, tallest - 200)
  }
  private func worldViewport(_ rect: CGRect, extraHeight: Double = 0) -> CGRect {
    let z = camera.zoom
    let rect = CGRect(x: (rect.minX - camera.x) / z, y: (rect.minY - camera.y) / z,
      width: rect.width / z, height: rect.height / z)
    // A growing answer and a live drag or resize can extend past the persisted bounds.
    return rect.insetBy(dx: -(max(abs(drag.width), abs(regionDrag.width)) / z + abs(resizeDelta.width)),
      dy: -(max(abs(drag.height), abs(regionDrag.height)) / z + abs(resizeDelta.height) + extraHeight))
  }
  private func visible(_ viewport: CGRect) -> [MapEntry] {
    let padded = viewport.insetBy(dx: -50, dy: -50), world = worldViewport(padded, extraHeight: answerGrowth)
    var held = interactingReaders
    if let focusedReader { held.insert(focusedReader) }
    return visibility.entrances(in: world, keeping: held).filter { entry in
      held.contains(entry.id) || frame(entry).intersects(padded)
    }
  }
  private func readers(_ onScreen: [MapEntry]) -> Set<String> {
    guard !camera.overview else { return [] }
    let expanded = onScreen.filter(readingEntry)
    let priority =
      expanded.filter { $0.id == focusedReader }
      + expanded.filter { selection.contains($0.id) && $0.id != focusedReader }
    var result = interactingReaders
    result.formUnion(priority.prefix(6).map(\.id))
    for e in expanded where result.count < 6 { result.insert(e.id) }
    // Explicitly resumed readers keep their contents together while visible.
    for e in expanded where resumedReaders.contains(e.id) { result.insert(e.id) }
    return result
  }
  private func size(_ e: MapEntry) -> CGSize {
    if e.page != nil { return reserved(e).size }
    guard readingEntry(e) else { return DistantCanvas.cardSize }
    let base = reserved(e).size
    let delta = e.id == resizeID ? resizeDelta : .zero
    return CGSize(width: max(320, base.width + delta.width), height: max(220, base.height + delta.height))
  }
  private func reserved(_ e: MapEntry) -> CGRect {
    CanvasFootprint.reserved(e, measuredHeight: answerHeights[e.id].map { CGFloat($0) })
  }
  private func available(at point: CGPoint, size: CGSize) -> CGPoint {
    let occupied = entries.map(reserved) + (visitingPage.map { [reserved($0)] } ?? []) + drafts.map {
      CGRect(origin: CGPoint(x: $0.x, y: $0.y), size: CanvasFootprint.question)
    }
    return CanvasFootprint.available(near: point, size: size, obstacles: occupied,
      viewport: CGSize(width: canvasSize.width / camera.zoom, height: canvasSize.height / camera.zoom))
  }
  private func obstructed(_ e: MapEntry, size: CGSize) -> Bool {
    let target = CGRect(origin: reserved(e).origin, size: size)
    return entries.contains { $0.id != e.id && reserved($0).intersects(target) }
  }
  private func frame(_ e: MapEntry) -> CGRect {
    let d =
      regionTree.belongsToSelection(e.regionID, selected: selectedRegions)
        || selection.contains(e.id) ? (regionDrag == .zero ? drag : regionDrag) : .zero
    let z = camera.zoom
    let w = size(e)
    return CGRect(
      x: camera.x + e.x * z + d.width, y: camera.y + e.y * z + d.height, width: w.width * z,
      height: w.height * z)
  }
  private func adjustZoom(_ factor: Double, available: CGSize) {
    interruptCameraGlide()
    let focus = entries.first(where: { $0.id == focusedReader }) ?? chosen.first
    let p =
      focus.map { CGPoint(x: frame($0).midX, y: frame($0).midY) }
      ?? CGPoint(x: available.width / 2, y: available.height / 2)
    camera.scale(factor, at: p)
    persist()
  }
  private func showLocalContext(_ entry: MapEntry) {
    var next = camera
    if !next.overview {
      next.readingPlace = .init(x: camera.x, y: camera.y, zoom: camera.zoom, viewport: canvasSize,
        selection: selection, regions: selectedRegions, focus: focusedReader)
    }
    next.overview = true
    var family = connectedEntrances[entry.id] ?? []
    let parents = Set((map?.edges ?? []).filter { $0.history && $0.to == entry.target }.map(\.from))
    for edge in map?.edges ?? [] where edge.history && parents.contains(edge.from) {
      if let sibling = edge.resolvedEntrances(defaults: endpoint).to { family.append(sibling) }
    }
    let subject = CGRect(origin: CGPoint(x: entry.x, y: entry.y), size: DistantCanvas.cardSize)
    let bounds = family.filter { regionTree.collapsedOwner(of: $0.regionID) == nil }.reduce(subject) {
      $0.union(CGRect(origin: CGPoint(x: $1.x, y: $1.y), size: DistantCanvas.cardSize))
    }
    let fitted = min((canvasSize.width - 80) / bounds.width, (canvasSize.height - 100) / bounds.height)
    next.zoom = min(0.9, max(0.55, fitted))
    let center = fitted < 0.55 ? subject : bounds
    next.x = canvasSize.width / 2 - center.midX * next.zoom
    next.y = canvasSize.height / 2 - center.midY * next.zoom
    glideCamera(to: next, persistTarget: true)
  }

  private func toggleOverview() {
    if camera.overview {
      var next = camera
      if let place = camera.readingPlace {
        next.x = place.x
        next.y = place.y
        next.zoom = place.zoom
        let visibleIDs = Set(entries.filter { regionTree.collapsedOwner(of: $0.regionID) == nil }.map(\.id))
        selection = place.selection.filter { visibleIDs.contains($0) }
        selectedRegions = place.regions.filter { regionTree.regions[$0].map { !regionTree.hides($0) } ?? false }
        focusedReader = place.focus.flatMap { visibleIDs.contains($0) ? $0 : nil }
      } else if camera.distant {
        next.scale(0.75 / next.zoom, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
      }
      next.overview = false
      glideCamera(to: next, persistTarget: true)
    } else {
      camera.readingPlace = .init(x: camera.x, y: camera.y, zoom: camera.zoom, viewport: canvasSize,
        selection: selection, regions: selectedRegions, focus: focusedReader)
      camera.overview = true
      fit(canvasSize)
    }
  }

  private func previewOverlap(_ anchor: MapEntry, selected: [MapEntry]? = nil) {
    let neighbours = (selected ?? entries.filter { reserved($0).intersects(reserved(anchor)) }).filter { $0.id != anchor.id }
    s.perform {
      let targets = Set(neighbours.map(\.id))
      guard targets.count <= 20, targets.isDisjoint(with: editingPlacements.union(selectingReaders.keys).union(mapPDFSelection.keys)) else {
        throw AtlasStoreError.invalid("请缩小所选范围，并结束选字或编辑后再整理。")
      }
      let sizes = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, reserved($0).size) })
      let runs = Dictionary(uniqueKeysWithValues: ([anchor] + neighbours).compactMap { entry in
        run(entry).map { (entry.id, $0.id) }
      })
      let plan = try store.previewOverlap(anchor: anchor.id, neighbours: targets, sizes: sizes,
        cameraOrigin: CGPoint(x: camera.x, y: camera.y), zoom: camera.zoom, displayedRuns: runs)
      withAnimation(AtlasMotion.layout(reduceMotion)) {
        overlapPlan = plan
      }
    }
  }
  private func finishLayout(_ plan: OrganizationPlan, apply: Bool) {
    s.perform {
      if apply {
        let moving = Set(plan.edits.map(\.target))
        guard moving.isDisjoint(with: editingPlacements.union(selectingReaders.keys).union(mapPDFSelection.keys)),
          plan.scope.presentationSizes?.allSatisfy({ id, expected in
            entries.first { $0.id == id }.map { reserved($0).size == expected } == true
          }) == true else { throw AtlasStoreError.invalid("阅读状态已变化，请取消后重新预览。") }
        for edit in plan.edits {
          guard let x = edit.x, let y = edit.y, let target = entries.first(where: { $0.id == edit.target }) else { throw AtlasStoreError.invalid("入口已变化。") }
          let box = CGRect(origin: CGPoint(x: x,y: y), size: reserved(target).size)
          guard !entries.contains(where: { !moving.contains($0.id) && reserved($0).intersects(box) }) else {
            throw AtlasStoreError.invalid("预览位置已被占用，请重新预览。")
          }
        }
        _ = try store.applyOrganization(plan.id)
        appliedLayout = plan.id
      } else { try store.abandonOrganization(plan.id) }
      withAnimation(AtlasMotion.layout(reduceMotion)) {
        overlapPlan = nil
        update()
      }
    }
  }
  private func finishOrganization() {
    if let next = organizationQuestion {
      organizationQuestion = nil
      collectingFor = nil
      let entry = next.source.flatMap { source in
        entries.first { $0.id == source.id && $0.target == source.target }
      }
      if let entry, regionTree.collapsedOwner(of: entry.regionID) != nil || !frame(entry).intersects(CGRect(origin: .zero, size: canvasSize)) {
        rememberLocation("返回整理前视口")
        revealAncestors(of: entry.regionID)
        positionAtEntrance(entry)
      }
      compose(from: entry, reference: next.reference)
      return
    }
    guard let ids = organizationLocation else { return }
    organizationLocation = nil
    let members = entries.filter { ids.contains($0.id) }
    guard !members.isEmpty, canvasSize.width > 72, canvasSize.height > 64 else { return }
    if organizationVisit == nil {
      let origin = CanvasLocation(camera: camera, selection: selection, regions: selectedRegions, focus: focusedReader)
      organizationVisit = OrganizationVisit(origin: origin, unfolded: directoryUnfolded, located: locatedEntryID, run: taskRunID)
    }
    var ancestors = Set<String>()
    for entry in members {
      var next = entry.regionID
      while let id = next, ancestors.insert(id).inserted { next = regionTree.regions[id]?.parentID }
    }
    directoryUnfolded.formUnion(ancestors)
    update()
    selection = members.map(\.id)
    selectedRegions = []
    focusedReader = nil
    inspected = nil
    camera.overview = true
    let bounds = members.reduce(CGRect.null) {
      $0.union(CGRect(origin: CGPoint(x: $1.x, y: $1.y), size: DistantCanvas.cardSize))
    }
    let zoom = min(1.1, (canvasSize.width - 72) / bounds.width, (canvasSize.height - 64) / bounds.height)
    camera.overviewFloor = zoom < MapCamera.minimumZoom ? zoom : nil
    camera.zoom = zoom
    camera.x = canvasSize.width / 2 - bounds.midX * zoom
    camera.y = canvasSize.height / 2 - bounds.midY * zoom
  }

  private func returnFromOrganization() {
    guard let visit = organizationVisit else { return }
    organizationVisit = nil
    directoryUnfolded = visit.unfolded
    update()
    let ids = Set(entries.map(\.id))
    selection = visit.origin.selection.filter(ids.contains)
    selectedRegions = visit.origin.regions.intersection(regions.map(\.id))
    focusedReader = visit.origin.focus.flatMap { ids.contains($0) ? $0 : nil }
    locatedEntryID = visit.located.flatMap { ids.contains($0) ? $0 : nil }
    taskRunID = locatedEntryID == nil ? nil : visit.run
    glideCamera(to: visit.origin.camera, persistTarget: true)
  }

  private func fit(_ available: CGSize) {
    let rects =
      entries.filter { regionTree.collapsedOwner(of: $0.regionID) == nil }.map {
        CGRect(origin: CGPoint(x: $0.x, y: $0.y), size: size($0))
      }
      + regions.filter { !regionTree.hides($0) }.map { $0.frame }
    guard let first = rects.first else { persist(); return }
    var world = rects.dropFirst().reduce(first) { $0.union($1) }
    if camera.overview, let place = camera.readingPlace { world = world.union(place.worldRect) }
    guard available.width > 72, available.height > 64 else { return }
    let fitted = min(camera.overview ? 0.37 : 1.25, (available.width - 72) / max(1, world.width),
                     (available.height - 64) / max(1, world.height))
    guard fitted.isFinite && fitted > 0 else { return }
    if !camera.overview && fitted < 0.38 {
      changePresentation(hiding: { _ in true }) {
        toggleOverview()
      }
      return
    }
    var next = camera
    next.overviewFloor = fitted < MapCamera.minimumZoom ? fitted : nil
    next.zoom = fitted
    next.x = (available.width - world.width * next.zoom) / 2 - world.minX * next.zoom
    next.y = (available.height - world.height * next.zoom) / 2 - world.minY * next.zoom
    glideCamera(to: next, persistTarget: true)
  }
  private var emptyCanvas: some View {
    let draftText = question?.text ?? ""
    let hasInput = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        TaskCompanion(pose: draftText.isEmpty ? .calm : .exploring)
        VStack(alignment: .leading, spacing: 4) {
          Text("你想先弄清什么？")
            .font(AtlasTypeface.reading.font(24).weight(.medium))
            .foregroundStyle(AtlasPalette.ink)
          Text("直接写下困惑，或拖入 PDF / Markdown 开始这张图谱")
            .font(.system(size: 12.5))
            .foregroundStyle(AtlasPalette.umber)
        }
      }
      PaperRule()
      ZStack(alignment: .topLeading) {
        if draftText.isEmpty {
          Text("例如：进程回收后，界面状态和未提交输入应该怎样区分恢复？")
            .font(AtlasTypeface.reading.font(15))
            .foregroundStyle(AtlasPalette.umber.opacity(0.52))
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .allowsHitTesting(false)
        }
        Composer(value: draftText, focusRequest: questionFocus, changed: { text in
          guard text != (question?.text ?? "") else { return }
          s.perform {
            let draft: CanvasQuestionDraft
            if let current = question { draft = current }
            else {
              camera.overview = false; camera.zoom = max(1, camera.zoom)
              let origin = CGPoint(x: ((canvasSize.width-CanvasFootprint.question.width)/2-camera.x)/camera.zoom,
                y: ((canvasSize.height-CanvasFootprint.question.height)/2-camera.y)/camera.zoom)
              draft = try store.beginCanvasQuestion(x: origin.x, y: origin.y)
            }
            try saveQuestionText(text, in: draft)
          }
        }, send: { if let question { s.send(canvas: question) } })
      }
      .frame(height: 98)
      .background(AtlasPalette.paperInset.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(AtlasPalette.line.opacity(0.46), lineWidth: 0.85)
      }
      HStack(spacing: 9) {
        Button(action: chooseMaterial) {
          Label("放入资料…", systemImage: "doc.badge.plus")
        }
        .buttonStyle(PaperButton())
        Spacer()
        Button("只保存问题") { if let question { keepQuestion(question) } }
          .buttonStyle(PaperButton())
          .disabled(!hasInput)
        Button {
          if let question { s.send(canvas: question) }
        } label: {
          HStack(spacing: 6) {
            Text("提交问题")
            Text("⌘↵")
              .font(.system(size: 10.5, weight: .medium, design: .monospaced))
              .padding(.horizontal, 4.5)
              .padding(.vertical, 1.5)
              .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }
        .buttonStyle(PaperButton(primary: true))
        .disabled(!hasInput)
      }
    }
    .padding(26)
    .frame(width: min(516, max(280, canvasSize.width - 36)))
    .paperSheet(cornerRadius: 16, elevated: true)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      AtlasFolioCartouche()
        .padding(.bottom, 26)
    }
  }
  private func edgeInspector(_ edge: MapEdge) -> some View {
    let pair = edge.resolvedEntrances(defaults: endpoint)
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        HStack(spacing: 6) {
          Circle().fill(edge.history ? AtlasPalette.umber : AtlasPalette.blueInk).frame(width: 7, height: 7)
          Text(edge.label).font(AtlasTypeface.reading.font(15).weight(.semibold))
        }
        Spacer()
        Button("关闭") { withAnimation(AtlasMotion.surface(reduceMotion)) { inspected = nil } }.buttonStyle(AtlasChipButtonStyle())
      }
      PaperRule()
      Text(
        (pair.from.map(title) ?? "入口已移除")
          + (edge.directed ? " → " : " ↔ ")
          + (pair.to.map(title) ?? "入口已移除"))
        .font(.system(size: 13.5, weight: .medium))
      if !edge.explanation.isEmpty {
        Text(edge.explanation).font(.callout).foregroundStyle(AtlasPalette.ink.opacity(0.88)).textSelection(.enabled)
      }
      if edge.relationVersion != nil {
        Button(edge.explanation.isEmpty ? "补充关系说明" : "编辑关系说明") { editingRelation = edge }
          .buttonStyle(AtlasChipButtonStyle(emphasized: true))
      }
      if let version = edge.relationVersion {
        Button("查看关系依据") { s.perform { s.relationSource = try store.canvasRelationSource(version: version) } }
          .buttonStyle(PaperButton(compact: true))
        HStack(spacing: 8) {
          Button("就这条关系提问") {
            let previous = question?.id
            compose(relationVersion: version)
            if let current = question?.id, current != previous { inspected = nil }
          }.buttonStyle(PaperButton(primary: true, compact: true))
          Menu {
            Button("修改关系…") { editingRelation = edge }
            Button("移除关系…") { removingRelation = edge }
          } label: {
            AtlasMenuPillLabel(title: "管理关系", compact: true)
          }
          .menuStyle(.button)
          .menuIndicator(.hidden)
          .buttonStyle(AtlasMenuButtonStyle(compact: true))
          .fixedSize()
          .accessibilityLabel("管理关系")
        }
      }
      if let run = s.runs.first(where: { $0.turnID == edge.to && (edge.toVersion == nil || $0.versionID == edge.toVersion) }) {
        Button(edge.history ? "打开这条追问" : "阅读回答") {
          inspected = nil
          if let entry = pair.to {
            rememberLocation("返回关系位置")
            if regionTree.collapsedOwner(of: entry.regionID) != nil { revealAncestors(of: entry.regionID) }
            focusEntry(entry, runID: run.id)
          } else { taskPreview = TaskPreview(id: run.id) }
        }
        .buttonStyle(PaperButton(compact: true))
      } else if let entry = pair.to, item(entry)?.kind == .question {
        Button("打开这个问题") {
          inspected = nil
          rememberLocation("返回关系位置")
          openOnMap(entry.target, preferred: entry.id)
        }.buttonStyle(PaperButton(compact: true))
      }
    }.padding(16).frame(width: 340).paperSheet(cornerRadius: 13, elevated: true).padding(12).zIndex(5)

  }
  private func inputSurface(area: @escaping (CGPoint) -> String) -> some View {
    MapInput { v in configureSurface(v, area: area) }
  }

  private func configureSurface(_ v: MapSurface, area: @escaping (CGPoint) -> String) {
      coordinates.surface = v
      v.trialArea = area
      if trial.active { v.observeWheel = { event in trial.observeWheel(event) } } else { v.observeWheel = nil }
      v.panTool = panTool
      v.temporaryPan = { holdingSpace = $0 }
      v.copyObjects = copySelectedEntrances
      v.pasteObjects = pasteOnCanvas
      v.replayLayout = { redo in
        withAnimation(AtlasMotion.layout(reduceMotion)) {
          update { try store.replayMapEdit(redo: redo) }
        }
      }
      v.nudge = { dx, dy in
        guard !selection.isEmpty || !selectedRegions.isEmpty else { return false }
        recordMove { batch in
          try store.moveCanvasSelection(regionIDs: selectedRegions, placementIDs: Set(selection), dx: dx, dy: dy, batchID: batch)
        }
        return true
      }
      v.removeSelected = {
        guard !chosen.isEmpty else { return false }
        let removedCount = chosen.count
        withAnimation(AtlasMotion.surface(reduceMotion)) {
          update { try store.removeMapEntries(chosen) }
          pasteNotice = removedCount == 1 ? "已移除画布入口 · 按 ⌘Z 可撤销" : "已移除 \(removedCount) 个入口 · 按 ⌘Z 可撤销"
        }
        return true
      }
      v.escapeReturn = {
        if s.commandPalette {
          withAnimation(AtlasMotion.surface(reduceMotion)) { s.commandPalette = false }
          return true
        }
        if canvasDiffPreview != nil {
          abandonCanvasDiffPreview()
          return true
        }
        if directConnectPending != nil || directConnectDrag != nil {
          withAnimation(AtlasMotion.surface(reduceMotion)) {
            directConnectPending = nil
            directConnectDrag = nil
          }
          return true
        }
        if inspected != nil {
          withAnimation(AtlasMotion.surface(reduceMotion)) { inspected = nil }
          return true
        }
        if sourceReturn != nil { returnFromSource(); return true }
        if searchVisit != nil { returnFromSearch(); return true }
        if navigationReturn != nil { returnFromLocation(); return true }
        if relationReturn != nil { returnToRelation(); return true }
        if organizationVisit != nil { returnFromOrganization(); return true }
        return false
      }
      v.pan = { dx, dy in
        trial.action("pan")
        interruptCameraGlide()
        if holdingSpace { offer(.gestures) }
        camera.x += dx
        camera.y += dy
      }
      v.magnify = { factor, p in
        interruptCameraGlide()
        camera.scale(factor, at: p)
      }
      v.askAt = { point in
        if camera.distant {
          let world = CGPoint(x: (point.x-camera.x)/camera.zoom, y: (point.y-camera.y)/camera.zoom)
          let dots = DistantCanvas.materials(entries, tree: regionTree, zoom: camera.zoom)
          let hits = dots.values.compactMap { dot -> (DistantCanvas.Dot, Double)? in
            let distance = hypot(dot.center.x-world.x, dot.center.y-world.y) * camera.zoom
            return distance <= 7 ? (dot, distance) : nil
          }
          if let dot = hits.min(by: { $0.1 < $1.1 })?.0 {
            rememberLocation("返回出发位置")
            if dot.count == 1 {
              focusEntry(dot.first)
            } else {
              let bounds = dot.bounds
              camera.zoom = min(1, (canvasSize.width-64)/bounds.width, (canvasSize.height-64)/bounds.height)
              camera.x = canvasSize.width/2 - bounds.midX*camera.zoom
              camera.y = canvasSize.height/2 - bounds.midY*camera.zoom
            }
            persist()
            return
          }
        }
        compose(at: point)
      }
      v.persist = queueSave
      v.box = { rect, shift, done in
        if let rect, max(rect.width, rect.height) > 2 { trial.action("marquee") }
        marquee = done ? nil : rect
        if done, let rect {
          if rect.width > 2 || rect.height > 2 { offer(.gestures) }
          let hits = entries.filter {
            rect.width > 2 && rect.height > 2 && regionTree.collapsedOwner(of: $0.regionID) == nil
              && frame($0).intersects(rect)
          }.map(\.id)
          selection =
            shift
            ? selection.filter { !hits.contains($0) }
              + hits.filter { !selection.contains($0) } : hits
          if !shift { selectedRegions.removeAll() }
          inspected = nil
        }
      }

  }
  private struct Connection: Identifiable {
    let edge: MapEdge
    let points: [CGPoint]
    let direct: Bool
    var id: String { edge.id }
    var labelPoint: CGPoint {
      if points.count == 4, let a = points.first, let b = points.last {
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
      }
      let mid = points.count / 2
      return CGPoint(x: (points[mid-1].x + points[mid].x)/2, y: (points[mid-1].y + points[mid].y)/2)
    }
    var path: Path {
      Path { path in
        guard let first = points.first, let last = points.last else { return }
        path.move(to: first)
        if points.count == 4 {
          // Graceful S-shaped calligraphic cubic Bezier curve for clean unobstructed connections
          let span = abs(last.x - first.x)
          let dir: CGFloat = last.x >= first.x ? 1 : -1
          let tension = max(24, min(110, span * 0.48))
          let c1 = CGPoint(x: first.x + dir * tension, y: first.y)
          let c2 = CGPoint(x: last.x - dir * tension, y: last.y)
          path.addCurve(to: last, control1: c1, control2: c2)
        } else if points.count <= 2 {
          for point in points.dropFirst() { path.addLine(to: point) }
        } else {
          for i in 1 ..< points.count - 1 {
            let prev = points[i - 1], curr = points[i], next = points[i + 1]
            let r = min(10.0, hypot(curr.x - prev.x, curr.y - prev.y) * 0.4, hypot(next.x - curr.x, next.y - curr.y) * 0.4)
            if r > 1.5 {
              path.addArc(tangent1End: curr, tangent2End: next, radius: r)
            } else {
              path.addLine(to: curr)
            }
          }
          path.addLine(to: last)
        }
        if edge.directed, points.count >= 2 {
          let dx: CGFloat = (points.count == 4 ? first.x : points[points.count - 2].x) <= last.x ? -6.5 : 6.5
          path.move(to: CGPoint(x: last.x + dx, y: last.y - 3.5))
          path.addLine(to: last)
          path.addLine(to: CGPoint(x: last.x + dx, y: last.y + 3.5))
        }
      }
    }
  }

  private func routed(_ edge: MapEdge, from a: CGRect, to b: CGRect, direct: Bool, blockers: [CGRect]) -> Connection {
    let direction: CGFloat = a.midX <= b.midX ? 1 : -1
    let start = CGPoint(x: direction > 0 ? a.maxX : a.minX, y: a.midY)
    let end = CGPoint(x: direction > 0 ? b.minX : b.maxX, y: b.midY)
    let gap = min(26 * camera.zoom, max(8, abs(end.x-start.x)/2))
    let exitX = start.x + gap * direction, enterX = end.x - gap * direction
    let adjacent = [start, CGPoint(x: exitX,y: start.y), CGPoint(x: exitX,y: end.y), end]
    func clear(_ points: [CGPoint]) -> Bool {
      zip(points,points.dropFirst()).allSatisfy { p,q in
        let segment = CGRect(x: min(p.x,q.x),y: min(p.y,q.y),width: max(1,abs(q.x-p.x)),height: max(1,abs(q.y-p.y)))
        return !blockers.contains { $0.intersects(segment) }
      }
    }
    if direct && !clear(adjacent) {
      let local = blockers.filter { $0.intersects(a.union(b)) }
      let above = min(a.minY,b.minY,local.map(\.minY).min() ?? a.minY)-9
      let below = max(a.maxY,b.maxY,local.map(\.maxY).max() ?? a.maxY)+9
      for lane in [above,below].sorted(by: { abs($0-start.y) < abs($1-start.y) }) {
        let detour = [start,CGPoint(x:exitX,y:start.y),CGPoint(x:exitX,y:lane),CGPoint(x:enterX,y:lane),CGPoint(x:enterX,y:end.y),end]
        if clear(detour) { return Connection(edge:edge, points:detour, direct:true) }
      }
    }
    return Connection(edge:edge, points:adjacent, direct:direct)
  }

  private func visibleLines(_ viewport: CGRect, papers: [(id: String, rect: CGRect)]) -> [Connection] {
    let labelArea = viewport.insetBy(dx: -64, dy: -24)
    let world = worldViewport(labelArea, extraHeight: answerGrowth)
    let selected = Set(selection)
    return visibility.connections(in: world).compactMap { edge -> Connection? in
      guard let (from,to) = edge.entrances(defaults: endpoint) else { return nil }
      let a = displayedEndpoint(from), b = displayedEndpoint(to)
      guard a.union(b).intersects(labelArea) else { return nil }
      let direct = inspected?.id == edge.id || selected.contains(from.id) || selected.contains(to.id)
      let blockers = direct ? papers.compactMap { $0.id == from.id || $0.id == to.id ? nil : $0.rect } : []
      return routed(edge, from:a, to:b, direct:direct, blockers:blockers)
    }
  }

  @ViewBuilder private func edgeLayer(_ viewport: CGRect, papers: [(id: String, rect: CGRect)], lines: [Connection]) -> some View {
    // Draw and hit-test the same routed curve.
    Canvas { context, _ in
      // Mask occupied paper even when two old entrances overlap and no local route is clear.
      var mask = Path()
      for paper in papers { mask.addRoundedRect(in: paper.rect.insetBy(dx: 0.75, dy: 0.75), cornerSize: CGSize(width: 12, height: 12)) }
      context.clip(to: mask, options: .inverse)
      for line in lines {
        let warmOchre = Color(red: 0.565, green: 0.420, blue: 0.255)
        let ink = line.edge.history ? warmOchre : AtlasPalette.blueInk
        let active = inspected?.id == line.id
        let isEmerging = emergingBranchTarget != nil && line.edge.to == emergingBranchTarget
        let drawnPath = isEmerging ? line.path.trimmedPath(from: 0, to: branchReveal) : line.path
        if active || line.direct {
          context.stroke(
            drawnPath,
            with: .color((line.edge.history ? AtlasPalette.gold : ink).opacity(active ? 0.22 : 0.12)),
            style: StrokeStyle(lineWidth: active ? 5.2 : 3.8, lineCap: .round, lineJoin: .round)
          )
        }
        context.stroke(
          drawnPath,
          with: .color(ink.opacity(active ? 0.96 : (line.direct ? 0.86 : 0.48))),
          style: StrokeStyle(
            lineWidth: active ? 2.0 : (line.direct ? 1.5 : 1.2),
            lineCap: .round,
            lineJoin: .round,
            dash: line.edge.history ? [5.5, 3.5] : []
          )
        )
        if let start = line.points.first {
          let r: CGFloat = line.direct ? 3.2 : 2.5
          let anchor = Path(ellipseIn: CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2))
          context.fill(anchor, with: .color(AtlasPalette.paper))
          context.stroke(
            anchor,
            with: .color((line.edge.history ? AtlasPalette.gold : ink).opacity(line.direct ? 0.92 : 0.58)),
            lineWidth: line.direct ? 1.35 : 1.05
          )
        }
        // PH-02: Undirected semantic relations terminate with symmetric open-circle anchors (no arrow)
        if !line.edge.directed, let end = line.points.last {
          let r: CGFloat = line.direct ? 3.1 : 2.5
          let endAnchor = Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2))
          context.fill(endAnchor, with: .color(AtlasPalette.paper))
          context.stroke(endAnchor, with: .color(ink.opacity(line.direct ? 0.9 : 0.55)), lineWidth: 1.2)
        }
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
    ForEach(lines.filter { line in
      viewport.contains(line.labelPoint) &&
        !papers.contains { $0.rect.insetBy(dx: -18, dy: -9).contains(line.labelPoint) } &&
        (line.direct || !line.edge.label.isEmpty)
    }) { line in
      let isSelected = inspected?.id == line.id
      let warmOchre = Color(red: 0.545, green: 0.400, blue: 0.240)
      let ink = line.edge.history ? warmOchre : AtlasPalette.blueInk
      Button {
        withAnimation(AtlasMotion.surface(reduceMotion)) { inspected = line.edge }
      } label: {
        Text(line.edge.label)
          .font(AtlasTypeface.reading.font(11.5).weight(isSelected || line.direct ? .medium : .regular))
          .foregroundStyle(isSelected ? Color.white : ink.opacity(line.direct ? 0.96 : 0.78))
          .fixedSize()
          .padding(.horizontal, 8.5)
          .padding(.vertical, 3)
          .background {
            Capsule(style: .continuous)
              .fill(isSelected ? ink : AtlasPalette.paper.opacity(line.direct ? 0.96 : 0.88))
          }
          .overlay {
            if !isSelected {
              Capsule(style: .continuous)
                .stroke(ink.opacity(line.direct ? 0.46 : 0.28), lineWidth: 0.8)
            }
          }
          .shadow(color: Color(red: 0.24, green: 0.18, blue: 0.11).opacity(line.direct ? 0.10 : 0.05), radius: 3, y: 1)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(line.edge.label)
      .position(line.labelPoint)
    }
  }
  private var skippedHints: Bool { s.defaults.bool(forKey: CanvasHint.skipKey) }
  @ViewState private var activeHint: CanvasHint?

  private func offer(_ hint: CanvasHint) {
    let seen = s.defaults.integer(forKey: CanvasHint.seenKey)
    guard !skippedHints, seen & hint.rawValue == 0, hint != .move || activeHint == nil else { return }
    s.defaults.set(seen | hint.rawValue, forKey: CanvasHint.seenKey)
    withAnimation(AtlasMotion.surface(reduceMotion)) {
      activeHint = hint
    }
  }

  private func hintNote(_ hint: CanvasHint) -> some View {
    CanvasHintNote(hint: hint, dismiss: {
      withAnimation(AtlasMotion.surface(reduceMotion)) { activeHint = nil }
    }, skip: {
      s.defaults.set(true, forKey: CanvasHint.skipKey)
      withAnimation(AtlasMotion.surface(reduceMotion)) { activeHint = nil }
    })
  }

  @ViewState private var guidedAnswerID: String?

  private func selectAnswer(_ run: AtlasRun, from entry: MapEntry, wide: Bool) {
    if guidedAnswerID == run.id { guidedAnswerID = nil }
    answerOrigin = entry.id
    if wide { returnToFocusedAnswer = entry; focusSheet = nil }
    answerPage = AnswerSourcePage(runID: run.id, body: run.answer, title: "从回答选句")
  }

  @ViewBuilder private func answerGuidance(_ run: AtlasRun, entry: MapEntry, wide: Bool) -> some View {
    if guidedAnswerID == run.id && !skippedHints {
      VStack(alignment: .leading, spacing: 5) {
        Text(CanvasHint.firstAnswer.title).font(.system(size: 13, weight: .semibold))
        Text(CanvasHint.firstAnswer.detail)
          .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("选择一句追问") { selectAnswer(run, from: entry, wide: wide) }
            .buttonStyle(AtlasChipButtonStyle(emphasized: true))
          Button("知道了") { guidedAnswerID = nil }.buttonStyle(.plain)
        }
      }
      .foregroundStyle(AtlasPalette.ink)
      .padding(.leading, 10)
      .overlay(alignment: .leading) { Rectangle().fill(AtlasPalette.gold).frame(width: 2) }
    }
  }

  private func trackHover(_ e: MapEntry, inside: Bool) {
    if inside { hoveredEntry = e.id; offer(.move) }
    else if hoveredEntry == e.id { hoveredEntry = nil }
  }

  private func moveGrip(_ e: MapEntry, scale: CGFloat = 1) -> some View {
    let prominent = selection.contains(e.id) || hoveredEntry == e.id
    return AtlasGripIcon(prominent: prominent, scale: scale)
  }

  private func titleDrag(_ e: MapEntry) -> some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named("atlas-region-map"))
      .onChanged { value in
        if focusedReader != e.id { focusedReader = e.id }
        if !selection.contains(e.id) {
          selection = [e.id]
          selectedRegions = []
        }
        trial.action("move-node")
        drag = value.translation
        activeDrop = selection.count == 1 && selectedRegions.isEmpty ? regionDrop(at: value.location) : nil
      }
      .onEnded { value in
        focusLayout()
        let batch = chosen
        let target = activeDrop
        drag = .zero
        activeDrop = nil
        let dx = value.translation.width / camera.zoom
        let dy = value.translation.height / camera.zoom
        recordMove { id in
          if let target, batch.count == 1 {
            try store.joinMapRegion(placementID: e.id, regionID: target, x: e.x + dx, y: e.y + dy, batchID: id)
          } else if !selectedRegions.isEmpty {
            try store.moveCanvasSelection(regionIDs: selectedRegions, placementIDs: Set(selection), dx: dx, dy: dy, batchID: id)
          } else {
            try store.moveMapEntries(batch, dx: dx, dy: dy, batchID: id)
          }
        }
      }
  }

  @ViewBuilder private func pagePaper(_ e: MapEntry, _ meta: CanvasPDFPage, live: Bool) -> some View {
    let rect = frame(e)
    let z = camera.zoom
    let temporary = visitingPage?.id == e.id
    let historical = s.docs.first(where: { $0.id == e.target })?.versionID != meta.version
    let pageKey = e.id + meta.version
    let isScanned = scannedPages.contains(pageKey)
    let isSelected = selection.contains(e.id)
    let isLineageRelated = !isSelected && connectedToFocus(e.id)
    let isDragging = drag != .zero && (selection.contains(e.id) || (selection.isEmpty && focusedReader == e.id))
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        if let file = file(e) {
          HStack(spacing: 6) {
            if !temporary { moveGrip(e, scale: z) }
            Text((temporary ? "临时查看 · " : "") + file.title + " · " + meta.caption)
              .font(AtlasTypeface.reading.font(max(9, 13 * z)))
              .foregroundStyle(AtlasPalette.ink)
              .lineLimit(1)
              .accessibilityLabel(file.title + " · " + meta.caption)
            Text("v" + String(file.ordinal))
              .font(.system(size: max(9, 11 * z), design: .monospaced))
              .foregroundStyle(AtlasPalette.umber)
              .accessibilityLabel("页面版本 " + String(file.ordinal))
            if historical {
              Text("提问时版本")
                .font(.system(size: max(8.5, 10 * z), weight: .medium, design: .serif))
                .foregroundStyle(AtlasPalette.umber)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1.5)
                .background(AtlasPalette.umber.opacity(0.11), in: Capsule())
                .overlay { Capsule().strokeBorder(AtlasPalette.umber.opacity(0.28), lineWidth: 0.65) }
            }
            Spacer(minLength: 2)
          }
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
          .help(temporary ? "提问时的原页" : (isScanned ? "此页无文字层：拖动标题移动此页；在页内拖动可框选区域引用。" : "拖动标题移动此页；在页内拖动可选字或圈选区域。"))
          .canvasMoveCursor(enabled: !temporary, dragging: drag != .zero && selection.contains(e.id))
          .onTapGesture { if !temporary { select(e); focusedReader = e.id; focusLayout() } }
          .gesture(titleDrag(e), including: temporary ? .none : .all)
          if live {
            if temporary {
              Button("保留这页") { s.perform { try store.putCanvasEntries([e]); visitingPage = nil; update() } }
                .buttonStyle(PaperButton(primary: true, compact: true))
            } else if let anchor = mapPDFSelection[e.id] {
              Button("用选句追问") { compose(from: e, anchor: anchor) }
                .buttonStyle(PaperButton(primary: true, compact: true))
              Button("高亮") { s.perform { _ = try store.markPDF(anchor, kind: .highlight); markRevision += 1 } }
                .buttonStyle(AtlasChipButtonStyle(emphasized: true))
            } else if let region = regionSelections[e.id] {
              Button("用区域追问") { s.perform { compose(from: e, reference: try store.capturePDFPage(versionID: meta.version, page: meta.index, region: region)) } }
                .buttonStyle(PaperButton(primary: true, compact: true))
            } else if isScanned {
              HStack(spacing: 3.5) {
                Image(systemName: "viewfinder")
                  .font(.system(size: max(8.5, 9.5 * z), weight: .medium))
                Text("无文字层 · 拖框选区")
                  .font(.system(size: max(8.5, 10 * z), weight: .medium))
              }
              .foregroundStyle(AtlasPalette.umber)
              .padding(.horizontal, 6.5)
              .padding(.vertical, 2)
              .background(AtlasPalette.gold.opacity(0.14), in: Capsule())
              .overlay { Capsule().strokeBorder(AtlasPalette.gold.opacity(0.45), lineWidth: 0.65) }
              .help("此页没有文字层，可在页面上直接拖动框选区域以引用或追问。")
            } else {
              Text("拖选原文可追问").font(.system(size: max(10, 11 * z)))
                .foregroundStyle(AtlasPalette.umber).lineLimit(1).fixedSize()
            }
            Menu {
              Button("围绕这一页提问") { s.perform { compose(from: e, reference: try store.capturePDFPage(versionID: meta.version, page: meta.index, includePageText: true)) } }
              Button("把下一页也放到画布") { putPages(file, indices: [meta.index+1], near: CGPoint(x: e.x+meta.width+52, y: e.y)) }
              Button("打开整本书") { s.openDocument(file) }
            } label: {
              Image(systemName: "ellipsis")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AtlasPalette.umber)
                .frame(width: 22, height: 22)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(AtlasChipButtonStyle())
            .fixedSize()
            .accessibilityLabel("页面操作")
          }
        } else {
          Text("这一版本的原件不可用")
            .font(.system(size: 12))
            .foregroundStyle(AtlasPalette.umber)
        }
      }
      .padding(.horizontal, 9)
      .frame(height: CanvasPDFPage.header * z)
      .background(historical ? Color(red: 0.955, green: 0.928, blue: 0.876) : AtlasPalette.paperHeader)
      .overlay(alignment: .bottom) { PaperRule() }
      .contentShape(Rectangle())
      if let file = file(e) {
        if live {
          CanvasPageSurface(file: file, page: meta, store: store, highlight: sourceHighlights[e.id], region: regionSelections[e.id],
            markRevision: markRevision, select: { anchor in
              if mapPDFSelection[e.id] != anchor {
                mapPDFSelection[e.id] = anchor
                if anchor != nil { trial.action("select-text"); offer(.quotation) }
              }
            }, selectRegion: { regionSelections[e.id] = $0 }, zoomCanvas: { factor, location in
              interruptCameraGlide()
              guard let surface = coordinates.surface else { return }
              camera.scale(factor, at: surface.convert(location, from: nil)); persist()
            }, pan: { dx, dy in
              trial.action("pan")
              interruptCameraGlide()
              camera.x += dx
              camera.y += dy
              queueSave()
            }, onTextLayerDetected: { hasText in
              if hasText { scannedPages.remove(pageKey) } else { scannedPages.insert(pageKey) }
            }, failure: { s.error = $0 }).id(pageKey)
        } else {
          CanvasPageThumbnail(file: file, meta: meta, store: store, revision: markRevision)
            .onTapGesture { focusedReader = e.id; selection = [e.id]; revealWork(reserved(e)); pulseArrival(e.id); persist() }
        }
      } else { Color.white }
    }
    .frame(width: rect.width, height: rect.height)
    .background(Color.white)
    .clipShape(shape)
    .background {
      if historical {
        ZStack {
          shape.fill(Color(red: 0.945, green: 0.914, blue: 0.855))
            .overlay { shape.strokeBorder(AtlasPalette.umber.opacity(0.32), lineWidth: 0.75) }
            .offset(x: 4, y: 4)
          shape.fill(Color(red: 0.965, green: 0.937, blue: 0.882))
            .overlay { shape.strokeBorder(AtlasPalette.umber.opacity(0.36), lineWidth: 0.75) }
            .offset(x: 2, y: 2)
        }.allowsHitTesting(false)
      }
    }
    .overlay {
      shape.strokeBorder(
        isSelected
          ? AtlasPalette.blueInk.opacity(0.84)
          : (isLineageRelated
            ? AtlasPalette.gold.opacity(0.75)
            : (historical ? AtlasPalette.umber.opacity(0.55) : AtlasPalette.line.opacity(0.68))),
        lineWidth: isSelected ? 1.5 : (isLineageRelated ? 1.2 : 0.85)
      )
      .allowsHitTesting(false)
    }
    .overlay(alignment: .bottom) {
      if live, !temporary, let anchor = mapPDFSelection[e.id] {
        HStack(spacing: 6) {
          Button { compose(from: e, anchor: anchor) } label: {
            Label("追问这句", systemImage: "sparkles")
          }
          .buttonStyle(PaperButton(primary: true, compact: true))
          Button {
            s.perform { _ = try store.markPDF(anchor, kind: .highlight); markRevision += 1 }
          } label: {
            Label("高亮", systemImage: "highlighter")
          }
          .buttonStyle(AtlasChipButtonStyle(emphasized: true))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .paperSheet(cornerRadius: 10, elevated: true)
        .padding(.bottom, 12)
        .transition(AtlasMotion.surfaceTransition(reduceMotion))
      } else if live, !temporary, let region = regionSelections[e.id] {
        HStack(spacing: 6) {
          Button {
            s.perform { compose(from: e, reference: try store.capturePDFPage(versionID: meta.version, page: meta.index, region: region)) }
          } label: {
            Label("追问所选区域", systemImage: "sparkles")
          }
          .buttonStyle(PaperButton(primary: true, compact: true))
          Button("取消选区") { regionSelections[e.id] = nil }
            .buttonStyle(AtlasChipButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .paperSheet(cornerRadius: 10, elevated: true)
        .padding(.bottom, 12)
        .transition(AtlasMotion.surfaceTransition(reduceMotion))
      }
    }
    .atlasArrivalHalo(active: arrivalPulseID == e.id, cornerRadius: 4)
    .shadow(
      color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(isDragging ? 0.18 : 0.10),
      radius: isDragging ? 14 : 6,
      y: isDragging ? 6 : 2.5
    )
    .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.05), radius: 1.5, y: 1)
    .scaleEffect(isDragging && !reduceMotion ? 1.008 : 1)
    .animation(AtlasMotion.micro(reduceMotion), value: isDragging)
    .onHover { trackHover(e, inside: $0) }
    .accessibilityElement(children: .contain)
    .accessibilityValue(live && file(e) != nil ? "PDF 正文阅读" : "PDF 页面预览")
    .accessibilityIdentifier("canvas.entrance." + e.id)
    .offset(x: rect.minX + previewOffset(e).width, y: rect.minY + previewOffset(e).height)
  }
  @ViewBuilder private func placedCard(_ e: MapEntry, mounted: Bool, overlaps: Bool) -> some View {
    let r = frame(e)
    let live = readingEntry(e)
    card(e, mounted: mounted && focusSheet?.id != e.id, overlaps: overlaps).environment(\.canvasTextCoordinates, coordinates).frame(
      width: live ? r.width : size(e).width, height: live ? r.height : size(e).height
    )
    .scaleEffect(live ? 1 : camera.zoom, anchor: .topLeading)
    .frame(width: r.width, height: r.height, alignment: .topLeading).offset(
      x: r.minX + previewOffset(e).width, y: r.minY + previewOffset(e).height
    )
    .allowsHitTesting(overlapPlan == nil && canvasDiffPreview == nil).zIndex(e.id == focusedReader ? 3 : selection.contains(e.id) ? 2 : 0)

  }
  private func previewOffset(_ entry: MapEntry) -> CGSize {
    if let diff = canvasDiffPreview {
      return diff.offset(for: entry, zoom: camera.zoom)
    }
    guard let edit = overlapPlan?.edits.first(where: { $0.target == entry.id }), let x = edit.x, let y = edit.y else { return .zero }
    return CGSize(width: (x-entry.x)*camera.zoom, height: (y-entry.y)*camera.zoom)
  }
  private func sourcePageSize(in pane: CGSize) -> CGSize {
    CGSize(width: min(610, max(0, pane.width - 32)), height: min(510, max(0, pane.height - 32)))
  }
  @ViewBuilder private func scene(_ paneSize: CGSize) -> some View {
    let sourceSize = sourcePageSize(in: paneSize)
    let viewport = CGRect(origin: .zero, size: paneSize)
    let onScreen = camera.distant ? [] : visible(viewport)
    let overlappingReader = onScreen.first { $0.id == focusedReader && readingEntry($0) }.flatMap { active -> String? in
      let visiblePaper = frame(active).intersection(viewport)
      let overlaps = onScreen.contains { other in
        guard other.id != active.id else { return false }
        let shared = visiblePaper.intersection(frame(other))
        return shared.width > 0 && shared.height > 0
      }
      return overlaps ? active.id : nil
    }
    let mounted = readers(onScreen)
    let papers = onScreen.map { (id: $0.id, rect: displayedEndpoint($0)) }
    let lines = camera.distant ? [] : visibleLines(viewport, papers: papers)
    ZStack(alignment: .topLeading) {
      inputSurface { point in
        if let entry = onScreen.last(where: { frame($0).contains(point) }) {
          let offset = point.y - frame(entry).minY
          if offset < (entry.page != nil ? CanvasPDFPage.header * camera.zoom : 36) { return "node-header" }
          return entry.page != nil ? "pdf-body" : "node-body"
        }
        if lines.contains(where: { $0.path.strokedPath(StrokeStyle(lineWidth: 14)).contains(point) }) { return "edge" }
        return "blank"
      }.zIndex(panTool || holdingSpace ? 10 : 0)
      if camera.distant, let map {
        DistantCanvas(snapshotID: snapshotID, map: map, regions: regions, tree: regionTree, endpoints: endpoint, focusedEntrances: Set(selection),
          focusedRegions: selectedRegions, counts: regionCounts, zoom: camera.zoom,
          origin: CGPoint(x: camera.x, y: camera.y), size: paneSize, title: title, visitEntry: { e in
            rememberLocation("回到刚才")
            openOnMap(e.target, preferred: e.id, center: true)
          }) { id in
          if let region = regionTree.regions[id] { focusRegion(region); persist() }
        }
      } else {
        regionLayer(viewport: CGRect(origin: .zero, size: paneSize))
        edgeLayer(viewport, papers: papers, lines: lines)
        ForEach(onScreen) { e in
          if let page = e.page { pagePaper(e, page, live: mounted.contains(e.id) && !camera.overview) }
          else if let source = searchVisit?.pdf ?? inlineWholePDF, source.entrance?.id == e.id {
            let rect = frame(e)
            CanvasPDFSourceSheet(source: source, store: store, returnLabel: nil, close: searchVisit?.pdf != nil ? returnFromSearch : returnFromSource)
              .frame(width: sourceSize.width, height: sourceSize.height)
              .paperSheet().offset(x: rect.minX, y: rect.minY).zIndex(6)
          } else {
            placedCard(e, mounted: mounted.contains(e.id), overlaps: overlappingReader == e.id)
          }
        }
        if let diff = canvasDiffPreview {
          CanvasOrganizationOverlay(
            preview: diff,
            entries: onScreen,
            zoom: camera.zoom,
            origin: CGPoint(x: camera.x, y: camera.y),
            frameForEntry: frame,
            onFocusEdit: { id in
              withAnimation(AtlasMotion.micro(reduceMotion)) {
                canvasDiffPreview?.focusedEditID = (canvasDiffPreview?.focusedEditID == id ? nil : id)
              }
            }
          )
          .zIndex(7)
          .transition(.opacity)
        }
        if !camera.overview, canvasDiffPreview == nil, overlapPlan == nil, !panTool, !holdingSpace,
          entries.count >= 2
        {
          if directConnectPending == nil,
            let handleEntryID = directConnectDrag?.sourceEntryID
              ?? hoveredConnectEntry
              ?? hoveredEntry
              ?? (selection.count == 1 ? selection.first : nil),
            let handleEntry = onScreen.first(where: { $0.id == handleEntryID })
          {
            CanvasDirectConnectHandles(
              entry: handleEntry,
              rect: frame(handleEntry),
              drag: directConnectDrag,
              onHandleHover: { inside in
                if inside { hoveredConnectEntry = handleEntry.id }
                else if hoveredConnectEntry == handleEntry.id { hoveredConnectEntry = nil }
              },
              onDragChanged: { side, point in
                handleDirectConnectChanged(source: handleEntry, side: side, point: point, onScreen: onScreen)
              },
              onDragEnded: { _, point in
                handleDirectConnectEnded(source: handleEntry, point: point, onScreen: onScreen)
              }
            )
            .zIndex(8)
          }
          if directConnectDrag != nil || directConnectPending != nil {
            CanvasDirectConnectOverlay(
              drag: directConnectDrag,
              pending: directConnectPending,
              entries: onScreen,
              frameForEntry: frame
            )
            .zIndex(9)
          }
          if let pending = directConnectPending,
            let fromEntry = entries.first(where: { $0.id == pending.sourceEntryID }),
            let toEntry = entries.first(where: { $0.id == pending.targetEntryID })
          {
            let center = CanvasDirectConnectGeometry.clampedPopoverCenter(
              between: frame(fromEntry),
              and: frame(toEntry),
              popoverSize: CanvasDirectConnectPopover.preferredSize,
              in: paneSize
            )
            CanvasDirectConnectPopover(
              pending: Binding(
                get: { directConnectPending ?? pending },
                set: { directConnectPending = $0 }
              ),
              sourceTitle: title(fromEntry),
              targetTitle: title(toEntry),
              onCancel: {
                withAnimation(AtlasMotion.surface(reduceMotion)) { directConnectPending = nil }
              },
              onConfirm: commitDirectConnect
            )
            .position(center)
            .zIndex(13)
            .transition(AtlasMotion.surfaceTransition(reduceMotion))
          }
        }
      }
      if camera.distant {
        ForEach(entries.filter { $0.page != nil && regionTree.collapsedOwner(of: $0.regionID) == nil && frame($0).intersects(viewport) }) { e in
          if let page = e.page { pagePaper(e, page, live: false) }
        }
      }
      if let e = visitingPage, let page = e.page { pagePaper(e, page, live: true).zIndex(5) }
      if let source = inlineMarkdown, let id = source.entrance?.id,
         let target = onScreen.first(where: { $0.id == id }) {
        let rect = frame(target)
        markdownSourceView(source)
          .id(source.id).frame(width: sourceSize.width, height: sourceSize.height)
          .paperSheet().offset(x: rect.minX, y: rect.minY).zIndex(6)
      }
      if camera.overview, let place = camera.readingPlace {
        let rect = place.worldRect
        let box = RoundedRectangle(cornerRadius: 8, style: .continuous)
        box
          .fill(AtlasPalette.blueInk.opacity(0.045))
          .overlay {
            box.stroke(
              AtlasPalette.blueInk.opacity(0.68),
              style: StrokeStyle(lineWidth: 1.25, dash: [6, 4])
            )
          }
          .frame(width: rect.width * camera.zoom, height: rect.height * camera.zoom)
          .overlay(alignment: .topLeading) {
            Text("阅读位置")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(AtlasPalette.blueInk)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(AtlasPalette.paper.opacity(0.96), in: Capsule())
              .overlay { Capsule().strokeBorder(AtlasPalette.blueInk.opacity(0.35), lineWidth: 0.8) }
              .shadow(color: Color.brown.opacity(0.08), radius: 2, y: 1)
              .fixedSize()
              .offset(x: 8, y: -12)
          }
          .offset(x: camera.x + rect.minX * camera.zoom, y: camera.y + rect.minY * camera.zoom)
          .allowsHitTesting(false).zIndex(4)
      }
      if camera.distant, organizationVisit != nil {
        ForEach(chosen) { entry in
          Circle().stroke(AtlasPalette.blueInk, lineWidth: 2).frame(width: 12, height: 12)
            .position(x: camera.x + (entry.x + DistantCanvas.cardSize.width / 2) * camera.zoom,
                      y: camera.y + (entry.y + DistantCanvas.cardSize.height / 2) * camera.zoom)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      if let r = marquee {
        Rectangle().fill(AtlasPalette.line.opacity(0.14)).border(AtlasPalette.blueInk).frame(
          width: r.width, height: r.height
        ).offset(x: r.minX, y: r.minY).allowsHitTesting(false)
      }
      if map != nil && entries.isEmpty && regions.isEmpty && question?.referenceID == nil {
        emptyCanvas
      }
      if let edge = inspected, relationReturn == nil {
        edgeInspector(edge)
          .padding(.top, 44)
          .transition(AtlasMotion.surfaceTransition(reduceMotion))
      }
      if collecting {
        HStack(spacing: 10) {
          Text("在 PDF、Markdown 或回答中选句，再加入本题。")
            .font(.system(size: 12.5))
          Button("返回问题") { collectingFor = nil; questionFocus = UUID() }
            .buttonStyle(PaperButton(primary: true, compact: true))
        }.padding(.horizontal, 14).padding(.vertical, 9).paperSheet(cornerRadius: 10, elevated: true).padding(12).zIndex(12)
          .transition(AtlasMotion.surfaceTransition(reduceMotion))
      } else if let draft = question, relationReturn == nil, !entries.isEmpty || !regions.isEmpty || draft.referenceID != nil {
        questionPanel(draft).id(draft.id)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
          .offset(
          x: composerOrigin(draft, in: paneSize).x,
          y: composerOrigin(draft, in: paneSize).y
        ).zIndex(12)
          .transition(AtlasMotion.surfaceTransition(reduceMotion))
      }
    }
    .overlay(alignment: .bottomLeading) {
      if let plan = overlapPlan {
        HStack(spacing: 10) {
          Text("将移动 " + String(plan.edits.count) + " 个入口")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(AtlasPalette.ink)
          Button("取消") { finishLayout(plan, apply: false) }
            .buttonStyle(PaperButton(compact: true))
          Button("应用排布") { finishLayout(plan, apply: true) }
            .buttonStyle(PaperButton(primary: true, compact: true))
        }.padding(.horizontal, 14).padding(.vertical, 9).paperSheet(cornerRadius: 10, elevated: true).padding(12)
          .transition(AtlasMotion.surfaceTransition(reduceMotion))
      } else if let movedBatch {
        HStack(spacing: 8) {
          Circle().fill(AtlasPalette.gold.opacity(0.85)).frame(width: 5.5, height: 5.5)
          Text("已移动图版").font(.system(size: 12)).foregroundStyle(AtlasPalette.ink)
          Button("撤销移动 ⌘Z") {
            withAnimation(AtlasMotion.layout(reduceMotion)) {
              update { try store.replayMapEdit(redo: false, expectedBatchID: movedBatch) }
            }
          }.buttonStyle(PaperButton(compact: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 7).paperSheet(cornerRadius: 9, elevated: true).padding(12)
        .transition(AtlasMotion.surfaceTransition(reduceMotion))
        .task(id: movedBatch) {
          try? await Task.sleep(for: .seconds(8))
          if !Task.isCancelled && self.movedBatch == movedBatch {
            withAnimation(AtlasMotion.surface(reduceMotion)) { self.movedBatch = nil }
          }
        }
      } else if let id = appliedLayout {
        Button("撤回这次排布") {
          withAnimation(AtlasMotion.layout(reduceMotion)) {
            s.perform { _ = try store.undoOrganization(id); appliedLayout = nil; update() }
          }
        }
          .buttonStyle(PaperButton(compact: true))
          .padding(12)
          .transition(AtlasMotion.surfaceTransition(reduceMotion))
      } else if let pasteNotice {
        Text(pasteNotice).font(.system(size: 12)).foregroundStyle(AtlasPalette.umber)
          .padding(.horizontal, 12).padding(.vertical, 7).paperSheet(cornerRadius: 8).padding(12).allowsHitTesting(false)
          .transition(AtlasMotion.surfaceTransition(reduceMotion))
          .task(id: pasteNotice) {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
              withAnimation(AtlasMotion.surface(reduceMotion)) { self.pasteNotice = nil }
            }
          }
      }
    }
    .frame(width: paneSize.width, height: paneSize.height, alignment: .topLeading)
    .coordinateSpace(name: "atlas-region-map").background {
      CanvasWorldGround(projection: WorldGroundProjection(origin: CGPoint(x: camera.x, y: camera.y), zoom: camera.zoom),
                        prominent: entries.isEmpty || camera.overview)
    }.clipped().onAppear { canvasSize = paneSize; consumePageRequest() }
      .onChange(of: paneSize) { _, size in canvasSize = size; consumePageRequest() }

  }
  private var mapScene: some View {
    GeometryReader { proxy in
      scene(proxy.size)
        .overlay(alignment: .bottom) {
      if canvasDiffPreview != nil {
        CanvasOrganizationControlBar(
          preview: Binding(
            get: { canvasDiffPreview! },
            set: { canvasDiffPreview = $0 }
          ),
          onReturnToDesk: {
            reopenOrganizationPlanID = canvasDiffPreview?.plan.id
            canvasDiffPreview = nil
            showingOrganization.wrappedValue = true
          },
          onAbandon: abandonCanvasDiffPreview,
          onApply: applyCanvasDiffPreview
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 52)
        .transition(AtlasMotion.surfaceTransition(reduceMotion))
      }
    }
    .overlay(alignment: .bottomLeading) {
          if let activeHint, activeHint != .theme, !skippedHints {
            hintNote(activeHint)
              .padding(.leading, 12)
              .padding(.bottom, 52)
              .transition(AtlasMotion.surfaceTransition(reduceMotion))
          }
        }
        .overlay(alignment: .topLeading) { toolbar(proxy.size).padding(8) }
        .overlay(alignment: .bottomTrailing) {
          VStack(alignment: .trailing, spacing: 8) {
            if showMiniMap, !camera.overview, !camera.distant, canvasDiffPreview == nil,
              (entries.count >= 2 || !regions.isEmpty),
              proxy.size.width >= 540, proxy.size.height >= 340
            {
              miniMapView(proxy.size)
                .transition(AtlasMotion.surfaceTransition(reduceMotion, offsetY: 6))
            }
            navigationControls(proxy.size)
          }
          .padding(8)
        }
    }.onAppear {
      update()
      s.perform {
        resumedReaders = Set(try store.readViewState([String].self, key: "map.resumed-readers") ?? [])
        showMiniMap = try store.readViewState(Bool.self, key: "map.minimap") ?? false
        sourceHighlights =
          try store.readViewState([String: PDFAnchor].self, key: "map.source-highlights") ?? [:]
        let storedPins = try store.readViewState([String: String].self, key: "map.pdf-versions")
        // Earlier releases stored explicit historical versions with their last highlighted anchor.
        let pins = storedPins ?? sourceHighlights.mapValues(\.versionID)
        pinnedPDFs = pins.compactMapValues { try? store.pdfInfo(versionID: $0) }
        if storedPins == nil { try store.saveViewState(pins, key: "map.pdf-versions") }
        documentVisits = try store.readViewState([String].self, key: "map.document-visits")
          ?? store.readViewState([String].self, key: "map.pdf-visits") ?? []
        shownRuns = try store.readViewState([String: String].self, key: "map.shown-runs") ?? [:]
        camera = try store.readViewState(MapCamera.self, key: "map.camera") ?? MapCamera()
        consumePageRequest()
      }
      if entries.isEmpty, regions.isEmpty { question = drafts.first { $0.referenceID == nil } }
      locateRequestedRun()
      locateRelationEntrance()
      consumeAssistantDestination()
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty, urls.allSatisfy({ $0.isFileURL && ["pdf","md","markdown"].contains($0.pathExtension.lowercased()) }) else { return false }
      for url in urls { addFile(url) }
      return true
    }
    .onChange(of: action.wrappedValue) { _, next in
      action.wrappedValue = nil
      switch next {
      case .ask: if entries.isEmpty && regions.isEmpty { questionFocus = UUID() } else { compose() }
      case .material: chooseMaterial()
      case .markdown: createWriting(.markdown)
      case .idea: createWriting(.idea)
      case .region: addingTopic = true
      case nil: break
      }
    }
    .onChange(of: relationVisit.wrappedValue?.id) { _, _ in locateRelationEntrance() }
    .onChange(of: s.assistantShown) { _, shown in
      if shown {
        let visibleSource = inlineMarkdown?.entrance ?? (searchVisit?.pdf ?? inlineWholePDF)?.entrance
        s.assistantSelectedEntrances = visibleSource.map { [$0.id] } ?? Set(selection)
        s.assistantVisibleRuns = locatedEntryID.flatMap { id in taskRunID.map { [id: $0] } } ?? [:]
      }
    }
    .onChange(of: s.assistantDestination) { _, _ in consumeAssistantDestination() }
    .onChange(of: requestedRun.wrappedValue) { _, _ in locateRequestedRun() }
    .onChange(of: s.pageToPlace?.id, initial: true) { _, _ in
      consumePageRequest()
    }
    .onChange(of: s.submittedCanvasDraft) { _, id in
      if let draft = question, id == draft.id {
        question = nil
        latestBranch = s.submittedCanvasTurn
        update()
        if let turn = latestBranch,
          let placed = entries.first(where: { $0.target == turn }) {
          focusedReader = placed.id
          selection = [placed.id]
          triggerBranchDrawIn(targetID: placed.id)
          pulseArrival(placed.id)
          persist()
        }
      }
    }
    .onChange(of: s.runs.map(\.turnID)) { _, _ in update() }
    .onChange(of: s.runs.map { $0.id + ":" + $0.status.rawValue }, initial: true) { _, _ in
      syncBackgroundCompletions()
    }
    .onReceive(NotificationCenter.default.publisher(for: .atlasWritingChanged).receive(on: RunLoop.main)) { note in
      guard note.object as? String == store.workspaceID, let id = note.userInfo?["itemID"] as? String else { return }
      s.perform {
        let item = try store.writing(id: id)
        let old = writings[id]
        if old?.currentVersionID != item.currentVersionID || (old?.draft == nil) != (item.draft == nil) ||
          note.userInfo?["entranceVersionChanged"] as? Bool == true {
          writingFragments.merge(try store.writingFragments(document: id)) { _, new in new }
          writingLabels.merge(try store.markdownEntranceLabels(document: id)) { _, new in new }
        }
        if writings[id]?.displayTitle != item.displayTitle { snapshotID = UUID() }
        writings[id] = item
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .atlasAgentCommitted)) { note in
      if note.object as? AtlasStore === store { update() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .atlasLifecycleChanged)) { note in
      if note.object as? AtlasStore === store { update() }
    }
    .onDisappear {
      interruptCameraGlide()
      arrivalTask?.cancel()
      branchRevealTask?.cancel()
      trial.stop()
      paintSave?.cancel()
      persist()
    }
  }
  var body: some View {
    mapScene
      .onChange(of: camera.zoom, initial: true) { _, zoom in
        if zoom < 0.5 { compactCards = true }
        else if zoom > 0.62 { compactCards = false }
      }
      .onChange(of: focusedReader) { _, id in
        if let id { newlyCompletedEntries.remove(id) }
        guard let id, let e = entries.first(where: { $0.id == id }), file(e) != nil || item(e)?.kind == .markdown else { return }
        rememberDocumentVisit(id)
      }
      .sheet(isPresented: showingOrganization, onDismiss: { reopenOrganizationPlanID = nil; finishOrganization() }) {
        let members = selectedRegions.isEmpty ? [] : entries.filter {
          regionTree.belongsToSelection($0.regionID, selected: selectedRegions)
        }.map(\.id)
        let visit = locatedEntryID.flatMap { id in taskRunID.map { [id: $0] } } ?? [:]
        OrganizationDesk.workspace(s, store: store, placements: Set(selection).union(members),
          regions: selectedRegions, displayedRuns: visit, initialPlanID: reopenOrganizationPlanID,
          showOnCanvas: {
            organizationLocation = $0
            showingOrganization.wrappedValue = false
          },
          previewOnCanvas: { plan, picked in
            showingOrganization.wrappedValue = false
            startCanvasDiffPreview(plan, picked: picked)
          }
        ) { reference, source in
          organizationQuestion = (reference, source)
          showingOrganization.wrappedValue = false
        }
      }
      .sheet(isPresented: canvasSearch, onDismiss: finishSearch) {
        AtlasSearchPanel(
          store: store, profile: s.profile, onOpen: { searchAction = .read($0) },
          onAsk: { searchAction = .ask($0) }, allowsRelationQuestion: true
        ).environmentObject(s)
      }
      .overlay(alignment: .topLeading) {
        if let listing = directory {
          CanvasDirectory(rows: listing.rows, close: { directory = nil }) { selection in
            directorySelection = selection
            directory = nil
            locateFromDirectory()
          }.frame(width: min(420, max(260, canvasSize.width - 24)), height: min(480, max(180, canvasSize.height - 72)))
            .paperSheet().padding(.leading, 8).padding(.top, 48)
        }
      }
      .overlay(alignment: .top) {
        if s.commandPalette {
          ZStack(alignment: .top) {
            Color(red: 0.14, green: 0.12, blue: 0.09).opacity(0.16)
              .contentShape(Rectangle())
              .onTapGesture {
                withAnimation(AtlasMotion.surface(reduceMotion)) { s.commandPalette = false }
              }
            CanvasCommandPalette(items: paletteItems) {
              withAnimation(AtlasMotion.surface(reduceMotion)) { s.commandPalette = false }
            }
            .onAppear { paletteItems = commandPaletteItems() }
            .onDisappear { paletteItems = [] }
            .padding(.top, 64)
            .transition(AtlasMotion.surfaceTransition(reduceMotion, offsetY: -6))
          }
        }
      }
      .sheet(item: $pagePicker, onDismiss: { pickerDocument = nil }) { file in
        if let doc = pickerDocument { CanvasPagePicker(document: doc, file: file, place: { putPages(file, indices: $0) }, book: { putPages(file, indices: []) }) }
      }
      .sheet(item: $materialReview) { run in MaterialSettings(store: store, run: run) }
      .sheet(item: $focusSheet) { entry in
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Button("回到刚才") { focusSheet = nil }
              .buttonStyle(PaperButton(compact: true))
            Spacer()
            Button("固定在图中") {
              let size = CGSize(width: entry.readingWidth ?? CanvasFootprint.question.width,
                height: entry.readingHeight ?? CanvasFootprint.question.height)
              let point = CanvasFootprint.available(near: reserved(entry).origin, size: size,
                obstacles: entries.filter { $0.id != entry.id }.map(reserved),
                viewport: canvasSize)
              s.perform {
                try store.pinMapReader(entry, size: size, near: point)
                focusSheet = nil
                rememberLocation("回到刚才")
                update()
                openOnMap(entry.target, preferred: entry.id, center: true)
              }
            }
            .buttonStyle(PaperButton(primary: true, compact: true))
          }
          card(entry, mounted: true, overlaps: false, wide: true)
        }.padding(18).frame(minWidth: 560, minHeight: 420).background(AtlasPalette.cream)
      }
      .sheet(item: $taskPreview) { preview in
        if let task = s.runs.first(where: { $0.id == preview.id }) {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("任务记录").font(.system(size: 13, weight: .medium)).foregroundStyle(AtlasPalette.umber)
              Spacer()
              Button("返回画布") { taskPreview = nil }.buttonStyle(PaperButton(compact: true))
            }
            Text(task.question).font(AtlasTypeface.reading.font(20).weight(.medium))
            Text([task.version.map { "版本 " + String($0) }, task.statusText].compactMap { $0 }.joined(separator: " · "))
              .font(.caption).foregroundStyle(AtlasPalette.umber)
            PaperRule()
            if !task.answer.isEmpty { AnswerReader(text: task.answer).id(task.id) }
            if task.status == .failed, let reason = task.reason { Text(reason).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
              Button("专注阅读") { taskPreview = nil; s.openQuestion(task) }.buttonStyle(PaperButton(primary: true, compact: true))
              if task.status.isActive { Button("停止生成") { s.stop(task) }.buttonStyle(PaperButton(compact: true)) }
            }
          }.padding(22).frame(minWidth: 490, minHeight: 280).background(AtlasPalette.paper)
        } else { Button("任务已移除 · 返回画布") { taskPreview = nil }.buttonStyle(PaperButton()).padding() }
      }
      .sheet(item: $searchPDFSheet) { source in
        CanvasPDFSourceSheet(source: source, store: store, returnLabel: "返回画布") { searchPDFSheet = nil }
          .frame(minWidth: 530, minHeight: 390)
      }
      .sheet(item: $searchMarkdownSheet, onDismiss: {
        if question != nil && !collecting { questionFocus = UUID() }
      }) { source in
        markdownSourceView(source, returnLabel: "返回画布", close: { searchMarkdownSheet = nil })
          .frame(minWidth: 530, minHeight: 390)
      }
      .sheet(item: $temporaryPDF, onDismiss: returnFromSource) { source in
        CanvasPDFSourceSheet(source: source, store: store) { temporaryPDF = nil }
          .frame(minWidth: 530, minHeight: 390)
      }
      .sheet(item: $temporaryMarkdown, onDismiss: {
        returnFromSource()
        if question != nil && !collecting { questionFocus = UUID() }
      }) { source in
        markdownSourceView(source, close: { temporaryMarkdown = nil })
          .frame(minWidth: 530, minHeight: 390)
      }
      .sheet(item: $versionChoice) { choice in
        VStack(alignment: .leading, spacing: 10) {
          Text("此入口显示的 PDF 版本").font(.system(size: 16, weight: .medium, design: .serif))
          PaperRule()
          Button("跟随当前版") { changePDF(choice.id, to: nil) }.buttonStyle(PaperButton(compact: true))
          ForEach(choice.versions, id: \.versionID) { v in
            Button("固定版本 " + String(v.ordinal)) { changePDF(choice.id, to: v) }.buttonStyle(PaperButton(compact: true))
          }
          HStack {
            Spacer()
            Button("关闭") { versionChoice = nil }.buttonStyle(AtlasChipButtonStyle())
          }
        }.padding(20).frame(minWidth: 260).background(AtlasPalette.paper)
      }
      .sheet(isPresented: $showsDraftCitations) {
        if let draft = question {
          CanvasCitationPanel(store: store, citations: draft.citations, remove: { item in
            s.perform {
              guard let current = question, current.id == draft.id else { return }
              question = try store.removeCanvasMaterial(item.id, from: current)
              drafts = try store.canvasDrafts()
            }
          })
        }
      }
      .sheet(item: $answerPage, onDismiss: {
        if let back = returnToFocusedAnswer { returnToFocusedAnswer = nil; focusSheet = back }
      }) { page in
        AnswerSourcePanel(
          page: page, actionLabel: collecting ? "把回答选句加入本题" : nil,
          ask: { value in
            compose(from: entries.first(where: { $0.id == answerOrigin }), excerpt: value)
          })
      }
      .sheet(item: $openProjection) { node in
        ChatArchiveImportView(
          store: store, projectionNodeID: node.id,
          onQuestion: {
            openProjection = nil
            compose(from: entries.first(where: { $0.target == node.id }), reference: $0)
          })
      }
      .onChange(of: question?.id) { _, _ in
        waitingForQuestionInput = false
        collectingFor = nil
      }
      .onChange(of: question?.referenceID, initial: true) { _, reference in
        draftRelation = nil
        draftMarkdownSource = nil
        draftWholePDF = nil
        if let reference {
          s.perform {
            if let info = try store.writingSourceInfo(reference) {
              draftMarkdownSource = DraftMarkdownSource(label: "引自 " + info.title + " · 版本 " + String(info.ordinal),
                version: info.versionID, selection: try store.resolveWritingSource(reference, in: info.versionID))
            } else if let pdf = try store.wholePDFSourceInfo(reference) {
              draftWholePDF = pdf
            } else {
              draftRelation = try store.canvasRelationSource(reference: reference)
            }
          }
        }
      }
      .sheet(item: $editingRelation) { edge in
        CanvasRelationEditor(edge: edge) { kind, explanation in
          try store.reviseMapRelation(edge, kind: kind, explanation: explanation)
          update()
          editingRelation = nil
          inspected = map?.edges.first { $0.id == edge.id }
        }
      }
      .alert("移除这条知识关系？", isPresented: Binding(get: { removingRelation != nil }, set: {
        if !$0 { removingRelation = nil }
      }), presenting: removingRelation) { edge in
        Button("移除关系", role: .destructive) {
          update { try store.removeMapRelation(edge) }
          inspected = map?.edges.first { $0.id == edge.id }
        }
        Button("取消", role: .cancel) {}
      } message: { _ in Text("已有提问仍可回看当时的关系和两端依据。") }
      .sheet(item: $relationPair) { pair in
        CanvasNewRelation(pair: pair) { first, second, kind, reason in
          try store.relate(first.material, second.material, as: kind, reason: reason,
                           entrances: (first.placement, second.placement), requestID: pair.id)
          update()
        }
      }
      .sheet(item: $departure) { preview in
        TopicDepartureForm(
          preview: preview, confirm: { confirmDeparture(preview) }, cancel: { departure = nil })
      }
      .sheet(item: $editingRegion) { r in
        RegionEditForm(
          region: r,
          save: { name, frame in
            update {
              try store.editMapRegion(r.id, title: name, frame: frame)
              editingRegion = nil
            }
          }, cancel: { editingRegion = nil })
      }
      .onChange(of: selection, initial: true) { _, ids in
        s.assistantSelectedEntrances = Set(ids)
        if !ids.isEmpty { offer(.move) }
        selectedTopics = (ids.count == 1 ? (try? store.topicIDsForPlacement(ids[0])) : nil) ?? []
      }
      .sheet(isPresented: $addingTopic) {
        VStack(alignment: .leading, spacing: 14) {
          Text(instanceTopic == nil ? "新主题的第一个地域" : "为现有主题创建另一个地域")
            .font(.system(.title3, design: .serif)).fontWeight(.medium)
          PaperRule()
          if activeHint == .theme { hintNote(.theme) }
          TextField("地域名称", text: $topicName).textFieldStyle(.roundedBorder)
          HStack {
            Spacer()
            Button("取消") { addingTopic = false }.buttonStyle(PaperButton(compact: true))
            Button("创建") {
              update {
                let w = min(620, max(220, canvasSize.width / camera.zoom * 0.6))
                let h = min(420, max(160, canvasSize.height / camera.zoom * 0.55))
                let region = try store.createMapRegion(
                  title: topicName, topicID: instanceTopic,
                  frame: CGRect(
                    x: (canvasSize.width / 2 - camera.x) / camera.zoom - w / 2,
                    y: (canvasSize.height / 2 - camera.y) / camera.zoom - h / 2, width: w, height: h
                  ))
                selectedRegions = [region]
                selection = []
                topicName = ""
                addingTopic = false
              }
            }
            .buttonStyle(PaperButton(primary: true, compact: true))
            .disabled(topicName.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }.padding(22).frame(width: 340).background(AtlasPalette.paper)
          .onAppear { if instanceTopic == nil { offer(.theme) } }
          .onDisappear { if activeHint == .theme { activeHint = nil } }
      }
  }
  private func confirmDeparture(_ preview: TopicDeparturePreview) {
    update {
      let latest = try store.previewTopicDeparture(
        placementID: preview.placementID, topicID: preview.topicID)
      let actualIDs: [String] = latest.map { $0.id }
      let expectedIDs: [String] = preview.rows.map { $0.id }
      guard actualIDs == expectedIDs else {
        departure = .init(
          placementID: preview.placementID, topicID: preview.topicID, title: preview.title,
          rows: latest)
        throw AtlasStoreError.invalid("入口已改变，请核对更新后的范围。")
      }
      try store.leaveMapTopic(
        placementID: preview.placementID, topicID: preview.topicID,
        expectedEntrances: Set(preview.rows.map(\.id)))
      departure = nil
    }
  }
  private func regionFrame(_ r: CanvasRegion) -> CGRect {
    let delta =
      regionTree.belongsToSelection(r.id, selected: selectedRegions)
      ? (regionDrag == .zero ? drag : regionDrag) : .zero
    return CGRect(
      origin: CGPoint(
        x: camera.x + r.frame.minX * camera.zoom + delta.width,
        y: camera.y + r.frame.minY * camera.zoom + delta.height),
      size: CanvasRegionChrome.displaySize(r, zoom: camera.zoom))
  }

  private func displayedEndpoint(_ e: MapEntry) -> CGRect {
    if let id = regionTree.collapsedOwner(of: e.regionID), let region = regionTree.regions[id] {
      return regionFrame(region)
    }
    let offset = previewOffset(e)
    return frame(e).offsetBy(dx: offset.width, dy: offset.height)
  }

  private func regionDrop(at point: CGPoint) -> String? {
    regions.reversed().first { r in
      !regionTree.hides(r) && r.topicID != nil
        && CanvasRegionChrome.dropRect(in: regionFrame(r)).contains(point)
    }?.id
  }

  private func pickRegion(_ r: CanvasRegion) {
    focusLayout()
    if NSEvent.modifierFlags.contains(.shift) {
      if !selectedRegions.insert(r.id).inserted { selectedRegions.remove(r.id) }
    } else {
      selectedRegions = [r.id]
      selection = []
    }
    inspected = nil
  }

  @ViewBuilder private func regionLayer(viewport: CGRect) -> some View {
    let nearby = visibility.regionCandidates(in: worldViewport(viewport))
    ForEach(nearby.filter { regionFrame($0).intersects(viewport) }) { r in
      let rect = regionFrame(r)
      CanvasRegionChrome(
        region: r, size: rect.size, selected: selectedRegions.contains(r.id),
        accepting: activeDrop == r.id,
        canAccept: drag != .zero && selectedRegions.isEmpty && selection.count == 1
          && r.topicID != nil, externalEdges: externalEdgeCounts[r.id] ?? 0,
        select: { pickRegion(r) },
        track: { delta in
          if !selectedRegions.contains(r.id) {
            if !NSEvent.modifierFlags.contains(.shift) {
              selection = []
              selectedRegions = []
            }
            selectedRegions.insert(r.id)
          }
          regionDrag = delta
        },
        finish: { delta in
          focusLayout()
          regionDrag = .zero
          recordMove { id in
            try store.moveCanvasSelection(
              regionIDs: selectedRegions, placementIDs: Set(selection),
              dx: delta.width / camera.zoom, dy: delta.height / camera.zoom, batchID: id)
          }
        },
        toggle: {
          changePresentation(hiding: { id in
            !r.collapsed && regionTree.belongsToSelection(entries.first { $0.id == id }?.regionID, selected: [r.id])
          }) {
            update {
              if directoryUnfolded.remove(r.id) == nil {
                try store.setRegionCollapsed(r.id, collapsed: !r.collapsed)
              }
            }
          }
        }, edit: { editingRegion = r }
      )
      .offset(x: rect.minX, y: rect.minY)
    }
  }

  private var regionMenu: some View {
    Menu("地域与主题") {
      Button("创建新主题的地域…") {
        instanceTopic = nil
        topicName = ""
        addingTopic = true
      }
      Menu("为现有主题另建地域") {
        ForEach(map?.topics ?? []) { t in
          Button(t.title) {
            instanceTopic = t.id
            topicName = t.title
            addingTopic = true
          }
        }
      }
      if let id = selectedRegions.first, selectedRegions.count == 1, let r = regionTree.regions[id]
      {
        Button("边界适合内容") {
          let members = entries.filter { regionTree.belongsToSelection($0.regionID, selected: [id]) }
          let childRegions = regions.filter { $0.id != id && regionTree.belongsToSelection($0.parentID, selected: [id]) }
          let bounds = (members.map(reserved) + childRegions.map(\.frame)).reduce(CGRect.null) { $0.union($1) }
          if !bounds.isNull { update { try store.resizeMapRegion(id, frame: bounds.insetBy(dx: -28, dy: -52)) } }
        }
        Button("编辑「" + r.title + "」…") { editingRegion = r }
        Menu("设置上级地域") {
          Button("移到画布根层") { update { try store.setRegionParent(id, parentID: nil) } }
          ForEach(regions.filter { !regionTree.belongsToSelection($0.id, selected: [id]) }) { p in
            Button(p.title) { update { try store.setRegionParent(id, parentID: p.id) } }
          }
        }
      }
      if chosen.count == 1, let e = chosen.first {
        Menu("将当前入口加入地域") {
          ForEach(regions.filter { $0.topicID != nil }) { r in
            Button(r.title) {
              update {
                try store.joinMapRegion(
                  placementID: e.id, regionID: r.id, x: r.frame.minX + 24, y: r.frame.minY + 48)
              }
            }
          }
        }
        Menu("在地域中创建引用入口") {
          ForEach(regions.filter { $0.topicID != nil }) { r in
            Button(r.title) {
              update { _ = try store.copyMapEntrance(placementID: e.id, regionID: r.id) }
            }
          }
        }
        Button("移出此地域，保留主题") { update { try store.leaveMapRegion(placementID: e.id) } }.disabled(
          e.regionID == nil)
        Menu("退出主题并保留入口") {
          ForEach((map?.topics ?? []).filter { selectedTopics.contains($0.id) }) { t in
            Button(t.title + "…") {
              s.perform {
                departure = .init(
                  placementID: e.id, topicID: t.id, title: t.title,
                  rows: try store.previewTopicDeparture(placementID: e.id, topicID: t.id))
              }
            }
          }
        }.disabled(selectedTopics.isEmpty)
      }
    }
  }
  private func toolbar(_ available: CGSize) -> some View {
    HStack(spacing: 6) {
      Button { changePresentation(hiding: { _ in true }, apply: showDirectory) } label: {
        Label("目录", systemImage: "list.bullet.indent")
      }
      .buttonStyle(AtlasChipButtonStyle())
      .accessibilityLabel("画布目录").help("定位画布上的地域和对象")
      if selection.count == 1, let id = selection.first {
        let viewport = CGRect(origin: .zero, size: available)
        let remote = (connectedEntrances[id] ?? []).filter { !viewport.intersects(displayedEndpoint($0)) }
        if !remote.isEmpty {
          Rectangle().fill(AtlasPalette.line.opacity(0.35)).frame(width: 0.75, height: 14)
          Menu {
            ForEach(Array(Set(remote.map(\.id))).sorted(), id: \.self) { id in
              if let entry = remote.first(where: { $0.id == id }) {
                Button(title(entry)) {
                  rememberLocation("回到刚才")
                  revealAncestors(of: entry.regionID)
                  focusEntry(entry)
                }
              }
            }
          } label: {
            AtlasMenuPillLabel(title: "画外的相连材料", compact: true)
          }
          .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
          .accessibilityLabel("画外的相连材料")
        }
      }
      if camera.overview && !regions.isEmpty {
        Rectangle().fill(AtlasPalette.line.opacity(0.35)).frame(width: 0.75, height: 14)
        Menu {
          ForEach(regions) { region in
            Button(region.title + " · " + String(regionCounts[region.id, default: 0]) + " 个直属入口") {
              focusRegion(region)
              persist()
            }
          }
        } label: {
          AtlasMenuPillLabel(title: "定位地域", icon: "mappin.and.ellipse", compact: true)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
        .accessibilityLabel("定位地域")
      }
      if awaitingComposition {
        Text("确认或取消候选文字后收起").font(.caption)
      }
      if let latestBranch, let branch = entries.first(where: { $0.target == latestBranch }),
        !CGRect(origin: .zero, size: canvasSize).contains(
          CGPoint(x: frame(branch).midX, y: frame(branch).minY + 12))
      {
        Button("新分支已创建 · 前往") { rememberLocation("回到刚才"); openOnMap(latestBranch, center: true) }
      }
      if organizationVisit != nil {
        Button("返回整理定位前", action: returnFromOrganization)
      } else if relationReturn != nil {
        Button("返回关系依据", action: returnToRelation)
      } else if searchVisit != nil {
        Button("返回画布", action: returnFromSearch)
      } else if navigationReturn != nil && sourceReturn == nil {
        Button(navigationReturnLabel, action: returnFromLocation)
      }
      if sourceReturn != nil && searchVisit == nil && temporaryPDF == nil && temporaryMarkdown == nil {
        Button("返回提问处", action: returnFromSource)
      }
      if let back = changedOrigin {
        if let moved = entries.first(where: { $0.id == back.entry.id }) {
          Button("入口已移动 · 定位现位置") {
            openOnMap(moved.target, preferred: moved.id, center: true)
            changedOrigin = nil
          }
        } else {
          Button("入口已移除 · 查看当时的问答") {
            s.perform {
              let original = try store.run(back.runID)
              answerOrigin = nil
              answerPage = AnswerSourcePage(runID: original.id, body: original.answer, title: original.question,
                historical: true)
            }
            changedOrigin = nil
          }
        }
      }
      if !chosen.isEmpty || !selectedRegions.isEmpty {
      Rectangle().fill(AtlasPalette.line.opacity(0.35)).frame(width: 0.75, height: 14)
      Menu {
      if chosen.count > 1, let first = chosen.first {
        Button("排开所选") { previewOverlap(first, selected: chosen) }
      }
      regionMenu
      Button("建立关系") {
        s.perform {
          let pair = chosen
          guard pair.count == 2 else { return }
          relationPair = try CanvasRelationPair(first: relationInput(pair[0]), second: relationInput(pair[1]))
        }
      }.disabled(chosen.count != 2 || Set(chosen.map(\.target)).count != 2 || chosen.contains { entry in
        run(entry)?.versionID == nil && file(entry) == nil && item(entry)?.kind != .markdown
      })
      Menu("布局") {
        Button("整理画布选区…") { canvasOrganization.wrappedValue = true }
          .disabled(selection.isEmpty && selectedRegions.isEmpty)
        Divider()
        Button("撤销") { coordinates.surface?.replayLayout?(false) }
        Button("重做") { coordinates.surface?.replayLayout?(true) }
        Divider()
        Button("复制引用入口") {
          s.perform { try insertReferences(chosen.map(entranceReference), at: materialOrigin()) }
        }.disabled(chosen.isEmpty || !selectedRegions.isEmpty)
        if chosen.count == 1, let entry = chosen.first, item(entry)?.kind == .markdown {
          Button("从此版本创建独立副本") {
            s.perform {
              let copy = try store.deriveMarkdown(placement: entry.id, at: materialOrigin())
              openOnMap(copy.id, center: true)
            }
          }
        }
        Button("移除选中入口") { update { try store.removeMapEntries(chosen) } }.disabled(chosen.isEmpty)
      }
      } label: {
        AtlasMenuPillLabel(title: "所选操作", compact: true)
      }
      .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
      .accessibilityLabel("所选操作")
      }
      if !drafts.isEmpty && question == nil {
        let draftTitle = "草稿（" + String(drafts.count) + "）"
        Rectangle().fill(AtlasPalette.line.opacity(0.35)).frame(width: 0.75, height: 14)
        Menu {
          ForEach(drafts) { draft in
            Button(draft.text.isEmpty ? (draft.quote ?? "空白问题") : draft.text) {
              question = draft
              questionFocus = UUID()
            }
          }
        } label: {
          AtlasMenuPillLabel(title: draftTitle, icon: "doc.text", compact: true)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
        .accessibilityLabel(draftTitle)
      }
    }.buttonStyle(AtlasChipButtonStyle()).fixedSize().atlasFloatingBar()
  }
  private func navigationEntry(in available: CGSize) -> MapEntry? {
    if let entry = chosen.first ?? entries.first(where: { $0.id == focusedReader }) { return entry }
    let viewport = CGRect(origin: .zero, size: available)
    guard camera.distant else { return visible(viewport).first }
    let padded = viewport.insetBy(dx: -50, dy: -50)
    return visibility.firstEntrance(in: worldViewport(padded)) { frame($0).intersects(padded) }
  }

  private func navigationControls(_ available: CGSize) -> some View {
    let zoomLabel = camera.zoom < 0.01 ? "<1%" : String(Int(camera.zoom * 100)) + "%"
    let showTrialDiagnostics = ProcessInfo.processInfo.environment["LIVING_ATLAS_TRIAL_HOME"] != nil || trial.active
    return HStack(spacing: 4) {
      if showTrialDiagnostics {
        Button {
          if trial.active { trial.stop() }
          else if let surface = coordinates.surface { trial.start(on: surface) }
        } label: {
          Label(trial.active ? "诊断中" : "诊断", systemImage: trial.active ? "record.circle.fill" : "waveform.path.ecg")
        }
        .buttonStyle(AtlasChipButtonStyle(emphasized: trial.active))
        .accessibilityLabel(trial.active ? "停止试用诊断" : "开启试用诊断")
        .help(trial.notice ?? (trial.active ? "停止本地试用诊断；右键显示日志" : "开启本地试用诊断，记录手势与出帧时间"))
        .contextMenu {
          if let url = trial.file { Button("在访达中显示诊断日志") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }
      }
      AtlasHomingCompass(offscreenAngle: offscreenContentAngle(in: available)) { fit(canvasSize) }
      if !camera.overview, !camera.distant, (entries.count >= 2 || !regions.isEmpty) {
        Button { toggleMiniMap() } label: { Image(systemName: "map") }
          .buttonStyle(AtlasChipButtonStyle(emphasized: showMiniMap))
          .accessibilityLabel(showMiniMap ? "收起阅读缩略图" : "显示阅读缩略图")
          .help(showMiniMap ? "收起右下角缩略图" : "打开阅读尺幅缩略图，点击或拖动快速漫游")
      }
      Button { s.canvasHelp = true } label: { Image(systemName: "questionmark.circle") }
        .buttonStyle(AtlasChipButtonStyle()).accessibilityLabel("画布操作帮助").help("画布操作帮助")
      Button { panTool.toggle() } label: { Label("平移", systemImage: "hand.draw") }
        .buttonStyle(AtlasChipButtonStyle(emphasized: panTool))
        .accessibilityValue(panTool ? "已开启" : "已关闭")
        .help("按住空格拖动可以临时平移；直接拖动画布空白处可框选。")
      Button(camera.overview ? (camera.readingPlace == nil ? "阅读视图" : "返回阅读位置") : "概览视图") {
        changePresentation(hiding: { _ in !camera.overview }, apply: toggleOverview)
      }
      .buttonStyle(AtlasChipButtonStyle(emphasized: camera.overview && camera.readingPlace != nil))
      Button("全图") { fit(canvasSize) }
        .buttonStyle(AtlasChipButtonStyle())
        .keyboardShortcut("0", modifiers: .command)
        .help("适合全图 (⌘0)")
      Rectangle().fill(AtlasPalette.line.opacity(0.35)).frame(width: 0.75, height: 14).padding(.horizontal, 2)
      Button {
        adjustZoom(0.8, available: available)
      } label: {
        Image(systemName: "minus.magnifyingglass").font(.system(size: 12))
      }
      .buttonStyle(AtlasChipButtonStyle())
      .accessibilityLabel("缩小画布").keyboardShortcut("-", modifiers: .command)
      Button {
        adjustZoom(1.25, available: available)
      } label: {
        Image(systemName: "plus.magnifyingglass").font(.system(size: 12))
      }
      .buttonStyle(AtlasChipButtonStyle())
      .accessibilityLabel("放大画布").keyboardShortcut("+", modifiers: .command)
      Menu {
        if let entry = navigationEntry(in: available) {
          Button("阅读所选对象") { changePresentation(hiding: { $0 != entry.id }) { positionAtEntrance(entry) } }
          Button("局部脉络") { changePresentation(hiding: { _ in true }) { showLocalContext(entry) } }
        }
        Button("整体地图") {
          changePresentation(hiding: { _ in true }) {
            if camera.overview { fit(available) } else { toggleOverview() }
          }
        }
        Divider()
        ForEach([25, 50, 75, 100, 150, 200], id: \.self) { n in
          Button("\(n)%") {
            interruptCameraGlide()
            camera.scale(
              Double(n) / 100 / camera.zoom,
              at: CGPoint(x: available.width / 2, y: available.height / 2))
            persist()
          }
        }
      } label: {
        AtlasMenuPillLabel(title: zoomLabel, compact: true)
      }
      .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
      .accessibilityLabel(zoomLabel)
    }.fixedSize().atlasFloatingBar()
  }
  private func relationInput(_ entry: MapEntry) throws -> CanvasRelationPair.Input {
    if let run = run(entry), let version = run.version {
      return .init(placement: entry.id, material: .answer(run), label: run.question, version: version, passage: run.answer)
    }
    if let file = file(entry) {
      let selected = mapPDFSelection[entry.id].flatMap { $0.versionID == file.versionID ? $0 : nil }
      return .init(placement: entry.id, material: .pdf(file, selection: selected), label: file.title,
                   version: file.ordinal, passage: selected?.quote)
    }
    let item = try store.writing(id: entry.target)
    if item.kind != .markdown, item.draft == nil, let version = try store.writingVersions(item).first {
      return .init(placement: entry.id, material: .writing(id: item.id, version: version.id),
                   label: item.displayTitle, version: version.ordinal, passage: version.body)
    }
    let state = try store.readViewState(CanvasWritingState.self, key: CanvasWritingState.key(entry.id))
    guard item.kind == .markdown, let id = state?.pinnedVersion ?? (item.draft == nil ? item.currentVersionID : nil)
    else { throw AtlasStoreError.invalid("请先把这份 Markdown 草稿保存为版本，再建立关系。") }
    let version = try store.markdownRelationInfo(documentID: item.id, versionID: id)
    var parts = [WritingSelection]()
    if readingEntry(entry), state?.editing != true {
      let key = "markdown.selection." + CanvasWritingState.positionPrefix(entry.id) + id
      parts = try store.readViewState(WritingPreview.Coordinator.SelectionBookmark.self, key: key)?.parts ?? []
    }
    return .init(placement: entry.id, material: .markdown(documentID: item.id, versionID: id, selection: parts),
                 label: version.title,
                 version: version.ordinal, passage: parts.isEmpty ? nil : parts.map(\.quote).joined(separator: "\n"))
  }
  private func cardKind(_ e: MapEntry) -> AtlasKindBadge.Kind {
    if e.kind == "turn" {
      let r = run(e)
      let isFollowup = r?.parentAnswer != nil || r?.anchor != nil || r?.sourceReferenceID != nil
      return isFollowup ? .followup : .question
    }
    if item(e)?.kind == .question { return .question }
    if file(e) != nil { return .pdf }
    if item(e)?.kind == .markdown { return .markdown }
    if e.kind == "document" { return .material }
    return .idea
  }

  private func isHistoricalCard(_ e: MapEntry) -> Bool {
    if let label = writingLabels[e.id], label.hasPrefix("历史") { return true }
    if let pinned = pinnedPDFs[e.id],
      let latest = s.docs.first(where: { $0.id == e.target }),
      pinned.versionID != latest.versionID
    {
      return true
    }
    if let shown = shownRuns[e.id],
      let latest = s.runs.first(where: { $0.turnID == e.target }),
      shown != latest.id
    {
      return true
    }
    return false
  }

  private func card(_ e: MapEntry, mounted: Bool, overlaps: Bool, wide: Bool = false) -> some View {
    let expanded = wide || readingEntry(e)
    let isSelected = selection.contains(e.id)
    let isDragging = drag != .zero && isSelected
    let isArriving = arrivalPulseID == e.id
    let isLineageRelated = !wide && !isSelected && connectedToFocus(e.id)
    let isAmbientOther = !wide && !isSelected && !isLineageRelated && !isArriving
      && focusAnchorID != nil && focusAnchorID != e.id && entries.count >= 3
    let isNewlyDiscovered = newlyCompletedEntries.contains(e.id) && run(e)?.status == .completed
    let isPreviewRemoved = canvasDiffPreview?.isMarkedForRemoval(e.id) == true
    let hasPreviewRewrite = canvasDiffPreview?.hasRewriteProposal(e.id) == true
    let historical = isHistoricalCard(e)
    return VStack(alignment: .leading, spacing: 0) {
      if expanded, run(e)?.status.isActive == true {
        LinearGradient(
          colors: [.clear, AtlasPalette.gold.opacity(0.85), .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(height: 2)
        .atlasWorkingBreath(active: true)
      }
      // Editorial archival header strip
      VStack(alignment: .leading, spacing: expanded ? 6 : 4) {
        HStack(spacing: 6) {
          if expanded, run(e)?.status.isActive == true {
            TaskCompanion(pose: .working, size: 24)
          } else if isNewlyDiscovered {
            TaskCompanion(pose: .discovery, size: 22)
          }
          AtlasKindBadge(kind: cardKind(e))
          if isNewlyDiscovered {
            Text("新回答")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(AtlasPalette.umber)
              .padding(.horizontal, 5.5)
              .padding(.vertical, 1.5)
              .background(AtlasPalette.gold.opacity(0.18), in: Capsule())
              .overlay { Capsule().strokeBorder(AtlasPalette.gold.opacity(0.48), lineWidth: 0.65) }
          }
          if isPreviewRemoved {
            Text("将移出画布")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(AtlasPalette.terracotta)
              .padding(.horizontal, 5.5)
              .padding(.vertical, 1.5)
              .background(AtlasPalette.terracotta.opacity(0.12), in: Capsule())
              .overlay { Capsule().strokeBorder(AtlasPalette.terracotta.opacity(0.45), lineWidth: 0.65) }
          } else if hasPreviewRewrite {
            Text("有修订提案")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(AtlasPalette.blueInk)
              .padding(.horizontal, 5.5)
              .padding(.vertical, 1.5)
              .background(AtlasPalette.blueInk.opacity(0.10), in: Capsule())
              .overlay { Capsule().strokeBorder(AtlasPalette.blueInk.opacity(0.32), lineWidth: 0.65) }
          }
          if historical {
            Text("历史卷")
              .font(.system(size: 10, weight: .medium, design: .serif))
              .foregroundStyle(AtlasPalette.umber)
              .padding(.horizontal, 5.5)
              .padding(.vertical, 1.5)
              .background(AtlasPalette.umber.opacity(0.11), in: Capsule())
              .overlay { Capsule().strokeBorder(AtlasPalette.umber.opacity(0.28), lineWidth: 0.65) }
          }
          Spacer(minLength: 4)
          if overlaps {
            Button { previewOverlap(e) } label: {
              ViewThatFits(in: .horizontal) {
                Label("排开重叠", systemImage: "square.2.layers.3d")
                Image(systemName: "square.2.layers.3d")
              }
            }
            .buttonStyle(AtlasChipButtonStyle(emphasized: true))
            .accessibilityLabel("预览局部整理")
            .help("预览相邻图版的移动位置，也可以拖动标题手动移开。")
          }
          if expanded, let r = run(e) {
            if locatedEntryID == e.id, let version = r.version {
              Text("版本 " + String(version)).font(.system(size: 11)).foregroundStyle(AtlasPalette.umber)
            }
            if r.status != .completed {
              HStack(spacing: 4) {
                // PH-04: open/paused thought uses a calm open amber ring; only real failures use muted terracotta
                if r.status == .failed {
                  Circle().fill(AtlasPalette.terracotta).frame(width: 5.5, height: 5.5)
                } else if r.status.isActive {
                  Circle().fill(AtlasPalette.gold).frame(width: 5.5, height: 5.5)
                    .atlasWorkingBreath(active: true)
                } else {
                  Circle().strokeBorder(AtlasPalette.gold, lineWidth: 1.4).frame(width: 6.5, height: 6.5)
                }
                Text(r.statusText).font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
              }
            }
            if r.status.isActive {
              Button("停止") { s.stop(r) }
                .buttonStyle(PaperButton(compact: true))
            } else if r.status != .completed {
              Button("重试") {
                s.send(retry: r, onMap: true)
                if let next = s.runs.first(where: { $0.turnID == r.turnID && $0.status.isActive }),
                  next.retryOf == r.id
                {
                  if locatedEntryID == e.id { taskRunID = next.id }
                  if shownRuns[e.id] != nil {
                    shownRuns[e.id] = next.id
                    s.perform { try store.saveViewState(shownRuns, key: "map.shown-runs") }
                  }
                }
              }
              .buttonStyle(PaperButton(compact: true))
              .disabled(s.runs.contains { $0.turnID == r.turnID && $0.status.isActive })
            }
          }
          if !wide {
            Button(expanded ? "收起" : "打开阅读") {
              if !expanded, obstructed(e, size: reserved(e).size) { focusSheet = e; return }
              changePresentation(hiding: { $0 == e.id && expanded }) {
                update {
                  if locatedEntryID == e.id {
                    locatedEntryID = nil
                    if e.expanded || camera.overview { try store.toggleMapEntryForReading(e, wasOverview: camera.overview) }
                  } else { try store.toggleMapEntryForReading(e, wasOverview: camera.overview) }
                  if expanded { rememberResumedReaders(resumedReaders.subtracting([e.id])) }
                  else { resumeReader(e) }
                  focusedReader = e.id
                  camera.overview = false
                  persist()
                }
              }
            }
            .buttonStyle(AtlasChipButtonStyle())
          }
        }
        HStack(spacing: 6) {
          if !wide { moveGrip(e) }
          Text(title(e))
            .font(AtlasTypeface.reading.font(expanded ? 17.5 : 15).weight(.medium))
            .lineSpacing(2).foregroundStyle(AtlasPalette.ink).lineLimit(2)
        }
          .help(wide ? title(e) : "拖动标题移动图版；在正文中拖动可选字。")
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          .simultaneousGesture(TapGesture().onEnded { focusLayout() })
          .canvasMoveCursor(enabled: !wide, dragging: drag != .zero && isSelected)
          .gesture(titleDrag(e), including: wide ? .none : .all)
        if let version = writingLabels[e.id] ?? file(e).map({ file in
          (pinnedPDFs[e.id] == nil ? "跟随当前 · v" : (file.versionID == s.docs.first(where: { $0.id == e.target })?.versionID ? "固定 · v" : "历史 · v")) + String(file.ordinal)
        }) {
          let count = entranceCounts[e.target] ?? 1
          HStack(spacing: 6) {
            Text(version + (count > 1 ? "　共享正文 · " + String(count) + " 处入口" : ""))
              .font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
            if count > 1 {
              AtlasSharedFolioBadge(count: count)
                .accessibilityHidden(true)
            }
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 11)
      .padding(.bottom, 10)
      .background(
        (historical ? Color(red: 0.933, green: 0.894, blue: 0.824) : AtlasPalette.paperHeader)
          .opacity(hoveredEntry == e.id ? (expanded ? 0.92 : 0.72) : (expanded ? 0.62 : 0.44))
      )
      .animation(AtlasMotion.micro(reduceMotion), value: hoveredEntry == e.id)

      PaperRule()

      VStack(alignment: .leading, spacing: 8) {
      if expanded && !mounted {
        Button("继续阅读") { resumeReader(e) }.buttonStyle(PaperButton())
      } else if expanded {
        if let run = run(e) {
          if run.extraCitationCount > 0 {
            Button("附加引用材料（" + String(run.extraCitationCount) + "）") { s.showCanvasCitations(run) }
              .buttonStyle(AtlasChipButtonStyle(emphasized: true))
          }
          if let source = run.parentAnswer ?? run.anchor?.quote ?? run.referenceLabel {
            Button {
              if wide {
                if run.parentAnswer != nil { returnToFocusedAnswer = e }
                focusSheet = nil
              }
              revealOrigin(run, from: e)
            } label: {
              AtlasQuoteCallout(text: source, clickable: true)
            }.buttonStyle(.plain).accessibilityLabel(source)
          }
          answerGuidance(run, entry: e, wide: wide)
          AnswerReader(
            text: run.answer, streaming: run.status.isActive, zoom: camera.zoom,
            reading: CanvasAnswerReading(store: store, placementID: e.id, runID: run.id,
              onFailure: { s.error = $0 }),
            measured: { height in
              if (e.readingHeight == nil || !run.status.isActive), abs((answerHeights[e.id] ?? 0) - height) > 1 {
                answerHeights[e.id] = height
              }
            },
            naturalCanvasHeight: !wide && e.readingHeight == nil,
            onReaderScroll: trial.active ? { trial.action("reader-scroll") } : nil,
            canvasWheelEnabled: !wide,
            collecting: collecting, onInteraction: { active in
              holdReader(e.id, run: run.id, active: active, in: $selectingReaders)
              if active { focusedReader = e.id }
            },
            onSelectText: { trial.action("select-text"); offer(.quotation) },
            selectedSource: { body, range, screenPoint in
              focusedReader = e.id
              answerOrigin = e.id
              if guidedAnswerID == run.id { guidedAnswerID = nil }
              if let range, range.length > 0, let stringRange = Range(range, in: body) {
                s.perform {
                  if wide { focusSheet = nil }
                  let start = body[..<stringRange.lowerBound].unicodeScalars.count
                  let end = start + body[stringRange].unicodeScalars.count
                  let source = try AnswerExcerpt(runID: run.id, body: body, start: start, end: end)
                  compose(at: screenPoint.flatMap(coordinates.point), from: e, excerpt: source)
                }
              } else {
                answerPage = AnswerSourcePage(runID: run.id, body: body, title: "从回答选句")
              }
            }
          )
          .onChange(of: !run.answer.isEmpty && s.submittedCanvasTurn == e.target
            && focusedReader == e.id && !camera.overview && !collecting
            && (wide || frame(e).intersects(CGRect(origin: .zero, size: canvasSize))), initial: true) { _, ready in
            let seen = s.defaults.integer(forKey: CanvasHint.seenKey)
            guard ready, !skippedHints, seen & CanvasHint.firstAnswer.rawValue == 0 else { return }
            s.defaults.set(seen | CanvasHint.firstAnswer.rawValue, forKey: CanvasHint.seenKey)
            activeHint = nil
            guidedAnswerID = run.id
          }
          .onChange(of: run.status.isActive, initial: true) { _, active in
            holdReader(e.id, run: run.id, active: active, in: $streamingReaders)
          }
          .onDisappear {
            holdReader(e.id, run: run.id, active: false, in: $streamingReaders)
            holdReader(e.id, run: run.id, active: false, in: $selectingReaders)
          }.id(run.id)
          if !run.answer.isEmpty && !collecting && guidedAnswerID != run.id {
            HStack(spacing: 6) {
              AtlasArt.compass.resizable().scaledToFit().frame(width: 10, height: 10).opacity(0.45)
              Text("拖选回答中的一句话，即可就这句追问")
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(AtlasPalette.umber)
            }
            .padding(.top, 2)
            .allowsHitTesting(false)
          }
        } else if let file = file(e) {
          DocumentReader(
            file: file, store: store, placementID: e.id, focus: sourceHighlights[e.id],
            focusRequest: sourceRequests[e.id], citation: sourceHighlights[e.id], zoomRequest: pdfZoom[e.id],
            selected: { anchor in
              mapPDFSelection[e.id] = anchor
              if anchor != nil { trial.action("select-text"); focusedReader = e.id; offer(.quotation) }
            }, failure: { s.error = $0 })
          .padding(4)
          .background(Color(red: 0.941, green: 0.910, blue: 0.855), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .strokeBorder(AtlasPalette.line.opacity(0.42), lineWidth: 0.75)
              .allowsHitTesting(false)
          }
          .onDisappear {
            if mapPDFSelection[e.id]?.versionID == file.versionID { mapPDFSelection[e.id] = nil }
          }
          HStack(spacing: 6) {
            Menu {
              Button("把这一页放到画布") {
                s.perform {
                  NotificationCenter.default.post(name: .atlasSavePDFPlace, object: store)
                  let index = (try? store.readViewState(PDFReadingPlace.self, key: "map.pdf."+e.id+"."+file.versionID))?.page ?? 0
                  putPages(file, indices: [index], near: CGPoint(x: reserved(e).maxX + 52, y: e.y))
                }
              }
              Button("适合宽度") {
                pdfZoom[e.id] = PDFZoomRequest(action: .fitWidth, versionID: file.versionID)
              }
              Button("放大 PDF") {
                pdfZoom[e.id] = PDFZoomRequest(action: .zoomIn, versionID: file.versionID)
              }
              Button("缩小 PDF") {
                pdfZoom[e.id] = PDFZoomRequest(action: .zoomOut, versionID: file.versionID)
              }
            } label: {
              AtlasMenuPillLabel(title: "PDF 页缩放", compact: true)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
            .accessibilityLabel("PDF 页缩放")
            Button("版本 " + String(file.ordinal) + (pinnedPDFs[e.id] == nil ? " · 跟随当前版" : " · 已固定")) {
              s.perform { versionChoice = try VersionChoice(id: e.id, versions: store.pdfVersions(documentID: file.id)) }
            }
            .buttonStyle(AtlasChipButtonStyle())
            Spacer(minLength: 0)
            if let anchor = mapPDFSelection[e.id], anchor.versionID == file.versionID {
              Button(collecting ? "把 PDF 选句加入本题" : "用选句追问") { if wide { focusSheet = nil }; compose(from: e, anchor: anchor) }
                .buttonStyle(PaperButton(primary: true, compact: true))
            }
          }
        } else if let page = webPages[e.target] {
          AnswerReader(text: page.body)
          Button("查看网页快照") { s.webSource = page }.buttonStyle(AtlasChipButtonStyle(emphasized: true))
        } else if let node = projections[e.target] {
          AnswerReader(text: node.body)
          Button("查看原消息") { openProjection = node }.buttonStyle(AtlasChipButtonStyle(emphasized: true))
        } else if let w = item(e) {
          CanvasWritingObject(
            store: store, itemID: w.id, placementID: e.id, editorFocus: editorFocus, addSelection: collecting ? { addMaterial(.markdown(version: $0, selection: $1)) } : nil,
            onSelectText: { trial.action("select-text"); offer(.quotation) },
            onInteraction: { active in
              if active {
                editingPlacements.insert(e.id)
                focusedReader = e.id
              } else {
                editingPlacements.remove(e.id)
              }
            }, onQuestion: { ref in if wide { focusSheet = nil }; compose(from: e, reference: ref) })
        }
      } else if let pdf = file(e) {
        PDFPreviewLine(file: pdf)
      } else {
        Text(
          cleanMarkdownPreview(
            run(e)?.answer ?? (writingLabels[e.id]?.contains("跟随当前") == true || item(e)?.currentVersionID == nil || item(e)?.kind != .markdown ? item(e)?.draft : nil) ?? writingFragments[e.id]
              ?? (webPages[e.target]?.body ?? projections[e.target]?.body) ?? ""
          )
        ).lineLimit(3).font(AtlasTypeface.reading.font(14)).lineSpacing(3).foregroundStyle(AtlasPalette.ink.opacity(0.84))
      }
      Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.top, 9)
      .padding(.bottom, expanded ? 6 : 11)
      .contentShape(Rectangle())
      .canvasMoveCursor(enabled: !expanded && !wide, dragging: drag != .zero && isSelected)
      .gesture(titleDrag(e), including: !expanded && !wide ? .all : .none)

      if expanded {
        PaperRule().padding(.horizontal, 14)
        HStack(spacing: 6) {
          if let writing = item(e), writing.kind == .question {
            Button("从此题追问") {
              s.perform { compose(from: e, reference: try store.referenceWriting(writing)) }
            }.buttonStyle(AtlasChipButtonStyle(emphasized: true))
              .disabled(writing.currentVersionID == nil || writing.draft != nil)
          }
          if let r = run(e) {
            if !r.answer.isEmpty {
              Button(collecting ? "从回答选择材料" : "选句追问") {
                guard let source = run(e) else { return }
                selectAnswer(source, from: e, wide: wide)
              }
              .buttonStyle(AtlasChipButtonStyle(emphasized: true))
            }
            Menu {
              Button("查看材料与用量") { materialReview = r }
              Button("按当前范围重新回答") { s.send(retry: r, reusingContext: false, onMap: true) }
                .disabled(r.status.isActive)
                .disabled(s.runs.contains { $0.turnID == r.turnID && $0.status.isActive })
              Divider()
              if e.readingHeight == nil {
                Button("固定阅读窗") {
                  update { try store.resizeMapEntry(e, width: size(e).width, height: 340) }
                }
              } else {
                Button("在画布展开全文") {
                  let height = max(240, (answerHeights[e.id] ?? 200) + 146)
                  if obstructed(e, size: CGSize(width: size(e).width, height: height)) {
                    focusSheet = e
                  } else { update { try store.growMapAnswer(e) } }
                }.disabled(r.status.isActive || answerHeights[e.id] == nil)
              }
              if !wide {
                Divider()
                Button("宽读") { focusSheet = e }
              }
            } label: {
              AtlasMenuPillLabel(title: "阅读方式", compact: true)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
            .accessibilityLabel("阅读方式")
            let attempts = s.runs.filter { $0.turnID == e.target }
            if attempts.count > 1 {
              Menu {
                Button("跟随最新回答") {
                  if locatedEntryID == e.id { taskRunID = nil }
                  shownRuns[e.id] = nil
                  s.perform { try store.saveViewState(shownRuns, key: "map.shown-runs") }
                }
                ForEach(attempts) { v in
                  Button(v.version.map { "版本 " + String($0) } ?? v.statusText) {
                    if locatedEntryID == e.id { taskRunID = nil }
                    shownRuns[e.id] = v.id
                    s.perform { try store.saveViewState(shownRuns, key: "map.shown-runs") }
                  }
                }
              } label: {
                AtlasMenuPillLabel(title: "回答历史", compact: true)
              }
              .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
              .accessibilityLabel("回答历史")
            }
          }
          Spacer()
          if !wide {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(AtlasPalette.umber.opacity(0.48))
              .padding(4)
              .contentShape(Rectangle())
              .accessibilityLabel("调整入口尺寸").gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global).onChanged { v in
                  if focusedReader != e.id { focusedReader = e.id }
                  resizeID = e.id
                  resizeDelta = CGSize(
                    width: v.translation.width / camera.zoom,
                    height: v.translation.height / camera.zoom)
                }.onEnded { _ in
                  let next = size(e)
                  resizeID = nil
                  resizeDelta = .zero
                  if obstructed(e, size: next) { focusSheet = e }
                  else { update { try store.resizeMapEntry(e, width: next.width, height: next.height) } }
                })
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
      }
    }
    .paperSheet(cornerRadius: 12, elevated: e.id == focusedReader || isDragging, historical: historical)
    .overlay {
      if isArriving {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(AtlasPalette.gold.opacity(0.90), lineWidth: 2.2)
          .shadow(color: AtlasPalette.gold.opacity(0.36), radius: 9)
          .allowsHitTesting(false)
      } else if isSelected {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(AtlasPalette.blueInk.opacity(0.84), lineWidth: 1.5)
          .shadow(color: AtlasPalette.blueInk.opacity(0.22), radius: 5)
          .allowsHitTesting(false)
      } else if isLineageRelated {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(AtlasPalette.gold.opacity(0.68), lineWidth: 1.15)
          .allowsHitTesting(false)
      }
    }
    .opacity(isPreviewRemoved ? 0.48 : (isAmbientOther ? 0.91 : 1))
    .contentShape(Rectangle()).simultaneousGesture(
      TapGesture().onEnded {
        newlyCompletedEntries.remove(e.id)
        select(e)
        if expanded { focusedReader = e.id } else { focusLayout() }
      }
    )
    .onHover { if !wide { trackHover(e, inside: $0) } }
    .accessibilityElement(children: .contain).accessibilityLabel(title(e))
    .accessibilityIdentifier("canvas.entrance." + e.id)
  }
}
extension AtlasStore {
  fileprivate func toggleMapEntryForReading(_ entry: MapEntry, wasOverview: Bool) throws {
    if !(wasOverview && entry.expanded) { try toggleMapEntry(entry) }
  }
}

private extension View {
  @ViewBuilder func canvasMoveCursor(enabled: Bool, dragging: Bool) -> some View {
    if !enabled { self }
    else if #available(macOS 15, *) { pointerStyle(dragging ? .grabActive : .grabIdle) }
    else {
      onContinuousHover { phase in
        if case .active = phase { (dragging ? NSCursor.closedHand : .openHand).set() }
      }
    }
  }
}
