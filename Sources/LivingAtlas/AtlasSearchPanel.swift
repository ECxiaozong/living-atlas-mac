import AtlasCore
import SwiftUI

struct AtlasSearchPanel: View {
  let store: AtlasStore
  let profile: ProviderProfile?
  let onOpen: (AtlasSearchSource) -> Void
  let onAsk: (String) -> Void
  var allowsRelationQuestion = false
  @EnvironmentObject private var s: Session
  @Environment(\.dismiss) private var dismiss
  @ViewState private var query = ""
  @ViewState private var kind: AtlasSearchKind?
  @ViewState private var history = false
  @ViewState private var trash = false
  @ViewState private var sendCandidates = false
  @ViewState private var items: [AtlasSearchHit] = []
  @ViewState private var local: [AtlasSearchHit] = []
  @ViewState private var selected: String?
  @ViewState private var status = ""
  @ViewState private var busy = false
  @ViewState private var work: Task<Void, Never>?
  @ViewState private var index: AtlasSearchIndex?
  @ViewState private var source: AtlasSearchSource?
  @FocusState private var focused: Bool

  var scope: AtlasSearchScope {
    var value = AtlasSearchScope()
    if let kind { value.kinds = [kind] }
    value.includeHistory = history
    value.includeTrash = trash
    return value
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        TaskCompanion(pose: busy ? .working : (source != nil ? .discovery : .exploring), size: 40)
        Text("搜索图谱").font(AtlasTypeface.reading.font(21).weight(.medium)).foregroundStyle(AtlasPalette.ink)
        Spacer()
        Button("关闭") { dismiss() }.buttonStyle(PaperButton(compact: true)).keyboardShortcut(.cancelAction)
      }
      PaperRule()
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(AtlasPalette.umber)
        TextField("搜索文字、代码或记得的关系", text: $query).textFieldStyle(.roundedBorder).focused($focused)
          .accessibilityIdentifier("atlas.search.query").accessibilityLabel("搜索文字、代码或记得的关系")
          .onSubmit { run(semantic: false) }
        if busy { ProgressView().controlSize(.small) }
        Button("自然语言找回") { run(semantic: true) }
          .buttonStyle(PaperButton(primary: true, compact: true))
          .disabled(
            profile == nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      HStack(spacing: 12) {
        Picker("范围", selection: $kind) {
          Text("全部来源").tag(nil as AtlasSearchKind?)
          ForEach(AtlasSearchKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }.frame(maxWidth: 220)
        Toggle("含历史版本", isOn: $history)
        Toggle("含回收内容", isOn: $trash)
        Spacer()
        Menu {
          Button("重建本地索引") { rebuild() }
          Button("恢复已排除的对象") {
            do {
              try store.excludeSearchObject(nil)
              run(semantic: false)
            } catch { status = error.localizedDescription }
          }
        } label: {
          Image(systemName: "ellipsis.circle").foregroundStyle(AtlasPalette.umber)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasChipButtonStyle()).fixedSize()
      }.font(.system(size: 12.5))
      if let profile {
        Toggle("允许将候选片段发至 " + profile.serviceLabel + " 重排", isOn: $sendCandidates).font(.callout)
      } else {
        Text("本地检索可用。在模型设置中连接服务后可使用自然语言找回。").font(.callout)
      }
      HSplitView {
        List(items, selection: $selected) { hit in
          VStack(alignment: .leading, spacing: 3) {
            Text(hit.title).font(AtlasTypeface.reading.font(14).weight(.medium)).lineLimit(1)
            Text(hit.kind.label + " · 版本 " + String(hit.ordinal) + " · " + hit.reason).font(
              .system(size: 11)
            ).foregroundStyle(AtlasPalette.umber).lineLimit(2)
            Text(hit.preview).font(AtlasTypeface.reading.font(12.5)).foregroundStyle(AtlasPalette.ink.opacity(0.8)).lineLimit(2)
          }.padding(.vertical, 4).listRowBackground(Color.clear).tag(hit.id)
        }.scrollContentBackground(.hidden).frame(minWidth: 270)
        VStack(alignment: .leading, spacing: 8) {
          if let source {
            Text(source.hit.title).font(AtlasTypeface.reading.font(16).weight(.medium))
            Text("版本 " + String(source.hit.ordinal) + " · " + source.hit.kind.label)
              .font(.system(size: 11.5))
              .foregroundStyle(AtlasPalette.umber)
            ScrollView {
              Text(highlight(source))
                .font(AtlasTypeface.reading.font(14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(AtlasPalette.paperInset.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AtlasPalette.line.opacity(0.36), lineWidth: 0.7)
            }
            HStack(spacing: 8) {
              Button("打开来源") {
                do {
                  let read = try store.searchSource(source.hit, scope: scope)
                  dismiss()
                  onOpen(read)
                } catch { status = error.localizedDescription }
              }
              .buttonStyle(PaperButton(compact: true))
              if source.hit.kind != .topic {
                Button("引用此段追问") {
                  do {
                    let id = try store.searchReference(source.hit, scope: scope)
                    dismiss()
                    onAsk(id)
                  } catch { status = error.localizedDescription }
                }
                .buttonStyle(PaperButton(primary: true, compact: true))
                .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier(
                  "atlas.search.ask")
              }
              Menu {
                Button("在此图谱的搜索中排除此对象") {
                  do {
                    try store.excludeSearchObject(source.hit.objectID)
                    run(semantic: false)
                  } catch { status = error.localizedDescription }
                }
              } label: {
                Image(systemName: "ellipsis.circle")
              }
            }
            if allowsRelationQuestion && source.hit.kind == .relation {
              Button("结合两端依据提问") {
                do {
                  let reference = try store.searchRelationReference(source.hit, scope: scope)
                  dismiss()
                  onAsk(reference)
                } catch { status = error.localizedDescription }
              }
            }
          } else {
            Text("选择结果以核对原文").foregroundStyle(.secondary)
          }
        }.padding(8).frame(
          minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      HStack {
        Text(status).font(.caption).lineLimit(2)
        Spacer()
        if items != local {
          Button("查看本地结果") {
            replace(local)
            status = "本地词法结果"
          }
        }
      }
    }.padding(18).paperSheet().frame(
      minWidth: 730, idealWidth: 880, minHeight: 480, idealHeight: 620
    )
    .onAppear {
      focused = true
      do {
        index = try AtlasSearchIndex(store: store)
        sendCandidates = try profile.map(store.maySendSearchSnippets(to:)) ?? false
      } catch {
        status = error.localizedDescription
      }
    }
    .onDisappear { work?.cancel() }
    .onChange(of: query) { _, _ in run(semantic: false, debounce: true) }
    .onChange(of: kind) { _, _ in run(semantic: false) }
    .onChange(of: history) { _, _ in run(semantic: false) }
    .onChange(of: trash) { _, _ in run(semantic: false) }
    .onChange(of: sendCandidates) { _, value in
      if let profile {
        do { try store.permitSearchSnippets(value, to: profile) } catch {
          status = error.localizedDescription
        }
      }
      run(semantic: false)
    }
    .onChange(of: selected) { _, _ in selectSource() }
  }

  func highlight(_ source: AtlasSearchSource) -> AttributedString {
    var attributed = AttributedString(source.fullText)
    if let ns = source.range, let r = Range(ns, in: source.fullText),
      let selection = Range(r, in: attributed)
    {
      attributed[selection].backgroundColor = Color.orange.opacity(0.22)
    }
    if let ns = source.matchRange, let r = Range(ns, in: source.fullText),
      let selection = Range(r, in: attributed)
    {
      attributed[selection].backgroundColor = Color.yellow.opacity(0.48)
    }
    return attributed
  }
  func selectSource() {
    guard let hit = items.first(where: { $0.id == selected }) else {
      source = nil
      return
    }
    do { source = try store.searchSource(hit, scope: scope) } catch {
      source = nil
      status = error.localizedDescription
    }
  }
  func replace(_ hits: [AtlasSearchHit]) {
    items = hits
    if !hits.contains(where: { $0.id == selected }) { selected = hits.first?.id }
    selectSource()
  }
  func rebuild() {
    guard let index else { return }
    work?.cancel()
    work = Task { @MainActor in
      do {
        _ = try await Task.detached { try index.rebuild() }.value
        run(semantic: false)
      } catch { status = error.localizedDescription }
    }
  }
  func run(semantic: Bool, debounce: Bool = false) {
    work?.cancel()
    guard let index else { return }
    let q = query
    let sc = scope
    if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      local = []
      replace([])
      status = ""
      busy = false
      return
    }
    busy = true
    work = Task { @MainActor in
      defer { if !Task.isCancelled { busy = false } }
      do {
        if debounce { try await Task.sleep(nanoseconds: 160_000_000) }
        let scan = Task.detached(priority: .userInitiated) { try index.matches(q, scope: sc) }
        let initial = try await withTaskCancellationHandler {
          try await scan.value
        } onCancel: {
          scan.cancel()
        }
        try Task.checkCancellation()
        local = initial
        replace(initial)
        status = "本地匹配 " + String(initial.count) + " 项"
        guard semantic, let profile else { return }
        status = "已显示本地匹配，正在等待模型…"
        while s.active.count >= 2 { try await Task.sleep(nanoseconds: 200_000_000) }
        try Task.checkCancellation()
        let reservation = "search-" + UUID().uuidString
        s.active.insert(reservation)
        defer { s.active.remove(reservation) }
        let key = try Credentials.read(profile)
        try Task.checkCancellation()
        status = "正在扩展描述…"
        let result = try await index.refine(
          q, scope: sc, local: initial,
          maySendSnippets: {
            !Task.isCancelled && (try? store.maySendSearchSnippets(to: profile)) == true
          }
        ) { prompt, budget in
          try await send(profile, prompt: prompt, budget: budget, key: key)
        }
        try Task.checkCancellation()
        local = initial.filter { (try? store.searchSource($0, scope: sc)) != nil }
        var visible = result.results
        if let current = selected,
          let pinned = result.candidates.first(where: { $0.id == current }),
          !visible.contains(where: { $0.id == current })
        {
          visible.append(pinned)
        }
        replace(visible)
        status = result.status
      } catch { if !Task.isCancelled { status = error.localizedDescription } }
    }
  }
  @MainActor func send(_ profile: ProviderProfile, prompt: String, budget: Int, key: String?)
    async throws
    -> String
  {
    try Task.checkCancellation()
    if budget > 512, try !store.maySendSearchSnippets(to: profile) {
      throw AtlasStoreError.invalid("候选发送权限已关闭。")
    }
    let packet = try profile.prepare(question: prompt, materials: [], maxOutputTokens: budget)
    var output = ""
    try await profile.stream(prepared: packet, key: key) { delta in
      try Task.checkCancellation()
      guard output.utf8.count + delta.utf8.count <= 65536 else {
        throw AtlasStoreError.invalid("模型结果过长。")
      }
      output += delta
    }
    return output
  }
}
