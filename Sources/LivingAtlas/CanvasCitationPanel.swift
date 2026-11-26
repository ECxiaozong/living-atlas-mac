import AtlasCore
import SwiftUI

struct CanvasCitationList: Identifiable {
  let id = UUID()
  let citations: [CanvasCitation]
}

struct CanvasCitationPanel: View {
  let store: AtlasStore
  let citations: [CanvasCitation]
  var remove: ((CanvasCitation) -> Void)?
  @Environment(\.dismiss) private var dismiss
  @ViewState private var selected: CanvasCitation?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        if selected != nil { Button("返回材料列表") { selected = nil } }
        Text(selected.map { $0.title + " · 版本 " + String($0.ordinal) } ?? "附加引用材料")
          .font(.system(.title3, design: .serif)).lineLimit(2)
        Spacer()
        Button("关闭") { dismiss() }
      }
      if let selected {
        CanvasCitationDetail(store: store, citation: selected).id(selected.id)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(citations) { item in
              VStack(alignment: .leading, spacing: 5) {
                let kind = item.kind == .answer ? "回答" : item.kind == .pdf ? "PDF" : "Markdown"
                HStack {
                  Text(kind + " · 版本 " + String(item.ordinal)).font(.caption)
                  Spacer()
                  if let remove {
                    Button("移除") { remove(item) }.accessibilityLabel("移除引用 " + item.title)
                  }
                }
                Button(item.title) { selected = item }.buttonStyle(.plain)
                Text(item.quote).textSelection(.enabled)
                PaperRule()
              }
            }
            if citations.isEmpty { Text("还没有附加材料。") }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }.padding(18).frame(minWidth: 540, minHeight: 365).background(AtlasPalette.cream)
  }
}

struct CanvasCitationDetail: View {
  let store: AtlasStore
  let reference, versionID, quote: String
  let kind: CanvasCitation.Kind
  var wholeDocument = false

  init(store: AtlasStore, citation: CanvasCitation) {
    self.store = store
    (reference, versionID, quote, kind) = (citation.id, citation.versionID, citation.quote, citation.kind)
  }

  init(store: AtlasStore, endpoint: CanvasRelationSource.Endpoint, kind: CanvasCitation.Kind) {
    self.store = store
    (reference, versionID, quote, self.kind) = (endpoint.id, endpoint.versionID, endpoint.quote, kind)
    wholeDocument = endpoint.selector == "whole"
  }

  private enum Content {
    case pdf(AtlasPDF, PDFAnchor?)
    case answer(AnswerExcerpt)
    case markdown(WrittenPage, [WritingSelection]?, [String: String])
  }
  @ViewState private var content: Content?
  @ViewState private var issue: String?
  var body: some View {
    VStack(alignment: .leading) {
      if let issue {
        Text(quote).textSelection(.enabled)
        Text(issue).foregroundStyle(AtlasPalette.umber)
      } else if let content {
        switch content {
        case .pdf(let file, let anchor):
          DocumentReader(
            file: file, store: store, placementID: "citation." + reference, remembersPlace: false,
            focus: anchor, citation: anchor, locked: { _ in issue = "此 PDF 需要密码。" },
            selected: { _ in }, failure: { issue = $0 })
        case .answer(let excerpt):
          SourceText(bodyText: excerpt.body, initial: excerpt.nativeRange, changed: { _ in })
        case .markdown(let page, let selection, let links):
          WritingPreview(
            imageStore: store, imageVersion: versionID, onFailure: { issue = $0 },
            imageLinks: links, page: page, marks: [], focus: selection, onSelect: { _ in })
        }
      } else {
        ProgressView()
      }
    }.onAppear {
      do {
        switch kind {
        case .pdf:
          let anchor = try store.canvasPDFAnchor(reference: reference)
          guard wholeDocument || anchor?.versionID == versionID else {
            throw missing()
          }
          let file = try store.pdf(versionID: versionID)
          if let anchor { _ = try anchor.selection(in: store.readablePDF(file)) }
          content = .pdf(file, anchor)
        case .answer:
          guard let excerpt = try store.canvasAnswerExcerpt(reference: reference) else {
            throw missing()
          }
          content = .answer(excerpt)
        case .markdown:
          guard let target = try store.writingSourceTarget(reference), target.versionID == versionID else { throw missing() }
          let version = try store.markdownVersion(versionID, documentID: target.documentID)
          let selection = try store.resolveWritingSource(reference, in: versionID)
          guard wholeDocument || selection != nil else { throw missing() }
          content = try .markdown(
            WrittenMarkdown.parse(version.body, callouts: version.supportsCallouts), selection,
            store.writingImageLinks(version: version.id))
        }
      } catch { issue = error.localizedDescription }
    }
  }
  private func missing() -> AtlasStoreError { .invalid("无法定位提问当时的原句。") }
}
