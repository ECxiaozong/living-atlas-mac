import AtlasCore
import SwiftUI

struct OrganizationDiff: View {
  let plan: OrganizationPlan
  let selection: Set<String>
  let focused: String?
  let after: Bool
  let savedCamera: Bool
  var previewStore: AtlasStore?
  @ViewState private var pages: [String: Image] = [:]

  private func stampY(in box: CGRect, measured: CGSize) -> CGFloat {
    box.minY + max(0, (box.height - measured.height) / 2)
  }
  var body: some View {
    ZStack {
      if plan.scope.presentationSizes == nil { MapGround().opacity(0.58) } else { AtlasPalette.cream.opacity(0.5) }
      Canvas { context, size in
        let scope = plan.scope
        let localLayout = scope.presentationSizes != nil
        let edits = plan.edits.filter { selection.contains($0.id) }
        let base = Dictionary(
          uniqueKeysWithValues: scope.objects.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
        var points = base
        var labels = Dictionary(uniqueKeysWithValues: scope.objects.map { ($0.id, $0.title) })
        var ending: [String: CGPoint] = [:]
        var removed = Set<String>()
        for e in edits {
          guard let p = base[e.target] else { continue }
          if e.action == .move, let x = e.x, let y = e.y { ending[e.target] = CGPoint(x: x, y: y) }
          if e.action == .removeEntrance { removed.insert(e.target) }
          if e.action == .addEntrance {
            ending[e.id] = CGPoint(x: e.x ?? p.x + 288, y: e.y ?? p.y + 144)
            labels[e.id] = labels[e.target]
          }
        }
        if after {
          points.merge(ending) { _, b in b }
          for id in removed { points.removeValue(forKey: id) }
        }
        func paper(_ id: String, at p: CGPoint) -> CGRect {
          CGRect(origin: p, size: scope.presentationSizes?[id] ?? CGSize(width: 248, height: 116))
        }
        var world = CGRect.null
        for (id, p) in Array(base) + Array(ending) {
          world = world.union(paper(id, at: p))
        }
        for r in scope.regions {
          world = world.union(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
        }
        guard !world.isNull, size.width > 2, size.height > 2 else { return }
        let scale =
          savedCamera
          ? scope.zoom
          : min(
            (size.width - 28) / max(248, world.width), (size.height - 24) / max(116, world.height),
            0.94)
        let ox =
          savedCamera ? scope.cameraX : (size.width - world.width * scale) / 2 - world.minX * scale
        let oy =
          savedCamera
          ? scope.cameraY : (size.height - world.height * scale) / 2 - world.minY * scale
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + ox, y: p.y * scale + oy) }
        func box(_ id: String, at p: CGPoint) -> CGRect {
          let size = paper(id, at: p).size
          return CGRect(origin: point(p), size: CGSize(width: size.width * scale, height: size.height * scale))
        }
        func center(_ id: String, _ p: CGPoint) -> CGPoint {
          let rect = box(id, at: p)
          return CGPoint(x: rect.midX, y: rect.midY)
        }
        func segment(_ p: CGPoint, _ q: CGPoint, color: Color, dash: [CGFloat], arrow: Bool = false)
        {
          var line = Path()
          line.move(to: p)
          line.addLine(to: q)
          context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.7, dash: dash))
          if arrow {
            let angle = atan2(q.y - p.y, q.x - p.x)
            let mid = CGPoint(x: p.x + (q.x - p.x) * 0.6, y: p.y + (q.y - p.y) * 0.6)
            var tip = Path()
            tip.move(to: CGPoint(x: mid.x - cos(angle - 0.5) * 8, y: mid.y - sin(angle - 0.5) * 8))
            tip.addLine(to: mid)
            tip.addLine(
              to: CGPoint(x: mid.x - cos(angle + 0.5) * 8, y: mid.y - sin(angle + 0.5) * 8))
            context.stroke(tip, with: .color(color), lineWidth: 1.8)
          }
        }
        for r in scope.regions {
          let box = CGRect(
            origin: point(CGPoint(x: r.x, y: r.y)),
            size: .init(width: r.width * scale, height: r.height * scale))
          let style = AtlasPalette.regionStyle(for: r.id)
          let shape = OrganicRegionShape(seed: r.id).path(in: box)
          context.fill(shape, with: .color(style.fill.opacity(0.10)))
          context.stroke(
            shape, with: .color(style.stroke.opacity(0.55)),
            style: StrokeStyle(lineWidth: 0.95, lineCap: .round, dash: [4, 3]))
          context.draw(
            Text(r.title).font(.system(size: 10.5, weight: .semibold, design: .serif)).foregroundStyle(style.badgeInk),
            at: CGPoint(x: box.minX + 8, y: box.minY + 5), anchor: .topLeading)
        }
        for edge in scope.links where !localLayout {
          if let a = points[edge.from], let b = points[edge.to] {
            segment(
              center(edge.from, a), center(edge.to, b),
              color: edge.history ? AtlasPalette.umber.opacity(0.65) : AtlasPalette.blueInk.opacity(0.65),
              dash: edge.history ? [4, 3] : [], arrow: edge.directed)
          }
        }
        if after {
          for e in edits where e.action == .relate {
            if let peer = e.peer, let a = points[e.target], let b = points[peer] {
              segment(
                center(e.target, a), center(peer, b), color: AtlasPalette.gold, dash: [5, 3.5],
                arrow: MapRelation(rawValue: e.relation ?? "")?.directed ?? false)
              let mid = CGPoint(
                x: (center(e.target, a).x + center(peer, b).x) / 2, y: (center(e.target, a).y + center(peer, b).y) / 2)
              context.draw(
                Text(MapRelation(rawValue: e.relation ?? "")?.label ?? "关系").font(
                  AtlasTypeface.reading.font(11).weight(.medium)
                ).foregroundStyle(AtlasPalette.umber), at: mid, anchor: .bottom)
            }
          }
          for e in edits where e.action == .move || e.action == .removeEntrance {
            guard let p = base[e.target] else { continue }
            let ghost = box(e.target, at: p)
            context.stroke(
              Path(roundedRect: ghost, cornerRadius: 5), with: .color(AtlasPalette.umber.opacity(0.65)),
              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if !localLayout, let next = ending[e.target] {
              segment(center(e.target, p), center(e.target, next), color: AtlasPalette.umber.opacity(0.75), dash: [3, 3.5], arrow: true)
            }
          }
        }
        let active = plan.edits.first { $0.id == focused }
        for key in points.keys.sorted() {
          guard let p = points[key] else { continue }
          let box = box(key, at: p)
          let emph = active?.target == key || (!localLayout && active?.peer == key) || active?.id == key
          let path = Path(roundedRect: box, cornerRadius: 4)
          context.fill(
            path,
            with: .color(emph ? Color(red: 0.99, green: 0.88, blue: 0.66) : AtlasPalette.cream))
          context.stroke(
            path, with: .color(emph ? .brown : AtlasPalette.umber.opacity(0.5)),
            lineWidth: emph ? 1.7 : 0.8)
          let ink = box.insetBy(dx: 5, dy: 3)
          guard ink.width > 3, ink.height > 3 else { continue }
          var lettering = context
          lettering.clip(to: Path(ink))
          if localLayout, let object = scope.objects.first(where: { $0.id == key }) {
            let heading = Text(object.title).font(.system(size: 13, weight: .semibold, design: .serif))
              .foregroundStyle(AtlasPalette.ink)
            lettering.draw(lettering.resolve(heading), in: CGRect(x: ink.minX+4, y: ink.minY+3, width: ink.width-8, height: 22))
            let body = CGRect(x: ink.minX+5, y: ink.minY+29, width: ink.width-10, height: ink.height-33)
            if body.width > 0, body.height > 0 {
              if let page = pages[key] {
                let resolved = lettering.resolve(page)
                let factor = min(body.width/resolved.size.width, body.height/resolved.size.height)
                lettering.draw(resolved, in: CGRect(origin: body.origin, size: CGSize(width: resolved.size.width*factor, height: resolved.size.height*factor)))
              } else {
                lettering.draw(lettering.resolve(Text(String(object.body.prefix(800))).font(.system(size: 12)).foregroundStyle(AtlasPalette.ink)), in: body)
              }
            }
            continue
          }
          let title = labels[key] ?? ""
          let font = Font.system(
            size: max(9, min(14, box.height * 0.39)), weight: emph ? .semibold : .regular,
            design: .serif)
          let paragraph = lettering.resolve(
            Text(title).font(font).foregroundStyle(AtlasPalette.ink))
          let width = ink.width
          let measured = paragraph.measure(in: CGSize(width: width, height: ink.height))
          lettering.draw(
            paragraph,
            in: CGRect(
              x: ink.minX, y: stampY(in: ink, measured: measured), width: width, height: ink.height)
          )

        }
        if localLayout && after {
          for edit in edits where edit.action == .move {
            guard let old = base[edit.target], let new = ending[edit.target] else { continue }
            let from = box(edit.target, at: old), to = box(edit.target, at: new)
            let start = CGPoint(x: from.midX, y: from.minY + 4)
            let finish = CGPoint(x: to.midX, y: to.minY + 4)
            segment(start, finish, color: AtlasPalette.umber, dash: [3, 3], arrow: true)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 2, y: start.y - 2, width: 4, height: 4)),
                         with: .color(AtlasPalette.umber))
          }
        }
      }
    }.frame(minHeight: 210, idealHeight: 300, maxHeight: 310).clipShape(
      RoundedRectangle(cornerRadius: 12)
    )
    .task(id: plan.id) {
      pages = [:]
      guard let previewStore, plan.scope.presentationSizes != nil else { return }
      for object in plan.scope.objects where object.documentKind == "pdf" {
        if let pdf = try? previewStore.readablePDF(previewStore.pdf(versionID: object.version)), let page = pdf.page(at: 0) {
          pages[object.id] = Image(nsImage: page.thumbnail(of: CGSize(width: 500, height: 550), for: .cropBox))
        }
      }
    }
    .accessibilityLabel(after ? "整理后图谱，同相机" : "整理前图谱，同相机")
  }
}
