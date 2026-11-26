import AtlasCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Session: ObservableObject {
  enum Area: String, CaseIterable {
    case overview = "全图"
    case graph = "图谱"
    case library = "资料"
    case notes = "笔记"
    case history = "历史"
  }
  enum ReadingPane: String { case source, task }
  private struct QuestionReturn: Codable {
    let area: String
    let run: String?
    let documentVersion: String?
    let place: PDFReadingPlace?
    let highlight: PDFAnchor?
  }
  private struct DesktopView: Codable {
    let area: String
    let run: String?
    let documentVersion: String?
    let highlight: PDFAnchor?
    let returnToQuestion: Bool
    let pane: String?
    let questionReturn: QuestionReturn?
  }
  private var restoring = false
  private var hasUnsavedDraft = false
  private func persistDesktop() {
    guard !restoring, let store else { return }
    do {
      let state = DesktopView(
        area: area.rawValue, run: selected, documentVersion: shownPDF?.versionID,
        highlight: highlight, returnToQuestion: returnToQuestion, pane: readingPane.rawValue,
        questionReturn: questionReturn)
      try store.saveViewState(state, key: "desktop")
    } catch {
      saving = "保存失败"
      self.error = error.localizedDescription
    }
  }
  @Published private(set) var canvasZoom = 1.0
  func zoomCanvas(to scale: Double) {
    guard let store else { return }
    perform {
      try store.setCanvasZoom(scale)
      canvasZoom = scale
    }
  }
  @Published var canvasHelp = false
  @Published var commandPalette = false
  @Published var assistantShown = false
  @Published var assistantDestination: String?
  var assistantSelectedEntrances = Set<String>()
  var assistantVisibleRuns: [String: String] = [:]
  var assistantNote: (id: String?, version: String?) = (nil, nil)
  @Published var area: Area = .graph { didSet { persistDesktop() } }
  @Published var store: AtlasStore?
  @Published var folder: URL?
  @Published var runs: [AtlasRun] = []
  @Published var docs: [AtlasPDF] = []
  @Published var selected: String? { didSet { persistDesktop() } }
  @Published var shownPDF: AtlasPDF? { didSet { persistDesktop() } }
  @Published var highlight: PDFAnchor? { didSet { persistDesktop() } }
  @Published var readingPane: ReadingPane = .task { didSet { persistDesktop() } }
  @Published var sourceFocusRequest: UUID?
  private var questionReturn: QuestionReturn?
  @Published var anchor: PDFAnchor?
  @Published var excerpt: AnswerExcerpt?
  @Published var referenceID: String?
  @Published var draft = ""
  @Published var composerFocus: UUID?
  @Published var error = ""
  @Published var saving = ""
  let agentAccess: AtlasAgentService
  @Published var agentSettings = false
  @Published var settings = false
  @Published var returnToQuestion = false { didSet { persistDesktop() } }
  @Published var active: Set<String> = []
  @Published var profile: ProviderProfile?
  private var handles: [String: Task<Void, Never>] = [:]
  private var stores: [URL: AtlasStore] = [:]
  // Only endpoint-bound public profile data goes into UserDefaults.
  let defaults: UserDefaults
  private let credential: (ProviderProfile) throws -> String?
  init(
    defaults: UserDefaults = .standard,
    credential: @escaping (ProviderProfile) throws -> String? = Credentials.read
  ) {
    self.agentAccess = AtlasAgentService(preferences: defaults)
    self.credential = credential
    self.defaults = defaults
    if let data = defaults.data(forKey: "modelProfile") {
      let saved = try? JSONDecoder().decode(ProviderProfile.self, from: data)
      // Retired app-owned OAuth profiles remain decodable for historical run manifests.
      profile = saved?.subscriptionAccount == nil ? saved : nil
    }
    if let path = defaults.string(forKey: "recentAtlas"),
      FileManager.default.fileExists(atPath: path)
    {
      do { try open(URL(fileURLWithPath: path)) } catch { self.error = error.localizedDescription }
    }
  }
  func openFirstAtlas() {
    guard store == nil, error.isEmpty, defaults.string(forKey: "recentAtlas") == nil else { return }
    perform {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let first = support.appendingPathComponent("Living Atlas/项目/未命名 Atlas", isDirectory: true)
      try open(first, creating: !FileManager.default.fileExists(atPath: first.path))
    }
  }
  var current: AtlasRun? { runs.first { $0.id == selected } }
  var versions: [AtlasRun] { runs.filter { $0.turnID == current?.turnID } }
  func fresh(focus: Bool = false) {
    excerpt = nil
    referenceID = nil
    saveDraft(draft, anchor: nil)
    selected = nil
    questionReturn = nil
    area = .graph
    readingPane = .task
    returnToQuestion = false
    composerFocus = focus ? UUID() : nil
  }
  func beginQuestion(from selection: PDFAnchor) {
    guard selection.versionID == shownPDF?.versionID else {
      error = "当前显示的文档版本已改变，请在原文中重新选择。"
      return
    }
    excerpt = nil
    referenceID = nil
    saveDraft(draft, anchor: selection)
    guard !hasUnsavedDraft else { return }
    selected = nil
    questionReturn = nil
    returnToQuestion = false
    // A text selection binds this question, without moving or reloading the reader.
    if highlight != selection { highlight = nil }
    readingPane = .task
    composerFocus = UUID()
  }
  struct ChatOriginList: Identifiable {
    let id = UUID()
    let origins: [ChatArchiveExcerpt]
  }
  @Published var webSource: FrozenWebPage?
  @Published var citationList: CanvasCitationList?
  func showCanvasCitations(_ run: AtlasRun) {
    guard let store else { return }
    perform { citationList = try CanvasCitationList(citations: store.canvasCitations(forTurn: run.turnID)) }
  }
  @Published var relationSource: CanvasRelationSource?
  @Published var chatOriginList: ChatOriginList?
  struct SearchOrigin: Identifiable {let id=UUID();let source:AtlasSearchSource}
  @Published var searchOrigin:SearchOrigin?
  func revealSearch(_ source:AtlasSearchSource) {
    if let anchor=source.pdfAnchor {follow(anchor)}
    else {searchOrigin=SearchOrigin(source:source)}
  }
  @Published var writingReference: String?
  func openReference(_ id: String) {
    guard let store else { return }
    perform {
      if let relation = try store.canvasRelationSource(reference: id) { relationSource = relation; return }
      if let page=try store.frozenWeb(reference:id){webSource=page;return}
      let origins = try store.chatOrigins(referenceID: id)
      if !origins.isEmpty {
        chatOriginList = ChatOriginList(origins: origins)
        return
      }
      if try store.writingSourceTarget(id) != nil {
        writingReference = id
        area = .notes
        return
      }
      if let target = try store.pdfPageSourceTarget(id) {
        followPage(target.file, page: target.page)
        return
      }
      if let pdf = try store.wholePDFSourceInfo(id) {
        followPage(try store.pdf(versionID: pdf.versionID), page: 0)
        return
      }
      if let source=try store.searchSource(referenceID:id){revealSearch(source);return}
      throw AtlasStoreError.invalid("未能打开这项来源。")
    }
  }
  func ask(excerpt source: AnswerExcerpt? = nil, reference: String? = nil) {
    excerpt = source
    referenceID = reference
    saveDraft(draft, anchor: nil)
    guard !hasUnsavedDraft else { return }
    selected = nil
    questionReturn = nil
    returnToQuestion = false
    area = .graph
    readingPane = .task
    composerFocus = UUID()
  }
  func saveRecoveryPointsOnClose() {
    do {
      NotificationCenter.default.post(name:.atlasSavePDFPlace,object:store)
      NotificationCenter.default.post(name: .atlasSaveAnswerPlace, object: store)
      for openStore in stores.values {
        let root=try RecoveryPolicy.root(openStore,defaults:defaults)
        _ = try openStore.saveRecoveryPoint(at:root,keep:RecoveryPolicy.keep(defaults))
        RecoveryPolicy.remember(root,store:openStore,defaults:defaults)
      }
    } catch {
      self.error="本机恢复点未完成："+error.localizedDescription
      let alert=NSAlert();alert.messageText="本机恢复点未完成";alert.informativeText=error.localizedDescription;alert.runModal()
    }
  }
  func refreshAfterLifecycle(_ target:AtlasStore)throws{
    try refresh(target)
    docs=try target.pdfs()
    if let shownPDF,!docs.contains(where:{$0.id==shownPDF.id}){self.shownPDF=docs.first;highlight=nil;sourceFocusRequest=nil}
    if let selected,!runs.contains(where:{$0.id==selected}){self.selected=nil}
    NotificationCenter.default.post(name:.atlasLifecycleChanged,object:target)
  }
  func didPurgeProject(_ url:URL) {
    stores.removeValue(forKey:url.standardizedFileURL)
    if store?.directory==url {
      agentAccess.revoke()
      agentAccess.attach(store:nil)
      store=nil;folder=nil;runs=[];docs=[];selected=nil;shownPDF=nil
      defaults.removeObject(forKey:"recentAtlas")
    }
  }
  func choose(new: Bool) {
    if new {
      let panel = NSSavePanel()
      panel.title = "新建 Atlas"
      panel.nameFieldStringValue = "阅读札记"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      perform {
        guard !FileManager.default.fileExists(atPath: url.path) else {
          throw AtlasStoreError.invalid("请选择一个新项目名称。")
        }
        try open(url, creating: true)
      }
    } else {
      let panel = NSOpenPanel()
      panel.title = "打开 Atlas 文件夹"
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      guard panel.runModal() == .OK, let url = panel.url else { return }
      perform { try open(url) }
    }
  }
  func open(_ url: URL, creating: Bool = false) throws {
    if hasUnsavedDraft, let store {
      do {
        try store.saveDraft(draft, anchor: anchor, excerpt: excerpt, referenceID: referenceID)
        hasUnsavedDraft = false
      } catch { throw AtlasStoreError.invalid("当前草稿未能保存，仍保留在这个项目中。" + error.localizedDescription) }
    }
    let dir = URL(
      fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
    if !creating, stores[dir] == nil {
      guard
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspace.sqlite").path)
      else {
        throw AtlasStoreError.invalid("这个目录里没有 Atlas 数据库。")
      }
    }
    let newStore = try stores[dir] ?? AtlasStore(directory: dir, title: dir.lastPathComponent)
    let draftState = try newStore.loadDraft()
    let rows = try newStore.runs()
    let files = try newStore.pdfs()
    let view = try newStore.readViewState(DesktopView.self, key: "desktop")
    var nextPDF = files.first
    var restoreProblem = ""
    if let version = view?.documentVersion {
      do { nextPDF = try newStore.pdf(versionID: version) } catch {
        nextPDF = nil
        restoreProblem = "项目已打开。上次阅读的原件无法恢复：" + error.localizedDescription
      }
    }
    let restoredZoom = try newStore.canvasZoom()
    restoring = true
    canvasZoom = restoredZoom
    composerFocus = nil
    sourceFocusRequest = nil
    stores[dir] = newStore
    assistantDestination = nil
    assistantSelectedEntrances = []
    assistantVisibleRuns = [:]
    assistantNote = (nil, nil)
    assistantShown = false
    store = newStore
    agentAccess.attach(store:newStore)
    folder = dir
    runs = rows
    docs = files
    selected = view?.run.flatMap { id in rows.first(where: { $0.id == id })?.id }
    shownPDF = nextPDF
    highlight = nextPDF == nil ? nil : view?.highlight
    draft = draftState.text
    citationList = nil
    relationSource = nil
    chatOriginList = nil
    writingReference = nil
    excerpt = draftState.excerpt
    referenceID = draftState.referenceID
    anchor = draftState.anchor
    area = view.flatMap { Area(rawValue: $0.area) } ?? .overview
    readingPane =
      view?.pane.flatMap(ReadingPane.init(rawValue:)) ?? (area == .library ? .source : .task)
    questionReturn = view?.questionReturn
    returnToQuestion = view?.returnToQuestion ?? false
    saving = "已保存"
    error = restoreProblem
    restoring = false
    defaults.set(dir.path, forKey: "recentAtlas")
  }
  func perform(_ action: () throws -> Void) {
    do { try action() } catch {
      if !hasUnsavedDraft { saving = "操作未完成" }
      self.error = error.localizedDescription
    }
  }
  func saveDraft(_ text: String, anchor newAnchor: PDFAnchor?) {
    draft = text
    anchor = newAnchor
    guard let store else { return }
    do {
      try store.saveDraft(text, anchor: newAnchor, excerpt: excerpt, referenceID: referenceID)
      hasUnsavedDraft = false
      saving = "已保存"
    } catch {
      hasUnsavedDraft = true
      self.error = error.localizedDescription
      saving = "保存失败"
    }
  }
  func saveProfile(_ p: ProviderProfile) throws {
    let data = try JSONEncoder().encode(p)
    defaults.set(data, forKey: "modelProfile")
    profile = p
    try store?.saveViewState(false,key:"restore.needs-model-confirmation")
  }
  func refresh(_ target: AtlasStore) throws {
    guard target === store else { return }
    runs = try target.runs()
  }
  private(set) var submittedCanvasTurn: String?
  @Published private(set) var submittedCanvasDraft: String?
  func send(retry: AtlasRun? = nil, reusingContext: Bool = true, canvas: CanvasQuestionDraft? = nil, onMap: Bool = false) {
    guard let store, retry != nil || !(canvas?.text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    if let retry, runs.contains(where: { $0.turnID == retry.turnID && active.contains($0.id) }) {
      return
    }
    guard active.count < 2 else {
      error = "已有两个回答在生成，请稍后再试。"
      return
    }
    guard let profile else {
      settings = true
      return
    }
    perform {
      if try store.readViewState(Bool.self,key:"restore.needs-model-confirmation")==true {settings=true;return}
      let key = try credential(profile)
      if profile.endpoint.host?.lowercased() == "api.deepseek.com", key?.isEmpty != false {
        settings = true
        return
      }
      let run: AtlasRun
      if let retry {
        run = try store.retry(
          retry.id, provider: profile.endpoint.absoluteString, model: profile.model,
          requestProfile: profile, reusingContext: reusingContext)
      } else if let canvas {
        run = try store.start(question:canvas.text,referenceID:canvas.referenceID,provider:profile.endpoint.absoluteString,model:profile.model,requestProfile:profile,canvas:canvas)
        submittedCanvasTurn = run.turnID
        submittedCanvasDraft = canvas.id
      } else {
        run = try store.start(
          question: draft, anchor: anchor,
          following: excerpt?.runID ?? current.flatMap { $0.answer.isEmpty ? nil : $0.id },
          excerpt: excerpt, referenceID: referenceID,
          provider: profile.endpoint.absoluteString, model: profile.model, requestProfile: profile)
        excerpt = nil
        referenceID = nil
        draft = ""
        anchor = nil
      }
      if canvas == nil && !onMap {
        selected = run.id
        if area != .library { area = .graph }
        readingPane = .task
      }
      guard run.status.isActive, handles[run.id] == nil else {
        try refresh(store)
        return
      }
      active.insert(run.id)
      saving = "已保存"
      error = ""
      try refresh(store)
      handles[run.id] = Task { [weak self] in
        guard let self else { return }
        defer {
          active.remove(run.id)
          handles.removeValue(forKey: run.id)
        }
        do {
          try await profile.stream(
            frozenBody: store.frozenBody(for: run.id),
            recordedProfile: store.frozenProfile(for: run.id), key: key,
            cliInput: profile.isCodexCLI ? store.frozenCLIInput(for: run.id) : nil,
            onUsage: { try store.recordUsage($0, for: run.id) },
            onFinish: { try store.recordFinishReason($0, for: run.id) }
          ) { delta in
            try Task.checkCancellation()
            guard try store.append(delta, to: run.id) else { throw CancellationError() }
            // A delta changes one draft. Keep the other open answers and their history in place.
            if self.store === store {
              if let index = self.runs.firstIndex(where: { $0.id == run.id }) {
                self.runs[index] = try store.run(run.id)
              } else {
                try self.refresh(store)
              }
            }
          }
          try Task.checkCancellation()
          _ = try store.finish(run.id, status: .completed)
        } catch {
          if !Task.isCancelled {
            do {
              _ = try store.finish(run.id, status: .failed, reason: error.localizedDescription)
            } catch {
              if self.store === store {
                self.saving = "保存失败"
                self.error = error.localizedDescription
              }
            }
          }
        }
        self.perform { try self.refresh(store) }
      }
    }
  }
  func describeOrganizationRange(_ description: String) async throws -> String {
    try await interpretRequest(description, instruction: OrganizationRangeDescription.instruction, task: nil)
  }

  func interpretRequest(_ description: String, instruction: String, task: AnswerTask? = .structured) async throws -> String {
    guard let profile, let store else { throw AtlasStoreError.invalid("请设置模型，或输入完整标题或地域名。") }
    guard try store.readViewState(Bool.self, key: "restore.needs-model-confirmation") != true else {
      throw AtlasStoreError.invalid("请先确认恢复项目使用的模型。")
    }
    let packet = try profile.prepare(question: instruction,
                                     materials: [.quotation(description)], maxOutputTokens: 768, task: task)
    var output = ""
    try await profile.stream(prepared: packet, key: credential(profile)) { delta in
      try Task.checkCancellation()
      guard output.utf8.count + delta.utf8.count <= 16_384 else { throw AtlasStoreError.invalid("范围解析结果过长。") }
      output += delta
    }
    return output
  }
  func organize(_ scope: OrganizationScope) async throws -> OrganizationModelEnvelope {
    try await organize(scope, instruction: OrganizationModelEnvelope.instruction)
  }
  func organizeArticle(_ scope: OrganizationScope) async throws -> OrganizationModelEnvelope {
    try await organize(scope, instruction: OrganizationModelEnvelope.instruction
      + "\n本次用户想梳理一篇材料。用 summary 写出材料主旨，用 coverage 分点梳理原文的关键论点或步骤，用 open_questions 记录原文留下的问题。原文无需修改时仍提供这份梳理，operations 为空。", task: .structured)
  }
  private func organize(_ scope: OrganizationScope, instruction: String, task: AnswerTask? = nil) async throws -> OrganizationModelEnvelope {
    guard let profile,let store else {settings=true;throw AtlasStoreError.invalid("请先设置模型。")}
    guard try store.readViewState(Bool.self,key:"restore.needs-model-confirmation") != true else {settings=true;throw AtlasStoreError.invalid("请确认恢复项目使用的模型。")}
    let materials=try OrganizationModelEnvelope.input(scope)
    let prepared=try profile.prepare(question:instruction,materials:[.quotation(materials)],maxOutputTokens:OrganizationModelEnvelope.outputTokenBudget,task:task)
    guard prepared.body.count <= OrganizationModelEnvelope.requestByteLimit else {throw AtlasStoreError.invalid("所选整理材料超过输入预算。请缩小范围。")}
    var result=""
    try await profile.stream(prepared:prepared,key:credential(profile)){text in
      try Task.checkCancellation()
      result+=text
      guard result.utf8.count<=256000 else {throw AtlasStoreError.invalid("整理建议超出可读取长度。")}
    }
    return try OrganizationModelEnvelope.decode(result,within:scope)
  }
  func stop(_ run: AtlasRun) {
    guard let store, let task = handles[run.id] else { return }
    task.cancel()
    active.remove(run.id)
    do {
      _ = try store.finish(run.id, status: .cancelled)
      try refresh(store)
      saving = "已保存"
    } catch {
      saving = "保存失败"
      self.error = error.localizedDescription
    }
  }
  @Published var pageToPlace: PDFPageRequest?
  struct PDFPageRequest: Identifiable { let id = UUID(); let file: AtlasPDF; let index: Int? }
  func importDocument(update: Bool, canvasOrigin: CGPoint? = nil, deferPlacement: Bool = false, onMap: ((AtlasPDF) -> Void)? = nil) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    importPDF(at: url, update: update, canvasOrigin: canvasOrigin, deferPlacement: deferPlacement, onMap: onMap)
  }
  func importPDF(at url: URL, update: Bool = false, canvasOrigin: CGPoint?, deferPlacement: Bool = false, onMap: ((AtlasPDF) -> Void)?) {
    guard let store else { return }
    perform {
      let file: AtlasPDF
      do {
        file = try store.importPDF(at: url, updating: update ? shownPDF?.id : nil, canvasOrigin: canvasOrigin, deferPlacement: deferPlacement)
      } catch PDFUnlockError.required {
        guard let password = promptPDFPassword(url.lastPathComponent) else { return }
        file = try store.importPDF(
          at: url, updating: update ? shownPDF?.id : nil, password: password, canvasOrigin: canvasOrigin, deferPlacement: deferPlacement)
      }
      docs = try store.pdfs()
      if let onMap { onMap(file) } else { openDocument(file) }
      saving = "已保存"
    }
  }
  func openQuestion(_ run: AtlasRun, keepingReadingPlace: Bool = false) {
    let preserve = keepingReadingPlace && current?.turnID == run.turnID
    selected = run.id
    questionReturn = nil
    returnToQuestion = false
    if !preserve {
      if let source = run.anchor, let store {
        do {
          shownPDF = try store.pdf(versionID: source.versionID)
          highlight = source
          sourceFocusRequest = UUID()
        } catch {
          shownPDF = nil
          highlight = nil
          sourceFocusRequest = nil
          self.error = "历史问题已打开，冻结版本的原件暂不可读。" + error.localizedDescription
        }
      } else {
        // The left column remains available for independent reading. This turn has no source to paint.
        highlight = nil
        sourceFocusRequest = nil
      }
    }
    area = .graph
    readingPane = .task
  }

  func openDocument(_ file: AtlasPDF) {
    // Changing the material being read must not reinterpret the draft's frozen citation.
    highlight = nil
    sourceFocusRequest = nil
    shownPDF = file
    area = .library
    readingPane = .source
  }

  private func rememberSourceReturn(_ store: AtlasStore) throws {
    if questionReturn == nil {
      NotificationCenter.default.post(name: .atlasSavePDFPlace, object: store)
      let place = try shownPDF.flatMap {
        try store.readViewState(PDFReadingPlace.self, key: "pdf." + $0.versionID)
      }
      questionReturn = QuestionReturn(
        area: area.rawValue, run: selected, documentVersion: shownPDF?.versionID, place: place,
        highlight: highlight)
    }
  }

  func followPage(_ file: AtlasPDF, page: Int) {
    guard let store else { return }
    perform {
      try rememberSourceReturn(store)
      let place = PDFReadingPlace(
        page: page, x: 0, y: 0, selection: nil, navigation: UUID(), scaleMode: .fitWidth,
        scale: nil, pageTop: true)
      try store.saveViewState(place, key: "pdf." + file.versionID)
      shownPDF = file
      highlight = nil
      sourceFocusRequest = nil
      area = .library
      readingPane = .source
      returnToQuestion = true
      NotificationCenter.default.post(
        name: .atlasRestorePDFPlace, object: store,
        userInfo: ["version": file.versionID, "place": place])
    }
  }
  func follow(_ source: PDFAnchor) {
    guard let store else { return }
    perform {
      let historical = try store.pdf(versionID: source.versionID)
      try rememberSourceReturn(store)
      shownPDF = historical
      highlight = source
      sourceFocusRequest = UUID()
      area = .library
      readingPane = .source
      returnToQuestion = true
    }
  }

  func backToQuestion() {
    guard let store else { return }
    let target = questionReturn
    if let target {
      selected = target.run
      highlight = nil
      sourceFocusRequest = nil
      if let version = target.documentVersion {
        do {
          shownPDF = try store.pdf(versionID: version)
          highlight = target.highlight
          if let place = target.place {
            try store.saveViewState(place, key: "pdf." + version)
            NotificationCenter.default.post(
              name: .atlasRestorePDFPlace, object: store,
              userInfo: ["version": version, "place": place, "focus": target.highlight as Any])
          }
        } catch {
          if shownPDF?.versionID != version { shownPDF = nil }
          self.error = "已返回追问，先前的阅读位置暂时无法恢复。" + error.localizedDescription
        }
      } else {
        shownPDF = nil
      }
    }
    questionReturn = nil
    area = target.flatMap { Area(rawValue: $0.area) } ?? .graph
    readingPane = .task
    returnToQuestion = false
    if selected == nil { composerFocus = UUID() }
  }
}
