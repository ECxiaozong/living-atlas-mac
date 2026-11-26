import AtlasCore
import SwiftUI

extension Session {
  func assistantContext(in choices: [AtlasStore.OrganizationChoice], referringTo name: String) -> Set<String> {
    if area == .overview { return assistantSelectedEntrances }
    let target: String?
    var version: String?
    switch area {
    case .notes:
      guard let published = assistantNote.version else { return [] }
      target = assistantNote.id; version = published
    case .library: target = shownPDF?.id; version = shownPDF?.versionID
    case .graph where readingPane == .source || (shownPDF != nil && ["文章","文档"].contains(where: name.contains)): target = shownPDF?.id; version = shownPDF?.versionID
    case .graph: target = current?.turnID; version = current?.versionID
    default: target = nil
    }
    return Set(choices.filter { $0.targetID == target && (version == nil || $0.versionID == version) }.map(\.id))
  }
}

/// Only a user-selected entrance is read. This path always stages edits for review,
/// including in an Atlas with a separate automatic organization grant.
@MainActor func assistantOrganizationPreview(store: AtlasStore, choice: AtlasStore.OrganizationChoice,
  displayedRuns: [String: String] = [:], generate: (OrganizationScope) async throws -> OrganizationModelEnvelope) async throws
  -> (detail: String, plan: OrganizationPlan?) {
  let scope = try store.organizationScope(placements: [choice.id], regions: [], allowed: [.rewrite], displayedRuns: displayedRuns)
  guard let article = scope.objects.first, article.version == choice.versionID else {
    throw AtlasStoreError.invalid("材料版本已改变，请重新选择。")
  }
  let captured = try await store.organizationScopeWithPDFText(scope)
  let response = try await generate(captured)
  try Task.checkCancellation()
  let detail = ([response.summary] + response.coverage + response.openQuestions.map { "待探索 · " + $0 }).joined(separator: "\n\n")
  guard !response.edits.isEmpty else { return (detail, nil) }
  let plan = try store.previewOrganization(captured, edits: response.edits, title: response.summary,
    actor: "ai", assessment: response.assessment)
  return (detail, plan)
}

struct AtlasAssistant: View {
  typealias Choice = AtlasStore.OrganizationChoice
  @ObservedObject var session: Session
  let store: AtlasStore
  @Environment(\.dismiss) private var dismiss
  @FocusState private var inputFocused: Bool
  @ViewState private var phrase = ""
  @ViewState private var intent: AssistantIntent?
  @ViewState private var choices = [Choice]()
  @ViewState private var current = Set<String>()
  @ViewState private var displayedRuns: [String: String] = [:]
  @ViewState private var regionNames: [String: String] = [:]
  @ViewState private var source = ""
  @ViewState private var peer = ""
  @ViewState private var message = ""
  @ViewState private var plan: OrganizationPlan?
  @ViewState private var undoBatch: String?
  @ViewState private var job: Task<Void, Never>?
  @ViewState private var generation = UUID()

