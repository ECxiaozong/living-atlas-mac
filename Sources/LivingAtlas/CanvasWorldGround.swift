import SwiftUI

/// Canvas entries and landmarks share this world-to-viewport transform.
struct WorldGroundProjection {
  let origin: CGPoint
  let zoom: CGFloat

  func screenRect(_ world: CGRect) -> CGRect {
    CGRect(x: origin.x + world.minX * zoom, y: origin.y + world.minY * zoom,
           width: world.width * zoom, height: world.height * zoom)
  }

  /// Use the next coarser world grid as lines converge in the overview.
  var gridSpacing: CGFloat {
    var step = 40 * zoom
    while step < 12 && step > 0 { step *= 4 }
    return step
  }

  func phase(_ position: CGFloat, step: CGFloat) -> CGFloat {
    let remainder = position.truncatingRemainder(dividingBy: step)
    return remainder < 0 ? remainder + step : remainder
  }
}

struct CanvasWorldGround: View {
  let projection: WorldGroundProjection
  let prominent: Bool

  var body: some View {
    Canvas { context, size in
      let viewport = CGRect(origin: .zero, size: size)
      context.fill(Path(viewport), with: .color(AtlasPalette.cream))
      let zoom = projection.zoom
      guard zoom.isFinite, zoom > 0 else { return }

      if zoom >= 0.15 {
        var paper = context
        paper.opacity = 0.14
        paper.fill(Path(viewport), with: .tiledImage(AtlasArt.atlas, origin: projection.origin, scale: zoom))
      }

      let step = projection.gridSpacing
      let majorStep = 4 * step

      func ruling(_ spacing: CGFloat, opacity: Double, width: CGFloat) {
        var lines = Path()
        let x0 = projection.phase(projection.origin.x, step: spacing)
        let y0 = projection.phase(projection.origin.y, step: spacing)
        for x in stride(from: x0, through: size.width, by: spacing) {
          lines.move(to: CGPoint(x: x, y: 0))
          lines.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: y0, through: size.height, by: spacing) {
          lines.move(to: CGPoint(x: 0, y: y))
          lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lines, with: .color(AtlasPalette.umber.opacity(opacity)), lineWidth: width)
      }
      ruling(step, opacity: 0.042, width: 0.5)
      ruling(majorStep, opacity: 0.088, width: 0.68)

      // World-locked cartographic registration crosshairs at major intersections.
      if majorStep >= 48 {
        var ticks = Path()
        let x0 = projection.phase(projection.origin.x, step: majorStep)
        let y0 = projection.phase(projection.origin.y, step: majorStep)
        let arm: CGFloat = min(3.4, max(2.0, majorStep * 0.026))
        for gx in stride(from: x0, through: size.width, by: majorStep) {
          for gy in stride(from: y0, through: size.height, by: majorStep) {
            ticks.move(to: CGPoint(x: gx - arm, y: gy))
            ticks.addLine(to: CGPoint(x: gx + arm, y: gy))
            ticks.move(to: CGPoint(x: gx, y: gy - arm))
            ticks.addLine(to: CGPoint(x: gx, y: gy + arm))
          }
        }
        context.stroke(ticks, with: .color(AtlasPalette.umber.opacity(0.18)), lineWidth: 0.75)
      }

      func landmark(_ image: Image, _ world: CGRect, opacity: Double) {
        let rect = projection.screenRect(world)
        guard rect.intersects(viewport) else { return }
        var ink = context
        ink.opacity = opacity
        ink.blendMode = .multiply
        ink.draw(image, in: rect)
      }
      landmark(AtlasArt.worldCape, CGRect(x: -348, y: 308, width: 350, height: 260),
               opacity: prominent ? 0.56 : 0.21)
      landmark(AtlasArt.motifPines, CGRect(x: 1236, y: 92, width: 224, height: 164),
               opacity: prominent ? 0.38 : 0.14)
      landmark(AtlasArt.motifPeaks, CGRect(x: 842, y: 678, width: 288, height: 138),
               opacity: prominent ? 0.48 : 0.16)
      landmark(AtlasArt.motifArmillary, CGRect(x: 96, y: 626, width: 118, height: 144),
               opacity: prominent ? 0.30 : 0.11)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
