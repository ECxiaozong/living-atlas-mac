import AtlasCore
import SwiftUI
import UniformTypeIdentifiers

/// Embed this sheet in a workspace. Only selected, committed message versions reach the conversion callback.
struct ChatArchiveImportView: View {
  let store: AtlasStore
  let projectionNodeID: String?
  let sourceExcerpt: ChatArchiveExcerpt?
  let onQuestion: ((String) -> Void)?
  var onOrganize: (([ChatArchiveSource]) -> Void)? = nil
  init(
    store: AtlasStore, projectionNodeID: String? = nil, sourceExcerpt: ChatArchiveExcerpt? = nil,
    onOrganize: (([ChatArchiveSource]) -> Void)? = nil, onQuestion: ((String) -> Void)? = nil
  ) {
    self.store = store
    self.projectionNodeID = projectionNodeID
    self.sourceExcerpt = sourceExcerpt
    self.onOrganize = onOrganize
    self.onQuestion = onQuestion
  }
  @ViewState private var proposal: ChatProjectionPlan?
  @ViewState private var plans: [ChatProjectionPlan] = []
  @ViewState private var composeSources: [ChatArchiveSource] = []
  @ViewState private var highlighted: NSRange?
  @ViewState private var textSelection: NSRange?
  @Environment(\.dismiss) private var dismiss
  @ViewState private var namespace = "我的 ChatGPT"
  @ViewState private var paste = ""
  @ViewState private var pasteEditor = false
  @ViewState private var picker = false
  @ViewState private var archives: [SavedChatArchive] = []
  @ViewState private var preview: ChatImportPreview?
  @ViewState private var chosen: Set<String> = []
  @ViewState private var changes: [String: ChatImportChanges] = [:]
  @ViewState private var busy = false
  @ViewState private var status = ""
  @ViewState private var issue: String?
  @ViewState private var sources: [ChatArchiveSource] = []
  @ViewState private var selectedSource: ChatArchiveSource?
  @ViewState private var original: String?
  @ViewState private var saveTask: Task<ChatImportReceipt, Error>?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        TaskCompanion(pose: busy ? .working : (proposal != nil ? .discovery : .calm), size: 52)
        VStack(alignment: .leading, spacing: 3) {
          Text("聊天原档")
            .font(AtlasTypeface.reading.font(22).weight(.medium))
            .foregroundStyle(AtlasPalette.ink)
          Text("从导出包或粘贴文本恢复会话与消息来路")
            .font(.system(size: 12.5))
            .foregroundStyle(AtlasPalette.umber)
        }
        Spacer()
        Button("关闭") { dismiss() }
          .buttonStyle(PaperButton(compact: true))
          .disabled(busy)
      }
      PaperRule()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let selectedSource {
            originalPane(selectedSource)
          } else if let proposal {
            projectionPane(proposal)
          } else if !composeSources.isEmpty {
            ChatProjectionComposer(
              store: store, sources: composeSources,
              onPlan: {
                proposal = $0
                composeSources = []
                refreshArchives()
              }, onClose: { composeSources = [] })
          } else if let preview {
            previewPane(preview)
          } else {
            entryPane
          }
          if let issue {
            Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(
              .enabled)
          }
          if !status.isEmpty {
            Text(status).foregroundStyle(.secondary).accessibilityIdentifier("chat-import-status")
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(3)
      }
    }.padding(22).foregroundStyle(AtlasPalette.ink).background(AtlasPalette.paper)
      .frame(minWidth: 450, idealWidth: 760, minHeight: 420, idealHeight: 630)
      .task {
        refreshArchives()
        if let sourceExcerpt {
          openOrigin(sourceExcerpt)
        } else if let projectionNodeID {
          proposal = plans.first { $0.changes.contains(where: { $0.nodeID == projectionNodeID }) }
        }
      }
      .interactiveDismissDisabled(busy)
      .dropDestination(for: URL.self) { urls, _ in
        guard !busy, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
        inspectFile(url)
        return true
      }
      .fileImporter(isPresented: $picker, allowedContentTypes: [.zip, .json, .plainText, .folder]) {
        result in
        switch result {
        case .failure(let error):
          if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
        case .success(let url):
          inspectFile(url)
        }
      }
  }

  private func inspectFile(_ url: URL) {
    let scope = namespace
    inspect {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      return try ChatArchiveParser.preview(file: url, namespace: scope)
    }
  }

  private var entryPane: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("导出来源，例如「个人账号」", text: $namespace)
        .textFieldStyle(.roundedBorder).accessibilityLabel("导出来源")
      Text("同一来源可识别新增或变更的消息；不同账号请用不同来源名称。").font(.callout)
      HStack {
        Button("选择导出文件或目录") { picker = true }.buttonStyle(PaperButton(primary: true))
        Button("粘贴文本") { pasteEditor.toggle() }.buttonStyle(PaperButton())
      }.disabled(busy || namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      if pasteEditor {
        TextEditor(text: $paste).frame(minHeight: 110).accessibilityLabel("要保存的原始文本")
        Button("预览文本") {
          let body = paste
          let scope = namespace
          inspect { try ChatArchiveParser.pasted(body, namespace: scope) }
        }
        .disabled(busy || paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if !plans.isEmpty {
        Divider()
        Text("转换历史").font(.headline)
        ForEach(plans) { p in
          Button((p.changes.first?.item.title ?? "选段转换") + " · " + stateName(p.status)) {
            proposal = p
            issue = nil
          }
        }
      }
      if !archives.isEmpty {
        Divider()
        Text("本项目已保存的原档").font(.headline)
        ForEach(archives) { item in
          Button {
            let store = self.store
            inspect(saved: item) { try store.reopenChatArchive(item.id) }
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(item.filename)
                Text("\(item.namespace) · 已保存 \(item.savedConversations) 个会话").font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right")
            }
          }.buttonStyle(.plain).disabled(busy)
        }
      }
    }
  }

  @ViewBuilder private func previewPane(_ value: ChatImportPreview) -> some View {
    Button("返回原档列表") { reset() }.disabled(busy)
    Text(value.filename).font(.title3.bold())
    Text("完整原件保存在本机。只有勾选且已保存的会话可交给整理。").font(.callout)
    ForEach(value.conversations) { c in
      Toggle(
        isOn: Binding(
          get: { chosen.contains(c.id) },
          set: { flag in
            if flag { chosen.insert(c.id) } else { chosen.remove(c.id) }
            sources = []
            status = ""
          })
      ) {
        VStack(alignment: .leading, spacing: 4) {
          Text(c.title)
          let counts = changes[c.id] ?? ChatImportChanges()
          Text("\(c.messages.count) 条消息 · \(c.branchCount) 个分支 · \(c.attachmentCount) 个附件或非文本片段")
            .font(.caption)
          if let stamp = c.messages.compactMap(\.timestamp).min() {
            Text("最早可用时间  " + stamp).font(.caption)
          } else {
            Text("原消息时间未提供").font(.caption)
          }
          Text("新增 \(counts.new)  ·  变更 \(counts.changed)  ·  已有 \(counts.unchanged)").font(
            .caption
          ).foregroundStyle(.secondary)
        }
      }.disabled(busy)
    }
    if !value.diagnostics.isEmpty {
      DisclosureGroup("解析报告（\(value.diagnostics.count) 项）") {
        ForEach(Array(value.diagnostics.enumerated()), id: \.offset) { _, s in
          Text(s).font(.callout).textSelection(.enabled)
        }
      }
    }
    if busy && saveTask != nil {
      Button("保存完当前会话后停止") { saveTask?.cancel() }
    } else {
      HStack {
        Group {
          Button(
            chosen.isEmpty
              || chosen.contains(where: {
                (changes[$0]?.new ?? 0) + (changes[$0]?.changed ?? 0) > 0
              }) ? "保存并整理所选增量" : "整理已保存的所选会话"
          ) { save(value, organize: true) }
          .buttonStyle(PaperButton(primary: true)).disabled(chosen.isEmpty || busy)
        }
        Button("仅保存档案") { save(value, organize: false) }.buttonStyle(PaperButton()).disabled(busy)
      }
    }
    if !sources.isEmpty {
      Divider()
      Text("已保存的原消息").font(.headline)
      ForEach(sources) { msg in
        Button {
          highlighted = nil
          textSelection = nil
          selectedSource = msg
          original = nil
          issue = nil
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(msg.conversationTitle) · \(roleName(msg.role)) · 版本 \(msg.version)").font(
              .caption
            ).foregroundStyle(.secondary)
            Text(msg.body.isEmpty ? "非文本消息" : msg.body).lineLimit(2)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
      }
    }
  }
  private func openOrigin(_ excerpt: ChatArchiveExcerpt) {
    do {
      let located = try excerpt.resolve(in: store)
      highlighted = located.1
      textSelection = located.1
      original = nil
      selectedSource = located.0
    } catch { issue = error.localizedDescription }
  }
  @ViewBuilder private func originalPane(_ msg: ChatArchiveSource) -> some View {
    Button("返回会话消息") {
      selectedSource = nil
      original = nil
    }
    Text(msg.conversationTitle).font(.title3.bold())
    Text(
      "\(roleName(msg.role)) · 原角色 \(msg.rawRole ?? "未提供") · 版本 \(msg.version) · \(msg.timestamp ?? "原时间未提供")"
    ).font(.caption)
    if let parent = msg.parent { Text("原分支父消息  " + parent).font(.caption) }
    ChatSelectableMessage(source: msg, highlighted: highlighted) { textSelection = $0 }.frame(
      minHeight: 135, maxHeight: 215)
    if onQuestion != nil {
      Button("从所选原句继续问") {
        guard let r = textSelection else { return }
        do {
          let ref = try store.chatReference(ChatArchiveExcerpt.capture(msg, range: r))
          dismiss()
          onQuestion?(ref)
        } catch { issue = error.localizedDescription }
      }.disabled(textSelection == nil)
    }
    ForEach(msg.parts.filter { $0.kind != "text" }, id: \.index) { part in
      Text(
        "附件或其他片段 · \(part.kind) · \(part.status == "archived" ? "存在于原包" : part.status == "unavailable" ? "原包中未定位到" : "未解析")"
      ).font(.callout)
    }
    Divider()
    Text(
      [msg.filename, msg.location.member, msg.location.pointer].compactMap { $0 }.joined(
        separator: "  /  ")
    ).font(.caption).textSelection(.enabled)
    Button("定位原档中的这条消息") {
      let store = self.store
      Task {
        do {
          original = try await Task.detached { try store.chatOriginal(versionID: msg.id) }.value
        } catch { issue = error.localizedDescription }
      }
    }
    if let original {
      Text(original).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
    }
  }
  private func roleName(_ role: String) -> String {
    ["user": "用户", "assistant": "助手", "system": "系统", "developer": "开发者", "tool": "工具"][role]
      ?? "身份未知"
  }
  private func inspect(
    saved: SavedChatArchive? = nil, parse: @escaping @Sendable () throws -> ChatImportPreview
  ) {
    busy = true
    issue = nil
    status = "正在本地解析…"
    Task {
      defer { busy = false }
      do {
        let store = self.store
        let (value, counts) = try await Task.detached {
          let p = try parse()
          return (p, try store.chatImportChanges(p))
        }.value
        let keys =
          saved.map { Set($0.selection) }
          ?? (value.conversations.count == 1 ? Set(value.conversations.map(\.id)) : [])
        preview = value
        changes = counts
        chosen = keys
        if let saved {
          sources = try await Task.detached {
            try store.chatSources(archiveID: saved.id, selected: keys)
          }.value
        }
        status = saved == nil ? "请选择要保存的会话。" : "已重新打开原档，可继续处理所选会话。"
      } catch {
        issue = error.localizedDescription
        status = ""
      }
    }
  }
  private func save(_ p: ChatImportPreview, organize: Bool) {
    let store = self.store
    let scope = chosen
    busy = true
    issue = nil
    status = "正在保存原件与所选会话…"
    let running = Task.detached {
      try store.saveChatImport(p, selected: scope, cancelled: { Task.isCancelled })
    }
    saveTask = running
    Task {
      defer {
        busy = false
        saveTask = nil
      }
      do {
        let report = try await running.value
        let complete = Set(report.completed)
        let data = try await Task.detached {
          (
            try store.chatSources(archiveID: report.archiveID, selected: complete),
            try store.chatImportChanges(p)
          )
        }.value
        sources = data.0
        changes = data.1
        refreshArchives()
        status =
          "原档已保存。已完成 \(complete.count) 个会话，剩余 \(report.pending.count) 个；新增 \(report.changes.new)，变更 \(report.changes.changed)，已有 \(report.changes.unchanged)。"
        let failures = report.diagnostics.filter { !p.diagnostics.contains($0) }
        if !failures.isEmpty { issue = failures.joined(separator: "\n") }
        if organize && report.pending.isEmpty && !sources.isEmpty {
          let ids = Set(report.changedVersionIDs)
          let eligible = ids.isEmpty ? sources : sources.filter { ids.contains($0.id) }
          if let onOrganize { onOrganize(eligible) } else { composeSources = eligible }
        }
      } catch {
        issue = error.localizedDescription
        status = ""
      }
    }
  }
  private func stateName(_ status: String) -> String {
    ["reviewable": "待确认", "applied": "已应用", "cancelled": "已放弃", "rolled_back": "已撤回"][status]
      ?? status
  }
  @ViewBuilder private func projectionPane(_ p: ChatProjectionPlan) -> some View {
    Button("返回原档") {
      proposal = nil
      issue = nil
      refreshArchives()
    }
    Text("转换对照 · " + stateName(p.status)).font(.system(.title2, design: .serif))
    ForEach(p.changes) { c in
      VStack(alignment: .leading, spacing: 6) {
        Text(c.item.kind.label + " · " + c.item.title).font(.headline)
        Text(p.status == "reviewable" ? "原图谱无此对象 → 新增条目和画布入口" : "对应图谱条目").font(.caption)
          .foregroundStyle(.secondary)
        Text(c.item.body).textSelection(.enabled)
        ForEach(Array(c.item.sources.enumerated()), id: \.offset) { index, e in
          Button("回到原消息 " + String(index + 1) + " · " + String(e.exact.prefix(28))) {
            openOrigin(e)
          }
        }
        if p.status == "applied", onQuestion != nil {
          Button("从这项内容继续问") {
            do {
              let ref = try store.chatProjectionReference(nodeID: c.nodeID)
              dismiss()
              onQuestion?(ref)
            } catch { issue = error.localizedDescription }
          }
        }
      }.padding(12).modifier(PaperSurface())
    }
    if p.status == "reviewable" {
      HStack {
        Button("应用到本图谱") {
          do {
            proposal = try store.applyChatProjection(p.id)
            refreshArchives()
          } catch { issue = error.localizedDescription }
        }.buttonStyle(PaperButton(primary: true))
        Button("放弃建议") {
          do {
            try store.discardChatProjection(p.id)
            refreshArchives()
            proposal = plans.first { $0.id == p.id }
          } catch { issue = error.localizedDescription }
        }
      }
    } else if p.status == "applied" {
      Button("检查并撤回本次转换") {
        do {
          try store.undoChatProjection(p.id)
          refreshArchives()
          proposal = plans.first { $0.id == p.id }
        } catch { issue = error.localizedDescription }
      }
    }
  }
  private func refreshArchives() {
    do {
      archives = try store.chatArchives()
      plans = try store.chatProjectionPlans()
    } catch { issue = error.localizedDescription }
  }
  private func reset() {
    preview = nil
    selectedSource = nil
    original = nil
    sources = []
    issue = nil
    status = ""
    refreshArchives()
  }
}
