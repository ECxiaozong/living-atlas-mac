import Foundation
import GRDB

extension AtlasStore {
  /// Use measured reader sizes so a naturally growing answer keeps its place.
  public func previewOverlap(anchor: String, neighbours: Set<String>, sizes: [String: CGSize],
                             cameraOrigin: CGPoint, zoom: Double, displayedRuns: [String: String] = [:]) throws -> OrganizationPlan {
    let targets = neighbours.subtracting([anchor])
    guard !targets.isEmpty else { throw organizationError("图版已经分开。") }
    let scopeIDs = targets.union([anchor])
    var scope = try organizationScope(placements: scopeIDs, allowed: [.move], displayedRuns: displayedRuns)
    scope.cameraX = cameraOrigin.x
    scope.cameraY = cameraOrigin.y
    scope.zoom = zoom
    scope.presentationSizes = sizes.filter { scopeIDs.contains($0.key) }
    let labels = try markdownEntranceLabels()
    let tree = CanvasRegionTree(try canvasRegions())
    let pins = try readViewState([String: String].self, key: "map.pdf-versions") ?? [:]
    let entriesPerDocument = try database.read { db in
      Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
        SELECT document_id,count(*) n FROM placement WHERE view_id='atlas' AND document_id IS NOT NULL GROUP BY document_id
        """).map { ($0["document_id"] as String, $0["n"] as Int) })
    }
    var descriptions = [String: String]()
    for object in scope.objects {
      var terms = [String]()
      if let label = labels[object.id] { terms.append(label) }
      else if object.documentKind == "pdf" {
        let pdf = try pdfInfo(versionID: object.version)
        let current = try pdfVersions(documentID: pdf.id).first?.versionID
        terms.append((pins[object.id] == nil ? "跟随当前 · v" : (current == pdf.versionID ? "固定 · v" : "历史 · v")) + String(pdf.ordinal))
      }
      if let count = entriesPerDocument[object.target], count > 1 {
        terms.append("共享正文 · " + String(count) + " 处入口")
      }
      if let region = object.region, let name = tree.regions[region]?.title { terms.append(name) }
      descriptions[object.id] = terms.joined(separator: " · ")
    }
    scope.entranceDescriptions = descriptions
    let hints = targets.sorted().map {
      OrganizationEdit(action: .move, target: $0, reason: "移开重叠图版，保留当前阅读位置。", peer: anchor)
    }
    let edits = try layoutOrganizationIntents(hints, within: scope, displayedSizes: sizes)
    return try previewOrganization(scope, edits: edits, title: "排开重叠图版")
  }

  /// The model supplies a semantic neighbour, never a world-space coordinate. The host chooses
  /// one bounded, repeatable position and persists that same position in Diff and commit.
  public func layoutOrganizationIntents(
    _ hints: [OrganizationEdit], within scope: OrganizationScope, displayedSizes: [String: CGSize] = [:]
  ) throws -> [OrganizationEdit] {
    let lookup = Dictionary(uniqueKeysWithValues: scope.objects.map { ($0.id, $0) })
    // Collision checking uses only local placement rectangles; the model never receives unselected material.
    var occupied = try database.read { db in
      Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(
          db, sql: "SELECT id,x,y,width,height FROM placement WHERE view_id='atlas'"
        ).map { r in
          (
            r["id"] as String,
            CGRect(
              x: r["x"] as Double, y: r["y"] as Double, width: r["width"] as Double,
              height: r["height"] as Double)
          )
        })
    }
    for o in scope.objects {
      occupied[o.id] = CGRect(x: o.x, y: o.y, width: o.width, height: o.height)
    }
    for (id, size) in displayedSizes where occupied[id] != nil {
      guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
        throw organizationError("图版尺寸无效。")
      }
      occupied[id]?.size = size
    }
    var output: [OrganizationEdit] = []
    for var e in hints {
      guard let o = lookup[e.target] else { throw organizationError("布局意图超出所选材料。") }
      if e.action == .move || e.action == .addEntrance {
        guard e.x == nil && e.y == nil else { throw organizationError("模型整理仅接受布局意图，像素位置由本地计算。") }
        let anchor: CGRect
        if e.action == .move {
          guard let id = e.peer, lookup[id] != nil, let neighbor = occupied[id], id != o.id else {
            throw organizationError("相邻布局需要另一个所选入口。")
          }
          if let state = try? JSONSerialization.jsonObject(with: Data(o.reader.utf8))
            as? [String: Any], state["pinned"] as? Bool == true
          {
            throw organizationError("该入口已固定，请修改提案。")
          }
          anchor = neighbor
          occupied.removeValue(forKey: o.id)
        } else {
          guard let region = scope.regions.first(where: { $0.id == e.region }) else {
            throw organizationError("选择可写入的地域。")
          }
          anchor = CGRect(
            x: region.x + 16 - o.width - 36, y: region.y + 38, width: o.width, height: o.height)
        }
        let size = displayedSizes[o.id] ?? CGSize(width: o.width, height: o.height)
        var next = CGRect(origin: CGPoint(x: anchor.maxX + 36, y: anchor.minY), size: size)
        func fits(_ candidate: CGRect) -> Bool {
          !occupied.values.contains { $0.insetBy(dx: -12, dy: -12).intersects(candidate) }
        }
        if scope.presentationSizes != nil && !fits(next) {
          let nearby = [CGPoint(x: anchor.minX - size.width - 36, y: anchor.minY),
                        CGPoint(x: anchor.minX, y: anchor.maxY + 36),
                        CGPoint(x: anchor.minX, y: anchor.minY - size.height - 36)]
            .map { CGRect(origin: $0, size: size) }.filter(fits)
          if let closest = nearby.min(by: {
            hypot($0.minX-o.x, $0.minY-o.y) < hypot($1.minX-o.x, $1.minY-o.y)
          }) { next = closest }
        }
        while !fits(next) {
          next.origin.y += next.height + 36
        }
        e.x = next.minX
        e.y = next.minY
        occupied[e.action == .move ? o.id : e.id] = next
      } else if e.x != nil || e.y != nil {
        throw organizationError("该语义修改不能提供布局坐标。")
      }
      output.append(e)
    }
    return output
  }
}
