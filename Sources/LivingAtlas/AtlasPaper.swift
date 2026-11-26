import AppKit
import SwiftUI

enum AtlasPalette {
  // Primary reading & structural inks
  static let ink = AtlasTheme.current.color(.ink, default: Color(red: 0.145, green: 0.173, blue: 0.192))          // #252C31 warm slate-ink
  static let blueInk = AtlasTheme.current.color(.accent, default: Color(red: 0.165, green: 0.298, blue: 0.365))      // #2A4C5D mineral Prussian slate
  static let blueInkHover = Color(red: 0.125, green: 0.243, blue: 0.306) // #203E4E deeper hover
  static let umber = AtlasTheme.current.color(.secondaryInk, default: Color(red: 0.467, green: 0.380, blue: 0.286))        // #776149 archival umber
  static let line = AtlasTheme.current.color(.line, default: Color(red: 0.745, green: 0.659, blue: 0.545))         // #BEA88B warm binding hairline
  static let gold = Color(red: 0.773, green: 0.620, blue: 0.373)         // #C59E5F compass brass gold

  // Window chrome — unified deep maritime slate family
  static let navy = Color(red: 0.106, green: 0.153, blue: 0.208)         // #1B2735 deep atlas indigo
  static let rail = Color(red: 0.122, green: 0.169, blue: 0.220)         // #1F2B38 harmonized rail slate
  static let railActive = Color(red: 0.722, green: 0.573, blue: 0.353)   // #B8925A warm gold highlight
  static let railActiveText = Color(red: 0.945, green: 0.859, blue: 0.690) // #F1DBB0 luminous parchment gold

  // Archival paper surfaces
  static let cream = Color(red: 0.961, green: 0.937, blue: 0.886)        // #F5EFE2 warm parchment ground
  static let paper = AtlasTheme.current.color(.paper, default: Color(red: 0.980, green: 0.965, blue: 0.929))        // #FAF6ED tactile ivory rag paper
  static let paperHeader = Color(red: 0.945, green: 0.916, blue: 0.859)  // #F1EADB archival header strip
  static let paperInset = AtlasTheme.current.color(.inset, default: Color(red: 0.961, green: 0.935, blue: 0.884))   // #F5EFE1 recessed input/quote well
  static let barFill = Color(red: 0.976, green: 0.960, blue: 0.922)      // #F9F5EB floating bar surface

  // Semantic badge inks
  static let terracotta = Color(red: 0.694, green: 0.357, blue: 0.255)   // #B15B41 PDF stamp
  static let sage = Color(red: 0.306, green: 0.431, blue: 0.365)         // #4E6E5D idea / note stamp

  struct RegionStyle {
    let fill: Color
    let stroke: Color
    let badgeBg: Color
    let badgeInk: Color
  }

  private static let regionStyles: [RegionStyle] = [
    // Mineral slate-blue wash
    RegionStyle(
      fill: Color(red: 0.345, green: 0.478, blue: 0.549),
      stroke: Color(red: 0.255, green: 0.388, blue: 0.459),
      badgeBg: Color(red: 0.929, green: 0.949, blue: 0.957),
      badgeInk: Color(red: 0.180, green: 0.310, blue: 0.380)
    ),
    // Warm ochre-sand wash
    RegionStyle(
      fill: Color(red: 0.667, green: 0.529, blue: 0.337),
      stroke: Color(red: 0.545, green: 0.420, blue: 0.251),
      badgeBg: Color(red: 0.965, green: 0.941, blue: 0.890),
      badgeInk: Color(red: 0.455, green: 0.345, blue: 0.200)
    ),
    // Muted cartographic plum-slate wash
    RegionStyle(
      fill: Color(red: 0.494, green: 0.431, blue: 0.549),
      stroke: Color(red: 0.408, green: 0.349, blue: 0.463),
      badgeBg: Color(red: 0.949, green: 0.937, blue: 0.961),
      badgeInk: Color(red: 0.345, green: 0.290, blue: 0.396)
    ),
  ]

  /// Deterministic regional tint per topic/region identity (stable across pans, zooms and restarts).
  static func regionStyle(for key: String) -> RegionStyle {
    var hash: UInt64 = 14695981039346656037
    for byte in key.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return regionStyles[Int(hash % UInt64(regionStyles.count))]
  }
}

