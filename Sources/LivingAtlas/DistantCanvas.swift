import AtlasCore
import SwiftUI

/// At fit-to-map scales the positions and paths remain visible without mounting full cards.
/// The drawn map moves as a layer between viewport rebases. Labels retain native hit targets.
struct DistantCanvas: View {
  static let cardSize = CanvasFootprint.preview
  let snapshotID: UUID
  let map: AtlasMap
  let regions: [CanvasRegion]
  let tree: CanvasRegionTree
  let endpoints: [String: MapEntry]
  let focusedEntrances, focusedRegions: Set<String>
  let counts: [String: Int]
  let zoom: Double
  var origin: CGPoint
  var size: CGSize
  let title: (MapEntry) -> String
  let visitEntry: (MapEntry) -> Void
  let visit: (String) -> Void

  private func project(_ point: CGPoint) -> CGPoint {
    CGPoint(x: origin.x + point.x * zoom, y: origin.y + point.y * zoom)
  }
  private static func center(_ entry: MapEntry, tree: CanvasRegionTree) -> CGPoint {
    if let owner = tree.collapsedOwner(of: entry.regionID), let region = tree.regions[owner] {
      return region.frame.origin
    }
    return Self.worldFrame(entry).centerPoint
  }

  private static func worldFrame(_ entry: MapEntry) -> CGRect {
    entry.page == nil ? CGRect(origin: CGPoint(x: entry.x, y: entry.y), size: cardSize) : CanvasFootprint.reserved(entry)
  }
  // A cell stays attached to the map while the user pans.
  struct Cell: Hashable, Comparable {
    let x, y: Double
    init(_ world: CGPoint, zoom: Double) {
      x = floor(world.x * zoom / 12)
      y = floor(world.y * zoom / 12)
    }
    static func < (a: Self, b: Self) -> Bool { (a.x, a.y) < (b.x, b.y) }
  }
  struct Dot {
    let first: MapEntry
    var bounds = CGRect.null
    var x = 0.0, y = 0.0, count = 0
    mutating func add(_ frame: CGRect) {
      x += frame.midX
      y += frame.midY
      count += 1
      bounds = bounds.union(frame)
    }
    var center: CGPoint { CGPoint(x: x / Double(count), y: y / Double(count)) }
  }
  static func materials(_ entries: [MapEntry], tree: CanvasRegionTree, zoom: Double) -> [Cell: Dot] {
    var dots = [Cell: Dot]()
    dots.reserveCapacity(min(entries.count, 512))
    for entry in entries where entry.page == nil && tree.collapsedOwner(of: entry.regionID) == nil {
      let frame = worldFrame(entry)
      dots[Cell(frame.centerPoint, zoom: zoom), default: Dot(first: entry)].add(frame)
    }
    return dots
  }

  private struct Link: Hashable {
    let a, b: Cell
    let history: Bool
  }

  private struct CachedPin {
    let worldCenter: CGPoint
    let radius: CGFloat
    let colorIndex: Int
  }

  private struct CachedEdge {
    let start: CGPoint
    let end: CGPoint
    let history: Bool
    let active: Bool
  }

  private struct CacheKey: Equatable {
    let snapshotID: UUID
    let zoom: Double
    let focusedEntrances: Set<String>
    let focusedRegions: Set<String>
  }

  private struct CachedGeometry {
    let key: CacheKey
    let pins: [CachedPin]
    let edges: [CachedEdge]
    let hasFocus: Bool
  }

  @MainActor private final class GeometryCache {
    static let shared = GeometryCache()
    var cached: CachedGeometry?
  }

  private static let pinColors: [Color] = [
    AtlasPalette.blueInk,
    Color(red: 0.255, green: 0.388, blue: 0.459),
    Color(red: 0.545, green: 0.420, blue: 0.251),
    Color(red: 0.408, green: 0.349, blue: 0.463),
  ]

