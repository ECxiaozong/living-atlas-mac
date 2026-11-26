import AppKit
import SwiftUI

/// Centralized, restrained motion tokens and accessibility-first helpers for Living Atlas.
/// Every animation is short (110–240ms), interruptible, and degrades gracefully under Reduce Motion.
enum AtlasMotion {
  static func micro(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.12)
  }

  static func surface(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.17)
  }

  static func layout(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.19)
  }

  static func companion(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeInOut(duration: 0.20)
  }

  static func echo(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.34)
  }

  static func surfaceTransition(_ reduceMotion: Bool, offsetY: CGFloat = 5) -> AnyTransition {
    if reduceMotion { return .opacity }
    return .opacity.combined(with: .offset(y: offsetY))
  }

  /// Cubic ease-out interpolation curve: brisk start, calm settled arrival with zero bounce.
  static func easeOutCubic(_ t: Double) -> Double {
    let clamped = min(1, max(0, t))
    let inv = 1 - clamped
    return 1 - inv * inv * inv
  }
}

/// Snapshot of camera coordinates used by interruptible glides.
struct CameraPose: Equatable {
  var x: Double
  var y: Double
  var zoom: Double

  static func composerWidth(in pane: CGSize) -> CGFloat { min(392, max(260, pane.width - 24)) }

  /// The question editor has a fixed screen size even when its world anchor is zoomed.
  /// Keep the current framing whenever possible and otherwise pan only the missing distance.
  func revealingComposer(at anchor: CGPoint, in pane: CGSize, height: CGFloat, zoom nextZoom: Double) -> CameraPose {
    revealing(at: anchor, size: CGSize(width: Self.composerWidth(in: pane), height: height),
      within: CGRect(x: 12, y: 12, width: max(0, pane.width - 24), height: max(0, pane.height - 64)), zoom: nextZoom)
  }

  func revealing(at anchor: CGPoint, size: CGSize, within safe: CGRect, zoom nextZoom: Double) -> CameraPose {
    let right = max(safe.minX, safe.maxX - size.width)
    let bottom = max(safe.minY, safe.maxY - size.height)
    let screenX = min(right, max(safe.minX, x + anchor.x * zoom))
    let screenY = min(bottom, max(safe.minY, y + anchor.y * zoom))
    return CameraPose(x: screenX - anchor.x * nextZoom, y: screenY - anchor.y * nextZoom, zoom: nextZoom)
  }
}

/// Interruptible 60fps camera interpolator for user-initiated canvas jumps (return to origin,
/// overview toggle, fit-all, directory locate). Any user scroll, pinch, or drag cancels it
/// synchronously on the main actor so the user always owns the viewport.
@MainActor final class CanvasCameraGlide {
  private var timer: Timer?
  private var startTime: TimeInterval = 0
  private var duration: TimeInterval = 0.21
  private var from = CameraPose(x: 0, y: 0, zoom: 1)
  private var to = CameraPose(x: 0, y: 0, zoom: 1)
  private var onStep: ((CameraPose) -> Void)?
  private var onFinish: (() -> Void)?

  var isRunning: Bool { timer != nil }

  func glide(
    from start: CameraPose,
    to target: CameraPose,
    duration: TimeInterval = 0.21,
    reduceMotion: Bool,
    step: @escaping (CameraPose) -> Void,
    finish: (() -> Void)? = nil
  ) {
    cancel()
    let deltaPos = hypot(target.x - start.x, target.y - start.y)
    let deltaZoom = abs(target.zoom - start.zoom)
    if reduceMotion || duration <= 0 || (deltaPos < 2 && deltaZoom < 0.005) {
      step(target)
      finish?()
      return
    }
    self.from = start
    self.to = target
    self.duration = duration
    self.startTime = ProcessInfo.processInfo.systemUptime
    self.onStep = step
    self.onFinish = finish

    let frameTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.tick() }
    }
    RunLoop.main.add(frameTimer, forMode: .common)
    timer = frameTimer
  }

  func cancel() {
    timer?.invalidate()
    timer = nil
    onStep = nil
    onFinish = nil
  }

  /// Pure interpolation step for deterministic testing and frame updates.
  static func interpolate(from: CameraPose, to: CameraPose, progress: Double) -> CameraPose {
    let e = AtlasMotion.easeOutCubic(progress)
    return CameraPose(
      x: from.x + (to.x - from.x) * e,
      y: from.y + (to.y - from.y) * e,
      zoom: from.zoom + (to.zoom - from.zoom) * e
    )
  }

  private func tick() {
    let elapsed = ProcessInfo.processInfo.systemUptime - startTime
    let progress = min(1, max(0, elapsed / duration))
    let pose = Self.interpolate(from: from, to: to, progress: progress)
    let stepHandler = onStep
    if progress >= 1 {
      let finishHandler = onFinish
      cancel()
      stepHandler?(to)
      finishHandler?()
    } else {
      stepHandler?(pose)
    }
  }
}