enum AtlasArt {
  private static func load(_ name: String, _ ext: String) -> Image {
    let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Art")
    return Image(nsImage: url.flatMap(NSImage.init(contentsOf:)) ?? NSImage())
  }

  private static func loadHiDPI(_ base: String, size: NSSize) -> Image {
    let image = NSImage(size: size)
    for suffix in ["", "@2x"] {
      if let url = Bundle.module.url(
        forResource: base + suffix, withExtension: "png", subdirectory: "Art"),
        let bytes = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: bytes)
      {
        rep.size = size
        image.addRepresentation(rep)
      }
    }
    return Image(nsImage: image)
  }

  static let pupu: Image = loadHiDPI("pupu-56", size: NSSize(width: 56, height: 54))
  static let pupuIdle: Image = loadHiDPI("pupu-idle", size: NSSize(width: 64, height: 64))
  static let pupuQuestion: Image = loadHiDPI("pupu-question", size: NSSize(width: 64, height: 64))
  static let pupuWaiting: Image = loadHiDPI("pupu-waiting", size: NSSize(width: 64, height: 64))
  static let pupuExplore: Image = loadHiDPI("pupu-explore", size: NSSize(width: 64, height: 64))

  static let compass = load("compass-star", "svg")
  static let paper = load("paper", "webp")
  static let atlas = load("atlas", "webp")
  static let mountains: Image = {
    if let url = Bundle.module.url(forResource: "mountains-hd", withExtension: "png", subdirectory: "Art"),
      let img = NSImage(contentsOf: url)
    {
      return Image(nsImage: img)
    }
    return load("mountains", "webp")
  }()
  static let topMountains = load("top-mountains", "png")
  static let regionContour = load("region-contour", "png")
  static let worldCape = load("world-cape", "png")
  static let coastLeft = load("coast-left", "png")
  static let coastRight = load("coast-right", "png")
  static let motifPeaks = load("motif-peaks", "png")
  static let motifPines = load("motif-pines", "png")
  static let motifObservatory = load("motif-observatory", "png")
  static let motifArmillary = load("motif-armillary", "png")

  static func regionMotif(for key: String) -> Image {
    var hash: UInt64 = 14695981039346656037
    for byte in key.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    let motifs = [motifPeaks, motifPines, motifObservatory, motifArmillary]
    return motifs[Int(hash % UInt64(motifs.count))]
  }
}

/// Deterministic, softly undulating cartographic boundary that transforms rigid rectangles
/// into gentle archival map territories without clipping interior reading cards.
struct OrganicRegionShape: Shape {
  let seed: String
  var inset: CGFloat = 0

  private static func hashValue(_ seed: String, index: Int) -> Double {
    var h: UInt64 = 14695981039346656037 ^ UInt64(bitPattern: Int64(index &* 2654435761))
    for byte in seed.utf8 {
      h ^= UInt64(byte)
      h &*= 1099511628211
    }
    return Double(h % 10000) / 10000.0 * 2.0 - 1.0 // -1.0 ... 1.0
  }

