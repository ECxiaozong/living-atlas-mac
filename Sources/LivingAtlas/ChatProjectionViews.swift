import AppKit
import AtlasCore
import SwiftUI

/// Native character selection. A locator opened from a conversion reselects the exact stored span.
struct ChatSelectableMessage: NSViewRepresentable {
  let source: ChatArchiveSource
  var highlighted: NSRange?
  let didSelect: (NSRange?) -> Void

  final class Coordinator: NSObject, NSTextViewDelegate {
    var owner: ChatSelectableMessage
    var displayed: String?
    var lastHighlight: NSRange?
    init(_ owner: ChatSelectableMessage) { self.owner = owner }
    func textViewDidChangeSelection(_ note: Notification) {
      guard let text = note.object as? NSTextView else { return }
      let selected = text.selectedRange()
      DispatchQueue.main.async { self.owner.didSelect(selected.length > 0 ? selected : nil) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    guard let t = scroll.documentView as? NSTextView else { return scroll }
    t.isEditable = false
    t.isSelectable = true
    t.drawsBackground = false
    t.delegate = context.coordinator
    t.font = NSFont.systemFont(ofSize: 15)
    t.textContainerInset = NSSize(width: 8, height: 8)
    t.setAccessibilityLabel("原消息正文")
    scroll.drawsBackground = false
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.owner = self
    guard let t = scroll.documentView as? NSTextView else { return }
    let changedSource = context.coordinator.displayed != source.id
    if changedSource {
      context.coordinator.displayed = source.id
      t.string = source.body
    }
    guard changedSource || context.coordinator.lastHighlight != highlighted else { return }
    context.coordinator.lastHighlight = highlighted
    if let r = highlighted, NSMaxRange(r) <= (source.body as NSString).length {
      t.setSelectedRange(r)
      t.scrollRangeToVisible(r)
    }
  }
}

struct ChatProjectionComposer: View {
  let store: AtlasStore
  let sources: [ChatArchiveSource]
  let onPlan: (ChatProjectionPlan) -> Void
  let onClose: () -> Void
  @ViewState private var sourceID = ""
  @ViewState private var selection: NSRange?
  @ViewState private var collected: [ChatArchiveExcerpt] = []
  @ViewState private var kind: ChatProjectionKind = .excerpt
  @ViewState private var title = ""
  @ViewState private var draft = ""
  @ViewState private var items: [ChatProjectionItem] = []
  @ViewState private var problem = ""
  private var current: ChatArchiveSource? {
    sources.first(where: { $0.id == sourceID }) ?? sources.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button("返回聊天原档", action: onClose)
      Text("从原消息整理").font(.system(.title2, design: .serif))
      Text("逐段选择来源。摘录保留原句，补充问题与解释由你撰写。").font(.callout).foregroundStyle(.secondary)
      Picker("原消息", selection: $sourceID) {
        ForEach(sources) { s in Text(String(s.body.prefix(46))).tag(s.id) }
      }.onAppear { sourceID = sources.first?.id ?? "" }.onChange(of: sourceID) { _, _ in
        selection = nil
      }
      if let source = current {
        ChatSelectableMessage(source: source) { selection = $0 }.frame(
          minHeight: 110, maxHeight: 170)
        HStack {
          Button("取所选片段") { if let range = selection { collect(source, range) } }.disabled(
            selection == nil)
          Button("取整条消息") {
            collect(source, NSRange(location: 0, length: (source.body as NSString).length))
          }
          .disabled(source.body.isEmpty)
        }
      }
      ForEach(Array(collected.enumerated()), id: \.offset) { i, e in
        HStack {
          Text(e.exact).font(.callout).lineLimit(2)
          Spacer()
          Button("移除") { collected.remove(at: i) }
        }
      }
      Picker("形成", selection: $kind) {
        ForEach(ChatProjectionKind.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      TextField("条目标题", text: $title).textFieldStyle(.roundedBorder)
      if kind != .excerpt {
        TextEditor(text: $draft).frame(minHeight: 70).accessibilityLabel("我的补写正文")
      }
      Button(kind == .excerpt ? "加入原文摘录" : "加入我的补写") {
        guard !collected.isEmpty else { return }
        let text = kind == .excerpt ? collected[0].exact : draft
        items.append(
          .init(
            kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: text,
            sources: collected))
        collected = []
        draft = ""
        title = ""
        problem = ""
      }.disabled(
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || collected.isEmpty
          || (kind == .excerpt
            ? collected.count != 1 : draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      )
      if !items.isEmpty {
        Divider()
        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
          HStack {
            Text("\(item.kind.label) · \(item.title)")
            Spacer()
            Button("移除条目") { items.remove(at: i) }
          }
        }
        Button("预览 \(items.count) 项变更") {
          do {
            onPlan(
              try store.proposeChatProjection(items, permittedVersionIDs: Set(sources.map(\.id))))
          } catch { problem = error.localizedDescription }
        }.buttonStyle(PaperButton(primary: true))
      }
      if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
    }
  }
  private func collect(_ source: ChatArchiveSource, _ range: NSRange) {
    do {
      let e = try ChatArchiveExcerpt.capture(source, range: range)
      if !collected.contains(e) { collected.append(e) }
      if title.isEmpty { title = String(e.exact.prefix(22)) }
      problem = ""
    } catch { problem = error.localizedDescription }
  }
}
