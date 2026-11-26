import SwiftUI

enum CanvasHint: Int, CaseIterable {
  case move = 1, gestures = 2, quotation = 4, theme = 8, firstAnswer = 16

  var title: String {
    switch self {
    case .move: "移动图版"
    case .gestures: "框选与平移"
    case .quotation: "追问这句"
    case .firstAnswer: "从这段回答继续追问"
    case .theme: "同属一个主题"
    }
  }
  var detail: String {
    switch self {
    case .move: "拖动标题上的移动把手可移动图版。按 ⌘Z 撤销。"
    case .gestures: "拖动空白处可框选。按住空格再拖动可平移整张地图。"
    case .quotation: "选好原句后点追问，问题会留在原文旁。"
    case .firstAnswer: "选中想弄懂的一句，新问题会出现在这段回答旁。"
    case .theme: "同属主题只表示一起归类。要表达支持、矛盾等关系，请单独建立关系。"
    }
  }
  var symbol: String {
    switch self {
    case .move: "arrow.up.and.down.and.arrow.left.and.right"
    case .gestures: "hand.draw"
    case .quotation: "text.quote"
    case .firstAnswer: "arrow.triangle.branch"
    case .theme: "map"
    }
  }
  static let seenKey = "canvas.firstUse.seen"
  static let skipKey = "canvas.firstUse.skipped"
}

struct CanvasHintNote: View {
  let hint: CanvasHint
  let dismiss: () -> Void
  let skip: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var hoverSkip = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        AtlasArt.compass
          .resizable()
          .scaledToFit()
          .frame(width: 12, height: 12)
          .opacity(0.85)
          .accessibilityHidden(true)
        Text(hint.title)
          .font(AtlasTypeface.reading.font(15).weight(.medium))
          .foregroundStyle(AtlasPalette.ink)
        Spacer()
        Button("知道了", action: dismiss)
          .buttonStyle(AtlasChipButtonStyle(emphasized: true))
      }
      Text(hint.detail)
        .font(.system(size: 12.5))
        .lineSpacing(2.5)
        .foregroundStyle(AtlasPalette.ink.opacity(0.84))
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(action: skip) {
          Text("跳过首用提示")
            .font(.system(size: 11.5))
            .foregroundStyle(hoverSkip ? AtlasPalette.blueInk : AtlasPalette.umber.opacity(0.82))
            .underline(hoverSkip, color: AtlasPalette.blueInk.opacity(0.6))
        }
        .buttonStyle(.plain)
        .onHover { hoverSkip = $0 }
        .animation(AtlasMotion.micro(reduceMotion), value: hoverSkip)
        Spacer()
      }
      .padding(.top, 1)
    }
    .padding(.leading, 18)
    .padding(.trailing, 13)
    .padding(.vertical, 11)
    .frame(width: 284)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(AtlasPalette.gold.opacity(0.88))
        .frame(width: 2.5)
        .padding(.vertical, 11)
        .padding(.leading, 8)
        .allowsHitTesting(false)
    }
    .paperSheet(cornerRadius: 11, elevated: true)
  }
}

struct CanvasGuide: View {
  @Environment(\.dismiss) private var dismiss

  private let shortcuts: [(keys: String, label: String)] = [
    ("⌘K", "命令面板与快速定位"),
    ("⌘0", "适合全图"),
    ("⌘Z / ⇧⌘Z", "撤销与重做画布操作"),
    ("⌘+ / ⌘-", "放大与缩小画布"),
    ("方向键", "微调选中图版位置"),
    ("⌫", "移除画布入口（保留资料）"),
    ("⌘↵", "提交当前问题"),
    ("Esc", "返回定位前视口"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        AtlasArt.compass
          .resizable()
          .scaledToFit()
          .frame(width: 22, height: 22)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("画布操作帮助")
            .font(AtlasTypeface.reading.font(21).weight(.medium))
            .foregroundStyle(AtlasPalette.ink)
          Text("从一个问题开始，也可以放入 PDF 或 Markdown。")
            .font(.system(size: 12.5))
            .foregroundStyle(AtlasPalette.umber)
        }
      }
      PaperRule()
      VStack(alignment: .leading, spacing: 8) {
        ForEach(CanvasHint.allCases, id: \.rawValue) { hint in
          HStack(alignment: .top, spacing: 11) {
            Image(systemName: hint.symbol)
              .font(.system(size: 12.5, weight: .medium))
              .foregroundStyle(AtlasPalette.blueInk)
              .frame(width: 26, height: 26)
              .background(AtlasPalette.blueInk.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .strokeBorder(AtlasPalette.blueInk.opacity(0.18), lineWidth: 0.7)
              }
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(hint.title)
                .font(AtlasTypeface.reading.font(14.5).weight(.medium))
                .foregroundStyle(AtlasPalette.ink)
              Text(hint.detail)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(AtlasPalette.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(.horizontal, 11)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AtlasPalette.paperInset.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(AtlasPalette.line.opacity(0.38), lineWidth: 0.75)
          }
        }
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("常用快捷键")
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(AtlasPalette.umber)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 6) {
          ForEach(shortcuts, id: \.keys) { item in
            HStack(spacing: 6) {
              Text(item.keys)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(AtlasPalette.blueInk)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 2)
                .background(AtlasPalette.paper, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                .overlay {
                  RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(AtlasPalette.line.opacity(0.55), lineWidth: 0.7)
                }
              Text(item.label)
                .font(.system(size: 11.5))
                .foregroundStyle(AtlasPalette.ink.opacity(0.82))
                .lineLimit(1)
              Spacer(minLength: 0)
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(AtlasPalette.paperInset.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(AtlasPalette.line.opacity(0.32), lineWidth: 0.7)
        }
      }
      HStack {
        Spacer()
        Button("关闭帮助") { dismiss() }
          .buttonStyle(PaperButton(primary: true))
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 2)
    }
    .padding(24)
    .frame(width: 472)
    .background(AtlasPalette.paper)
  }
}

enum CompanionPose: String, CaseIterable {
  case calm = "平静", exploring = "探索", working = "工作", discovery = "发现"
  var art: Image {
    switch self {
    case .calm: AtlasArt.pupuIdle
    case .exploring: AtlasArt.pupuQuestion
    case .working: AtlasArt.pupuWaiting
    case .discovery: AtlasArt.pupuExplore
    }
  }
}

struct TaskCompanion: View {
  let pose: CompanionPose
  var size: CGFloat = 56
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      pose.art
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .id(pose)
        .transition(.opacity)
    }
    .frame(width: size, height: size)
    .animation(AtlasMotion.companion(reduceMotion), value: pose)
    .accessibilityLabel("噗噗 · " + pose.rawValue)
  }
}
