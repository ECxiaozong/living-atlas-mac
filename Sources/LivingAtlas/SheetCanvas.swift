import AppKit
import AtlasCore
import SwiftUI

extension Notification.Name {
  static let atlasResetSheet = Notification.Name("LivingAtlasResetSheet")
}

struct SheetPlacement: Codable, Equatable {
  var x = 12.0
  var y = 10.0
  var objectKey: String?
  var cameraX = 0.0
  var cameraY = 0.0
}

final class SheetWorld: NSView { override var isFlipped: Bool { true } }

/// Reading and input own scroll events inside the sheet, even at their boundaries.
final class SheetScroll: NSScrollView {
  var sheetFrame: NSRect = .zero
  var didResize: (() -> Void)?
  var didZoom: ((CGFloat) -> Void)?
  override func magnify(with event: NSEvent) {
    super.magnify(with: event)
    didZoom?(magnification)
  }
  override func layout() {
    super.layout()
    didResize?()
  }
  override func scrollWheel(with event: NSEvent) {
    if let documentView,
      sheetFrame.contains(documentView.convert(event.locationInWindow, from: nil))
    {
      return
    }
    super.scrollWheel(with: event)
  }
}

final class SheetMover: NSView {
  var move: ((NSPoint, Bool) -> Void)?
  var reset: (() -> Void)?
  private var last: NSPoint?
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      reset?()
      return
    }
    window?.makeFirstResponder(self)
    last = convertToWorld(event)
    NSCursor.closedHand.push()
  }
  private func convertToWorld(_ event: NSEvent) -> NSPoint {
    var target = superview
    while let element = target, !(element is SheetWorld) { target = element.superview }
    return target?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start = last else { return }
    let point = convertToWorld(event)
    move?(NSPoint(x: point.x - start.x, y: point.y - start.y), false)
    last = point
  }
  override func mouseUp(with event: NSEvent) {
    guard last != nil else { return }
    last = nil
    NSCursor.pop()
    move?(.zero, true)
  }
  override func keyDown(with event: NSEvent) {
    let step = event.modifierFlags.contains(.shift) ? 32.0 : 8.0
    switch event.keyCode {
    case 123: move?(NSPoint(x: -step, y: 0), true)
    case 124: move?(NSPoint(x: step, y: 0), true)
    case 125: move?(NSPoint(x: 0, y: step), true)
    case 126: move?(NSPoint(x: 0, y: -step), true)
    default: super.keyDown(with: event)
    }
  }
}

private struct SheetGrip: NSViewRepresentable {
  let move: (NSPoint, Bool) -> Void
  let reset: () -> Void
  func makeNSView(context: Context) -> SheetMover {
    let view = SheetMover()
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.button)
    view.setAccessibilityLabel("拖动图版标题，方向键微移，双击归位")
    return view
  }
  func updateNSView(_ view: SheetMover, context: Context) {
    view.move = move
    view.reset = reset
  }
}

struct SheetTitle: View {
  let text: String
  let move: (NSPoint, Bool) -> Void
  let reset: () -> Void
  var body: some View {
    Text(text).font(AtlasTypeface.reading.font(19).weight(.medium))
      .lineLimit(1).truncationMode(.middle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(SheetGrip(move: move, reset: reset))
      .help("拖动标题摆放图版，聚焦后用方向键微移，双击归位")
  }
}

struct SheetCanvas<Content: View>: NSViewRepresentable {
  let store: AtlasStore
  let key: String
  let target: SheetObject?
  let zoom: Double
  let zoomChanged: (Double) -> Void
  let failure: (String) -> Void
  @ViewBuilder let content: (@escaping (NSPoint, Bool) -> Void, @escaping () -> Void) -> Content