  func path(in rect: CGRect) -> Path {
    let r = rect.insetBy(dx: inset, dy: inset)
    guard r.width > 36, r.height > 36 else {
      return Path(roundedRect: r, cornerRadius: max(4, min(14, min(r.width, r.height) * 0.25)))
    }
    let ampX = min(7.5, r.width * 0.032)
    let ampY = min(7.5, r.height * 0.032)
    let hSegs = max(2, min(6, Int(r.width / 130)))
    let vSegs = max(2, min(8, Int(r.height / 130)))
    let corner = min(18, min(r.width, r.height) * 0.16)

    var pts: [CGPoint] = []
    var idx = 0
    // Top edge (left -> right)
    for i in 0 ... hSegs {
      let t = CGFloat(i) / CGFloat(hSegs)
      let x = r.minX + corner + (r.width - corner * 2) * t
      let edgeFactor: CGFloat = (i == 0 || i == hSegs) ? 0.25 : 1.0
      let dy = CGFloat(Self.hashValue(seed, index: idx)) * ampY * edgeFactor
      pts.append(CGPoint(x: x, y: r.minY + dy))
      idx += 1
    }
    // Right edge (top -> bottom)
    for i in 0 ... vSegs {
      let t = CGFloat(i) / CGFloat(vSegs)
      let y = r.minY + corner + (r.height - corner * 2) * t
      let edgeFactor: CGFloat = (i == 0 || i == vSegs) ? 0.25 : 1.0
      let dx = CGFloat(Self.hashValue(seed, index: idx)) * ampX * edgeFactor
      pts.append(CGPoint(x: r.maxX + dx, y: y))
      idx += 1
    }
    // Bottom edge (right -> left)
    for i in 0 ... hSegs {
      let t = CGFloat(i) / CGFloat(hSegs)
      let x = r.maxX - corner - (r.width - corner * 2) * t
      let edgeFactor: CGFloat = (i == 0 || i == hSegs) ? 0.25 : 1.0
      let dy = CGFloat(Self.hashValue(seed, index: idx)) * ampY * edgeFactor
      pts.append(CGPoint(x: x, y: r.maxY + dy))
      idx += 1
    }
    // Left edge (bottom -> top)
    for i in 0 ... vSegs {
      let t = CGFloat(i) / CGFloat(vSegs)
      let y = r.maxY - corner - (r.height - corner * 2) * t
      let edgeFactor: CGFloat = (i == 0 || i == vSegs) ? 0.25 : 1.0
      let dx = CGFloat(Self.hashValue(seed, index: idx)) * ampX * edgeFactor
      pts.append(CGPoint(x: r.minX + dx, y: y))
      idx += 1
    }

    guard pts.count >= 4 else { return Path(roundedRect: r, cornerRadius: 14) }
    var path = Path()
    let n = pts.count
    let mid0 = CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2)
    path.move(to: mid0)
    for i in 0 ..< n {
      let curr = pts[i]
      let next = pts[(i + 1) % n]
      let mid = CGPoint(x: (curr.x + next.x) / 2, y: (curr.y + next.y) / 2)
      path.addQuadCurve(to: mid, control: curr)
    }
    path.closeSubpath()
    return path
  }
}

/// Classical engraved folio cartouche for empty/welcome atlas views.
struct AtlasFolioCartouche: View {
  var subtitle = "问起于惑 · 图成于行"

