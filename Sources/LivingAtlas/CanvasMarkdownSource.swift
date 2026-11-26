import AtlasCore
import SwiftUI

struct CanvasMarkdownSource: Identifiable {
  let id = UUID()
  let title: String
  let version: WritingVersion
  let quote: String
  let page: WrittenPage
  let focus: [WritingSelection]?
  let images: [String: String]
  let entrance: MapEntry?

  @MainActor static func resolve(reference: String, quote: String, store: AtlasStore, from origin: MapEntry,
                      entries: [MapEntry], regions: [CanvasRegion], visits: [String]) throws -> Self? {
    guard let target = try store.writingSourceTarget(reference) else { return nil }
    let parts = try store.resolveWritingSource(reference, in: target.versionID)
    let focus = parts?.map(\.quote).joined(separator: "\n") == quote ? parts : nil
    return try resolve(document: target.documentID, version: target.versionID, quote: quote, focus: focus,
                       store: store, from: origin, entries: entries, regions: regions, visits: visits)
  }

  @MainActor static func resolve(search: AtlasSearchSource, store: AtlasStore, from origin: MapEntry?,
                      entries: [MapEntry], regions: [CanvasRegion], visits: [String]) throws -> Self? {
    guard let selection = search.markdownSelection else { return nil }
    return try resolve(document: search.hit.objectID, version: search.hit.versionID, quote: selection.quote,
                       focus: [selection], store: store, from: origin, entries: entries, regions: regions, visits: visits)
  }

  @MainActor private static func resolve(document: String, version id: String, quote: String, focus: [WritingSelection]?,
                      store: AtlasStore, from origin: MapEntry?, entries: [MapEntry], regions: [CanvasRegion],
                      visits: [String]) throws -> Self {
    let item = try store.writing(id: document)
    guard let version = try store.writingVersions(item).first(where: { $0.id == id }) else {
      throw AtlasStoreError.invalid("无法读取引文的历史版本。")
    }
    let matches = try entries.filter { entry in
      guard entry.target == item.id else { return false }
      let state = try store.readViewState(CanvasWritingState.self, key: CanvasWritingState.key(entry.id))
      let shown = state?.pinnedVersion ?? (item.draft == nil ? item.currentVersionID : nil)
      return shown == version.id && state?.editing != true
    }
    return Self(title: item.displayTitle, version: version, quote: quote, page: try WrittenMarkdown.parse(version.body, callouts: version.supportsCallouts),
                focus: focus, images: try store.writingImageLinks(version: version.id),
                entrance: focus == nil ? nil : CanvasSourceEntrance.preferred(matches, from: origin, regions: regions, visits: visits))
  }
}

struct CanvasMarkdownSourceView: View {
  let source: CanvasMarkdownSource
  let store: AtlasStore
  var collecting = false
  var draftSelection: [WritingSelection]?
  var ask: (([WritingSelection]) -> Void)?
  var returnLabel = "返回提问处"
  var close: (() -> Void)?
  @ViewState private var selection: [WritingSelection] = []
  @ViewState private var problem: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        AtlasKindBadge(kind: .markdown)
        Text(source.title + " · 版本 " + String(source.version.ordinal))
          .font(AtlasTypeface.reading.font(17).weight(.medium))
        Spacer()
        if let ask, let passage = selection.isEmpty ? source.focus : selection, !passage.isEmpty {
          Button(collecting ? "加入本题" : (selection.isEmpty ? "就引文追问" : "就选句追问")) { ask(passage) }
            .buttonStyle(PaperButton(primary: true, compact: true))
        }
        if let close { Button(returnLabel, action: close).buttonStyle(PaperButton(compact: true)) }
      }
      PaperRule()
      if source.focus == nil {
        AtlasQuoteCallout(text: source.quote).textSelection(.enabled)
        Text("引文已保留，在这个版本中未能定位原句。").font(.caption).foregroundStyle(AtlasPalette.umber)
      }
      WritingPreview(imageStore: store, imageVersion: source.version.id, onFailure: { problem = $0 },
                     imageLinks: source.images, page: source.page,
                     marks: draftSelection.map { [.init(kind: "highlight", parts: $0)] } ?? [],
                     focus: draftSelection == nil ? source.focus : nil, onSelect: { selection = $0 })
      if let problem { Text(problem).font(.caption).foregroundStyle(AtlasPalette.terracotta) }
    }.padding(18).background(AtlasPalette.paper)
  }
}
