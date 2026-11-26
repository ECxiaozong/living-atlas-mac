import AtlasCore
import SwiftUI

struct OrganizationDesk: View {
  let store: AtlasStore
  var onQuestion: ((String, OrganizationObject?) -> Void)? = nil
  var generate: ((OrganizationScope) async throws -> [OrganizationEdit])? = nil
  var initialPlanID: String? = nil
  var modelProposal: ((OrganizationScope) async throws -> OrganizationModelEnvelope)? = nil
  var interpretRange: ((String) async throws -> String)?
  var showOnCanvas: ((Set<String>) -> Void)?
  var previewOnCanvas: ((OrganizationPlan, Set<String>) -> Void)? = nil
  var validateLayout: ((OrganizationScope) throws -> Void)?
  var initialPlacements = Set<String>()
  var initialRegions = Set<String>()
  var displayedRuns: [String: String] = [:]

  static func workspace(_ session: Session, store: AtlasStore, placements: Set<String> = [],
                        regions: Set<String> = [], displayedRuns: [String: String] = [:], initialPlanID: String? = nil,
                        validateLayout: ((OrganizationScope) throws -> Void)? = nil, showOnCanvas: ((Set<String>) -> Void)? = nil,
                        previewOnCanvas: ((OrganizationPlan, Set<String>) -> Void)? = nil,
                        onQuestion: @escaping (String, OrganizationObject?) -> Void) -> Self {
    let model: ((OrganizationScope) async throws -> OrganizationModelEnvelope)? = session.profile == nil
      ? nil : { scope in
        guard session.store === store else { throw AtlasStoreError.invalid("项目已切换，请在原项目重新开始整理。") }
        return try await session.organize(scope)
      }
    return Self(store: store, onQuestion: onQuestion, initialPlanID: initialPlanID, modelProposal: model,
                interpretRange: session.describeOrganizationRange, showOnCanvas: showOnCanvas, previewOnCanvas: previewOnCanvas,
                validateLayout: validateLayout, initialPlacements: placements, initialRegions: regions, displayedRuns: displayedRuns)
  }
  @Environment(\.dismiss) private var dismiss
  @ViewState private var choices: [AtlasStore.OrganizationChoice] = []
  @ViewState private var regions: [OrganizationRegion] = []
  @ViewState private var regionPaths: [String: String] = [:]
  @ViewState private var history: [OrganizationPlan] = []
  @ViewState private var selected = Set<String>()
  @ViewState private var readOnly = Set<String>()
  @ViewState private var areas = Set<String>()
  @ViewState private var onlySelected = false
  @ViewState private var describing = false
  @ViewState private var descriptionText = ""
  @ViewState private var rangeStatus = ""
  @ViewState private var matching: Task<Void, Never>?

  @ViewState private var allowed: Set<OrganizationAction> = [
    .move, .rewrite, .addEntrance, .relate,
  ]
  @ViewState private var scope: OrganizationScope?
  @ViewState private var plan: OrganizationPlan?
  @ViewState private var edits: [OrganizationEdit] = []
  @ViewState private var picked = Set<String>()
  @ViewState private var focused: String?
  @ViewState private var after = true
  @ViewState private var savedCamera = false
  @ViewState private var issues: [OrganizationConflict] = []
  @ViewState private var remaining = Set<String>()
  @ViewState private var task: Task<Void, Never>?
  @ViewState private var originals: [ChatArchiveExcerpt] = []
  @ViewState private var rawOrigin: ChatArchiveExcerpt?
  @ViewState private var grant: OrganizationGrant?
  @ViewState private var feedback = ""
  @ViewState private var reason = ""
  @ViewState private var bodyCorrection = ""
  @ViewState private var editMode = false

