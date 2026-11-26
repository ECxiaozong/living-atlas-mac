import AtlasCore
import SwiftUI

enum ConnectAnchorSide: Equatable {
  case leading
  case trailing

  func point(on rect: CGRect, overhang: CGFloat = 0) -> CGPoint {
    switch self {
    case .leading: CGPoint(x: rect.minX - overhang, y: rect.midY)
    case .trailing: CGPoint(x: rect.maxX + overhang, y: rect.midY)
    }
  }
}

struct CanvasDirectConnectDrag: Equatable {
  let sourceEntryID: String
  let anchorSide: ConnectAnchorSide
  var currentPoint: CGPoint
  var hoveredTargetEntryID: String?
}

struct CanvasDirectConnectPending: Identifiable, Equatable {
  let id: UUID
  let sourceEntryID: String
  let targetEntryID: String
  var kind: MapRelation = .compares
  var swapped: Bool = false
  var reason: String = ""
  var error: String? = nil

  var effectiveSourceID: String { swapped ? targetEntryID : sourceEntryID }
  var effectiveTargetID: String { swapped ? sourceEntryID : targetEntryID }
}

enum CanvasDirectConnectGeometry {
  /// Intersects a ray from `rect`'s center toward `target` with `rect`'s perimeter.
  static func edgeAnchor(of rect: CGRect, toward target: CGPoint, inset: CGFloat = -2) -> CGPoint {
    let box = rect.insetBy(dx: inset, dy: inset)
    let cx = box.midX, cy = box.midY
    let dx = target.x - cx, dy = target.y - cy
    let hw = max(1, box.width / 2), hh = max(1, box.height / 2)
    if abs(dx) < 0.001 && abs(dy) < 0.001 { return CGPoint(x: cx, y: cy) }
    let tx = abs(dx) > 0.001 ? hw / abs(dx) : .greatestFiniteMagnitude
    let ty = abs(dy) > 0.001 ? hh / abs(dy) : .greatestFiniteMagnitude
    let t = min(tx, ty)
    return CGPoint(x: cx + dx * t, y: cy + dy * t)
  }

  /// Finds the topmost target entry under `point` (with generous magnetic snap margin).
  static func magneticTarget(
    at point: CGPoint,
    excluding sourceID: String,
    entries: [MapEntry],
    frameForEntry: (MapEntry) -> CGRect,
    snapMargin: CGFloat = 14
  ) -> MapEntry? {
    entries.last { entry in
      entry.id != sourceID && frameForEntry(entry).insetBy(dx: -snapMargin, dy: -snapMargin).contains(point)
    }
  }

  /// Clamps a floating popover center inside the visible canvas pane with safe margins.
  static func clampedPopoverCenter(
    between a: CGRect,
    and b: CGRect,
    popoverSize: CGSize,
    in paneSize: CGSize,
    margin: CGFloat = 18
  ) -> CGPoint {
    let midX = (a.midX + b.midX) / 2
    let midY = (a.midY + b.midY) / 2
    let minX = min(paneSize.width / 2, margin + popoverSize.width / 2)
    let maxX = max(paneSize.width / 2, paneSize.width - margin - popoverSize.width / 2)
    let minY = min(paneSize.height / 2, 54 + popoverSize.height / 2)
    let maxY = max(paneSize.height / 2, paneSize.height - 62 - popoverSize.height / 2)
    return CGPoint(
      x: min(max(midX, minX), maxX),
      y: min(max(midY, minY), maxY)
    )
  }
}

/// Subtle warm brass-gold perimeter handles mounted outside the active/hovered card so
/// they never interfere with WKWebView/PDFView hit testing inside cards.
struct CanvasDirectConnectHandles: View {
  let entry: MapEntry
  let rect: CGRect
  let drag: CanvasDirectConnectDrag?
  let onHandleHover: (Bool) -> Void
  let onDragChanged: (ConnectAnchorSide, CGPoint) -> Void
  let onDragEnded: (ConnectAnchorSide, CGPoint) -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      handle(for: .leading)
      handle(for: .trailing)
    }
  }

  private func handle(for side: ConnectAnchorSide) -> some View {
    let isActive = drag?.sourceEntryID == entry.id && drag?.anchorSide == side
    let center = side.point(on: rect, overhang: 5)
    return DirectConnectHandleDot(
      side: side,
      active: isActive,
      onHoverChanged: onHandleHover,
      onChanged: { point in onDragChanged(side, point) },
      onEnded: { point in onDragEnded(side, point) }
    )
    .position(center)
  }
}

private struct DirectConnectHandleDot: View {
  let side: ConnectAnchorSide
  let active: Bool
  let onHoverChanged: (Bool) -> Void
  let onChanged: (CGPoint) -> Void
  let onEnded: (CGPoint) -> Void
  @ViewState private var hovered = false