/// Delicate 2x3 archival dot-matrix grip for moving canvas cards and PDF pages.
/// Quiet at rest; brightens cleanly into Prussian slate when hovered or selected.
struct AtlasGripIcon: View {
  let prominent: Bool
  var scale: CGFloat = 1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let dot = max(1.8, 2.2 * scale)
    let spacing = max(1.7, 2.2 * scale)
    VStack(spacing: spacing) {
      ForEach(0..<3, id: \.self) { _ in
        HStack(spacing: spacing) {
          Circle().frame(width: dot, height: dot)
          Circle().frame(width: dot, height: dot)
        }
      }
    }
    .foregroundStyle(prominent ? AtlasPalette.blueInk.opacity(0.88) : AtlasPalette.umber.opacity(0.36))
    .padding(.horizontal, 1.5)
    .padding(.vertical, 1)
    .animation(AtlasMotion.micro(reduceMotion), value: prominent)
    .accessibilityHidden(true)
  }
}

/// Calm, low-amplitude opacity breath for active streaming indicators (never bounces or loops under Reduce Motion).
struct AtlasWorkingBreath: ViewModifier {
  var active: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var dimmed = false

  func body(content: Content) -> some View {
    content
      .opacity(active && !reduceMotion && dimmed ? 0.42 : 1.0)
      .onAppear { startIfNeeded() }
      .onChange(of: active) { _, _ in startIfNeeded() }
      .onChange(of: reduceMotion) { _, _ in startIfNeeded() }
  }

  private func startIfNeeded() {
    guard active && !reduceMotion else {
      dimmed = false
      return
    }
    dimmed = false
    withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
      dimmed = true
    }
  }
}

/// Single-shot warm brass-gold arrival halo shown briefly when returning to a source or locating a card.
/// Emits no overlay view when inactive so embedded AppKit views (WKWebView / PDFView) keep direct hit-testing.
struct AtlasArrivalHalo: ViewModifier {
  let active: Bool
  var cornerRadius: CGFloat = 12
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.overlay {
      if active {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(AtlasPalette.gold.opacity(0.88), lineWidth: 2.2)
          .shadow(color: AtlasPalette.gold.opacity(0.36), radius: 10)
          .transition(.opacity)
      }
    }
    .animation(AtlasMotion.echo(reduceMotion), value: active)
  }
}

extension View {
  func atlasWorkingBreath(active: Bool) -> some View {
    modifier(AtlasWorkingBreath(active: active))
  }

  func atlasArrivalHalo(active: Bool, cornerRadius: CGFloat = 12) -> some View {
    modifier(AtlasArrivalHalo(active: active, cornerRadius: cornerRadius))
  }
}

/// Window-fixed cartographic compass button for the canvas navigation bar (Principle 6).
/// When the user pans away from all canvas content, a delicate brass pointer turns toward the
/// content centroid; clicking glides smoothly back to fit the map (`⌘0`).
struct AtlasHomingCompass: View {
  /// Angle in radians pointing from viewport center to off-screen content centroid, or nil if content is in view.
  let offscreenAngle: Double?
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var hovering = false

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(offscreenAngle != nil ? AtlasPalette.gold.opacity(hovering ? 0.24 : 0.16) : (hovering ? AtlasPalette.line.opacity(0.16) : .clear))
          .frame(width: 24, height: 24)
        Circle()
          .strokeBorder(
            offscreenAngle != nil ? AtlasPalette.gold.opacity(0.75) : AtlasPalette.line.opacity(hovering ? 0.65 : 0.32),
            lineWidth: offscreenAngle != nil ? 1.0 : 0.75
          )
          .frame(width: 24, height: 24)
        AtlasArt.compass
          .resizable()
          .scaledToFit()
          .frame(width: 13, height: 13)
          .opacity(offscreenAngle != nil ? 0.96 : 0.78)
        if let angle = offscreenAngle {
          Image(systemName: "arrowtriangle.up.fill")
            .font(.system(size: 5.5))
            .foregroundStyle(AtlasPalette.blueInk)
            .offset(y: -11)
            .rotationEffect(.radians(angle + .pi / 2))
            .animation(AtlasMotion.micro(reduceMotion), value: angle)
        }
      }
      .frame(width: 24, height: 24)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(AtlasMotion.micro(reduceMotion), value: hovering)
    .animation(AtlasMotion.micro(reduceMotion), value: offscreenAngle != nil)
    .accessibilityLabel(offscreenAngle != nil ? "回到图谱内容方向" : "适合全图")
    .help(offscreenAngle != nil ? "图谱内容在指针方向 · 点击平滑回到全图 (⌘0)" : "适合全图 (⌘0)")
  }
}