  final class Coordinator {
    weak var scroll: SheetScroll?
    var host: NSHostingView<Content>?
    let world = SheetWorld()
    let store: AtlasStore
    let key: String
    var failure: (String) -> Void
    var placement = SheetPlacement()
    var target: SheetObject?
    var zoom: Double
    var dragging = false
    var configured = false
    var saved = SheetPlacement()
    var resetObserver: NSObjectProtocol?
    var observer: NSObjectProtocol?
    var pending: DispatchWorkItem?
    init(_ parent: SheetCanvas) {
      store = parent.store
      key = parent.key
      zoom = parent.zoom
      target = parent.target
      failure = parent.failure
      do {
        placement =
          try store.readViewState(SheetPlacement.self, key: "canvas." + key) ?? SheetPlacement()
        try restoreOrigin(for: target)
        saved = placement
      } catch {
        let message = error.localizedDescription
        DispatchQueue.main.async { parent.failure(message) }
      }
    }
    func restoreOrigin(for target: SheetObject?) throws {
      if let target, let point = try store.sheetOrigin(target) {
        placement.x = point.x
        placement.y = point.y
      } else if let old = placement.objectKey, let target, old != target.placementID {
        placement.x = SheetPlacement().x
        placement.y = SheetPlacement().y
      }
      placement.objectKey = target?.placementID
    }
    func layout() {
      guard let scroll, let host else { return }
      let size = scroll.contentView.frame.size
      guard size.width > 10, size.height > 10 else { return }
      if scroll.magnification != zoom {
        let origin = scroll.contentView.bounds.origin
        scroll.magnification = zoom
        scroll.contentView.scroll(to: origin)
      }
      let card = NSSize(width: max(1, min(1040, size.width - 26)), height: max(1, size.height - 22))
      let extents = NSSize(
        width: max(size.width + max(440, size.width * 0.65), placement.x + card.width + 24),
        height: max(size.height + max(320, size.height * 0.6), placement.y + card.height + 20))
      if world.frame.size != extents { world.setFrameSize(extents) }
      let rect = NSRect(origin: NSPoint(x: placement.x, y: placement.y), size: card)
      if host.frame != rect { host.frame = rect }
      scroll.sheetFrame = rect
      if !configured {
        configured = true
        scroll.contentView.scroll(
          to: NSPoint(
            x: max(0, min(placement.cameraX, extents.width - scroll.contentView.bounds.width)),
            y: max(0, min(placement.cameraY, extents.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
    }
    func move(_ delta: NSPoint, _ finished: Bool) {
      guard let host, let scroll else { return }
      let size = scroll.contentView.bounds.size
      dragging = !finished
      placement.x = max(0, min(max(440, size.width * 0.65), placement.x + delta.x))
      placement.y = max(0, min(max(320, size.height * 0.6), placement.y + delta.y))
      layout()
      if finished {
        // Keep part of the title reachable after keyboard movement near an edge.
        let header = NSRect(
          x: host.frame.minX + 8, y: host.frame.minY + 12, width: min(140, host.frame.width),
          height: 32)
        world.scrollToVisible(header)
        save()
      }
    }
    func show(_ newTarget: SheetObject?) {
      guard newTarget != target else { return }
      dragging = false
      save()
      target = newTarget
      do {
        try restoreOrigin(for: newTarget)
        saved.x = placement.x
        saved.y = placement.y
      } catch { failure(error.localizedDescription) }
    }
    func reset() {
      placement = SheetPlacement()
      placement.objectKey = target?.placementID
      configured = false
      layout()
      save()
    }
    func schedule() {
      guard configured else { return }
      pending?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.save() }
      pending = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    func save() {
      guard configured, !dragging, let scroll else { return }
      let camera = scroll.contentView.bounds.origin
      placement.cameraX = camera.x
      placement.cameraY = camera.y
      guard saved != placement else { return }
      do {
        try store.saveSheet(
          placement, pane: key, camera: camera, target: target,
          from: CGPoint(x: saved.x, y: saved.y), frame: scroll.sheetFrame,
          requestID: UUID().uuidString)
        saved = placement
      } catch { failure(error.localizedDescription) }
    }
    func remove() {
      pending?.cancel()
      save()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
      resetObserver = nil
      scroll?.didResize = nil
      observer = nil
      host?.removeFromSuperview()
      host = nil
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> SheetScroll {
    let c = context.coordinator
    let scroll = SheetScroll()
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.75
    scroll.maxMagnification = 1.5
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.borderType = .noBorder
    c.resetObserver = NotificationCenter.default.addObserver(
      forName: .atlasResetSheet, object: nil, queue: .main
    ) { [weak c] note in
      guard let c, note.userInfo?["project"] as? String == c.store.workspaceID,
        note.userInfo?["area"] as? String == c.key
      else { return }
      c.reset()
    }
    c.scroll = scroll
    scroll.documentView = c.world
    let host = NSHostingView(
      rootView: content({ [weak c] d, done in c?.move(d, done) }, { [weak c] in c?.reset() }))
    host.sizingOptions = []
    c.host = host
    c.world.addSubview(host)
    scroll.didResize = { [weak c] in c?.layout() }
    scroll.contentView.postsBoundsChangedNotifications = true
    c.observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak c] _ in c?.schedule() }
    return scroll
  }
  func updateNSView(_ nsView: SheetScroll, context: Context) {
    let c = context.coordinator
    c.failure = failure
    nsView.didZoom = { zoomChanged(Double($0)) }
    c.show(target)
    c.zoom = zoom
    c.host?.rootView = content({ [weak c] d, done in c?.move(d, done) }, { [weak c] in c?.reset() })
    c.layout()
  }
  static func dismantleNSView(_ view: SheetScroll, coordinator: Coordinator) {
    coordinator.remove()
  }
}