  private static func colorIndex(for key: String?) -> Int {
    guard let key else { return 0 }
    var hash: UInt64 = 14695981039346656037
    for byte in key.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return 1 + Int(hash % 3)
  }

  private func cachedGeometry() -> CachedGeometry {
    let key = CacheKey(
      snapshotID: snapshotID, zoom: zoom,
      focusedEntrances: focusedEntrances,
      focusedRegions: focusedRegions
    )
    if let hit = GeometryCache.shared.cached, hit.key == key {
      return hit
    }

    let dots = Self.materials(map.entries, tree: tree, zoom: zoom)
    let hasFocus = !focusedEntrances.isEmpty || !focusedRegions.isEmpty
    var seenLinks = Set<Link>()
    seenLinks.reserveCapacity(map.edges.count)
    var cachedEdges: [CachedEdge] = []
    cachedEdges.reserveCapacity(map.edges.count)

    for edge in map.edges {
      guard let (from, to) = edge.entrances(defaults: endpoints) else { continue }
      let p = Self.center(from, tree: tree)
      let q = Self.center(to, tree: tree)
      let a = Cell(p, zoom: zoom), b = Cell(q, zoom: zoom)
      guard a != b else { continue }
      let link = Link(a: min(a, b), b: max(a, b), history: edge.history)
      guard seenLinks.insert(link).inserted else { continue }
      let isActive = hasFocus && (
        focusedEntrances.contains(from.id) || focusedEntrances.contains(to.id)
          || tree.belongsToSelection(from.regionID, selected: focusedRegions)
          || tree.belongsToSelection(to.regionID, selected: focusedRegions)
      )
      cachedEdges.append(CachedEdge(
        start: dots[a]?.center ?? p,
        end: dots[b]?.center ?? q,
        history: edge.history,
        active: isActive
      ))
    }

    var cachedPins: [CachedPin] = []
    cachedPins.reserveCapacity(dots.count)
    for dot in dots.values {
      let radius = min(4.8, 2.5 + 0.5 * log2(Double(dot.count)))
      let regionKey = dot.first.regionID.flatMap { tree.regions[$0]?.topicID ?? $0 }
      cachedPins.append(CachedPin(
        worldCenter: dot.center,
        radius: radius,
        colorIndex: Self.colorIndex(for: regionKey)
      ))
    }

    let built = CachedGeometry(key: key, pins: cachedPins, edges: cachedEdges, hasFocus: hasFocus)
    GeometryCache.shared.cached = built
    return built
  }

  private func drawMaterials(in context: GraphicsContext, viewport: CGRect) {
    let geometry = cachedGeometry()
    let expandedViewport = viewport.insetBy(dx: -36, dy: -36)
    var ambientHistory = Path(), ambientRelations = Path()
    var activeHistory = Path(), activeRelations = Path()

    for edge in geometry.edges {
      let start = project(edge.start), end = project(edge.end)
      let minX = min(start.x, end.x), maxX = max(start.x, end.x)
      let minY = min(start.y, end.y), maxY = max(start.y, end.y)
      if maxX < expandedViewport.minX || minX > expandedViewport.maxX
        || maxY < expandedViewport.minY || minY > expandedViewport.maxY
      {
        continue
      }
      let dist = hypot(end.x - start.x, end.y - start.y)
      let lift = min(22, dist * 0.14)
      let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - lift)
      if edge.active {
        if edge.history {
          activeHistory.move(to: start); activeHistory.addQuadCurve(to: end, control: mid)
        } else {
          activeRelations.move(to: start); activeRelations.addQuadCurve(to: end, control: mid)
        }
      } else {
        if edge.history {
          ambientHistory.move(to: start); ambientHistory.addQuadCurve(to: end, control: mid)
        } else {
          ambientRelations.move(to: start); ambientRelations.addQuadCurve(to: end, control: mid)
        }
      }
    }