  var body: some View {
    HStack(spacing: 10) {
      Rectangle()
        .fill(LinearGradient(colors: [.clear, AtlasPalette.line.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
        .frame(width: 34, height: 0.75)
      HStack(spacing: 7) {
        AtlasArt.compass.resizable().scaledToFit().frame(width: 13, height: 13).opacity(0.85)
        Text("Living Atlas")
          .font(.custom("Georgia-Italic", size: 13.5))
          .foregroundStyle(AtlasPalette.umber.opacity(0.9))
        Text("·")
          .foregroundStyle(AtlasPalette.gold)
        Text(subtitle)
          .font(AtlasTypeface.reading.font(12))
          .tracking(1.1)
          .foregroundStyle(AtlasPalette.umber.opacity(0.78))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(AtlasPalette.barFill.opacity(0.76), in: Capsule())
      .overlay {
        Capsule().strokeBorder(AtlasPalette.line.opacity(0.45), lineWidth: 0.75)
      }
      Rectangle()
        .fill(LinearGradient(colors: [AtlasPalette.line.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing))
        .frame(width: 34, height: 0.75)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct MapGround: View {
  var prominentTerrain = false

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      ZStack(alignment: .bottomTrailing) {
        // Warm archival parchment base
        AtlasPalette.cream

        // Soft low-frequency archival grain
        AtlasArt.atlas
          .resizable(resizingMode: .tile)
          .opacity(0.14)
          .frame(width: size.width, height: size.height)
          .clipped()

        // Dual-scale cartographic coordinate grid with delicate registration ticks
        Canvas { context, bounds in
          let minorStep: CGFloat = 40
          let majorStep: CGFloat = 160
          var minor = Path()
          var major = Path()
          var ticks = Path()

          var x: CGFloat = 0
          var ix = 0
          while x <= bounds.width {
            if ix % 4 == 0 {
              major.move(to: CGPoint(x: x, y: 0))
              major.addLine(to: CGPoint(x: x, y: bounds.height))
            } else {
              minor.move(to: CGPoint(x: x, y: 0))
              minor.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            x += minorStep
            ix += 1
          }
          var y: CGFloat = 0
          var iy = 0
          while y <= bounds.height {
            if iy % 4 == 0 {
              major.move(to: CGPoint(x: 0, y: y))
              major.addLine(to: CGPoint(x: bounds.width, y: y))
            } else {
              minor.move(to: CGPoint(x: 0, y: y))
              minor.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            y += minorStep
            iy += 1
          }
          for gx in stride(from: majorStep, to: bounds.width, by: majorStep) {
            for gy in stride(from: majorStep, to: bounds.height, by: majorStep) {
              ticks.move(to: CGPoint(x: gx - 3, y: gy))
              ticks.addLine(to: CGPoint(x: gx + 3, y: gy))
              ticks.move(to: CGPoint(x: gx, y: gy - 3))
              ticks.addLine(to: CGPoint(x: gx, y: gy + 3))
            }
          }
          context.stroke(minor, with: .color(AtlasPalette.umber.opacity(0.048)), lineWidth: 0.5)
          context.stroke(major, with: .color(AtlasPalette.umber.opacity(0.095)), lineWidth: 0.65)
          context.stroke(ticks, with: .color(AtlasPalette.umber.opacity(0.18)), lineWidth: 0.75)
        }

        // Subtle warm parchment edge vignette for depth
        RadialGradient(
          colors: [.clear, .clear, AtlasPalette.umber.opacity(0.07)],
          center: .center,
          startRadius: min(size.width, size.height) * 0.30,
          endRadius: max(size.width, size.height) * 0.78
        )

        // Bespoke copperplate left coastline hugging ONLY the far-left negative margin
        AtlasArt.coastLeft
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(height: size.height)
          .blendMode(.multiply)
          .opacity(prominentTerrain ? 0.44 : 0.22)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .offset(x: -4)

        // Bespoke copperplate right coastline & clouds fading cleanly before the bottom-right mountain range
        AtlasArt.coastRight
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(height: size.height * 0.88)
          .blendMode(.multiply)
          .opacity(prominentTerrain ? 0.36 : 0.17)
          .mask(
            LinearGradient(
              stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.68),
                .init(color: .clear, location: 0.96),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .offset(x: 6)

        // Delicate cartographic folio double-hairline frame around the map sheet (no fake scale/cardinal labels)
        Canvas { context, bounds in
          let outer = CGRect(origin: .zero, size: bounds).insetBy(dx: 7, dy: 7)
          let inner = outer.insetBy(dx: 3.5, dy: 3.5)
          guard inner.width > 40, inner.height > 40 else { return }
          context.stroke(Path(outer), with: .color(AtlasPalette.umber.opacity(0.14)), lineWidth: 0.7)
          context.stroke(Path(inner), with: .color(AtlasPalette.umber.opacity(0.085)), lineWidth: 0.5)
          var ticks = Path()
          for x in stride(from: inner.minX + 80, to: inner.maxX - 40, by: 80) {
            ticks.move(to: CGPoint(x: x, y: outer.minY))
            ticks.addLine(to: CGPoint(x: x, y: inner.minY))
            ticks.move(to: CGPoint(x: x, y: inner.maxY))
            ticks.addLine(to: CGPoint(x: x, y: outer.maxY))
          }
          for y in stride(from: inner.minY + 80, to: inner.maxY - 40, by: 80) {
            ticks.move(to: CGPoint(x: outer.minX, y: y))
            ticks.addLine(to: CGPoint(x: inner.minX, y: y))
            ticks.move(to: CGPoint(x: inner.maxX, y: y))
            ticks.addLine(to: CGPoint(x: outer.maxX, y: y))
          }
          context.stroke(ticks, with: .color(AtlasPalette.umber.opacity(0.16)), lineWidth: 0.65)
        }

        // Bespoke copperplate mountain range in bottom-right negative space, fused via multiply onto parchment
        AtlasArt.mountains
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: min(prominentTerrain ? 760 : 620, size.width * (prominentTerrain ? 0.58 : 0.46)))
          .blendMode(.multiply)
          .opacity(prominentTerrain ? 0.62 : 0.34)
          .offset(x: 4, y: 4)
      }
      .frame(width: size.width, height: size.height)
      .clipped()
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct PaperSurface: ViewModifier {
  var cornerRadius: CGFloat = 12
  var elevated: Bool = false
  var historical: Bool = false

  func body(content: Content) -> some View {
    let outline = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content
      .background {
        ZStack {
          historical ? Color(red: 0.969, green: 0.945, blue: 0.898) : AtlasPalette.paper
          // Tactile rag-paper fiber grain — warm book-leaf feel while keeping typography crisp
          AtlasArt.paper
            .resizable(resizingMode: .tile)
            .opacity(historical ? 0.16 : 0.12)
          LinearGradient(
            colors: [.white.opacity(0.30), .clear, AtlasPalette.line.opacity(historical ? 0.10 : 0.065)],
            startPoint: .top,
            endPoint: .bottom
          )
        }
      }
      .clipShape(outline)
      .overlay {
        ZStack {
          outline.strokeBorder(
            historical
              ? AtlasPalette.umber.opacity(0.60)
              : Color(red: 0.690, green: 0.596, blue: 0.482).opacity(0.66),
            lineWidth: 0.95
          )
          outline.inset(by: 1).strokeBorder(.white.opacity(0.48), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
      }
      // PH-03 Palimpsest strata: a historical/pinned folio subtly reveals an earlier leaf beneath
      .background {
        if historical {
          ZStack {
            outline
              .fill(Color(red: 0.945, green: 0.914, blue: 0.855))
              .overlay { outline.strokeBorder(AtlasPalette.umber.opacity(0.34), lineWidth: 0.8) }
              .offset(x: 4, y: 4)
            outline
              .fill(Color(red: 0.965, green: 0.937, blue: 0.882))
              .overlay { outline.strokeBorder(AtlasPalette.umber.opacity(0.38), lineWidth: 0.8) }
              .offset(x: 2, y: 2)
          }
          .allowsHitTesting(false)
        }
      }
      .shadow(
        color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(elevated ? 0.14 : 0.08),
        radius: elevated ? 16 : 7,
        y: elevated ? 7 : 3
      )
      .shadow(
        color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.06),
        radius: 1.5,
        y: 1
      )
  }
}

struct PaperButton: ButtonStyle {
  var primary = false
  var compact = false
  func makeBody(configuration: Configuration) -> some View {
    BodyView(configuration: configuration, primary: primary, compact: compact)
  }
  private struct BodyView: View {
    let configuration: Configuration
    let primary: Bool
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    var body: some View {
      let bg: Color = {
        if primary {
          if configuration.isPressed { return AtlasPalette.blueInkHover }
          return hovering ? AtlasPalette.blueInkHover : AtlasPalette.blueInk
        } else {
          if configuration.isPressed { return AtlasPalette.paperHeader }
          return hovering ? AtlasPalette.paperHeader.opacity(0.85) : AtlasPalette.paper
        }
      }()
      configuration.label
        .font(.system(size: compact ? 12 : 13, weight: primary ? .medium : .regular))
        .lineLimit(1)
        .padding(.horizontal, compact ? 10 : 13)
        .frame(minHeight: compact ? 26 : 30)
        .foregroundStyle(primary ? Color(red: 0.988, green: 0.976, blue: 0.949) : AtlasPalette.ink)
        .background(bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
              primary
                ? Color.white.opacity(0.16)
                : AtlasPalette.line.opacity(hovering ? 0.85 : 0.62),
              lineWidth: 0.85
            )
        }
        .shadow(
          color: primary
            ? AtlasPalette.blueInk.opacity(enabled ? 0.22 : 0)
            : Color.brown.opacity(0.05),
          radius: primary ? 3 : 1,
          y: 1
        )
        .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.985 : 1)
        .opacity(!enabled ? 0.45 : (configuration.isPressed ? 0.92 : 1))
        .onHover { hovering = $0 }
        .animation(AtlasMotion.micro(reduceMotion), value: hovering)
        .animation(AtlasMotion.micro(reduceMotion), value: configuration.isPressed)
    }
  }
}

/// Refined translucent button for the deep indigo window top bar.
struct TopBarButtonStyle: ButtonStyle {
  var active = false
  func makeBody(configuration: Configuration) -> some View {
    BodyView(configuration: configuration, active: active)
  }
  private struct BodyView: View {
    let configuration: Configuration
    let active: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 12.5, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .foregroundStyle(Color(red: 0.955, green: 0.933, blue: 0.886))
        .background(
          Color.white.opacity(
            configuration.isPressed ? 0.18 : (active ? 0.16 : (hovering ? 0.13 : 0.08))
          ),
          in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
              Color.white.opacity(hovering || active ? 0.26 : 0.15),
              lineWidth: 0.8
            )
        }
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(AtlasMotion.micro(reduceMotion), value: hovering)
        .animation(AtlasMotion.micro(reduceMotion), value: configuration.isPressed)
    }
  }
}

/// Luminous parchment-toned button for the right side of the gradient atlas top bar.
struct TopBarLightButtonStyle: ButtonStyle {
  var active = false
  func makeBody(configuration: Configuration) -> some View {
    BodyView(configuration: configuration, active: active)
  }
  private struct BodyView: View {
    let configuration: Configuration
    let active: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 12.5, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .foregroundStyle(active ? AtlasPalette.blueInk : AtlasPalette.ink)
        .background(
          (active ? AtlasPalette.paper : AtlasPalette.barFill)
            .opacity(configuration.isPressed ? 0.98 : (hovering || active ? 0.96 : 0.84)),
          in: RoundedRectangle(cornerRadius: 7.5, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 7.5, style: .continuous)
            .strokeBorder(
              active
                ? AtlasPalette.blueInk.opacity(0.45)
                : AtlasPalette.line.opacity(hovering ? 0.88 : 0.62),
              lineWidth: 0.85
            )
        }
        .shadow(color: Color(red: 0.24, green: 0.18, blue: 0.11).opacity(0.06), radius: 2, y: 1)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(AtlasMotion.micro(reduceMotion), value: hovering)
        .animation(AtlasMotion.micro(reduceMotion), value: configuration.isPressed)
    }
  }
}

/// Editorial search capsule for the top bar inspired by archival map index fields.
struct TopBarSearchPillStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    BodyView(configuration: configuration)
  }
  private struct BodyView: View {
    let configuration: Configuration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    var body: some View {
      configuration.label
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(
          AtlasPalette.paper.opacity(configuration.isPressed ? 0.99 : (hovering ? 0.97 : 0.90)),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
              AtlasPalette.line.opacity(hovering ? 0.90 : 0.66),
              lineWidth: 0.85
            )
        }
        .shadow(color: Color(red: 0.24, green: 0.18, blue: 0.11).opacity(0.06), radius: 2.5, y: 1)
        .onHover { hovering = $0 }
        .animation(AtlasMotion.micro(reduceMotion), value: hovering)
    }
  }
}

/// Subtle ghost/chip button for floating canvas toolbars & card headers/footers.
struct AtlasChipButtonStyle: ButtonStyle {
  var emphasized = false
  func makeBody(configuration: Configuration) -> some View {
    BodyView(configuration: configuration, emphasized: emphasized)
  }
  private struct BodyView: View {
    let configuration: Configuration
    let emphasized: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 12, weight: emphasized ? .medium : .regular))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .foregroundStyle(
          emphasized
            ? AtlasPalette.blueInk
            : (hovering ? AtlasPalette.ink : AtlasPalette.ink.opacity(0.84))
        )
        .background(
          configuration.isPressed
            ? AtlasPalette.line.opacity(0.24)
            : (hovering ? AtlasPalette.line.opacity(0.15) : (emphasized ? AtlasPalette.blueInk.opacity(0.08) : .clear)),
          in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .opacity(enabled ? 1 : 0.42)
        .onHover { hovering = $0 }
        .animation(AtlasMotion.micro(reduceMotion), value: hovering)
        .animation(AtlasMotion.micro(reduceMotion), value: configuration.isPressed)
    }
  }
}

/// Custom ButtonStyle for `.menuStyle(.button)` — renders full SwiftUI labels with crisp right-aligned chevrons
/// and completely eliminates macOS Aqua blue popup pills and NSPopUpButton foreground-stripping bugs.
struct AtlasMenuButtonStyle: ButtonStyle {
  var dark: Bool = false
  var compact: Bool = true
  var capsule: Bool = false
  var borderColor: Color? = nil

  func makeBody(configuration: Configuration) -> some View {
    BodyView(
      configuration: configuration,
      dark: dark,
      compact: compact,
      capsule: capsule,
      borderColor: borderColor
    )
  }

  private struct BodyView: View {
    let configuration: Configuration
    let dark: Bool
    let compact: Bool
    let capsule: Bool
    let borderColor: Color?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    var body: some View {
      let radius: CGFloat = capsule ? 999 : 6.5
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
      HStack(spacing: 5) {
        configuration.label
        Image(systemName: "chevron.down")
          .font(.system(size: 8.5, weight: .semibold))
          .foregroundStyle(dark ? Color.white.opacity(0.66) : AtlasPalette.umber.opacity(0.8))
      }
      .font(.system(size: compact ? 12 : 12.5, weight: .medium))
      .lineLimit(1)
      .padding(.horizontal, compact ? 9 : 11)
      .frame(height: compact ? 24 : 28)
      .foregroundStyle(dark ? Color(red: 0.955, green: 0.933, blue: 0.886) : AtlasPalette.ink)
      .background(
        dark
          ? Color.white.opacity(configuration.isPressed ? 0.18 : (hovering ? 0.14 : 0.085))
          : (configuration.isPressed
            ? AtlasPalette.paperHeader
            : (hovering ? AtlasPalette.paperHeader.opacity(0.88) : AtlasPalette.paper.opacity(0.95))),
        in: shape
      )
      .overlay {
        shape.strokeBorder(
          borderColor
            ?? (dark
              ? Color.white.opacity(hovering ? 0.28 : 0.16)
              : AtlasPalette.line.opacity(hovering ? 0.82 : 0.55)),
          lineWidth: 0.85
        )
      }
      .shadow(color: dark ? .clear : Color.brown.opacity(capsule ? 0.11 : 0.04), radius: capsule ? 4 : 1, y: capsule ? 1.5 : 0.5)
      .opacity(enabled ? 1 : 0.45)
      .onHover { hovering = $0 }
      .animation(AtlasMotion.micro(reduceMotion), value: hovering)
      .animation(AtlasMotion.micro(reduceMotion), value: configuration.isPressed)
    }
  }
}

/// Clean plain-text preview helper for collapsed/overview cards (removes raw Markdown syntax).
func cleanMarkdownPreview(_ raw: String) -> String {
  raw
    .replacingOccurrences(of: "**", with: "")
    .replacingOccurrences(of: "__", with: "")
    .replacingOccurrences(of: "`", with: "")
    .replacingOccurrences(of: "### ", with: "")
    .replacingOccurrences(of: "## ", with: "")
    .replacingOccurrences(of: "# ", with: "")
}

/// Warm archival pill label retained for any standalone icon+title menu label content.
struct AtlasMenuPillLabel: View {
  let title: String
  var icon: String? = nil
  var compact: Bool = true
  var dark: Bool = false

  var body: some View {
    HStack(spacing: 5) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: compact ? 11 : 12, weight: .medium))
          .foregroundStyle(dark ? AtlasPalette.gold : AtlasPalette.umber)
      }
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

/// Subtle warm-parchment floating bar surface replacing cold gray `.regularMaterial`.
struct AtlasFloatingBarModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
      .background(
        AtlasPalette.barFill.opacity(0.95),
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(AtlasPalette.line.opacity(0.52), lineWidth: 0.85)
      }
      .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.11), radius: 8, y: 3)
      .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.05), radius: 1.5, y: 1)
  }
}

