import AtlasCore
import SwiftUI

/// Live in-canvas visual joint Diff state for AI/manual organization proposals (P1-A).
struct CanvasOrganizationPreview: Equatable {
  let plan: OrganizationPlan
  var selectedEditIDs: Set<String>
  var showingAfter: Bool = true
  var focusedEditID: String? = nil

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.plan.id == rhs.plan.id
      && lhs.selectedEditIDs == rhs.selectedEditIDs
      && lhs.showingAfter == rhs.showingAfter
      && lhs.focusedEditID == rhs.focusedEditID
  }

  var activeEdits: [OrganizationEdit] {
    plan.edits.filter { selectedEditIDs.contains($0.id) }
  }

  /// Screen-space offset for an entry when previewing proposed layout moves.
  func offset(for entry: MapEntry, zoom: Double) -> CGSize {
    guard showingAfter,
      let move = activeEdits.first(where: { $0.action == .move && $0.target == entry.id }),
      let x = move.x, let y = move.y
    else { return .zero }
    return CGSize(width: (x - entry.x) * zoom, height: (y - entry.y) * zoom)
  }

  func isMarkedForRemoval(_ entryID: String) -> Bool {
    guard showingAfter else { return false }
    return activeEdits.contains { $0.action == .removeEntrance && $0.target == entryID }
  }

  func hasRewriteProposal(_ entryID: String) -> Bool {
    guard showingAfter else { return false }
    return activeEdits.contains { $0.action == .rewrite && $0.target == entryID }
  }

  struct SummaryCounts: Equatable {
    let moves: Int
    let relations: Int
    let additions: Int
    let removals: Int
    let rewrites: Int

    var summaryText: String {
      var parts: [String] = []
      if moves > 0 { parts.append("移动 \(moves)") }
      if relations > 0 { parts.append("关系 \(relations)") }
      if additions > 0 { parts.append("新入口 \(additions)") }
      if removals > 0 { parts.append("移出 \(removals)") }
      if rewrites > 0 { parts.append("修订 \(rewrites)") }
      return parts.isEmpty ? "未勾选修改" : parts.joined(separator: " · ")
    }
  }

  var counts: SummaryCounts {
    var moves = 0, relations = 0, additions = 0, removals = 0, rewrites = 0
    for edit in activeEdits {
      switch edit.action {
      case .move: moves += 1
      case .relate: relations += 1
      case .addEntrance: additions += 1
      case .removeEntrance: removals += 1
      case .rewrite: rewrites += 1
      }
    }
    return SummaryCounts(moves: moves, relations: relations, additions: additions, removals: removals, rewrites: rewrites)
  }

  /// Bounding rect in world coordinates covering all affected originals and proposed destinations.
  func worldBounds(entries: [MapEntry], entrySize: (MapEntry) -> CGSize) -> CGRect {
    let affected = Set(plan.edits.flatMap { [$0.target, $0.peer].compactMap { $0 } })
    var bounds = CGRect.null
    for entry in entries where affected.contains(entry.id) {
      let sz = entrySize(entry)
      bounds = bounds.union(CGRect(origin: CGPoint(x: entry.x, y: entry.y), size: sz))
    }
    for edit in plan.edits {
      if let x = edit.x, let y = edit.y {
        bounds = bounds.union(CGRect(x: x, y: y, width: 280, height: 150))
      }
    }
    return bounds
  }
}

/// Live in-canvas visual joint Diff layer:
/// - Ghost origin footprints + curved dashed movement trajectories for `.move`
/// - Luminous brass-gold dashed arcs + floating relation pills for `.relate`
/// - Translucent ghost cards for `.addEntrance`
/// - Soft terracotta archival outlines for `.removeEntrance`
struct CanvasOrganizationOverlay: View {
  let preview: CanvasOrganizationPreview
  let entries: [MapEntry]
  let zoom: Double
  let origin: CGPoint
  let frameForEntry: (MapEntry) -> CGRect
  let onFocusEdit: (String) -> Void

