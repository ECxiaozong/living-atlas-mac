import AtlasCore
import SwiftUI

struct OrganizationComposer: View {
  let scope: OrganizationScope
  @Binding var edits: [OrganizationEdit]
  @ViewState private var target = ""
  @ViewState private var peer = ""
  @ViewState private var chosenRegion = ""
  @ViewState private var type = OrganizationAction.move
  @ViewState private var relation = MapRelation.compares
  @ViewState private var reason = ""
  @ViewState private var words = ""
  @ViewState private var x = ""
  @ViewState private var y = ""
  @ViewState private var prerequisite = ""
  @ViewState private var issue = ""
  private var object: OrganizationObject? { scope.objects.first { $0.id == target } }
  private var targets: [OrganizationObject] { scope.objects.filter { scope.canEdit($0, action: type) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("材料", selection: $target) {
        ForEach(targets) { o in Text(o.title + " · " + String(o.id.suffix(6))).tag(o.id) }
      }
      Picker("修改", selection: $type) {
        ForEach(scope.allowed, id: \.self) { a in Text(a.label).tag(a) }
      }
      if let o = object {
        if type == .move || type == .addEntrance {
          HStack {
            TextField("横坐标", text: $x)
            TextField("纵坐标", text: $y)
          }
        }
        if type == .rewrite {
          Text(o.body).textSelection(.enabled)
          TextEditor(text: $words).frame(minHeight: 60)
        }
        if type == .addEntrance {
          Picker("主题", selection: $chosenRegion) {
            ForEach(scope.regions) { r in Text(r.title).tag(r.id) }
          }
        }
        if type == .relate {
          Picker("另一材料", selection: $peer) {
            ForEach(scope.objects.filter { $0.target != o.target && scope.canEdit($0, action: .relate) }) { r in
              Text(r.title + " · " + String(r.id.suffix(6))).tag(r.id)
            }
          }
          Picker("关系", selection: $relation) {
            ForEach(MapRelation.allCases) { r in Text(r.label).tag(r) }
          }
        }
      }
      TextField("为什么需要这项修改", text: $reason).textFieldStyle(.roundedBorder)
        .accessibilityLabel("为什么需要这项修改")
      if !edits.isEmpty {
        Picker("需要先采用", selection: $prerequisite) {
          Text("无前置项").tag("")
          ForEach(edits) { i in Text(i.action.label + " · " + i.reason).tag(i.id) }
        }
      }
      Button("加入提案") { add() }.disabled(
        reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || object == nil)
      if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
      ForEach(edits) { e in
        HStack {
          Text(e.action.label + " · " + e.reason)
          Spacer()
          Button("移出") {
            edits.removeAll { $0.id == e.id }
            prerequisite = ""
          }.disabled(edits.contains { $0.requires.contains(e.id) })
        }
      }
    }.onAppear {
      type = scope.allowed.first ?? .move
      chosenRegion = scope.regions.first?.id ?? ""
      target = targets.first?.id ?? ""
      sync()
    }.onChange(of: target) { _, _ in sync() }.onChange(of: type) { _, _ in
      if !targets.contains(where: { $0.id == target }) { target = targets.first?.id ?? "" }
      sync()
    }
  }
  private func sync() {
    guard let o = object else { return }
    x = String(Int(o.x) + 288)
    y = String(Int(o.y) + (type == .move ? 0 : 144))
    peer = scope.objects.first { $0.target != o.target && scope.canEdit($0, action: .relate) }?.id ?? ""
    words = o.body
  }
  private func add() {
    guard let o = object else { return }
    let px = Double(x)
    let py = Double(y)
    if (type == .move || type == .addEntrance) && (px?.isFinite != true || py?.isFinite != true) {
      issue = "请输入有效坐标。"
      return
    }
    if type == .rewrite && (!o.mayRewrite || words == o.body) {
      issue = "请选择解释或笔记，并写下修改后的正文。"
      return
    }
    if type == .relate && peer.isEmpty || type == .addEntrance && chosenRegion.isEmpty {
      issue = "请先选定另一端点或地域。"
      return
    }
    edits.append(
      .init(
        action: type, target: o.id, reason: reason, peer: type == .relate ? peer : nil,
        region: type == .addEntrance ? chosenRegion : nil, body: type == .rewrite ? words : nil,
        relation: type == .relate ? relation.rawValue : nil,
        x: type == .move || type == .addEntrance ? px : nil,
        y: type == .move || type == .addEntrance ? py : nil,
        requires: prerequisite.isEmpty ? [] : [prerequisite]))
    issue = ""
    reason = ""
    prerequisite = ""
  }
}