/// Editorial document/card kind stamp.
struct AtlasKindBadge: View {
  enum Kind {
    case question, followup, pdf, markdown, idea, material
  }
  let kind: Kind

  var body: some View {
    HStack(spacing: 4) {
      switch kind {
      case .pdf:
        Text("PDF")
          .font(.system(size: 9.5, weight: .bold, design: .serif))
          .foregroundStyle(.white)
          .padding(.horizontal, 5.5)
          .padding(.vertical, 2)
          .background(AtlasPalette.terracotta, in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
      case .markdown:
        Text("MD")
          .font(.system(size: 9.5, weight: .bold, design: .monospaced))
          .foregroundStyle(AtlasPalette.blueInk)
          .padding(.horizontal, 5)
          .padding(.vertical, 1.5)
          .background(AtlasPalette.blueInk.opacity(0.10), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
              .strokeBorder(AtlasPalette.blueInk.opacity(0.32), lineWidth: 0.7)
          }
      case .question:
        HStack(spacing: 3.5) {
          AtlasArt.compass
            .resizable()
            .scaledToFit()
            .frame(width: 11, height: 11)
          Text("问题")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(AtlasPalette.umber)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AtlasPalette.gold.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      case .followup:
        HStack(spacing: 3.5) {
          Image(systemName: "arrow.turn.down.right")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(AtlasPalette.blueInk)
          Text("追问")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(AtlasPalette.blueInk)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AtlasPalette.blueInk.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      case .idea:
        Text("灵感")
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(AtlasPalette.sage)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(AtlasPalette.sage.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      case .material:
        Text("资料")
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(AtlasPalette.umber)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(AtlasPalette.line.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      }
    }
  }
}

/// Compact badge showing a shared text living across multiple inquiries (PH-02).
struct AtlasSharedFolioBadge: View {
  let count: Int
  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "rectangle.on.rectangle")
        .font(.system(size: 9, weight: .medium))
      Text("共读 · " + String(count) + " 处")
        .font(.system(size: 10.5, weight: .medium))
    }
    .foregroundStyle(AtlasPalette.blueInk)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(AtlasPalette.blueInk.opacity(0.08), in: Capsule())
    .overlay { Capsule().strokeBorder(AtlasPalette.blueInk.opacity(0.22), lineWidth: 0.65) }
  }
}

/// Editorial recessed quote callout for source excerpts.
struct AtlasQuoteCallout: View {
  let text: String
  var clickable: Bool = false

  var body: some View {
    HStack(spacing: 6) {
      Text(text)
        .font(.system(size: 12.5, design: .serif))
        .foregroundStyle(AtlasPalette.umber)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      if clickable {
        Image(systemName: "arrow.uturn.backward")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(AtlasPalette.umber.opacity(0.7))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(AtlasPalette.paperInset.opacity(0.82), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(AtlasPalette.gold)
        .frame(width: 2.5)
        .padding(.vertical, 4)
        .padding(.leading, 3)
    }
  }
}

/// Integrates the macOS traffic lights seamlessly into the deep indigo top bar.
struct AtlasWindowChrome: NSViewRepresentable {
  final class ChromeHook: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.styleMask.insert(.fullSizeContentView)
      window.isMovableByWindowBackground = false
      window.backgroundColor = NSColor(red: 0.106, green: 0.153, blue: 0.208, alpha: 1)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  func makeNSView(context: Context) -> ChromeHook { ChromeHook() }
  func updateNSView(_ nsView: ChromeHook, context: Context) {}
}

/// Lets users drag the window from empty space in the integrated top bar.
struct AtlasTitlebarDragArea: NSViewRepresentable {
  final class DragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
      guard let window, !window.styleMask.contains(.fullScreen) else { return }
      if event.clickCount == 2 {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
      } else {
        window.performDrag(with: event)
      }
    }
  }
  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ nsView: DragView, context: Context) {}
}

extension View {
  func paperSheet(cornerRadius: CGFloat = 12, elevated: Bool = false, historical: Bool = false) -> some View {
    modifier(PaperSurface(cornerRadius: cornerRadius, elevated: elevated, historical: historical))
  }
  func atlasFloatingBar() -> some View {
    modifier(AtlasFloatingBarModifier())
  }
}

struct PaperRule: View {
  var body: some View {
    Rectangle().fill(AtlasPalette.line.opacity(0.32)).frame(height: 0.75)
  }
}
