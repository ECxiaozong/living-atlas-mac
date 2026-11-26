import AtlasCore
import SwiftUI

struct RelationEntranceVisit: Identifiable {
  let id = UUID()
  let entrance: String
  let source: CanvasRelationSource
}

struct CanvasRelationPanel: View {
  let source: CanvasRelationSource
  let store: AtlasStore
  var locate: ((RelationEntranceVisit) -> Void)?
  @ViewState private var entrances: [String: String] = [:]
  @ViewState private var locationError: String?
  @ViewState private var opened: CanvasRelationSource.Endpoint?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        if opened != nil { Button("返回关系") { opened = nil }.buttonStyle(PaperButton(compact: true)) }
        Text(opened?.title ?? source.title).font(.system(size: 19, weight: .medium, design: .serif))
        Spacer()
        Button("关闭") { dismiss() }.buttonStyle(PaperButton(compact: true))
      }
      PaperRule()
      if let opened, let kind = documentKind(opened) {
        if let ordinal = opened.ordinal { Text("版本 " + String(ordinal)).font(.caption) }
        CanvasCitationDetail(store: store, endpoint: opened, kind: kind).id(opened.id)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if let locationError { Text(locationError).foregroundStyle(AtlasPalette.umber) }
            Text((source.from.title ?? String(source.from.quote.prefix(60))) + (source.directed ? " → " : " ↔ ") +
                 (source.to.title ?? String(source.to.quote.prefix(60))))
              .font(.system(.headline, design: .serif)).textSelection(.enabled)
            Text(source.kind.label + (source.directed ? " · 有方向" : " · 无方向")).font(.subheadline)
            if !source.explanation.isEmpty { Text(source.explanation).textSelection(.enabled) }
            DisclosureGroup("关系版本与提出者") {
              let actor = ["user": "用户", "ai": "AI", "cli": "命令行", "system": "系统", "importer": "导入记录"]
              let basis = ["direct_source": "直接来源", "synthesis": "综合判断", "exploratory": "探索性联想"]
              Text("关系 v" + String(source.ordinal) + " · " + (actor[source.actorKind] ?? source.actorKind)
                   + "提出 · " + (basis[source.epistemicKind] ?? source.epistemicKind))
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
            endpoint(source.from, title: source.directed ? "起点依据" : "第一项依据")
            endpoint(source.to, title: source.directed ? "终点依据" : "第二项依据")
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }.padding(20).frame(minWidth: opened == nil ? 480 : 580, minHeight: opened == nil ? 320 : 440).background(AtlasPalette.cream)
    .onAppear {
      guard locate != nil else { return }
      do { entrances = try store.relationEntrances(source) }
      catch { locationError = error.localizedDescription }
    }
  }
  private func documentKind(_ value: CanvasRelationSource.Endpoint) -> CanvasCitation.Kind? {
    guard ["whole", "text", "pdf_rects"].contains(value.selector ?? "") else { return nil }
    return value.documentKind.flatMap(CanvasCitation.Kind.init(rawValue:))
  }
  private func endpoint(_ value: CanvasRelationSource.Endpoint, title: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      PaperRule()
      Text(title + (value.ordinal.map { " · 版本 " + String($0) } ?? ""))
        .font(AtlasTypeface.reading.font(15).weight(.medium))
      if let title = value.title {
        Text(title).font(.system(size: 12.5)).foregroundStyle(AtlasPalette.umber)
      }
      if value.selector == "whole" {
        Text("整份文档 · 仅引用题名与版本").font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
      } else {
        if value.selector == "pdf_rects" || value.selector == "text" {
          Text("选定片段").font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
        }
        Text(value.quote)
          .font(AtlasTypeface.reading.font(13.5))
          .lineSpacing(2.5)
          .textSelection(.enabled)
          .padding(9)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AtlasPalette.paperInset.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      }
      HStack(spacing: 8) {
        if documentKind(value) != nil {
          Button("打开当时的原文") { opened = value }
            .buttonStyle(PaperButton(compact: true))
            .accessibilityLabel("打开" + title + "原文")
        }
        if let locate, locationError == nil {
          if let entrance = entrances[value.id] {
            Button("定位画布入口") { locate(.init(entrance: entrance, source: source)); dismiss() }
              .buttonStyle(AtlasChipButtonStyle(emphasized: true))
              .accessibilityLabel("定位" + title + "的画布入口")
          } else {
            Text("这处画布入口已不存在").font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber)
          }
        }
      }
    }
  }
}

