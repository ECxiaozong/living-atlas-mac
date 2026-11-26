import AppKit
import AtlasCore
import SwiftUI

/// Draw the paper perimeter independently of its four input strips. The interior remains available
/// to cards, text, selection, panning and the blank-canvas action.
struct CanvasRegionChrome: View {
  let region: CanvasRegion
  let size: CGSize
  let selected, accepting, canAccept: Bool
  let externalEdges: Int
  let select: () -> Void
  let track: (CGSize) -> Void
  let finish: (CGSize) -> Void
  let toggle, edit: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var style: AtlasPalette.RegionStyle {
    AtlasPalette.regionStyle(for: region.topicID ?? region.id)
  }
  private var ink: Color { selected || accepting ? AtlasPalette.blueInk : style.stroke }
  nonisolated static func displaySize(_ region: CanvasRegion, zoom: Double) -> CGSize {
    if region.collapsed {
      return CGSize(width: max(124, min(240, region.frame.width * zoom)), height: 34)
    }
    return CGSize(
      width: max(1, region.frame.width * zoom), height: max(1, region.frame.height * zoom))
  }
  static func dropRect(in frame: CGRect) -> CGRect {
    guard frame.width >= 120 else { return .null }
    return CGRect(x: frame.maxX - 96, y: frame.minY + 2, width: 90, height: min(28, frame.height))
  }
  var body: some View {
    let seed = region.topicID ?? region.id
    let collapsedShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    let organic = OrganicRegionShape(seed: seed)
    let organicOuter = OrganicRegionShape(seed: seed, inset: -4)
    ZStack(alignment: .topLeading) {
      ZStack(alignment: .bottomTrailing) {
        if region.collapsed {
          collapsedShape.fill(style.fill.opacity(0.14))
          collapsedShape.stroke(ink.opacity(selected ? 0.85 : 0.48), lineWidth: selected ? 1.6 : 1.05)
        } else {
          // Layered watercolor island terrain: lush coastal wash at the shoreline, calm bright interior for reading cards
          organic.fill(
            RadialGradient(
              colors: [
                style.fill.opacity(0.145),
                style.fill.opacity(0.105),
                style.fill.opacity(0.055),
              ],
              center: .center,
              startRadius: min(size.width, size.height) * 0.08,
              endRadius: max(size.width, size.height) * 0.62
            )
          )
          if size.width > 160, size.height > 120 {
            let terraceInset = min(24, min(size.width, size.height) * 0.085)
            let innerTerrace = OrganicRegionShape(seed: seed + ".terrace", inset: terraceInset)
            innerTerrace.fill(style.fill.opacity(0.055))
            innerTerrace.stroke(ink.opacity(selected ? 0.24 : 0.14), lineWidth: 0.75)
          }
          if size.width > 260, size.height > 190 {
            let plateauInset = min(56, min(size.width, size.height) * 0.18)
            let plateau = OrganicRegionShape(seed: seed + ".plateau", inset: plateauInset)
            plateau.fill(AtlasPalette.cream.opacity(0.24))
          }
          if size.width > 120, size.height > 90 {
            AtlasArt.regionContour
              .resizable()
              .scaledToFill()
              .frame(width: size.width, height: size.height)
              .opacity(0.15)
              .blendMode(.multiply)
              .clipShape(organic)
          }
          if size.width > 180, size.height > 150 {
            AtlasArt.regionMotif(for: seed)
              .resizable()
              .interpolation(.high)
              .scaledToFit()
              .frame(width: 66, height: 56)
              .blendMode(.multiply)
              .opacity(0.46)
              .padding(.trailing, 14)
              .padding(.bottom, 12)
          }
          // Outer cartographic companion contour hairline
          organicOuter
            .stroke(ink.opacity(selected ? 0.36 : 0.20), lineWidth: 0.75)
          // Primary organic dashed coastline boundary
          organic.stroke(
            ink.opacity(selected ? 0.88 : 0.56),
            style: StrokeStyle(
              lineWidth: selected ? 1.65 : 1.15,
              lineCap: .round,
              dash: selected ? [] : [6.5, 4.5]
            )
          )
        }
      }
      .frame(width: size.width, height: size.height)
      .allowsHitTesting(false)

      // Cartographic title cartouche
      HStack(spacing: 5) {
        Image(systemName: region.collapsed ? "chevron.right" : "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 14, height: 18)
        Image(systemName: "mountain.2")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(ink.opacity(0.75))
          .accessibilityHidden(true)
        Text(region.title)
          .font(AtlasTypeface.reading.font(13).weight(.medium))
          .lineLimit(1)
        if region.collapsed && externalEdges > 0 {
          Text(String(externalEdges) + " 条连线")
            .font(.system(size: 10.5))
            .foregroundStyle(AtlasPalette.umber)
            .fixedSize()
        }
      }
      .foregroundStyle(selected ? AtlasPalette.blueInk : style.badgeInk)
      .padding(.horizontal, 9)
      .padding(.vertical, 3.5)
      .background(
        style.badgeBg.opacity(0.92),
        in: RoundedRectangle(cornerRadius: 7.5, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
          .strokeBorder(ink.opacity(selected ? 0.65 : 0.36), lineWidth: 0.85)
      }
      .shadow(color: Color.brown.opacity(0.07), radius: 2, y: 1)
      .frame(maxWidth: max(1, size.width - (canAccept ? 104 : 12)), alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .offset(x: 6, y: 4)
      .allowsHitTesting(false)
      .accessibilityHidden(true)

      if canAccept && size.width >= 120 {
        Text(accepting ? "松开加入" : "加入此主题")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(accepting ? Color.white : ink)
          .frame(width: 90, height: min(26, size.height))
          .background(
            accepting ? AtlasPalette.blueInk : AtlasPalette.paper,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(ink.opacity(0.7), lineWidth: 0.9)
          }
          .offset(x: size.width - 96, y: 4)
          .allowsHitTesting(false)
      }
      RegionInput(chrome: self)
        .frame(width: size.width, height: size.height)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .animation(AtlasMotion.micro(reduceMotion), value: accepting)
    .animation(AtlasMotion.micro(reduceMotion), value: selected)
  }
}

/// Native hit testing lets the interior fall through even when several region frames overlap.
final class RegionHitSurface: NSView {
  var chrome: CanvasRegionChrome?
  private var origin = CGPoint.zero
  private var moving = false
  private var disclosure = false
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  private var titleWidth: CGFloat {
    guard let chrome else { return 0 }
    let text = (chrome.region.title as NSString).size(withAttributes: [
      .font: NSFont.boldSystemFont(ofSize: 12)
    ]).width
    return min(
      bounds.width, 38 + text + (chrome.region.collapsed && chrome.externalEdges > 0 ? 65 : 0))
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    if let event = NSApp.currentEvent,
      event.type == .scrollWheel || event.type == .magnify || event.modifierFlags.contains(.option)
    {
      return nil
    }
    let local = convert(point, from: superview)
    guard !isHidden, bounds.contains(local) else { return nil }
    return local.y < 28 && local.x < titleWidth || !bounds.insetBy(dx: 6, dy: 6).contains(local)
      ? self : nil
  }
  override func mouseDown(with event: NSEvent) {
    origin = event.locationInWindow
    moving = false
    let p = convert(origin, from: nil)
    disclosure = p.x >= 4 && p.x < 32 && p.y >= 2 && p.y < 28
  }
  override func mouseDragged(with event: NSEvent) {
    let p = event.locationInWindow
    let d = CGSize(width: p.x - origin.x, height: origin.y - p.y)
    if !moving && hypot(d.width, d.height) < 3 { return }
    moving = true
    chrome?.track(d)
  }
  override func mouseUp(with event: NSEvent) {
    if moving {
      chrome?.finish(
        CGSize(
          width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y))
    } else if disclosure {
      chrome?.toggle()
    } else {
      chrome?.select()
    }
    moving = false
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    for (title, action) in [
      ("选择地域", #selector(selectRegion)), ("编辑名称与边界…", #selector(editRegion)),
      (chrome?.region.collapsed == true ? "展开地域" : "折叠地域", #selector(toggleRegion)),
    ] {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = self
    }
    return menu
  }
  @objc private func selectRegion() { chrome?.select() }
  @objc private func editRegion() { chrome?.edit() }
  @objc private func toggleRegion() { chrome?.toggle() }
  override func accessibilityPerformPress() -> Bool {
    guard let chrome else { return false }
    chrome.toggle()
    return true
  }
}
private struct RegionInput: NSViewRepresentable {
  let chrome: CanvasRegionChrome
  func makeNSView(context: Context) -> RegionHitSurface {
    let v = RegionHitSurface()
    configure(v)
    return v
  }
  func updateNSView(_ v: RegionHitSurface, context: Context) { configure(v) }
  private func configure(_ v: RegionHitSurface) {
    v.chrome = chrome
    v.setAccessibilityElement(true)
    v.setAccessibilityRole(.button)
    v.setAccessibilityLabel((chrome.region.collapsed ? "展开地域 " : "折叠地域 ") + chrome.region.title)
  }
}

struct RegionEditForm: View {
  let region: CanvasRegion
  let save: (String, CGRect) -> Void
  let cancel: () -> Void
  @ViewState private var title = ""
  @ViewState private var width = 0.0
  @ViewState private var height = 0.0
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("编辑地域").font(.system(.title3, design: .serif)).fontWeight(.medium)
      PaperRule()
      TextField("地域名称", text: $title).textFieldStyle(.roundedBorder)
      HStack(spacing: 10) {
        Text("宽").foregroundStyle(AtlasPalette.umber)
        TextField("宽度", value: $width, format: .number).textFieldStyle(.roundedBorder)
        Text("高").foregroundStyle(AtlasPalette.umber)
        TextField("高度", value: $height, format: .number).textFieldStyle(.roundedBorder)
      }
      HStack {
        Spacer()
        Button("取消", action: cancel).buttonStyle(PaperButton())
        Button("保存") {
          save(
            title, CGRect(origin: region.frame.origin, size: CGSize(width: width, height: height)))
        }
        .buttonStyle(PaperButton(primary: true))
        .disabled(
          width <= 0 || height <= 0 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }.padding(22).frame(width: 340).background(AtlasPalette.paper).onAppear {
      title = region.title
      width = region.frame.width
      height = region.frame.height
    }
  }
}

struct TopicDeparturePreview: Identifiable {
  let placementID, topicID, title: String
  let rows: [RegionDepartureEntry]
  var id: String { placementID + "." + topicID }
}
struct TopicDepartureForm: View {
  let preview: TopicDeparturePreview
  let confirm, cancel: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("退出「" + preview.title + "」").font(.system(.title3, design: .serif)).fontWeight(.medium)
      PaperRule()
      Text(preview.rows.isEmpty ? "将移除这项内容的主题归属。所有入口保留当前位置。" : "以下入口将从直属地域移到画布根层，坐标与正文保留。")
        .font(.callout).foregroundStyle(AtlasPalette.ink)
      ScrollView {
        VStack(alignment: .leading, spacing: 9) {
          ForEach(preview.rows) { row in
            HStack {
              Text(row.viewTitle + " · " + row.regionTitle)
              Spacer()
              Text("(" + String(Int(row.x)) + ", " + String(Int(row.y)) + ")").monospacedDigit()
                .foregroundStyle(AtlasPalette.umber)
            }
          }
        }
      }.frame(maxHeight: 160)
      HStack {
        Spacer()
        Button("取消", action: cancel).buttonStyle(PaperButton())
        Button("退出主题", action: confirm).buttonStyle(PaperButton(primary: true))
      }
    }.padding(22).frame(width: 420).background(AtlasPalette.paper)
  }
}
