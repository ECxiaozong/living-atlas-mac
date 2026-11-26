import AppKit
import AtlasCore
import CryptoKit
import SwiftUI

/// Only this entrance chooses its historical version and reading mode. The draft belongs to the document.
struct CanvasWritingState: Codable, Equatable {
  var pinnedVersion: String?
  var editing = false
  static func key(_ placement: String) -> String { "map.writing." + placement }
  static func positionPrefix(_ placement: String) -> String { "placement." + placement + "." }
}

struct CanvasWritingObject: View {
  let store: AtlasStore
  let itemID: String
  let placementID: String
  var editorFocus: CanvasEditorFocus? = nil
  var addSelection: ((String,[WritingSelection]) -> Void)? = nil
  var onSelectText: (() -> Void)? = nil
  var onInteraction: (Bool) -> Void = { _ in }
  var onQuestion: (String) -> Void = { _ in }
  var body: some View {
    WritingDesk(
      store: store, onQuestion: onQuestion, canvasItemID: itemID,
      placementID: placementID, editorFocus: editorFocus, addSelection: addSelection, onSelectText: onSelectText, onInteraction: onInteraction
    )
    .id(placementID + "." + itemID)
  }
}

/// Only an explicit layout change can return keyboard focus to a remounted editor.
final class CanvasEditorFocus {
  var returningTo: String?
}

struct CanvasEditorPlace: Codable, Equatable {
  let digest: String
  let selection: NSRange
  let top: CGFloat

  static func digest(_ text: String) -> String {
    Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
  }
  static func key(_ placement: String) -> String { "map.editor-place." + placement }
}

/// AppKit owns marked text and the active undo manager until the local editor releases focus.
final class WritingUndoManager: UndoManager {
  var didReplay: (() -> Void)?
  override func undo() {
    super.undo()
    didReplay?()
  }
  override func redo() {
    super.redo()
    didReplay?()
  }
}

final class CanvasTextView: AtlasTypingTextView {
  let localUndo = WritingUndoManager()
  var placementID = ""
  var afterComposition: (() -> Void)?
  var saveBeforeHiding: ((String) -> Bool)?
  var restoreWhenMounted: (() -> Void)?
  override func layout() {
    super.layout()
    restoreWhenMounted?()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    restoreWhenMounted?()
  }
  private func finishedComposition() {
    composingChanged?(false)
    // insertText can itself call unmarkText. Let the text delegate finish saving first.
    guard afterComposition != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.hasMarkedText(), self.window != nil else { return }
      let action = self.afterComposition
      self.afterComposition = nil
      action?()
    }
  }
  var composingChanged: ((Bool) -> Void)?
  var focusChanged: ((Bool) -> Void)?
  override var undoManager: UndoManager? { localUndo }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    composingChanged?(true)
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
  }
  override func insertText(_ string: Any, replacementRange: NSRange) {
    super.insertText(string, replacementRange: replacementRange)
    finishedComposition()
  }
  override func unmarkText() {
    super.unmarkText()
    finishedComposition()
  }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { focusChanged?(true) }
    return accepted
  }
  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { focusChanged?(false) }
    return accepted
  }
}

