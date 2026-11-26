import AtlasCore
import SwiftUI

enum CanvasReturnLocation: Equatable {
  case unchanged, moved, removed

  static func locate(_ original: MapEntry, in entries: [MapEntry]) -> Self {
    guard let current = entries.first(where: { $0.id == original.id }) else { return .removed }
    return current.x == original.x && current.y == original.y
      && current.regionID == original.regionID
      ? .unchanged : .moved
  }
}

enum CanvasSourceEntrance {
  static func preferred(_ matches: [MapEntry], from: MapEntry?, regions: [CanvasRegion], visits: [String]) -> MapEntry? {
    let themes = Dictionary(
      uniqueKeysWithValues: regions.compactMap { region in
        region.topicID.map { (region.id, $0) }
      })
    let theme = from?.regionID.flatMap { themes[$0] }
    func sameTheme(_ entry: MapEntry) -> Bool {
      if let region = from?.regionID, entry.regionID == region { return true }
      return theme != nil && entry.regionID.flatMap { themes[$0] } == theme
    }
    let rank = Dictionary(
      visits.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
    return matches.min { a, b in
      if sameTheme(a) != sameTheme(b) { return sameTheme(a) }
      let aVisit = rank[a.id] ?? Int.max
      let bVisit = rank[b.id] ?? Int.max
      return aVisit == bVisit ? a.id < b.id : aVisit < bVisit
    }
  }
}

struct CanvasPDFSource: Identifiable {
  let id = UUID()
  let anchor: PDFAnchor?
  let file: AtlasPDF?
  let entrance: MapEntry?
  let issue: String?
  let frozenQuote: String?

  /// Passage references must resolve their coordinates in the original version.
  static func resolve(
    anchor: PDFAnchor, store: AtlasStore, from: MapEntry?, entries: [MapEntry],
    regions: [CanvasRegion], visits: [String], displayed: (MapEntry) -> AtlasPDF?
  ) -> Self {
    resolve(version: anchor.versionID, anchor: anchor, store: store, from: from, entries: entries,
            regions: regions, visits: visits, displayed: displayed)
  }

  static func resolve(
    version: String, anchor: PDFAnchor? = nil, frozenQuote: String? = nil, store: AtlasStore, from: MapEntry?, entries: [MapEntry],
    regions: [CanvasRegion], visits: [String], displayed: (MapEntry) -> AtlasPDF?
  ) -> Self {
    do {
      let pdf = try store.pdf(versionID: version)
      if let anchor { _ = try anchor.selection(in: store.readablePDF(pdf)) }
      let matches = entries.filter {
        $0.target == pdf.id && displayed($0)?.versionID == pdf.versionID && ($0.page == nil || $0.page?.index == anchor?.segments.first?.pageIndex)
      }
      let best = CanvasSourceEntrance.preferred(matches, from: from, regions: regions, visits: visits)
      return Self(anchor: anchor, file: pdf, entrance: best, issue: nil, frozenQuote: frozenQuote)
    } catch {
      return Self(anchor: anchor, file: nil, entrance: nil, issue: error.localizedDescription, frozenQuote: frozenQuote)
    }
  }
}

struct CanvasPDFSourceSheet: View {
  let source: CanvasPDFSource
  let store: AtlasStore
  var returnLabel: String? = "返回提问处"
  var close: () -> Void
  @ViewState private var issue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        AtlasKindBadge(kind: .pdf)
        Text(source.file.map { $0.title + " · 版本 " + String($0.ordinal) } ?? "历史原文")
          .font(AtlasTypeface.reading.font(18).weight(.medium))
        Spacer()
        if let returnLabel {
          Button(returnLabel, action: close).buttonStyle(PaperButton(compact: true))
        }
      }
      PaperRule()
      if let anchor = source.anchor {
        AtlasQuoteCallout(text: anchor.quote).textSelection(.enabled)
      }
      if let issue = issue ?? source.issue {
        Text(issue).foregroundStyle(AtlasPalette.umber)
        if let quote = source.frozenQuote, !quote.isEmpty {
          Text("提问时保存的原文").font(.caption).foregroundStyle(AtlasPalette.umber)
          ScrollView { Text(quote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
      } else if let pdf = source.file {
        DocumentReader(
          file: pdf, store: store, placementID: "temporary-source", remembersPlace: false,
          focus: source.anchor, focusRequest: source.id, citation: source.anchor,
          locked: { _ in issue = "此 PDF 需要密码。" }, selected: { _ in }, failure: { issue = $0 })
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(AtlasPalette.paper)
  }
}
