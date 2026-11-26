import AtlasCore
import SwiftUI

/// Pure coordinate projection between world space and the reading-scale inset mini-map.
struct CanvasMiniMapProjection: Equatable {
  let worldBounds: CGRect
  let canvasSize: CGSize
  let scale: CGFloat
  let offset: CGPoint

  init(
    entryRects: [CGRect],
    regionRects: [CGRect],
    viewportWorldRect: CGRect,
    canvasSize: CGSize,
    padding: CGFloat = 10
  ) {
    var union = viewportWorldRect
    for r in entryRects { union = union.union(r) }
    for r in regionRects { union = union.union(r) }

    // Enforce a comfortable minimum world span so 2-3 card atlases still look balanced.
    let minWidth: CGFloat = 960
    let minHeight: CGFloat = 620
    if union.width < minWidth {
      let extra = (minWidth - union.width) / 2
      union = union.insetBy(dx: -extra, dy: 0)
    }
    if union.height < minHeight {
      let extra = (minHeight - union.height) / 2
      union = union.insetBy(dx: 0, dy: -extra)
    }
    // Add 10% cartographic breathing margin.
    union = union.insetBy(dx: -union.width * 0.10, dy: -union.height * 0.10)

    let innerWidth = max(1, canvasSize.width - padding * 2)
    let innerHeight = max(1, canvasSize.height - padding * 2)
    let s = min(innerWidth / max(1, union.width), innerHeight / max(1, union.height))
    let drawnW = union.width * s
    let drawnH = union.height * s
    let ox = (canvasSize.width - drawnW) / 2 - union.minX * s
    let oy = (canvasSize.height - drawnH) / 2 - union.minY * s

    self.worldBounds = union
    self.canvasSize = canvasSize
    self.scale = s
    self.offset = CGPoint(x: ox, y: oy)
  }

  func miniPoint(for world: CGPoint) -> CGPoint {
    CGPoint(x: offset.x + world.x * scale, y: offset.y + world.y * scale)
  }

  func miniRect(for world: CGRect) -> CGRect {
    let origin = miniPoint(for: world.origin)
    return CGRect(
      x: origin.x,
      y: origin.y,
      width: max(3.5, world.width * scale),
      height: max(2.8, world.height * scale)
    )
  }

  func worldPoint(for mini: CGPoint) -> CGPoint {
    guard scale > 0.00001 else { return .zero }
    return CGPoint(x: (mini.x - offset.x) / scale, y: (mini.y - offset.y) / scale)
  }

  /// Computes the MapCamera `(x, y)` origin that centers `worldPoint` inside `viewportSize`.
  static func cameraOrigin(
    centering worldPoint: CGPoint,
    viewportSize: CGSize,
    zoom: Double
  ) -> CGPoint {
    CGPoint(
      x: Double(viewportSize.width) / 2 - Double(worldPoint.x) * zoom,
      y: Double(viewportSize.height) / 2 - Double(worldPoint.y) * zoom
    )
  }
}

/// Collapsible warm-parchment cartographic inset mini-map for reading-scale spatial orientation.
struct CanvasMiniMap: View {
  struct Node: Identifiable {
    enum Tone { case question, pdf, writing }
    let id: String
    let worldRect: CGRect
    let tone: Tone
    let selected: Bool
    let focused: Bool
  }

  struct Edge: Identifiable {
    let id: String
    let from: CGPoint
    let to: CGPoint
  }

  let nodes: [Node]
  let regions: [CGRect]
  let edges: [Edge]
  let viewportWorldRect: CGRect
  let onPanToWorldPoint: (CGPoint, Bool) -> Void
  let onFitAll: () -> Void
  let onCollapse: () -> Void

  static let mapCanvasSize = CGSize(width: 200, height: 126)