  private func displayedRect(for entry: MapEntry) -> CGRect {
    let base = frameForEntry(entry)
    let delta = preview.offset(for: entry, zoom: zoom)
    return base.offsetBy(dx: delta.width, dy: delta.height)
  }

  private func project(_ worldPoint: CGPoint) -> CGPoint {
    CGPoint(x: origin.x + worldPoint.x * zoom, y: origin.y + worldPoint.y * zoom)
  }

  /// Intersects a ray from `rect`'s center toward `target` with `rect`'s perimeter so
  /// arcs and arrows anchor cleanly at card edges without crossing card text.
  private func edgeAnchor(of rect: CGRect, toward target: CGPoint, inset: CGFloat = -2) -> CGPoint {
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

  private struct RelationBadge: Identifiable {
    let id: String
    let label: String
    let point: CGPoint
    let focused: Bool
  }

  private struct GhostAddition: Identifiable {
    let id: String
    let title: String
    let regionTitle: String?
    let rect: CGRect
    let focused: Bool
  }

  var body: some View {
    if preview.showingAfter {
      let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
      let edits = preview.activeEdits

      let relationBadges: [RelationBadge] = edits.compactMap { edit in
        guard edit.action == .relate,
          let peerID = edit.peer,
          let from = entryMap[edit.target],
          let to = entryMap[peerID]
        else { return nil }
        let a = displayedRect(for: from), b = displayedRect(for: to)
        let p = edgeAnchor(of: a, toward: CGPoint(x: b.midX, y: b.midY))
        let q = edgeAnchor(of: b, toward: CGPoint(x: a.midX, y: a.midY))
        let dist = hypot(q.x - p.x, q.y - p.y)
        let lift = min(34, max(14, dist * 0.16))
        let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 - lift * 0.5)
        let label = MapRelation(rawValue: edit.relation ?? "")?.label ?? "新关系"
        return RelationBadge(id: edit.id, label: label, point: mid, focused: preview.focusedEditID == edit.id)
      }

      let additions: [GhostAddition] = edits.compactMap { edit in
        guard edit.action == .addEntrance, let source = entryMap[edit.target] else { return nil }
        let wx = edit.x ?? (source.x + 288)
        let wy = edit.y ?? (source.y + 144)
        let screenOrigin = project(CGPoint(x: wx, y: wy))
        let w = max(160, 250 * zoom)
        let h = max(78, 118 * zoom)
        let title = preview.plan.scope.objects.first { $0.id == edit.target }?.title ?? "共享入口"
        let regionTitle = edit.region.flatMap { id in preview.plan.scope.regions.first { $0.id == id }?.title }
        return GhostAddition(
          id: edit.id,
          title: title,
          regionTitle: regionTitle,
          rect: CGRect(origin: screenOrigin, size: CGSize(width: w, height: h)),
          focused: preview.focusedEditID == edit.id
        )
      }

      ZStack(alignment: .topLeading) {
        Canvas { context, _ in
          // 1. Movement origin ghosts + curved trajectories (anchored to destination card edge)
          for edit in edits where edit.action == .move {
            guard let entry = entryMap[edit.target] else { continue }
            let startRect = frameForEntry(entry)
            let endRect = displayedRect(for: entry)
            guard hypot(endRect.midX - startRect.midX, endRect.midY - startRect.midY) > 2 else { continue }
            let isFocused = preview.focusedEditID == edit.id

            // Ghost origin box (clips behind the destination card so card text stays 100% crisp)
            context.drawLayer { layer in
              layer.clip(to: Path(roundedRect: endRect.insetBy(dx: -1, dy: -1), cornerRadius: 11), options: .inverse)
              let ghostPath = Path(roundedRect: startRect, cornerRadius: 11)
              layer.fill(ghostPath, with: .color(AtlasPalette.umber.opacity(isFocused ? 0.08 : 0.045)))
              layer.stroke(
                ghostPath,
                with: .color(AtlasPalette.umber.opacity(isFocused ? 0.62 : 0.40)),
                style: StrokeStyle(lineWidth: isFocused ? 1.4 : 1.0, lineCap: .round, dash: [5, 4])
              )
            }

            // Curved dashed trajectory arc from origin center to destination card edge
            let p = CGPoint(x: startRect.midX, y: startRect.midY)
            let q = edgeAnchor(of: endRect, toward: p, inset: -4)
            let dist = hypot(q.x - p.x, q.y - p.y)
            guard dist > 8 else { continue }
            let lift = min(28, dist * 0.16)
            let ctrl = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 - lift)
            var arc = Path()
            arc.move(to: p)
            arc.addQuadCurve(to: q, control: ctrl)
            context.stroke(
              arc,
              with: .color(AtlasPalette.umber.opacity(isFocused ? 0.85 : 0.56)),
              style: StrokeStyle(lineWidth: isFocused ? 1.9 : 1.4, lineCap: .round, dash: [4, 4])
            )

            // Origin dot & destination arrowhead right outside the moved card border
            let originDot = Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            context.fill(originDot, with: .color(AtlasPalette.paper))
            context.stroke(originDot, with: .color(AtlasPalette.umber.opacity(0.78)), lineWidth: 1.3)

            let angle = atan2(q.y - ctrl.y, q.x - ctrl.x)
            var tip = Path()
            tip.move(to: CGPoint(x: q.x - cos(angle - 0.45) * 8.5, y: q.y - sin(angle - 0.45) * 8.5))
            tip.addLine(to: q)
            tip.addLine(to: CGPoint(x: q.x - cos(angle + 0.45) * 8.5, y: q.y - sin(angle + 0.45) * 8.5))
            context.stroke(tip, with: .color(AtlasPalette.umber.opacity(isFocused ? 0.90 : 0.68)), lineWidth: 1.6)
          }

          // 2. Proposed semantic relations (edge-anchored luminous brass-gold curved arcs)
          for edit in edits where edit.action == .relate {
            guard let peerID = edit.peer,
              let from = entryMap[edit.target],
              let to = entryMap[peerID]
            else { continue }
            let a = displayedRect(for: from), b = displayedRect(for: to)
            let p = edgeAnchor(of: a, toward: CGPoint(x: b.midX, y: b.midY))
            let q = edgeAnchor(of: b, toward: CGPoint(x: a.midX, y: a.midY))
            let dist = hypot(q.x - p.x, q.y - p.y)
            let lift = min(34, max(14, dist * 0.16))
            let ctrl = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 - lift)
            let isFocused = preview.focusedEditID == edit.id
            let relation = MapRelation(rawValue: edit.relation ?? "")

            var arc = Path()
            arc.move(to: p)
            arc.addQuadCurve(to: q, control: ctrl)
            // Soft golden glow understroke
            context.stroke(
              arc,
              with: .color(AtlasPalette.gold.opacity(isFocused ? 0.34 : 0.22)),
              style: StrokeStyle(lineWidth: isFocused ? 5.6 : 4.0, lineCap: .round)
            )
            // Crisp dashed brass-gold primary stroke
            context.stroke(
              arc,
              with: .color(AtlasPalette.gold.opacity(isFocused ? 0.98 : 0.88)),
              style: StrokeStyle(lineWidth: isFocused ? 2.1 : 1.7, lineCap: .round, dash: [6, 4])
            )

            // Endpoint markers (directed arrowhead vs undirected symmetric open rings)
            let startRing = Path(ellipseIn: CGRect(x: p.x - 3.8, y: p.y - 3.8, width: 7.6, height: 7.6))
            context.fill(startRing, with: .color(AtlasPalette.paper))
            context.stroke(startRing, with: .color(AtlasPalette.gold), lineWidth: 1.6)

            if relation?.directed == true {
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

          // 3. Removal terracotta dashed frames
          for edit in edits where edit.action == .removeEntrance {
            guard let entry = entryMap[edit.target] else { continue }
            let rect = displayedRect(for: entry)
            let border = Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 12)
            context.stroke(
              border,
              with: .color(AtlasPalette.terracotta.opacity(0.75)),
              style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [5, 4])
            )
          }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)

        // Ghost cards for newly proposed shared entrances
        ForEach(additions) { ghost in
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
              Image(systemName: "plus.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(AtlasPalette.blueInk)
              Text(ghost.regionTitle.map { "新入口 · " + $0 } ?? "新增共享入口")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AtlasPalette.blueInk)
            }
            Text(ghost.title)
              .font(AtlasTypeface.reading.font(13.5).weight(.medium))
              .foregroundStyle(AtlasPalette.ink)
              .lineLimit(2)
          }
          .padding(10)
          .frame(width: ghost.rect.width, height: ghost.rect.height, alignment: .topLeading)
          .background(AtlasPalette.paper.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .stroke(
                AtlasPalette.blueInk.opacity(ghost.focused ? 0.92 : 0.62),
                style: StrokeStyle(lineWidth: ghost.focused ? 1.8 : 1.25, dash: [5, 4])
              )
          }
          .shadow(color: AtlasPalette.blueInk.opacity(0.10), radius: 6, y: 2)
          .offset(x: ghost.rect.minX, y: ghost.rect.minY)
          .onTapGesture { onFocusEdit(ghost.id) }
        }

        // Interactive midpoint pills for proposed semantic relations
        ForEach(relationBadges) { badge in
          HStack(spacing: 4) {
            Image(systemName: "sparkles")
              .font(.system(size: 9.5, weight: .semibold))
              .foregroundStyle(badge.focused ? Color.white : AtlasPalette.gold)
            Text("新关系 · " + badge.label)
              .font(AtlasTypeface.reading.font(12).weight(.medium))
              .foregroundStyle(badge.focused ? Color.white : AtlasPalette.ink)
          }
          .fixedSize()
          .padding(.horizontal, 10)
          .padding(.vertical, 4.5)
          .background {
            Capsule(style: .continuous)
              .fill(badge.focused ? AtlasPalette.blueInk : AtlasPalette.paper.opacity(0.97))
          }
          .overlay {
            if !badge.focused {
              Capsule(style: .continuous)
                .stroke(AtlasPalette.gold.opacity(0.82), lineWidth: 1.0)
            }
          }
          .contentShape(Capsule(style: .continuous))
          .shadow(color: Color(red: 0.22, green: 0.17, blue: 0.11).opacity(0.14), radius: 5, y: 2)
          .onTapGesture { onFocusEdit(badge.id) }
          .accessibilityAddTraits(.isButton)
          .position(badge.point)
        }
      }
    }
  }
}