struct CanvasSourceEditor: NSViewRepresentable {
  @AppStorage("writing.smoothCaret") private var smoothCaret = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let text: String
  let store: AtlasStore
  let placementID: String
  let focus: CanvasEditorFocus?
  let failure: (String) -> Void
  let saveBeforeHiding: (String) -> Bool
  let onEdit: (String) -> Void
  let onFocus: (Bool) -> Void
  let onComposition: (Bool) -> Void
  final class Coordinator: NSObject, NSTextViewDelegate {
    var store: AtlasStore?
    var failure: ((String) -> Void)?
    var ready = false
    var restoring = false
    var onEdit: ((String) -> Void)?
    var onFocus: ((Bool) -> Void)?
    func textDidBeginEditing(_ notification: Notification) { onFocus?(true) }
    func textDidEndEditing(_ notification: Notification) { onFocus?(false) }
    func textDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextView, !field.hasMarkedText() else { return }
      onEdit?(field.string)
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let field = CanvasTextView(frame: .zero)
    field.isVerticallyResizable = true
    field.isHorizontallyResizable = false
    field.autoresizingMask = [.width]
    field.minSize = .zero
    field.maxSize = .init(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    field.textContainer?.widthTracksTextView = true
    field.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = field
    if let selection = AtlasTheme.current.nativeColor(.selection) {
      field.selectedTextAttributes[.backgroundColor] = selection
    }
    field.isRichText = false
    field.allowsUndo = true
    field.isAutomaticQuoteSubstitutionEnabled = false
    field.isAutomaticDashSubstitutionEnabled = false
    field.isAutomaticTextReplacementEnabled = false
    if let ink = AtlasTheme.current.nativeColor(.ink) { field.textColor = ink }
    field.font = AtlasTypeface.code.native(14)
    field.drawsBackground = false
    field.textContainerInset = NSSize(width: 7, height: 7)
    field.setAccessibilityLabel("编辑原文")
    scroll.drawsBackground = false
    field.delegate = context.coordinator
    field.localUndo.didReplay = { [weak field, weak coordinator = context.coordinator] in
      if let field { coordinator?.onEdit?(field.string) }
    }
    field.string = text
    field.placementID = placementID
    let coordinator = context.coordinator
    coordinator.store = store
    coordinator.failure = failure
    let bookmark: CanvasEditorPlace?
    do {
      bookmark = try store.readViewState(
        CanvasEditorPlace.self, key: CanvasEditorPlace.key(placementID))
    } catch {
      bookmark = nil
      failure(error.localizedDescription)
    }
    field.restoreWhenMounted = { [weak field, weak scroll, weak coordinator] in
      guard let coordinator, let field, let scroll, field.window != nil,
        scroll.contentSize.width > 1, scroll.contentSize.height > 1, !coordinator.restoring
      else { return }
      coordinator.restoring = true
      DispatchQueue.main.async { [weak field, weak scroll, weak coordinator] in
        guard let field, let scroll, let coordinator else { return }
        coordinator.restoring = false
        guard let window = field.window else { return }
        field.restoreWhenMounted = nil
        if let bookmark, !field.hasMarkedText(),
          CanvasEditorPlace.digest(field.string) == bookmark.digest,
          Range(bookmark.selection, in: field.string) != nil
        {
          field.setSelectedRange(bookmark.selection)
          if let container = field.textContainer {
            field.layoutManager?.ensureLayout(for: container)
          }
          var bounds = scroll.contentView.bounds
          bounds.origin.y = bookmark.top
          scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
          scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.ready = true
        if focus?.returningTo == placementID {
          focus?.returningTo = nil
          if !(window.firstResponder is NSText) { window.makeFirstResponder(field) }
        }
      }
    }
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let field = scroll.documentView as? CanvasTextView else { return }
    field.smoothTyping = smoothCaret && !reduceMotion
    field.focusChanged = { active in
      if active { focus?.returningTo = nil }
      onFocus(active)
    }
    field.saveBeforeHiding = saveBeforeHiding
    field.composingChanged = onComposition
    context.coordinator.onEdit = onEdit
    context.coordinator.onFocus = onFocus
    guard !field.hasMarkedText(), field.string != text else { return }
    // A replacement supplied by a different entrance invalidates local undo ranges.
    let oldRange = field.selectedRange()
    field.localUndo.removeAllActions()
    field.string = text
    field.setSelectedRange(
      NSRange(location: min(oldRange.location, field.string.utf16.count), length: 0))
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    if let field = scroll.documentView as? CanvasTextView {
      if coordinator.ready, !field.hasMarkedText() {
        let place = CanvasEditorPlace(
          digest: CanvasEditorPlace.digest(field.string),
          selection: field.selectedRange(), top: scroll.contentView.bounds.minY)
        do {
          try coordinator.store?.saveViewState(place, key: CanvasEditorPlace.key(field.placementID))
        } catch { coordinator.failure?(error.localizedDescription) }
      }
      field.afterComposition = nil
      field.saveBeforeHiding = nil
      field.restoreWhenMounted = nil
      field.localUndo.didReplay = nil
      field.focusChanged = nil
      field.composingChanged = nil
      field.delegate = nil
    }
    coordinator.onEdit = nil
    coordinator.onFocus = nil
  }
}