  var body: some View {
    let projection = CanvasMiniMapProjection(
      entryRects: nodes.map(\.worldRect),
      regionRects: regions,
      viewportWorldRect: viewportWorldRect,
      canvasSize: Self.mapCanvasSize
    )

    VStack(spacing: 0) {
      // Archival header strip
      HStack(spacing: 6) {
        AtlasArt.compass
          .resizable()
          .scaledToFit()
          .frame(width: 13, height: 13)
          .opacity(0.85)
          .accessibilityHidden(true)
        Text("图谱缩略")
          .font(AtlasTypeface.reading.font(12).weight(.medium))
          .foregroundStyle(AtlasPalette.ink)
        Text("\(nodes.count) 处")
          .font(.system(size: 10.5))
          .foregroundStyle(AtlasPalette.umber)
        Spacer(minLength: 4)
        Button("全图") { onFitAll() }
          .buttonStyle(AtlasChipButtonStyle())
          .help("适合全图 (⌘0)")
        Button {
          onCollapse()
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AtlasPalette.umber)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("收起缩略图")
        .accessibilityLabel("收起缩略图")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(AtlasPalette.paperHeader.opacity(0.65))

      PaperRule()

      // Interactive miniature cartographic viewport
      Canvas { context, size in
        // 1. Subtle parchment inset backdrop + cartographic crosshairs
        let bg = Path(CGRect(origin: .zero, size: size))
        context.fill(bg, with: .color(AtlasPalette.paperInset.opacity(0.55)))

        var crosses = Path()
        for xi in 1...3 {
          for yi in 1...2 {
            let cx = size.width * CGFloat(xi) / 4
            let cy = size.height * CGFloat(yi) / 3
            crosses.move(to: CGPoint(x: cx - 3, y: cy))
            crosses.addLine(to: CGPoint(x: cx + 3, y: cy))
            crosses.move(to: CGPoint(x: cx, y: cy - 3))
            crosses.addLine(to: CGPoint(x: cx, y: cy + 3))
          }
        }
        context.stroke(crosses, with: .color(AtlasPalette.umber.opacity(0.16)), lineWidth: 0.7)

        // 2. Region islands
        for region in regions {
          let rect = projection.miniRect(for: region)
          let path = Path(roundedRect: rect, cornerRadius: 3.5)
          context.fill(path, with: .color(AtlasPalette.blueInk.opacity(0.06)))
          context.stroke(
            path,
            with: .color(AtlasPalette.umber.opacity(0.32)),
            style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])
          )
        }

        // 3. Semantic relation hairlines
        if !edges.isEmpty {
          var edgePath = Path()
          for edge in edges {
            edgePath.move(to: projection.miniPoint(for: edge.from))
            edgePath.addLine(to: projection.miniPoint(for: edge.to))
          }
          context.stroke(edgePath, with: .color(AtlasPalette.umber.opacity(0.34)), lineWidth: 0.75)
        }

        // 4. Entry miniature cards (batched by tone)
        var questionPath = Path(), pdfPath = Path(), writingPath = Path(), highlightPath = Path()
        for node in nodes {
          let rect = projection.miniRect(for: node.worldRect)
          let rounded = Path(roundedRect: rect, cornerRadius: 1.8)
          switch node.tone {
          case .question: questionPath.addPath(rounded)
          case .pdf: pdfPath.addPath(rounded)
          case .writing: writingPath.addPath(rounded)
          }
          if node.selected || node.focused {
            highlightPath.addPath(Path(roundedRect: rect.insetBy(dx: -1.2, dy: -1.2), cornerRadius: 2.5))
          }
        }
        context.fill(questionPath, with: .color(AtlasPalette.blueInk.opacity(0.76)))
        context.fill(pdfPath, with: .color(AtlasPalette.umber.opacity(0.72)))
        context.fill(writingPath, with: .color(AtlasPalette.gold.opacity(0.86)))
        if !highlightPath.isEmpty {
          context.stroke(highlightPath, with: .color(AtlasPalette.gold), lineWidth: 1.2)
        }

        // 5. Current reading viewport frame with delicate corner brass ticks
        let vp = projection.miniRect(for: viewportWorldRect)
        let vpPath = Path(roundedRect: vp, cornerRadius: 2.5)
        context.fill(vpPath, with: .color(AtlasPalette.blueInk.opacity(0.09)))
        context.stroke(vpPath, with: .color(AtlasPalette.blueInk.opacity(0.82)), lineWidth: 1.25)

        let tick: CGFloat = min(5, min(vp.width, vp.height) * 0.25)
        if tick >= 2.5 {
          var corners = Path()
          // Top-left
          corners.move(to: CGPoint(x: vp.minX, y: vp.minY + tick))
          corners.addLine(to: CGPoint(x: vp.minX, y: vp.minY))
          corners.addLine(to: CGPoint(x: vp.minX + tick, y: vp.minY))
          // Top-right
          corners.move(to: CGPoint(x: vp.maxX - tick, y: vp.minY))
          corners.addLine(to: CGPoint(x: vp.maxX, y: vp.minY))
          corners.addLine(to: CGPoint(x: vp.maxX, y: vp.minY + tick))
          // Bottom-right
          corners.move(to: CGPoint(x: vp.maxX, y: vp.maxY - tick))
          corners.addLine(to: CGPoint(x: vp.maxX, y: vp.maxY))
          corners.addLine(to: CGPoint(x: vp.maxX - tick, y: vp.maxY))
          // Bottom-left
          corners.move(to: CGPoint(x: vp.minX + tick, y: vp.maxY))
          corners.addLine(to: CGPoint(x: vp.minX, y: vp.maxY))
          corners.addLine(to: CGPoint(x: vp.minX, y: vp.maxY - tick))
          context.stroke(corners, with: .color(AtlasPalette.gold), lineWidth: 1.5)
        }
      }
      .frame(width: Self.mapCanvasSize.width, height: Self.mapCanvasSize.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let world = projection.worldPoint(for: value.location)
            onPanToWorldPoint(world, false)
          }
          .onEnded { value in
            let world = projection.worldPoint(for: value.location)
            onPanToWorldPoint(world, true)
          }
      )
      .help("点击或拖动以快速漫游图谱")
      .accessibilityLabel("阅读尺幅缩略地图，点击或拖动可快速漫游")
    }
    .frame(width: Self.mapCanvasSize.width)
    .background(AtlasPalette.paper.opacity(0.95), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(AtlasPalette.line.opacity(0.65), lineWidth: 0.9)
    }
    .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.14), radius: 10, y: 3)
  }
}