/// Floating archival Diff control dock anchored at the bottom of the canvas during live joint Diff preview.
struct CanvasOrganizationControlBar: View {
  @Binding var preview: CanvasOrganizationPreview
  let onReturnToDesk: () -> Void
  let onAbandon: () -> Void
  let onApply: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var showDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showDetails {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("逐项勾选修改明细")
              .font(AtlasTypeface.reading.font(13.5).weight(.medium))
              .foregroundStyle(AtlasPalette.ink)
            Spacer()
            Button(preview.selectedEditIDs.count == preview.plan.edits.count ? "全部取消" : "全选") {
              withAnimation(AtlasMotion.layout(reduceMotion)) {
                if preview.selectedEditIDs.count == preview.plan.edits.count {
                  preview.selectedEditIDs.removeAll()
                } else {
                  preview.selectedEditIDs = Set(preview.plan.edits.map(\.id))
                }
              }
            }
            .buttonStyle(AtlasChipButtonStyle(emphasized: true))
          }
          ScrollView {
            VStack(alignment: .leading, spacing: 5) {
              ForEach(preview.plan.edits) { edit in
                let checked = preview.selectedEditIDs.contains(edit.id)
                let focused = preview.focusedEditID == edit.id
                let targetTitle = preview.plan.scope.objects.first { $0.id == edit.target }?.title ?? "入口"
                HStack(alignment: .top, spacing: 8) {
                  Toggle("", isOn: Binding(
                    get: { checked },
                    set: { on in
                      withAnimation(AtlasMotion.layout(reduceMotion)) {
                        if on { preview.selectedEditIDs.insert(edit.id) }
                        else { preview.selectedEditIDs.remove(edit.id) }
                      }
                    }
                  ))
                  .labelsHidden()
                  .toggleStyle(.checkbox)
                  .padding(.top, 2)
                  Button {
                    withAnimation(AtlasMotion.micro(reduceMotion)) {
                      preview.focusedEditID = focused ? nil : edit.id
                    }
                  } label: {
                    VStack(alignment: .leading, spacing: 2) {
                      HStack(spacing: 6) {
                        Text(edit.action.label)
                          .font(.system(size: 10.5, weight: .semibold))
                          .foregroundStyle(edit.action == .relate ? AtlasPalette.umber : AtlasPalette.blueInk)
                          .padding(.horizontal, 5.5)
                          .padding(.vertical, 1.5)
                          .background(
                            (edit.action == .relate ? AtlasPalette.gold : AtlasPalette.blueInk).opacity(0.12),
                            in: Capsule()
                          )
                        Text(targetTitle)
                          .font(AtlasTypeface.reading.font(13).weight(.medium))
                          .foregroundStyle(AtlasPalette.ink)
                          .lineLimit(1)
                      }
                      if !edit.reason.isEmpty {
                        Text(edit.reason)
                          .font(.system(size: 11.5))
                          .foregroundStyle(AtlasPalette.umber)
                          .lineLimit(2)
                      }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                  focused ? AtlasPalette.gold.opacity(0.14) : AtlasPalette.paperInset.opacity(0.55),
                  in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? AtlasPalette.gold.opacity(0.7) : AtlasPalette.line.opacity(0.32), lineWidth: 0.75)
                }
              }
            }
          }
          .frame(maxHeight: 190)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        PaperRule()
      }

