import AppKit
import SwiftUI

/// Observe only the owning workspace window. Closing a sheet should never trigger a project backup.
struct ProjectCloseObserver: NSViewRepresentable {
  var center: NotificationCenter = .default
  let save: () -> Void
  final class Hook: NSView {
    var center: NotificationCenter = .default
    var save: (() -> Void)?
    private var tokens = [NSObjectProtocol]()
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      clear()
      guard let window else { return }
      tokens.append(
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.save?() }
        })
      tokens.append(
        center.addObserver(
          forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.save?() } })
    }
    func clear() {
      for token in tokens { center.removeObserver(token) }
      tokens = []
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  func makeNSView(context: Context) -> Hook {
    let h = Hook()
    h.center = center
    h.save = save
    return h
  }
  func updateNSView(_ view: Hook, context: Context) { view.save = save }
  static func dismantleNSView(_ view: Hook, coordinator: ()) {
    view.clear()
    view.save = nil
  }
}
