import AtlasCore
import SwiftUI

/// Lightweight warm-parchment command and quick-jump palette (`⌘K`) for the canvas efficiency layer.
struct CanvasCommandPalette: View {
  struct Item: Identifiable {
    enum Group: String {
      case command = "画布命令"
      case region = "主题地域"
      case entry = "画布对象"
    }
    let id: String
    let group: Group
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    let keywords: String
    let run: () -> Void
  }

  let items: [Item]
  let close: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var query = ""
  @ViewState private var highlighted = 0
  @FocusState private var searchFocused: Bool

  private var filtered: [Item] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return items }
    return items.filter { item in
      item.title.lowercased().contains(q)
        || (item.subtitle?.lowercased().contains(q) ?? false)
        || item.keywords.lowercased().contains(q)
        || item.group.rawValue.lowercased().contains(q)
    }
  }

  private func execute(_ item: Item) {
    close()
    item.run()
  }

  var body: some View {
    let matches = filtered
    return VStack(alignment: .leading, spacing: 0) {
      // Search header
      HStack(spacing: 10) {
        AtlasArt.compass
          .resizable()
          .scaledToFit()
          .frame(width: 17, height: 17)
          .opacity(0.88)
          .accessibilityHidden(true)
        TextField("搜索画布命令、问题、文献或地域…", text: $query)
          .accessibilityLabel("搜索画布命令和对象")
          .textFieldStyle(.plain)
          .font(AtlasTypeface.reading.font(15.5))
          .foregroundStyle(AtlasPalette.ink)
          .focused($searchFocused)
          .onSubmit {
            if matches.indices.contains(highlighted) {
              execute(matches[highlighted])
            }
          }
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 13))
              .foregroundStyle(AtlasPalette.umber.opacity(0.65))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("清空搜索词")
        }
        Text("Esc")
          .font(.system(size: 10.5, weight: .medium, design: .monospaced))
          .foregroundStyle(AtlasPalette.umber.opacity(0.8))
          .padding(.horizontal, 6)
          .padding(.vertical, 2.5)
          .background(AtlasPalette.paperInset, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .strokeBorder(AtlasPalette.line.opacity(0.45), lineWidth: 0.7)
          }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .background(AtlasPalette.paperHeader.opacity(0.75))

      PaperRule()

      if matches.isEmpty {
        VStack(spacing: 6) {
          Text("未找到匹配的命令或画布对象")
            .font(AtlasTypeface.reading.font(14.5))
            .foregroundStyle(AtlasPalette.umber)
          Text("可尝试输入“提问”“全图”“地域”或卡片标题关键词")
            .font(.system(size: 12))
            .foregroundStyle(AtlasPalette.umber.opacity(0.72))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
              ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                if index == 0 || matches[index - 1].group != item.group {
                  Text(item.group.rawValue)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AtlasPalette.umber.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.top, index == 0 ? 4 : 10)
                    .padding(.bottom, 2)
                }
                let active = index == highlighted
                Button {
                  execute(item)
                } label: {
                  HStack(spacing: 10) {
                    Image(systemName: item.icon)
                      .font(.system(size: 12.5, weight: .medium))
                      .foregroundStyle(active ? AtlasPalette.blueInk : AtlasPalette.umber)
                      .frame(width: 22, height: 22)
                      .background(
                        active ? AtlasPalette.blueInk.opacity(0.11) : AtlasPalette.paperInset.opacity(0.75),
                        in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                      )
                    VStack(alignment: .leading, spacing: 1.5) {
                      Text(item.title)
                        .font(AtlasTypeface.reading.font(14).weight(active ? .medium : .regular))
                        .foregroundStyle(AtlasPalette.ink)
                        .lineLimit(1)
                      if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                          .font(.system(size: 11.5))
                          .foregroundStyle(AtlasPalette.umber.opacity(0.82))
                          .lineLimit(1)
                      }
                    }
                    Spacer(minLength: 8)
                    if let shortcut = item.shortcut {
                      Text(shortcut)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(active ? AtlasPalette.blueInk : AtlasPalette.umber.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                          active ? AtlasPalette.blueInk.opacity(0.10) : AtlasPalette.paperInset,
                          in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        )
                        .overlay {
                          RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(
                              active ? AtlasPalette.blueInk.opacity(0.28) : AtlasPalette.line.opacity(0.45),
                              lineWidth: 0.7
                            )
                        }
                    }
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    active ? AtlasPalette.blueInk.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                  )
                  .overlay {
                    if active {
                      RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AtlasPalette.blueInk.opacity(0.24), lineWidth: 0.8)
                    }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(item.id)
                .onHover { inside in if inside { highlighted = index } }
                .animation(AtlasMotion.micro(reduceMotion), value: active)
              }
            }
            .padding(8)
          }
          .frame(maxHeight: 330)
          .onChange(of: highlighted) { _, idx in
            if matches.indices.contains(idx) {
              proxy.scrollTo(matches[idx].id, anchor: .center)
            }
          }
        }
      }

      PaperRule()

      HStack(spacing: 14) {
        Label("选择", systemImage: "arrow.up.arrow.down")
        Label("执行", systemImage: "return")
        Spacer()
        Text("共 " + String(matches.count) + " 项")
      }
      .font(.system(size: 11))
      .foregroundStyle(AtlasPalette.umber.opacity(0.78))
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(AtlasPalette.paperHeader.opacity(0.55))
    }
    .frame(width: 520)
    .paperSheet(cornerRadius: 14, elevated: true)
    .onAppear {
      highlighted = 0
      searchFocused = true
    }
    .onChange(of: query) { _, _ in highlighted = 0 }
    .onKeyPress(.upArrow) {
      guard !matches.isEmpty else { return .ignored }
      highlighted = (highlighted - 1 + matches.count) % matches.count
      return .handled
    }
    .onKeyPress(.downArrow) {
      guard !matches.isEmpty else { return .ignored }
      highlighted = (highlighted + 1) % matches.count
      return .handled
    }
    .onKeyPress(.escape) {
      close()
      return .handled
    }
  }
}
