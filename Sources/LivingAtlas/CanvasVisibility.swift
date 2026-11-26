import AtlasCore
import Foundation

/// Conservative world bounds, rebuilt with the map snapshot. Camera changes only need
/// exact intersections within the current neighbourhood and any held offscreen readers.
@MainActor struct CanvasVisibility {
  private struct Footprint {
    let index: Int
    let bounds: CGRect
  }
  private final class WindowIndex {
    private var window = CGRect.null
    private var nearby = [Footprint]()

    func candidates(for rect: CGRect, in all: [Footprint]) -> [Footprint] {
      guard !rect.isNull && !rect.isInfinite && all.count > 64 else { return all }
      // Reuse nearby geometry during a gesture. Shrink the cache again after zooming in.
      if !window.contains(rect) || window.width > rect.width * 3 || window.height > rect.height * 3 {
        window = rect.insetBy(dx: -rect.width / 2, dy: -rect.height / 2)
        nearby = all.filter { $0.bounds.intersects(window) }
      }
      return nearby
    }
  }
  private let entryWindow = WindowIndex()
  private let edgeWindow = WindowIndex()
  private let regionWindow = WindowIndex()
  private(set) var worldBounds = CGRect.null
  private var regions = [CanvasRegion]()
  private var regionBounds = [Footprint]()
  private var visibleEntryBoundsByID = [String: Int]()
  private var entryBounds = [Footprint]()
  private var edgeBounds = [Footprint]()
  // Keep the arrays from the same immutable snapshot as the offsets. The scan itself
  // touches only numeric geometry; an offscreen relationship can carry a long evidence list.
  private var entries = [MapEntry]()
  private var edges = [MapEdge]()

  func firstEntrance(in world: CGRect, matching accepts: (MapEntry) -> Bool) -> MapEntry? {
    for item in entryWindow.candidates(for: world, in: entryBounds) where item.bounds.intersects(world) {
      let entry = entries[item.index]
      if accepts(entry) { return entry }
    }
    return nil
  }

  func entrances(in world: CGRect, keeping held: Set<String>) -> [MapEntry] {
    var matches = entryWindow.candidates(for: world, in: entryBounds).compactMap {
      $0.bounds.intersects(world) ? $0.index : nil
    }
    let offscreen = held.compactMap { id -> Int? in
      guard let offset = visibleEntryBoundsByID[id] else { return nil }
      let item = entryBounds[offset]
      return item.bounds.intersects(world) ? nil : item.index
    }
    if !offscreen.isEmpty {
      matches.append(contentsOf: offscreen)
      matches.sort()
    }
    return matches.map { entries[$0] }
  }
  func connections(in world: CGRect) -> [MapEdge] {
    edgeWindow.candidates(for: world, in: edgeBounds).compactMap {
      $0.bounds.intersects(world) ? edges[$0.index] : nil
    }
  }

  func regionCandidates(in world: CGRect) -> [CanvasRegion] {
    regionWindow.candidates(for: world, in: regionBounds).compactMap {
      $0.bounds.intersects(world) ? regions[$0.index] : nil
    }
  }

  init() {}
  init(map: AtlasMap, regions: [CanvasRegion], tree: CanvasRegionTree, endpoints: [String: MapEntry], minimumZoom: Double) {
    self.regions = regions
    for (index, region) in regions.enumerated() where !tree.hides(region) {
      let chrome = CanvasRegionChrome.displaySize(region, zoom: minimumZoom)
      // A folded label has its largest world footprint at the smallest ordinary zoom.
      let bounds = CGRect(origin: region.frame.origin,
        size: CGSize(width: chrome.width / minimumZoom, height: chrome.height / minimumZoom))
      regionBounds.append(Footprint(index: index, bounds: bounds))
      let worldSize = CanvasRegionChrome.displaySize(region, zoom: 1)
      worldBounds = worldBounds.union(CGRect(origin: region.frame.origin, size: worldSize))
    }
    entries = map.entries
    edges = map.edges
    var endpointBounds: [String: CGRect] = [:]
    for (index, entry) in entries.enumerated() {
      let bounds: CGRect
      if let owner = tree.collapsedOwner(of: entry.regionID), let region = tree.regions[owner] {
        // Folded region chrome is sized in screen points even at minimum zoom.
        let chrome = CanvasRegionChrome.displaySize(region, zoom: minimumZoom)
        bounds = CGRect(origin: region.frame.origin,
          size: CGSize(width: chrome.width / minimumZoom, height: chrome.height / minimumZoom))
      } else {
        bounds = CanvasFootprint.reserved(entry)
        visibleEntryBoundsByID[entry.id] = entryBounds.count
        entryBounds.append(Footprint(index: index, bounds: bounds))
        worldBounds = worldBounds.union(bounds)
      }
      endpointBounds[entry.id] = bounds
    }
    for (index, edge) in edges.enumerated() {
      guard let (from, to) = edge.entrances(defaults: endpoints),
        let a = endpointBounds[from.id], let b = endpointBounds[to.id] else { continue }
      let left = tree.collapsedOwner(of: from.regionID)
      let right = tree.collapsedOwner(of: to.regionID)
      if left == nil || left != right {
        edgeBounds.append(Footprint(index: index, bounds: a.union(b)))
      }
    }
  }
}