      HStack(spacing: 10) {
        TaskCompanion(pose: .discovery, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(preview.plan.summary.isEmpty ? "画布整理对照预览" : preview.plan.summary)
            .font(AtlasTypeface.reading.font(14).weight(.medium))
            .foregroundStyle(AtlasPalette.ink)
            .lineLimit(1)
          Text(preview.counts.summaryText)
            .font(.system(size: 11.5))
            .foregroundStyle(AtlasPalette.umber)
        }
        Spacer(minLength: 8)
        HStack(spacing: 3) {
          Button("整理前") {
            withAnimation(AtlasMotion.layout(reduceMotion)) { preview.showingAfter = false }
          }
          .buttonStyle(PaperButton(primary: !preview.showingAfter, compact: true))
          Button("提案效果") {
            withAnimation(AtlasMotion.layout(reduceMotion)) { preview.showingAfter = true }
          }
          .buttonStyle(PaperButton(primary: preview.showingAfter, compact: true))
        }
        Button {
          withAnimation(AtlasMotion.surface(reduceMotion)) { showDetails.toggle() }
        } label: {
          Label("明细 (\(preview.selectedEditIDs.count)/\(preview.plan.edits.count))",
                systemImage: showDetails ? "chevron.down" : "chevron.up")
        }
        .buttonStyle(AtlasChipButtonStyle(emphasized: showDetails))

        Rectangle().fill(AtlasPalette.line.opacity(0.38)).frame(width: 0.75, height: 18)

        Button("整理面板", action: onReturnToDesk)
          .buttonStyle(AtlasChipButtonStyle())
        Button("放弃", action: onAbandon)
          .buttonStyle(PaperButton(compact: true))
        Button("应用选中修改", action: onApply)
          .buttonStyle(PaperButton(primary: true, compact: true))
          .disabled(preview.selectedEditIDs.isEmpty)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .frame(maxWidth: 780)
    .paperSheet(cornerRadius: 13, elevated: true)
  }
}