  private var sources: [Choice] {
    guard let intent else { return [] }
    return AssistantIntent.matches(intent.object, in: choices, current: current)
  }
  private var peers: [Choice] {
    guard let name = intent?.relativeTo else { return [] }
    return AssistantIntent.matches(name, in: choices, current: current).filter { $0.id != source }
  }
  private func description(of c: Choice) -> String {
    var parts = [c.title.isEmpty ? "未命名材料" : c.title]
    if let page = c.physicalPageIndex { parts.append("第 " + String(page + 1) + " 页") }
    if let version = c.versionOrdinal { parts.append("版本 " + String(version)) }
    if let region = c.regionID.flatMap({ regionNames[$0] }) { parts.append(region) }
    return parts.joined(separator: " · ")
  }
  private func label(_ c: Choice) -> String {
    let title = description(of: c)
    if choices.contains(where: { $0.id != c.id && description(of: $0) == title }) {
      return title + " · 入口 " + String(c.id.suffix(8))
    }
    return title
  }
  private func picker(_ title: String, _ options: [Choice], _ binding: Binding<String>) -> some View {
    Picker(title, selection: binding) {
      Text("请选择").tag("")
      ForEach(options) { Text(label($0)).tag($0.id) }
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        TaskCompanion(pose: job == nil ? .exploring : .working)
        Text("噗噗助手").font(AtlasTypeface.reading.font(20))
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      TextField("例如：打开《状态恢复笔记》", text: $phrase)
        .focused($inputFocused).accessibilityLabel("告诉噗噗要做什么").onSubmit { understand() }
      HStack {
        Button("理解指令") { understand() }.disabled(job != nil || phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if job != nil { Button("取消") { cancel(); message = "已取消。" } }
      }
      if let intent {
        if !sources.isEmpty { picker("操作对象", sources, $source).disabled(job != nil) }
        if intent.action == .move, !peers.isEmpty { picker("参照对象", peers, $peer) }
        switch intent.action {
        case .open: Button("打开所选入口") { open() }.disabled(source.isEmpty)
        case .organize:
          Text("生成预览时会把所选版本的正文发给当前模型。").font(.caption)
          Button("生成整理预览") { organize() }.disabled(source.isEmpty || job != nil || session.profile == nil)
          if session.profile == nil { Text("配置模型后可生成整理预览。").font(.caption) }
        case .move:
          Button("移动到参照对象" + (intent.position?.label ?? "")) { move() }
            .disabled(source.isEmpty || peer.isEmpty || source == peer)
        }
      }
      if !message.isEmpty {
        ScrollView { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          .frame(maxHeight: 140)
      }
      if let undoBatch {
        Button("撤销这次移动") { perform {
          guard try store.replayMapEdit(redo: false, expectedBatchID: undoBatch) else {
            throw AtlasStoreError.invalid("已有后续画布操作。请先撤销较新的操作，再撤销这次移动。")
          }
          self.undoBatch = nil
          message = "已恢复原位置。"
          NotificationCenter.default.post(name: .atlasLifecycleChanged, object: store)
        } }
      }
      if intent == nil, job == nil, message.isEmpty {
        Text("也可以说“整理这篇文章”或“把这个节点移到《学习笔记》下面”。")
          .font(.caption).foregroundStyle(AtlasPalette.umber)
      }
    }
    .padding(20).frame(width: 510).background(AtlasPalette.paper)
    .onAppear { inputFocused = true }
    .onDisappear { cancel() }
    .onChange(of: phrase) { _, _ in cancel(); intent = nil; message = "" }
    .onChange(of: source) { _, _ in if !peers.contains(where: { $0.id == peer }) { peer = peers.count == 1 ? peers[0].id : "" } }
    .sheet(item: $plan) { p in
      OrganizationDesk.workspace(session, store: store, initialPlanID: p.id) { ref, _ in
        plan = nil; dismiss(); session.ask(reference: ref)
      }
    }
  }

  private func perform(_ work: () throws -> Void) {
    guard session.store === store else { return }
    do { try work() } catch { message = error.localizedDescription }
  }

  private func cancel() { generation = UUID(); job?.cancel(); job = nil }

  private func run(_ status: String, _ work: @escaping @MainActor () async throws -> Void) {
    guard job == nil, session.store === store else { return }
    let token = UUID()
    generation = token
    message = status
    job = Task { @MainActor in
      defer { if token == generation { job = nil } }
      do { try await work() } catch {
        if generation == token, session.store === store { message = error.localizedDescription }
      }
    }
  }

  private func understand() {
    let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, job == nil else { return }
    guard text.utf8.count <= 1600 else { message = "请用一句话描述操作。"; return }
    if let parsed = AssistantIntent.local(text) { perform { try resolve(parsed) }; return }
    guard session.profile != nil else { message = "可以离线使用“打开…”“整理…”或“把…移到…下面”。其他说法需要配置模型。"; return }
    run("正在用当前模型理解这句话…") {
      let raw = try await session.interpretRequest(text, instruction: AssistantIntent.instruction)
      try Task.checkCancellation()
      guard session.store === store else { return }
      try resolve(AssistantIntent.decoded(raw, phrase: text))
    }
  }
  private func resolve(_ parsed: AssistantIntent) throws {
    displayedRuns = session.area == .overview ? session.assistantVisibleRuns : [:]
    choices = try store.organizationChoices(displayedRuns: displayedRuns)
    regionNames = Dictionary(uniqueKeysWithValues: try store.organizationRegions().map { ($0.id, $0.title) })
    current = session.assistantContext(in: choices, referringTo: parsed.object)
    intent = parsed
    let missingContext = AssistantIntent.refersToCurrent(parsed.object) && current.isEmpty
    source = sources.count == 1 && !missingContext ? sources[0].id : ""
    peer = peers.count == 1 ? peers[0].id : ""
    message = sources.isEmpty ? "画布上找不到“" + parsed.object + "”。请换一个标题。" : ""
    if missingContext, !sources.isEmpty { message = "当前没有选中材料，请选择要操作的入口。" }
    if parsed.action == .move, peers.isEmpty { message = "请指定另一个仍在画布上的参照对象。" }
    if parsed.action == .open, !source.isEmpty { open() }
  }
  private func open() {
    guard session.store === store, sources.contains(where: { $0.id == source }) else { return }
    session.assistantDestination = source
    session.area = .overview
    dismiss()
  }
  private func move() {
    guard let position = intent?.position, let from = sources.first(where: { $0.id == source }),
      let to = peers.first(where: { $0.id == peer }) else { return }
    perform {
      let batch = try store.moveEntrance(from.id, relativeTo: to.id, position: position)
      if let batch { undoBatch = batch }
      message = batch == nil ? "入口已经在这里。" : "已将“" + from.title + "”移到“" + to.title + "”" + position.label + "。"
      NotificationCenter.default.post(name: .atlasLifecycleChanged, object: store)
    }
  }
  private func organize() {
    guard let chosen = sources.first(where: { $0.id == source }) else { return }
    run("正在读取所选版本，准备整理建议…") {
      let result = try await assistantOrganizationPreview(store: store, choice: chosen, displayedRuns: displayedRuns) { scope in
        let response = try await session.organizeArticle(scope)
        try Task.checkCancellation()
        guard session.store === store else { throw CancellationError() }
        return response
      }
      message = result.detail
      plan = result.plan
    }
  }
}
