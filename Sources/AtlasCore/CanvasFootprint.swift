import Foundation

/// World-space sizes. Zoom and overview change display only; placement always reserves the reader.
public enum CanvasFootprint {
  public static let preview = CGSize(width: 286, height: 116)
  public static let question = CGSize(width: 448, height: 400)
  public static let columnGap: CGFloat = 52
  public static let rowGap: CGFloat = 28

  public static func reserved(_ entry: MapEntry, measuredHeight: CGFloat? = nil) -> CGRect {
    if let page = entry.page { return CGRect(x: entry.x, y: entry.y, width: page.width, height: page.height + CanvasPDFPage.header) }
    let legacyHeight: CGFloat = entry.kind == "turn" ? max(240, (measuredHeight ?? 200) + 146) : 340
    return CGRect(x: entry.x, y: entry.y, width: max(320, entry.readingWidth ?? 400),
                  height: max(220, entry.readingHeight ?? legacyHeight))
  }

  /// Pick the closest unoccupied side of the source. Existing objects never move.
  public static func nearSource(_ source: CGRect, preferred: CGPoint, size: CGSize, obstacles: [CGRect]) -> CGPoint {
    let sides = [preferred, CGPoint(x: source.minX - columnGap - size.width, y: source.minY),
                 CGPoint(x: source.minX, y: source.maxY + rowGap),
                 CGPoint(x: source.minX, y: source.minY - rowGap - size.height)]
    for origin in sides {
      let rect = CGRect(origin: origin, size: size).insetBy(dx: -12, dy: -12)
      if !obstacles.contains(where: { $0.intersects(rect) }) { return origin }
    }
    return available(near: preferred, size: size, obstacles: obstacles, viewport: source.size)
  }

  public static func available(near origin: CGPoint, size: CGSize, obstacles: [CGRect],
                               viewport: CGSize) -> CGPoint {
    let maxY = origin.y + max(viewport.height * 3, size.height)
    let maxX = origin.x + max(viewport.width * 2, size.width)
    for column in 0..<3 {
      let x = origin.x + CGFloat(column) * (size.width + columnGap)
      guard x <= maxX else { break }
      var y = origin.y
      for _ in 0..<8 {
        let rect = CGRect(origin: CGPoint(x: x, y: y), size: size)
        let bottom = obstacles.lazy.filter { $0.insetBy(dx: -12, dy: -12).intersects(rect) }.map(\.maxY).max()
        guard let bottom else { return rect.origin }
        y = bottom + rowGap
        if y > maxY { break }
      }
    }
    return CGPoint(x: max(origin.x, (obstacles.map(\.maxX).max() ?? origin.x) + columnGap), y: origin.y)
  }
}
