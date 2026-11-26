import AppKit
import SwiftUI

/// The front window owns the command. Text and sheets keep their native undo domain.
@MainActor enum CanvasHistoryRoute {
  /// A menu can temporarily own key focus. Use the document that owns the edit.
  static var commandWindow: NSWindow? {
    NSApp.modalWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ??
      NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
  }

  static func canvas(in window: NSWindow?) -> MapSurface? {
    guard let window, window.attachedSheet == nil, !window.isSheet, let root = window.contentView else { return nil }
    if let text = window.firstResponder as? NSTextView, text.isEditable { return nil }
    if (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return nil }
    func find(_ view: NSView) -> MapSurface? {
      guard !view.isHidden else { return nil }
      if let surface = view as? MapSurface { return surface }
      for child in view.subviews {
        if let surface = find(child) { return surface }
      }
      return nil
    }
    return find(root)
  }

  static func perform(redo: Bool, in window: NSWindow?) {
    if let surface = canvas(in: window), let replay = surface.replayLayout {
      replay(redo)
      return
    }
    guard let responder = (window?.attachedSheet ?? window)?.firstResponder,
          (responder as? NSTextInputClient)?.hasMarkedText() != true else { return }
    if let text = responder as? NSTextView, text.isEditable {
      text.breakUndoCoalescing()
      replay(redo: redo, with: text.undoManager)
      return
    }
    let selector = NSSelectorFromString(redo ? "redo:" : "undo:")
    if !responder.tryToPerform(selector, with: nil) {
      replay(redo: redo, with: responder.undoManager)
    }
  }
  private static func replay(redo: Bool, with manager: UndoManager?) {
    guard let manager else { return }
    if redo {
      if manager.canRedo { manager.redo() }
    } else if manager.canUndo {
      manager.undo()
    }
  }
}

struct CanvasHistoryCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .undoRedo) {
      Button("撤销") { CanvasHistoryRoute.perform(redo: false, in: CanvasHistoryRoute.commandWindow) }
        .keyboardShortcut("z")
      Button("重做") { CanvasHistoryRoute.perform(redo: true, in: CanvasHistoryRoute.commandWindow) }
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }
  }
}