    let hasFocus = geometry.hasFocus
    context.stroke(
      ambientHistory,
      with: .color(AtlasPalette.umber.opacity(hasFocus ? 0.16 : 0.30)),
      style: StrokeStyle(lineWidth: 0.85, lineCap: .round, dash: [3.5, 3])
    )
    context.stroke(
      ambientRelations,
      with: .color(AtlasPalette.blueInk.opacity(hasFocus ? 0.18 : 0.34)),
      style: StrokeStyle(lineWidth: 0.9, lineCap: .round)
    )
    if !activeHistory.isEmpty {
      context.stroke(
        activeHistory,
        with: .color(AtlasPalette.umber.opacity(0.75)),
        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [4, 3])
      )
    }
    if !activeRelations.isEmpty {
      context.stroke(
        activeRelations,
        with: .color(AtlasPalette.blueInk.opacity(0.78)),
        style: StrokeStyle(lineWidth: 1.35, lineCap: .round)
      )
    }

    // Batch cartographic dual-ring pins by palette color (<= 4 draw calls even at 300+ nodes).
    var halos = Array(repeating: Path(), count: Self.pinColors.count)
    var strokes = Array(repeating: Path(), count: Self.pinColors.count)
    var cores = Path()

    for pin in geometry.pins {
      let p = project(pin.worldCenter)
      guard expandedViewport.contains(p) else { continue }
      let r = pin.radius
      let hr = r + 2.4
      halos[pin.colorIndex].addEllipse(in: CGRect(x: p.x - hr, y: p.y - hr, width: hr * 2, height: hr * 2))
      let coreRect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
      cores.addEllipse(in: coreRect)
      strokes[pin.colorIndex].addEllipse(in: coreRect)
    }

    for (idx, path) in halos.enumerated() where !path.isEmpty {
      context.fill(path, with: .color(Self.pinColors[idx].opacity(0.15)))
    }
    if !cores.isEmpty {
      context.fill(cores, with: .color(AtlasPalette.paper))
    }
    for (idx, path) in strokes.enumerated() where !path.isEmpty {
      context.stroke(path, with: .color(Self.pinColors[idx].opacity(0.85)), lineWidth: 1.35)
    }
  }

  private struct LabelGroup: Identifiable {
    let center: CGPoint
    var regions: [CanvasRegion]
    var id: String { regions[0].id }
  }

  private func labels() -> [LabelGroup] {
    var groups: [LabelGroup] = []
    let bounds = CGRect(origin: .zero, size: size)
    for region in regions where !tree.hides(region) {
      let anchor = project(region.frame.origin)
      guard bounds.contains(anchor) else { continue }
      let center = CGPoint(x: max(60, min(size.width - 60, anchor.x + 50)),
                           y: max(13, min(size.height - 13, anchor.y - 14)))
      if let i = groups.firstIndex(where: { abs($0.center.x - center.x) < 140 && abs($0.center.y - center.y) < 55 }) {
        groups[i].regions.append(region)
      } else {
        groups.append(LabelGroup(center: center, regions: [region]))
      }
    }
    return groups
  }

  private struct Landmark: Identifiable {
    let entry: MapEntry
    var count: Int
    let location: CGPoint
    var id: String { entry.id }
  }
  private func landmarks(avoiding regions: [LabelGroup]) -> [Landmark] {
    let visible = CGRect(origin: .zero, size: size).insetBy(dx: 70, dy: 18)
    var labels = [Landmark]()
    for entry in map.entries where entry.regionID == nil {
      let p = project(Self.worldFrame(entry).centerPoint)
      guard visible.contains(p), !regions.contains(where: { abs($0.center.x - p.x) < 150 && abs($0.center.y - p.y) < 46 }) else { continue }
      if let i = labels.firstIndex(where: { abs($0.location.x - p.x) < 155 && abs($0.location.y - p.y) < 50 }) {
        labels[i].count += 1
      } else {
        labels.append(.init(entry: entry, count: 1, location: p))
      }
    }
    return labels
  }

  private func drawMap(in context: GraphicsContext, viewport: CGRect) {
    let culledViewport = viewport.insetBy(dx: -24, dy: -24)
    for region in regions where !tree.hides(region) {
      let p = project(region.frame.origin)
      let style = AtlasPalette.regionStyle(for: region.topicID ?? region.id)
      if region.collapsed {
        guard culledViewport.contains(p) else { continue }
        let marker = Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
        context.fill(marker, with: .color(style.fill.opacity(0.24)))
        context.stroke(marker, with: .color(style.stroke.opacity(0.75)), lineWidth: 1.2)
      } else {
        let rect = CGRect(
          origin: p,
          size: CGSize(
            width: max(8, region.frame.width * zoom),
            height: max(8, region.frame.height * zoom)
          )
        )
        guard rect.intersects(culledViewport) else { continue }
        let seed = region.topicID ?? region.id
        let area = OrganicRegionShape(seed: seed).path(in: rect)
        let outer = OrganicRegionShape(seed: seed, inset: -3).path(in: rect)
        context.fill(area, with: .color(style.fill.opacity(0.11)))
        context.stroke(outer, with: .color(style.stroke.opacity(0.20)), lineWidth: 0.65)
        context.stroke(
          area,
          with: .color(style.stroke.opacity(0.56)),
          style: StrokeStyle(lineWidth: 1.05, lineCap: .round, dash: [5, 3.5])
        )
        if rect.width > 56, rect.height > 110 {
          let motifW = min(52, rect.width * 0.52)
          let motifRect = CGRect(
            x: rect.midX - motifW / 2,
            y: rect.maxY - motifW - 10,
            width: motifW,
            height: motifW * 0.85
          )
          if motifRect.intersects(culledViewport) {
            var motifCtx = context
            motifCtx.opacity = 0.38
            motifCtx.blendMode = .multiply
            motifCtx.draw(AtlasArt.regionMotif(for: seed), in: motifRect)
          }
        }
      }
    }
    drawMaterials(in: context, viewport: viewport)
  }

  /// Isolate the map's display list from the moving camera. AppKit scrolls a retained
  /// backing layer; buttons, menus and accessibility elements move with their ink.
  private struct Viewport: NSViewRepresentable {
    let map: DistantCanvas

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ surface: Surface, context: Context) { surface.display(map) }
  }

  private struct HitAreas: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
  }

  private var labelBounds: some View {
    GeometryReader { proxy in
      Color.clear.preference(key: HitAreas.self, value: [proxy.frame(in: .named("atlas.overview.plate"))])
    }
  }

  private final class Surface: NSView {
    override var isFlipped: Bool { true }
    private let plate = NSHostingView(rootView: AnyView(EmptyView()))
    private var key: CacheKey?
    private var origin = CGPoint.zero
    private var displaySize = CGSize.zero
    private var hitAreas: [CGRect] = []

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.masksToBounds = true
      plate.wantsLayer = true
      plate.sizingOptions = []
      addSubview(plate)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func display(_ map: DistantCanvas) {
      let step: CGFloat = 192
      let base = CGPoint(x: ceil(map.origin.x / step) * step, y: ceil(map.origin.y / step) * step)
      let size = CGSize(width: map.size.width + step, height: map.size.height + step)
      let next = CacheKey(snapshotID: map.snapshotID, zoom: map.zoom,
        focusedEntrances: map.focusedEntrances, focusedRegions: map.focusedRegions)
      if key != next || origin != base || displaySize != size {
        key = next
        origin = base
        displaySize = size
        var drawing = map
        drawing.origin = base
        drawing.size = size
        let groups = drawing.labels()
        let landmarks = drawing.landmarks(avoiding: groups)
        plate.rootView = AnyView(drawing.contents(groups, landmarks)
          .coordinateSpace(name: "atlas.overview.plate")
          .onPreferenceChange(HitAreas.self) { [weak self] areas in self?.hitAreas = areas })
        plate.setFrameSize(size)
      }
      plate.setFrameOrigin(CGPoint(x: map.origin.x-base.x, y: map.origin.y-base.y))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      let local = convert(point, from: superview)
      guard bounds.contains(local) else { return nil }
      let onPlate = plate.convert(local, from: self)
      guard hitAreas.contains(where: { $0.contains(onPlate) }) else { return nil }
      return super.hitTest(point)
    }
  }

  var body: some View { Viewport(map: self).frame(width: size.width, height: size.height) }

  private func contents(_ regionLabels: [LabelGroup], _ marks: [Landmark]) -> some View {
    ZStack(alignment: .topLeading) {
      Canvas { context, size in drawMap(in: context, viewport: CGRect(origin: .zero, size: size)) }
        .allowsHitTesting(false).accessibilityHidden(true)

      ForEach(marks) { label in
        let name = title(label.entry)
        Button { visitEntry(label.entry) } label: {
          VStack(spacing: 2) {
            Text(name)
              .font(AtlasTypeface.reading.font(12.5).weight(.medium))
              .foregroundStyle(AtlasPalette.ink)
              .lineLimit(1)
            if label.count > 1 {
              Text("附近 " + String(label.count) + " 个入口")
                .font(.system(size: 10.5))
                .foregroundStyle(AtlasPalette.umber)
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .frame(width: 146)
          .background(AtlasPalette.paper.opacity(0.95), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(AtlasPalette.line.opacity(0.62), lineWidth: 0.85)
          }
          .shadow(color: Color.brown.opacity(0.10), radius: 4, y: 1.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("定位入口 " + name)
        .background(labelBounds)
        .position(label.location)
      }

      ForEach(regionLabels) { group in
        if group.regions.count == 1, let region = group.regions.first {
          let style = AtlasPalette.regionStyle(for: region.topicID ?? region.id)
          Button {
            visit(region.id)
          } label: {
            HStack(spacing: 5) {
              Circle().fill(style.stroke).frame(width: 6, height: 6)
              Text(region.title + " · " + String(counts[region.id, default: 0]))
                .font(AtlasTypeface.reading.font(12.5).weight(.medium))
                .foregroundStyle(style.badgeInk)
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AtlasPalette.paper.opacity(0.96), in: Capsule())
            .overlay { Capsule().strokeBorder(style.stroke.opacity(0.45), lineWidth: 0.9) }
            .shadow(color: Color.brown.opacity(0.11), radius: 4, y: 1.5)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("定位地域 " + region.title)
          .background(labelBounds)
          .position(group.center)
        } else {
          let style = AtlasPalette.regionStyle(for: group.regions[0].topicID ?? group.regions[0].id)
          Menu {
            ForEach(group.regions) { region in Button(region.title) { visit(region.id) } }
          } label: {
            HStack(spacing: 5) {
              Circle().fill(style.stroke).frame(width: 6, height: 6)
              Text(group.regions[0].title + " 等" + String(group.regions.count) + "处")
                .font(AtlasTypeface.reading.font(12).weight(.medium))
                .foregroundStyle(style.badgeInk)
                .lineLimit(1)
            }
          }
          .menuStyle(.button)
          .menuIndicator(.hidden)
          .buttonStyle(AtlasMenuButtonStyle(compact: true, capsule: true, borderColor: style.stroke.opacity(0.45)))
          .fixedSize()
          .accessibilityLabel(String(group.regions.count) + " 个地域")
          .background(labelBounds)
          .position(group.center)
        }
      }
    }.frame(width: size.width, height: size.height, alignment: .topLeading)
  }
}

private extension CGRect {
  var centerPoint: CGPoint { CGPoint(x: midX, y: midY) }
}