struct CanvasRelationEditor: View {
  let edge: MapEdge
  let save: (MapRelation, String) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @ViewState private var kind: MapRelation
  @ViewState private var issue: String?
  @ViewState private var explanation: String

  init(edge: MapEdge, save: @escaping (MapRelation, String) throws -> Void) {
    self.edge = edge
    self.save = save
    _kind = ViewState(
      initialValue: MapRelation.allCases.first { $0.label == edge.label } ?? .related_to)
    _explanation = ViewState(initialValue: edge.explanation)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("修改知识关系").font(AtlasTypeface.reading.font(19).weight(.medium))
      PaperRule()
      Picker("关系", selection: $kind) {
        ForEach(MapRelation.allCases) { r in Text(r.label).tag(r) }
      }
      TextField("关系说明（选填）", text: $explanation, axis: .vertical)
        .textFieldStyle(.roundedBorder)
      if let issue { Text(issue).font(.system(size: 12.5)).foregroundStyle(AtlasPalette.terracotta) }
      HStack {
        Button("取消") { dismiss() }.buttonStyle(AtlasChipButtonStyle())
        Spacer()
        Button("保存新版本") {
          do { try save(kind, explanation) } catch { issue = error.localizedDescription }
        }
        .buttonStyle(PaperButton(primary: true))
        .disabled(kind.label == edge.label && explanation == edge.explanation)
      }
    }
    .padding(22)
    .frame(width: 440)
    .background(AtlasPalette.paper)
    .foregroundStyle(AtlasPalette.ink)
  }
}

struct CanvasRelationPair: Identifiable {
  struct Input {
    let placement: String
    let material: MapRelationMaterial
    let label: String
    let version: Int
    let passage: String?
  }
  let id = UUID()
  let first, second: Input
}

struct CanvasNewRelation: View {
  let pair: CanvasRelationPair
  let save: (CanvasRelationPair.Input, CanvasRelationPair.Input, MapRelation, String) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @ViewState private var kind = MapRelation.compares
  @ViewState private var swapped = false
  @ViewState private var reason = ""
  @ViewState private var error: String?

  var body: some View {
    let first = swapped ? pair.second : pair.first
    let second = swapped ? pair.first : pair.second
    VStack(alignment: .leading, spacing: 13) {
      HStack(spacing: 8) {
        AtlasArt.compass.resizable().scaledToFit().frame(width: 18, height: 18).accessibilityHidden(true)
        Text("建立知识关系").font(AtlasTypeface.reading.font(20).weight(.medium))
      }
      PaperRule()
      endpoint(first, heading: kind.directed ? "起点" : "第一项")
      endpoint(second, heading: kind.directed ? "终点" : "第二项")
      HStack(spacing: 8) {
        Picker("关系", selection: $kind) {
          ForEach(MapRelation.allCases) { relation in Text(relation.label).tag(relation) }
        }
        if kind.directed {
          Button("交换端点") { swapped.toggle() }.buttonStyle(PaperButton(compact: true))
        }
      }
      TextField("关系说明（选填）", text: $reason, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("关系说明")
      if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(AtlasPalette.terracotta) }
      HStack {
        Button("取消") { dismiss() }.buttonStyle(AtlasChipButtonStyle())
        Spacer()
        Button("保存关系") {
          do { try save(first, second, kind, reason); dismiss() }
          catch { self.error = error.localizedDescription }
        }
        .buttonStyle(PaperButton(primary: true))
      }
    }
    .padding(22)
    .frame(width: 500)
    .background(AtlasPalette.paper)
    .foregroundStyle(AtlasPalette.ink)
  }

  private func endpoint(_ input: CanvasRelationPair.Input, heading: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(heading + " · " + input.label + " · 版本 " + String(input.version))
        .font(AtlasTypeface.reading.font(14.5).weight(.medium))
        .lineLimit(2)
      Text(input.passage ?? "关联整份文档，仅引用题名与版本。")
        .font(.system(size: 12.5))
        .foregroundStyle(AtlasPalette.umber)
        .lineLimit(3)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AtlasPalette.paperInset.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(AtlasPalette.line.opacity(0.38), lineWidth: 0.7)
    }
  }
}
