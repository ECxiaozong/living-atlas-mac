import AppKit
import AtlasCore
import SwiftUI

struct AnswerSourcePage: Identifiable {
  let id = UUID()
  let runID, body, title: String
  var initial: NSRange?
  var historical = false
}
struct AnswerSourcePanel: View {
  let page: AnswerSourcePage
  var actionLabel: String? = nil
  let ask: (AnswerExcerpt) -> Void
  @Environment(\.dismiss) var dismiss
  @ViewState private var selected: NSRange?
  @ViewState private var issue = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(page.title).font(AtlasTypeface.reading.font(20).weight(.medium))
          Text(page.historical ? "提问时的回答原文" : "选择这次追问所依据的原句")
            .font(.system(size: 12)).foregroundStyle(AtlasPalette.umber)
        }
        Spacer()
        Button("关闭") { dismiss() }.buttonStyle(PaperButton(compact: true))
      }
      PaperRule()
      SourceText(bodyText: page.body, initial: page.initial, changed: { selected = $0 })
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(AtlasPalette.line.opacity(0.45), lineWidth: 0.85)
        }
      HStack {
        if !issue.isEmpty { Text(issue).font(.caption).foregroundStyle(AtlasPalette.terracotta) }
        Spacer()
        Button(actionLabel ?? (page.historical ? "从当时版本追问" : "用所选片段追问")) {
          let text = page.body as NSString
          guard let range = selected ?? page.initial, range.length > 0,
            NSMaxRange(range) <= text.length
          else { return }
          let start = text.substring(to: range.location).unicodeScalars.count
          do {
            let excerpt = try AnswerExcerpt(
              runID: page.runID, body: page.body, start: start,
              end: start + text.substring(with: range).unicodeScalars.count)
            ask(excerpt)
            dismiss()
          } catch { issue = error.localizedDescription }
        }.buttonStyle(PaperButton(primary: true)).disabled(
          (selected ?? page.initial)?.length ?? 0 == 0)
      }
    }.padding(22).frame(minWidth: 540, minHeight: 390).background(AtlasPalette.paper)
  }
}
struct SourceText: NSViewRepresentable {
  let bodyText: String, initial: NSRange?
  let changed: (NSRange) -> Void
  final class Observer: NSObject, NSTextViewDelegate {
    var changed: ((NSRange) -> Void)?
    func textViewDidChangeSelection(_ n: Notification) {
      if let v = n.object as? NSTextView { changed?(v.selectedRange()) }
    }
  }
  func makeCoordinator() -> Observer { Observer() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.drawsBackground = true
    scroll.backgroundColor = NSColor(calibratedRed: 0.965, green: 0.941, blue: 0.894, alpha: 1)
    let view = scroll.documentView as! NSTextView
    view.isEditable = false
    view.isSelectable = true
    view.isRichText = false
    view.drawsBackground = true
    view.backgroundColor = NSColor(calibratedRed: 0.988, green: 0.976, blue: 0.949, alpha: 1)
    view.textColor = NSColor(calibratedRed: 0.145, green: 0.173, blue: 0.192, alpha: 1)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 6
    view.defaultParagraphStyle = paragraph
    view.typingAttributes = [
      .font: AtlasTypeface.reading.native(16),
      .foregroundColor: NSColor(calibratedRed: 0.145, green: 0.173, blue: 0.192, alpha: 1),
      .paragraphStyle: paragraph,
    ]
    view.string = bodyText
    view.font = AtlasTypeface.reading.native(16)
    view.textContainerInset = NSSize(width: 16, height: 14)
    view.selectedTextAttributes = [
      .backgroundColor: NSColor(calibratedRed: 0.945, green: 0.824, blue: 0.490, alpha: 0.62),
      .foregroundColor: NSColor(calibratedRed: 0.145, green: 0.173, blue: 0.192, alpha: 1),
    ]
    view.setAccessibilityLabel("回答原句")
    view.delegate = context.coordinator
    if let initial {
      view.setSelectedRange(initial)
      DispatchQueue.main.async {
        view.window?.makeFirstResponder(view)
        view.scrollRangeToVisible(initial)
      }
    }
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.changed = changed
  }
}
