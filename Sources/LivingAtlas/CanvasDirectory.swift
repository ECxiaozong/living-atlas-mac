import AtlasCore
import SwiftUI

/// A row names a particular spatial entrance, even when several entrances share their content.
struct CanvasDirectory: View {
  enum Destination: Hashable {
    case region(String)
    case entry(String)
  }
  struct Row: Identifiable {
    let id: Destination
    let title, detail, path, icon: String
    var label: String { [title, detail, path].filter { !$0.isEmpty }.joined(separator: " · ") }
  }
  let rows: [Row]
  let close: () -> Void
  let locate: (Destination) -> Void
  @ViewState private var query = ""
  @FocusState private var filtering: Bool

  var body: some View {
    let words = query.split(whereSeparator: \.isWhitespace)
    let matches = words.isEmpty ? rows : rows.filter { row in
      words.allSatisfy { row.label.localizedCaseInsensitiveContains(String($0)) }
    }
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("画布目录").font(.system(size: 19, weight: .medium, design: .serif))
        Spacer()
        Button("关闭") { close() }.buttonStyle(PaperButton(compact: true))
      }
      PaperRule()
      TextField("筛选地域、对象或类型", text: $query).textFieldStyle(.roundedBorder)
        .accessibilityLabel("筛选地域、对象或类型").focused($filtering)
      if matches.isEmpty {
        Text(rows.isEmpty ? "画布上还没有地域或入口。" : "没有符合这些词的地域或入口。")
          .font(.callout)
          .foregroundStyle(AtlasPalette.umber)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { row in
              Button {
                locate(row.id)
              } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                  Image(systemName: row.icon).frame(width: 18).foregroundStyle(AtlasPalette.umber)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(AtlasPalette.ink).lineLimit(2)
                    Text([row.detail, row.path].filter { !$0.isEmpty }.joined(separator: " · "))
                      .font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
                  }
                  Spacer()
                  Image(systemName: "scope").font(.system(size: 12)).foregroundStyle(AtlasPalette.blueInk.opacity(0.8))
                }.padding(.vertical, 8).padding(.horizontal, 6).contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityLabel(row.label)
              PaperRule()
            }
          }
        }
      }
    }.padding(18)
      .background(AtlasPalette.paper).onAppear { filtering = true }
  }
}