  var body: some View {
    let lit = active || hovered
    ZStack {
      Circle()
        .fill(AtlasPalette.gold.opacity(lit ? 0.24 : 0.0))
        .frame(width: lit ? 20 : 12, height: lit ? 20 : 12)
      Circle()
        .fill(lit ? AtlasPalette.gold : AtlasPalette.paper)
        .frame(width: lit ? 10 : 8.5, height: lit ? 10 : 8.5)
        .overlay {
          Circle()
            .stroke(AtlasPalette.gold.opacity(lit ? 1.0 : 0.85), lineWidth: 1.5)
        }
        .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.18), radius: 2.5, y: 1)
    }
    .frame(width: 26, height: 26)
    .contentShape(Circle())
    .onHover { inside in
      hovered = inside
      onHoverChanged(inside)
    }
    .gesture(
      DragGesture(minimumDistance: 3, coordinateSpace: .named("atlas-region-map"))
        .onChanged { value in onChanged(value.location) }
        .onEnded { value in onEnded(value.location) }
    )
    .help("拖到另一张图版建立知识关系")
    .accessibilityLabel(side == .leading ? "从左侧拖出知识关系连线" : "从右侧拖出知识关系连线")
  }
}

/// Live preview overlay drawn during card-edge drag-to-connect or while picking relation type.
struct CanvasDirectConnectOverlay: View {
  let drag: CanvasDirectConnectDrag?
  let pending: CanvasDirectConnectPending?
  let entries: [MapEntry]
  let frameForEntry: (MapEntry) -> CGRect

  var body: some View {
    let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    if let drag, let source = entryMap[drag.sourceEntryID] {
      let sourceRect = frameForEntry(source)
      let targetEntry = drag.hoveredTargetEntryID.flatMap { entryMap[$0] }
      let targetRect = targetEntry.map(frameForEntry)
      let startPoint = drag.anchorSide.point(on: sourceRect, overhang: 2)
      let endPoint: CGPoint = {
        if let targetRect {
          return CanvasDirectConnectGeometry.edgeAnchor(of: targetRect, toward: startPoint, inset: -3)
        }
        return drag.currentPoint
      }()

      ZStack(alignment: .topLeading) {
        Canvas { context, _ in
          if let targetRect {
            let halo = Path(roundedRect: targetRect.insetBy(dx: -3, dy: -3), cornerRadius: 13)
            context.stroke(halo, with: .color(AtlasPalette.gold.opacity(0.28)), lineWidth: 6)
            context.stroke(
              halo,
              with: .color(AtlasPalette.gold.opacity(0.92)),
              style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )
          }

          drawArc(
            in: &context,
            from: startPoint,
            to: endPoint,
            directed: true,
            snapped: targetRect != nil
          )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)

        if let targetRect {
          Text("松开建立关系")
            .font(AtlasTypeface.reading.font(11.5).weight(.medium))
            .foregroundStyle(Color.white)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background { Capsule(style: .continuous).fill(AtlasPalette.blueInk) }
            .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.16), radius: 4, y: 1.5)
            .position(x: targetRect.midX, y: targetRect.minY - 16)
            .allowsHitTesting(false)
        }
      }
    } else if let pending,
      let from = entryMap[pending.effectiveSourceID],
      let to = entryMap[pending.effectiveTargetID]
    {
      let a = frameForEntry(from)
      let b = frameForEntry(to)
      let p = CanvasDirectConnectGeometry.edgeAnchor(of: a, toward: CGPoint(x: b.midX, y: b.midY), inset: -3)
      let q = CanvasDirectConnectGeometry.edgeAnchor(of: b, toward: CGPoint(x: a.midX, y: a.midY), inset: -3)

      Canvas { context, _ in
        for rect in [a, b] {
          let ring = Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 12)
          context.stroke(ring, with: .color(AtlasPalette.gold.opacity(0.75)), lineWidth: 1.5)
        }
        drawArc(in: &context, from: p, to: q, directed: pending.kind.directed, snapped: true)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private func drawArc(
    in context: inout GraphicsContext,
    from p: CGPoint,
    to q: CGPoint,
    directed: Bool,
    snapped: Bool
  ) {
    let dist = hypot(q.x - p.x, q.y - p.y)
    let lift = min(40, max(14, dist * 0.16))
    let ctrl = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 - lift)

    var arc = Path()
    arc.move(to: p)
    arc.addQuadCurve(to: q, control: ctrl)

    context.stroke(
      arc,
      with: .color(AtlasPalette.gold.opacity(snapped ? 0.30 : 0.18)),
      style: StrokeStyle(lineWidth: snapped ? 5.5 : 4.0, lineCap: .round)
    )
    context.stroke(
      arc,
      with: .color(AtlasPalette.gold.opacity(snapped ? 0.96 : 0.82)),
      style: StrokeStyle(lineWidth: snapped ? 2.0 : 1.65, lineCap: .round, dash: [6, 4])
    )

    let startRing = Path(ellipseIn: CGRect(x: p.x - 3.8, y: p.y - 3.8, width: 7.6, height: 7.6))
    context.fill(startRing, with: .color(AtlasPalette.paper))
    context.stroke(startRing, with: .color(AtlasPalette.gold), lineWidth: 1.6)

    if directed {
      let angle = atan2(q.y - ctrl.y, q.x - ctrl.x)
      var tip = Path()
      tip.move(to: CGPoint(x: q.x - cos(angle - 0.45) * 9.0, y: q.y - sin(angle - 0.45) * 9.0))
      tip.addLine(to: q)
      tip.addLine(to: CGPoint(x: q.x - cos(angle + 0.45) * 9.0, y: q.y - sin(angle + 0.45) * 9.0))
      context.stroke(tip, with: .color(AtlasPalette.gold), lineWidth: 1.9)
    } else {
      let endRing = Path(ellipseIn: CGRect(x: q.x - 3.8, y: q.y - 3.8, width: 7.6, height: 7.6))
      context.fill(endRing, with: .color(AtlasPalette.paper))
      context.stroke(endRing, with: .color(AtlasPalette.gold), lineWidth: 1.6)
    }
  }
}

