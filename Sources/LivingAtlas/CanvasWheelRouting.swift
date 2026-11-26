import AppKit
import PDFKit
import WebKit

/// The destination of a two-finger gesture is chosen at touch-down, including its inertia.
/// Otherwise the moving papers can slide a different responder under a stationary pointer.
@MainActor final class CanvasWheelRouting {
  private var monitor: Any?
  private var ownsCanvas: Bool?
  private var lastStamp = -Double.infinity

  func attach(_ surface: MapSurface) {
    detach()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak surface] event in
      guard let self, let surface, let window = surface.window, event.window === window,
            window.isKeyWindow, window.attachedSheet == nil, !surface.isHiddenOrHasHiddenAncestor,
            event.modifierFlags.intersection([.command,.control]).isEmpty else { return event }
      let point = surface.convert(event.locationInWindow, from: nil)
      let start = event.phase.contains(.mayBegin) || event.phase.contains(.began)
      let resumed = event.timestamp - self.lastStamp > 0.25 && event.momentumPhase.isEmpty && event.phase.isEmpty
      guard surface.visibleRect.contains(point) else { self.ownsCanvas = nil; return event }
      surface.observeWheel?(event)
      if start { self.ownsCanvas = nil }
      guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else {
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) { self.ownsCanvas = nil }
        return event
      }
      if self.ownsCanvas == nil || start || resumed {
        self.ownsCanvas = self.isCanvas(point, event: event, surface: surface, window: window)
      }
      self.lastStamp = event.timestamp
      let route = self.ownsCanvas == true
      if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) { self.ownsCanvas = nil }
      guard route else { return event }
      surface.scrollWheel(with: event)
      return nil
    }
  }

  private func isCanvas(_ point: CGPoint, event: NSEvent, surface: MapSurface, window: NSWindow) -> Bool {
    guard let root = window.contentView else { return false }
    var hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
    var nestedScroll = false
    while let view = hit {
      if view === surface || view is CanvasPageSurface.Surface { return true }
      if let web = view as? WKWebView {
        guard let answer = web.navigationDelegate as? AnswerReader.Coordinator else { return false }
        return !answer.scrollsInside(web, at: event.locationInWindow, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
      }
      if view is NSTextView || view is PDFView { return false }
      nestedScroll = nestedScroll || view is NSScrollView
      hit = view.superview
    }
    // Keep scrollable sheets, lists and controls in their own scroll domain.
    return !nestedScroll
  }

  func detach() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    ownsCanvas = nil
  }
}