  private var localLayout: Bool {
    if let plan { return plan.scope.presentationSizes != nil }
    return initialPlanID != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        if !localLayout {
          TaskCompanion(pose: task != nil || matching != nil ? .working :
            (plan?.status == "reviewable" && plan?.assessment != nil && plan?.edits.isEmpty == false ? .discovery : .calm))
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(localLayout ? "排开图版" : "整理图谱")
            .font(AtlasTypeface.reading.font(22).weight(.medium))
            .foregroundStyle(AtlasPalette.ink)
          Text(plan.map { state($0.status) } ?? (scope == nil ? "选择范围" : "拟定修改"))
            .font(.system(size: 12.5))
            .foregroundStyle(AtlasPalette.umber)
        }
        Spacer()
        if task != nil {
          Button("取消分析") {
            task?.cancel()
            task = nil
            feedback = "分析已取消。"
          }
          .buttonStyle(PaperButton(compact: true))
        }
        Button("关闭") {
          task?.cancel()
          dismiss()
        }
        .buttonStyle(PaperButton(compact: true))
      }
      PaperRule()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let plan {
            if localLayout { layoutReview(plan) } else { review(plan) }
          } else if let scope {
            Button("返回选区") {
              self.scope = nil
              task?.cancel()
              task = nil
              edits = []
            }
            .buttonStyle(AtlasChipButtonStyle(emphasized: true))
            OrganizationComposer(scope: scope, edits: $edits)
            Button("查看整理对照") {
              attempt {
                let p = try store.previewOrganization(scope, edits: edits, title: "手动整理")
                try open(p)
              }
            }.buttonStyle(PaperButton(primary: true)).disabled(edits.isEmpty)
          } else {
            choose
          }
          if !feedback.isEmpty {
            Text(feedback).foregroundStyle(AtlasPalette.umber).textSelection(.enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
      }
    }.padding(18).foregroundStyle(AtlasPalette.ink).background(AtlasPalette.cream).frame(
      minWidth: 500, idealWidth: localLayout ? 700 : 960, minHeight: 460, idealHeight: localLayout ? 550 : 760
    )
    .frame(maxWidth: localLayout ? 720 : nil, maxHeight: localLayout ? 550 : nil)
    .task {
      refresh()
      selected = initialPlacements.intersection(choices.map(\.id))
      areas = initialRegions.intersection(regions.map(\.id))
      if !initialPlacements.isEmpty || !initialRegions.isEmpty {
        allowed = [.move]
        onlySelected = !selected.isEmpty
      }
      if let initialPlanID, let p = history.first(where: { $0.id == initialPlanID }) {
        attempt { try open(p) }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for:.atlasAgentCommitted)) { note in
      guard note.object as? AtlasStore === store else{return}
      refresh()
      if let id=plan?.id,let updated=history.first(where:{$0.id==id}){
        plan=updated
        issues=(try? store.organizationConflicts(id)) ?? []
      }
    }
    .onDisappear { task?.cancel(); matching?.cancel() }
    .sheet(isPresented: Binding(get: { rawOrigin != nil }, set: { if !$0 { rawOrigin = nil } })) {
      if let rawOrigin {
        ChatArchiveImportView(store: store, sourceExcerpt: rawOrigin, onQuestion: onQuestion.map { ask in { ask($0, nil) } })
      }
    }
  }
  private func state(_ raw: String) -> String {
    [
      "reviewable": "待决定", "applied": "已应用", "rolled_back": "已撤回", "stale": "已过时",
      "cancelled": "已放弃", "applying": "应用中", "failed": "分析失败",
    ][raw] ?? raw
  }
  private func attempt(_ action: () throws -> Void) {
    do {
      feedback = ""
      try action()
    } catch {
      feedback = error.localizedDescription
      refresh()
      if let current = plan, let newer = history.first(where: { $0.id == current.id }) {
        plan = newer
        issues = (try? store.organizationConflicts(current.id)) ?? []
      }
    }
  }
  private func refresh() {
    do {
      history = try store.organizationPlans()
      grant = try store.organizationGrant()
      choices = try store.organizationChoices(displayedRuns: displayedRuns)
      regions = try store.organizationRegions()
      let tree = CanvasRegionTree(try store.canvasRegions())
      regionPaths = Dictionary(uniqueKeysWithValues: tree.regions.keys.map { id in
        (id, tree.path(to: id) { $0.title })
      })
    } catch { feedback = error.localizedDescription }
  }
  private func showCommitted(_ plan: OrganizationPlan) throws {
    NotificationCenter.default.post(name: .atlasLifecycleChanged, object: store)
    try open(plan)
  }
  private func open(_ p: OrganizationPlan) throws {
    cancelRange()
    originals = []
    plan = p
    scope = nil
    editMode = false
    issues = try store.organizationConflicts(p.id)
    remaining = Set(try store.remainingOrganizationEdits(p.id).map(\.id))
    picked = remaining
    focused = p.edits.first?.id
    after = !["rolled_back", "cancelled"].contains(p.status)
    history = try store.organizationPlans()
  }
  private func member<T: Hashable>(_ set: Binding<Set<T>>, _ id: T) -> Binding<Bool> {
    Binding(
      get: { set.wrappedValue.contains(id) },
      set: { on in if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
  }
  private func captureScope() throws -> OrganizationScope {
    try store.organizationScope(placements: selected, regions: areas, allowed: Array(allowed),
                                displayedRuns: displayedRuns, readOnlyPlacements: readOnly.intersection(selected))
  }
  private var exceedsLimit: Bool {
    selected.count > OrganizationScope.maxPlacements || areas.count > OrganizationScope.maxRegions
  }
  private func useRange(_ ids: Set<String>) {
    guard !ids.isEmpty else {
      rangeStatus = "没有匹配的入口，保留当前勾选。"
      return
    }
    let materials = Set(choices.lazy.filter { ids.contains($0.id) }.map(\.targetID)).count
    selected = ids
    areas = []
    allowed = [.move]
    onlySelected = true
    rangeStatus = "已匹配 " + String(ids.count) + " 个入口，涉及 " + String(materials) + " 份材料，可继续调整。"
  }
  private func matchDescription() {
    let text = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 1800 else {
      rangeStatus = "请输入较短的范围描述。"
      return
    }
    if let ids = OrganizationRangeDescription.literal(text, choices: choices, paths: regionPaths) {
      useRange(ids)
      return
    }
    guard let interpretRange else {
      rangeStatus = "可输入完整标题或地域名；按描述组合匹配需先配置模型。"
      return
    }
    rangeStatus = "正在解析描述…"
    matching = Task { @MainActor in
      do {
        let result = try await interpretRange(text)
        try Task.checkCancellation()
        let ids = try await OrganizationRangeDescription.resolve(result, description: text, choices: choices, paths: regionPaths, store: store)
        try Task.checkCancellation()
        useRange(ids)
      } catch {
        guard !Task.isCancelled else { return }
        rangeStatus = error.localizedDescription
      }
      matching = nil
    }
  }
  private func cancelRange() {
    matching?.cancel()
    matching = nil
    rangeStatus = ""
  }
  @ViewBuilder private var rangeControls: some View {
    HStack {
      Button(describing ? "收起范围描述" : "按描述选择…") {
        cancelRange()
        describing.toggle()
      }
      Button("选择整个 Atlas") {
        cancelRange()
        useRange(Set(choices.map(\.id)))
      }.disabled(choices.isEmpty)
      if let showOnCanvas {
        Button("在画布标出所选入口") { showOnCanvas(selected) }
          .disabled(selected.isEmpty || exceedsLimit || matching != nil)
      }
    }.disabled(task != nil)
    if describing {
      HStack {
        TextField("例如，历史版本核对里的 Markdown，只要版本 1", text: $descriptionText)
          .accessibilityLabel("整理范围描述").onSubmit { if matching == nil { matchDescription() } }
          .onChange(of: descriptionText) { _, _ in cancelRange() }
        Button("匹配并勾选") { matchDescription() }
          .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || matching != nil)
        if matching != nil { Button("取消匹配") { cancelRange() } }
      }.disabled(task != nil)
      Text("完整标题或地域名在本机匹配。组合描述仅将这句话发送给当前模型。匹配成功后先勾选移动入口。")
        .font(.caption).foregroundStyle(.secondary)
    }
    if !rangeStatus.isEmpty { Text(rangeStatus).font(.callout).foregroundStyle(AtlasPalette.umber) }
  }
  @ViewBuilder private var choose: some View {
    rangeControls
    rangePicker.disabled(matching != nil)
    if !history.isEmpty {
      Divider()
      Text("整理历史").font(.headline)
      ForEach(history) { p in
        Button(p.summary + " · " + state(p.status)) { attempt { try open(p) } }
      }
    }
  }
  @ViewBuilder private var rangePicker: some View {
    Text("可读取的材料 · 已选 " + String(selected.count) + " 个入口").font(.headline)
    if exceedsLimit {
      Text("每批最多整理 \(OrganizationScope.maxPlacements) 个入口、使用 \(OrganizationScope.maxRegions) 个地域。请缩小本次范围。")
        .foregroundStyle(AtlasPalette.umber)
    }
    if choices.isEmpty { Text("图谱里还没有材料。先从阅读或聊天原档加入内容。").foregroundStyle(.secondary) }
    if !choices.isEmpty { Toggle("只看已选入口", isOn: $onlySelected).toggleStyle(.checkbox) }
    LazyVStack(alignment: .leading) {
      ForEach(onlySelected ? choices.filter { selected.contains($0.id) } : choices) { o in
        let label = (o.title.isEmpty ? "无标题" : o.title) + " · " + String(o.id.suffix(6))
        let path = o.regionID.flatMap { regionPaths[$0] } ?? "画布根层"
        let detail = [path, o.versionOrdinal.map { "版本 " + String($0) }].compactMap { $0 }.joined(separator: " · ")
        HStack {
          Toggle(isOn: member($selected, o.id)) {
          HStack { Text(label); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.toggleStyle(.checkbox).accessibilityLabel(label).accessibilityHint(detail).accessibilityIdentifier("organization.placement." + o.id)
          if selected.contains(o.id) {
            Spacer()
            Toggle("仅作参考", isOn: member($readOnly, o.id)).toggleStyle(.checkbox)
              .accessibilityLabel(label + "仅作参考")
          }
        }
      }
    }
    if !regions.isEmpty {
      Text("可用主题地域").font(.headline)
      ForEach(regions) { r in Toggle(regionPaths[r.id] ?? r.title, isOn: member($areas, r.id)).toggleStyle(.checkbox) }
    }
    Text("可提出的修改").font(.headline)
    Text("移动和移除只影响所选入口。修订解释会更新共享正文，添加主题入口会改变材料的主题归属。").font(.caption).foregroundStyle(.secondary)
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)], alignment: .leading
    ) {
      ForEach(OrganizationAction.allCases, id: \.self) { a in
        Toggle(a.label, isOn: member($allowed, a)).toggleStyle(.checkbox)
      }
    }
    if modelProposal != nil, choices.contains(where: { selected.contains($0.id) && $0.materialKind == "pdf" }) {
      Text("分析时会将所选 PDF 版本中可提取的文字按页发送给当前模型。").font(.caption).foregroundStyle(.secondary)
    }
    HStack {
      Button("手动拟案") {
        attempt {
          scope = try captureScope()
          edits = []
        }
      }.buttonStyle(PaperButton(primary: generate == nil))
      if generate != nil || modelProposal != nil {
        Button("分析所选材料") { analyze() }.buttonStyle(PaperButton(primary: true))
      }
    }.disabled(selected.isEmpty || exceedsLimit || allowed.isEmpty || task != nil)
    DisclosureGroup("自动应用授权") {
      VStack(alignment: .leading, spacing: 6) {
        if let grant {
          Text(
            "已授权 " + String(grant.placements.count) + " 个入口 · "
              + grant.actions.map(\.label).joined(separator: "、"))
          Button("撤销自动应用授权") {
            attempt {
              try store.setOrganizationGrant(nil)
              refresh()
            }
          }
        } else {
          Text("当前逐批评审。").foregroundStyle(.secondary)
        }
        Button("授权在所选范围内自动应用非移除修改") {
          attempt {
            let captured = try captureScope()
            try store.setOrganizationGrant(
              captured, actions: allowed.subtracting([.removeEntrance]))
            refresh()
          }
        }.disabled(selected.isEmpty || exceedsLimit || allowed.subtracting([.removeEntrance]).isEmpty)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func analyze() {
    attempt {
      let selection = try captureScope()
      feedback = "正在读取 " + String(selection.objects.count) + " 个所选入口。"
      task = Task { @MainActor in
        do {
          let captured = try await store.organizationScopeWithPDFText(selection)
          try Task.checkCancellation()
          feedback = "已读取所选版本，正在请求整理建议…"
          let proposed: [OrganizationEdit]
          let assessment: OrganizationAssessment?
          let title: String
          if let modelProposal {
            let envelope = try await modelProposal(captured)
            title = envelope.summary
            assessment = envelope.assessment
            proposed = envelope.edits
          } else if let generate {
            proposed = try await generate(captured)
            title = "模型整理"
            assessment = nil
          } else {
            throw AtlasStoreError.invalid("模型整理服务未配置。")
          }
          try Task.checkCancellation()
          guard !proposed.isEmpty else {
            feedback = ([title + " · 没有提出修改。"] + (assessment?.coverage ?? []) + (assessment?.openQuestions.map { "未解决 · " + $0 } ?? [])).joined(separator: "\n")
            task = nil
            return
          }
          let p = try store.previewOrganization(
            captured, edits: try store.layoutOrganizationIntents(proposed, within: captured),
            title: title, actor: "ai", assessment: assessment)
          if try store.organizationGrant() != nil {
            let result = try store.applyAuthorizedOrganization(p.id)
            if result.applied != nil { NotificationCenter.default.post(name: .atlasLifecycleChanged, object: store) }
            refresh()
            feedback =
              result.applied == nil
              ? "建议已保存到整理历史，等待评审。"
              : result.pending == nil ? "已按授权应用，详情见整理历史。" : "独立且已授权的修改已应用；其余修改保留在整理历史中待决定。"
          } else {
            try open(p)
            feedback = ""
          }
        } catch is CancellationError { return } catch {
          if !Task.isCancelled { feedback = error.localizedDescription }
        }
        if !Task.isCancelled { task = nil }
      }
    }
  }
  @ViewBuilder private func layoutReview(_ p: OrganizationPlan) -> some View {
    Picker("预览位置", selection: $after) {
      Text("排开前").tag(false)
      Text("排开后").tag(true)
    }.pickerStyle(.segmented).labelsHidden()
    OrganizationDiff(plan: p, selection: Set(p.edits.map(\.id)), focused: nil, after: after,
                     savedCamera: false, previewStore: store)
    ForEach(p.scope.objects) { object in
      let moving = p.edits.contains { $0.target == object.id }
      HStack {
        Image(systemName: moving ? "arrow.right" : "pin")
        Text(object.title)
        Spacer()
        Text(moving ? "移动" : "保持原位").foregroundStyle(.secondary)
      }
      if let info = p.scope.entranceDescriptions?[object.id] { Text(info).font(.caption).foregroundStyle(AtlasPalette.umber) }
    }
    if !issues.isEmpty { ForEach(issues) { Text($0.reason).foregroundStyle(AtlasPalette.umber) } }
    HStack {
      Spacer()
      if p.status == "reviewable" {
        Button("取消") { attempt { try store.abandonOrganization(p.id); dismiss() } }
        Button("应用移动") {
          attempt {
            try validateLayout?(p.scope)
            try showCommitted(store.applyOrganization(p.id))
          }
        }
          .buttonStyle(PaperButton(primary: true))
      } else if p.status == "applied" {
        Button("撤回移动") { attempt { try showCommitted(store.undoOrganization(p.id)) } }.buttonStyle(PaperButton())
      }
    }
  }
  @ViewBuilder private func review(_ p: OrganizationPlan) -> some View {
    HStack(spacing: 8) {
      Button("返回整理范围") {
        plan = nil
        scope = nil
        editMode = false
        feedback = ""
        refresh()
      }
      .buttonStyle(AtlasChipButtonStyle(emphasized: true))
      Text(p.summary).font(AtlasTypeface.reading.font(16).weight(.medium))
      Spacer()
    }
    HStack(spacing: 8) {
      Button("整理前") {
        after = false
      }.buttonStyle(PaperButton(primary: !after, compact: true))
        .accessibilityAddTraits(after ? [] : .isSelected)
      Button(
        ["rolled_back", "cancelled"].contains(p.status)
          ? "原批次效果" : p.status == "reviewable" ? "提案效果" : "整理后"
      ) { after = true }.buttonStyle(
        PaperButton(primary: after, compact: true)
      ).accessibilityAddTraits(after ? .isSelected : [])
      Toggle("沿用图谱视口", isOn: $savedCamera).toggleStyle(.checkbox)
      Spacer()
      if p.status == "reviewable", let previewOnCanvas {
        Button {
          dismiss()
          previewOnCanvas(p, picked)
        } label: {
          Label("在画布中对照预览", systemImage: "map")
        }
        .buttonStyle(PaperButton(compact: true))
        .help("回到真实画布查看虚线移动轨迹、暖金新建关系与整理前后平滑切换")
      }
    }.zIndex(1)
    OrganizationDiff(
      plan: p, selection: p.status == "reviewable" ? picked : Set(p.edits.map(\.id)),
      focused: focused, after: after, savedCamera: savedCamera
    ).allowsHitTesting(false)
    if let ids = p.scope.readOnlyPlacements, !ids.isEmpty {
      Text("仅作参考 · " + p.scope.objects.filter { ids.contains($0.id) }.map(\.title).joined(separator: "、"))
    }
    ForEach(p.scope.objects.filter { $0.pdfTextByFilePage != nil }) { object in
      if let pages = object.pdfTextByFilePage {
        DisclosureGroup("《" + object.title + "》送审原文 · " + String(pages.compactMap { $0 }.count) + "/" + String(pages.count) + " 页有文字") {
          ForEach(pages.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 4) {
              Text("文件第 " + String(index + (object.pdfPageIndex ?? 0) + 1) + " 页").font(.caption).foregroundStyle(.secondary)
              Text(pages[index] ?? "本页没有可提取的文字。").textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
          }
        }
      }
    }
    if let assessment = p.assessment {
      if !assessment.coverage.isEmpty {
        DisclosureGroup("覆盖的材料") {
          ForEach(Array(assessment.coverage.enumerated()), id: \.offset) { _, text in Text(text) }
        }
      }
      if !assessment.openQuestions.isEmpty {
        DisclosureGroup("保留的未解问题") {
          ForEach(Array(assessment.openQuestions.enumerated()), id: \.offset) { _, text in
            Text(text)
          }
        }
      }
    }
    Text("修改明细").font(AtlasTypeface.reading.font(15.5).weight(.medium))
    ForEach(p.edits) { e in
      HStack(alignment: .firstTextBaseline) {
        if p.status == "reviewable" {
          Toggle("", isOn: member($picked, e.id)).labelsHidden().toggleStyle(.checkbox)
        }
        Button {
          focused = e.id
          editMode = false
        } label: {
          Text(
            e.action.label + " · " + (p.scope.objects.first { $0.id == e.target }?.title ?? "入口")
          ).fontWeight(focused == e.id ? .semibold : .regular)
        }.buttonStyle(.plain)
        Spacer()
        if p.status == "applied" && !remaining.contains(e.id) { Text("已撤回").font(.caption) }
        if issues.contains(where: { $0.id == e.id }) {
          Image(systemName: "exclamationmark.circle").accessibilityLabel("有冲突")
        }
      }
    }
    if let e = p.edits.first(where: { $0.id == focused }),
      let s = p.scope.objects.first(where: { $0.id == e.target })
    {
      VStack(alignment: .leading, spacing: 7) {
        Text(e.action.label + " · " + s.title).font(.system(.headline, design: .serif))
        switch e.action {
        case .rewrite:
          Text("原文").font(.caption).foregroundStyle(.secondary)
          Text(s.body).textSelection(.enabled)
          Text("提议修改").font(.caption).foregroundStyle(.secondary)
          Text(e.body ?? "").textSelection(.enabled)
        case .move:
          Text(
            "(" + String(Int(s.x)) + ", " + String(Int(s.y)) + ")  →  (" + String(Int(e.x ?? 0))
              + ", " + String(Int(e.y ?? 0)) + ")"
          ).monospacedDigit()
        case .relate:
          Text(
            s.title + "  " + (MapRelation(rawValue: e.relation ?? "")?.label ?? "关系") + "  "
              + (p.scope.objects.first { $0.id == e.peer }?.title ?? ""))
        case .addEntrance:
          Text("添加到" + (p.scope.regions.first { $0.id == e.region }?.title ?? "主题") + "，使用原内容版本。")
        case .removeEntrance: Text("此入口将从图谱移除。原文、原消息和其他入口仍可回看。")
        }
        Text(e.reason).font(.callout)
        if !e.requires.isEmpty {
          Text(
            "需要先采用 "
              + e.requires.compactMap { key in p.edits.first { $0.id == key }?.action.label }
              .joined(separator: "、")
          ).font(.caption)
        }
        Text("入口 " + s.id + " · 版本 " + s.version).font(.caption2).foregroundStyle(.secondary)
          .textSelection(.enabled)
        HStack {
          if onQuestion != nil {
            Button("从整理前版本继续问") {
              attempt {
                let ref = try store.organizationReference(plan: p.id, placement: e.target)
                dismiss()
                onQuestion?(ref, s)
              }
            }
          }
          if ["applied", "rolled_back"].contains(p.status),
            [OrganizationAction.rewrite, .relate].contains(e.action), onQuestion != nil
          {
            Button("从此项结果继续问") {
              attempt {
                let ref = try store.organizationResultReference(plan: p.id, editID: e.id)
                dismiss()
                onQuestion?(ref, nil)
              }
            }
          }
          Button("查看原始依据") {
            attempt {
              let ref = try store.organizationReference(plan: p.id, placement: e.target)
              originals = try store.chatOrigins(referenceID: ref)
              if originals.count == 1 {
                rawOrigin = originals[0]
              } else if originals.isEmpty {
                feedback = "此版本没有来自聊天原档的选段。"
              }
            }
          }
          if p.status == "reviewable" {
            Button("修改这项") {
              reason = e.reason
              bodyCorrection = e.body ?? ""
              editMode.toggle()
            }
          }
        }
        if originals.count > 1 {
          ForEach(Array(originals.enumerated()), id: \.offset) { i, e in
            Button("原消息 " + String(i + 1) + " · " + String(e.exact.prefix(48))) { rawOrigin = e }
          }
        }
        if editMode && p.status == "reviewable" {
          TextField("说明这项修改的依据", text: $reason).textFieldStyle(.roundedBorder)
          if e.action == .rewrite { TextEditor(text: $bodyCorrection).frame(minHeight: 60) }
          Button("保存修改") {
            attempt {
              var next = p.edits
              if let i = next.firstIndex(where: { $0.id == e.id }) {
                next[i].reason = reason
                if e.action == .rewrite { next[i].body = bodyCorrection }
              }
              try open(store.reviseOrganization(p.id, edits: next))
            }
          }
        }
      }.padding(12).frame(maxWidth: .infinity, alignment: .leading).modifier(PaperSurface())
    }
    if !issues.isEmpty {
      ForEach(issues) { i in Label(i.reason, systemImage: "exclamationmark.circle").font(.callout) }
    }
    HStack {
      if p.status == "reviewable" {
        Button("应用选中修改") {
          attempt {
            let subset = p.edits.filter { picked.contains($0.id) }
            let approved =
              try subset.count == p.edits.count ? p : store.reviseOrganization(p.id, edits: subset)
            try showCommitted(store.applyOrganization(approved.id))
          }
        }.buttonStyle(PaperButton(primary: true)).disabled(picked.isEmpty)
        Button("放弃提案") {
          attempt {
            try store.abandonOrganization(p.id)
            refresh()
            if let updated = history.first(where: { $0.id == p.id }) { try open(updated) }
          }
        }
        .buttonStyle(PaperButton())
      } else if p.status == "applied" {
        Button("撤回整批") { attempt { try showCommitted(store.undoOrganization(p.id)) } }.buttonStyle(
          PaperButton())
        if !issues.isEmpty {
          Button("保留冲突，撤回可独立修改") {
            attempt {
              let blocked = Set(issues.map(\.id))
              var keep = blocked
              var n = 0
              repeat {
                n = keep.count
                for e in p.edits where keep.contains(e.id) { keep.formUnion(e.requires) }
              } while n != keep.count
              try showCommitted(store.undoOrganization(p.id, selected: remaining.subtracting(keep)))
            }
          }
        }
      } else if p.status == "stale" {
        Button("按当前版本重新选范围") {
          selected = Set(p.scope.objects.map(\.id))
          areas = Set(p.scope.regions.map(\.id))
          readOnly = Set(p.scope.readOnlyPlacements ?? [])
          allowed = Set(p.scope.allowed)
          plan = nil
          scope = nil
          refresh()
        }
      }
    }
  }
}