/// Compact in-place parchment relation type picker floating right between two connected cards.
struct CanvasDirectConnectPopover: View {
  @Binding var pending: CanvasDirectConnectPending
  let sourceTitle: String
  let targetTitle: String
  let onCancel: () -> Void
  let onConfirm: () -> Void

  static let preferredSize = CGSize(width: 318, height: 204)

  var body: some View {
    let fromLabel = pending.swapped ? targetTitle : sourceTitle
    let toLabel = pending.swapped ? sourceTitle : targetTitle
    let arrow = pending.kind.directed ? " → " : " ↔ "

    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(AtlasPalette.gold)
        Text("建立知识关系")
          .font(AtlasTypeface.reading.font(14.5).weight(.medium))
          .foregroundStyle(AtlasPalette.ink)
        Spacer(minLength: 4)
        if pending.kind.directed {
          Button {
            pending.swapped.toggle()
          } label: {
            Label("互换方向", systemImage: "arrow.left.arrow.right")
              .font(.system(size: 11))
          }
          .buttonStyle(AtlasChipButtonStyle())
          .help("交换关系起点与终点")
        }
        Button {
          onCancel()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(AtlasPalette.umber)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("取消建立关系")
      }

      Text(fromLabel + arrow + toLabel)
        .font(AtlasTypeface.reading.font(12.5))
        .foregroundStyle(AtlasPalette.umber)
        .lineLimit(1)
        .truncationMode(.middle)

      // 7 relation types arranged in a compact archival two-row grid
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) {
        ForEach(MapRelation.allCases) { relation in
          let active = pending.kind == relation
          Button {
            pending.kind = relation
            pending.error = nil
          } label: {
            Text(relation.label)
              .font(AtlasTypeface.reading.font(12.5).weight(active ? .medium : .regular))
              .foregroundStyle(active ? Color.white : AtlasPalette.ink)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 5)
              .padding(.horizontal, 6)
              .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .fill(active ? AtlasPalette.blueInk : AtlasPalette.paperInset.opacity(0.68))
              }
              .overlay {
                if !active {
                  RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AtlasPalette.line.opacity(0.42), lineWidth: 0.7)
                }
              }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("选择关系类型：" + relation.label)
        }
      }

      TextField("补一句理由（选填，回车创建）", text: $pending.reason)
        .textFieldStyle(.plain)
        .font(AtlasTypeface.reading.font(12.5))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(AtlasPalette.paperInset.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(AtlasPalette.line.opacity(0.45), lineWidth: 0.75)
        }
        .onSubmit { onConfirm() }

      if let error = pending.error {
        Text(error)
          .font(.system(size: 11.5))
          .foregroundStyle(AtlasPalette.terracotta)
          .lineLimit(2)
      }

      HStack(spacing: 8) {
        Button("取消") { onCancel() }
          .buttonStyle(PaperButton(compact: true))
        Spacer()
        Button("建立「" + pending.kind.label + "」") { onConfirm() }
          .buttonStyle(PaperButton(primary: true, compact: true))
          .keyboardShortcut(.return, modifiers: [])
      }
    }
    .padding(14)
    .frame(width: Self.preferredSize.width)
    .background(AtlasPalette.paper.opacity(0.98), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(AtlasPalette.gold.opacity(0.55), lineWidth: 1.0)
    }
    .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.18), radius: 14, y: 5)
    .foregroundStyle(AtlasPalette.ink)
  }
}
