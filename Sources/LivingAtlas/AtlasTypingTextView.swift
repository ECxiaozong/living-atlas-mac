import AppKit

/// Share the insertion caret while leaving composition, undo and persistence to each editor.
class AtlasTypingTextView: NSTextView {
  var smoothTyping = true {
    didSet { if !smoothTyping { finishCaretMotion() } }
  }
  private var movingCaret: CALayer?
  private var originalCaretColor: NSColor?
  private func finishCaretMotion() {
    movingCaret?.removeFromSuperlayer()
    movingCaret = nil
    if let originalCaretColor { insertionPointColor = originalCaretColor }
    originalCaretColor = nil
  }
  private func caretRect() -> CGRect? {
    guard let window, window.firstResponder === self, selectedRange().length == 0 else { return nil }
    var rect = CGRect.zero
    // TextKit already knows the insertion location. Re-converting a UTF-16 offset
    // from the beginning of a long document for each keystroke can force extra layout.
    if let layout = textLayoutManager, let range = layout.textSelections.first?.textRanges.first, range.isEmpty {
      layout.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
        rect = frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
        return false
      }
    } else {
      let screen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
      rect = convert(window.convertFromScreen(screen), from: nil)
    }
    guard rect.height > 0 else { return nil }
    rect.size.width = 1.5
    return visibleRect.intersects(rect) ? convertToLayer(rect) : nil
  }
  private func moveCaret(from start: CGRect, to end: CGRect) {
    guard abs(start.midY - end.midY) < 1, abs(start.midX - end.midX) < 48, start.midX != end.midX else {
      finishCaretMotion()
      return
    }
    let previous = movingCaret?.presentation()?.position.x ?? start.midX
    finishCaretMotion()
    wantsLayer = true
    guard let layer else { return }
    let caret = CALayer()
    originalCaretColor = insertionPointColor
    caret.backgroundColor = insertionPointColor.cgColor
    insertionPointColor = .clear
    caret.frame = end
    layer.addSublayer(caret)
    movingCaret = caret
    let slide = CABasicAnimation(keyPath: "position.x")
    slide.fromValue = previous
    slide.toValue = end.midX
    slide.duration = 0.065
    slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self, weak caret] in
      guard let self, let caret, movingCaret === caret else { return }
      finishCaretMotion()
    }
    caret.add(slide, forKey: "typing")
    CATransaction.commit()
  }
  override func mouseDown(with event: NSEvent) {
    finishCaretMotion()
    super.mouseDown(with: event)
  }
  override func doCommand(by selector: Selector) {
    finishCaretMotion()
    super.doCommand(by: selector)
  }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    finishCaretMotion()
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
  }
  override func insertText(_ string: Any, replacementRange: NSRange) {
    let animates = smoothTyping && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      && !hasMarkedText() && selectedRange().length == 0 && replacementRange.length == 0
      && (string as? String)?.count == 1
    let before = animates ? caretRect() : nil
    super.insertText(string, replacementRange: replacementRange)
    if let before, let end = caretRect(), animates { moveCaret(from: before, to: end) }
    else { finishCaretMotion() }
  }
  override func resignFirstResponder() -> Bool {
    finishCaretMotion()
    return super.resignFirstResponder()
  }
}
