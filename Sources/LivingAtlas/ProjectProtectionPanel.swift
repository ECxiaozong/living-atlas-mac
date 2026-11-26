import AtlasCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
  static let atlasLifecycleChanged = Notification.Name("AtlasLifecycleChanged")
}

enum RecoveryPolicy {
  static let rootKey = "local.livingatlas.backup.root",
    keepKey = "local.livingatlas.backup.retention"
  static func root(_ store: AtlasStore, defaults: UserDefaults = .standard) throws -> URL {
    if let path = defaults.string(forKey: rootKey) {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return try store.defaultRecoveryRoot()
  }
  static func roots(_ store: AtlasStore, defaults: UserDefaults = .standard) throws -> [URL] {
    var paths = Set(
      defaults.stringArray(forKey: "local.livingatlas.backup.roots." + store.workspaceID) ?? [])
    paths.insert(try store.defaultRecoveryRoot().path)
    paths.insert(try root(store, defaults: defaults).path)
    return paths.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
  }
  static func remember(_ root: URL, store: AtlasStore, defaults: UserDefaults = .standard) {
    let key = "local.livingatlas.backup.roots." + store.workspaceID
    var paths = Set(defaults.stringArray(forKey: key) ?? [])
    paths.insert(root.path)
    defaults.set(paths.sorted(), forKey: key)
  }
  static func keep(_ defaults: UserDefaults = .standard) -> Int {
    let n = defaults.integer(forKey: keepKey)
    return (1...365).contains(n) ? n : 7
  }
}

struct ProjectProtectionPanel: View {
  let store: AtlasStore
  var defaults: UserDefaults = .standard
  let onRestore: (URL) -> Void
  var onPurge: (URL) -> Void = { _ in }
  var onChanged: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  @ViewState private var tab = 0
  @ViewState private var summary: ProjectArchiveSummary?
  @ViewState private var objects = [RecyclableObject]()
  @ViewState private var versions = [ExportVersion]()
  @ViewState private var points = [URL]()
  @ViewState private var backupRoot: URL?
  @ViewState private var knownRoots = [URL]()
  @ViewState private var keep = 7
  @ViewState private var selected: String?
  @ViewState private var showTrash = true
  @ViewState private var typed = ""
  @ViewState private var busy = false
  @ViewState private var job: Task<Void, Never>?
  @ViewState private var status = ""
  @ViewState private var problem = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 9) {
        AtlasArt.compass.resizable().scaledToFit().frame(width: 20, height: 20).accessibilityHidden(true)
        Text("项目与数据").font(AtlasTypeface.reading.font(21).weight(.medium)).foregroundStyle(AtlasPalette.ink)
        Spacer()
        Button(busy ? "取消操作" : "关闭") { if busy { job?.cancel() } else { dismiss() } }
          .buttonStyle(PaperButton(compact: true))
      }
      PaperRule()
      Picker("项目管理", selection: $tab) {
        Text("备份与恢复").tag(0)
        Text("内容导出").tag(1)
        Text("回收站").tag(2)
        Text("永久清除").tag(3)
      }.pickerStyle(.segmented)
      Group {
        switch tab {
        case 0: backup
        case 1: content
        case 2: recycle
        default: purge
        }
      }.disabled(busy)
      Spacer(minLength: 0)
      if !status.isEmpty {
        HStack(spacing: 8) {
          if busy { ProgressView().controlSize(.small) }
          Text(status).font(.system(size: 12.5)).foregroundStyle(AtlasPalette.umber)
        }
      }
      if !problem.isEmpty {
        Text(problem).font(.system(size: 12.5)).foregroundStyle(AtlasPalette.terracotta).textSelection(.enabled)
      }
    }
    .padding(22)
    .frame(minWidth: 620, minHeight: 450)
    .background(AtlasPalette.paper)
    .foregroundStyle(AtlasPalette.ink)
    .interactiveDismissDisabled(busy)
    .onAppear {
      refresh()
    }
  }
  private var backup: some View {
    VStack(alignment: .leading, spacing: 11) {
      Text(summary?.title ?? "").font(AtlasTypeface.reading.font(16).weight(.medium))
      if let summary {
        Text(
          "\(summary.assets) 份资产 · \(ByteCountFormatter.string(fromByteCount:Int64(summary.bytes),countStyle:.file))；项目包包含历史版本、草稿、批注与原档。"
        )
        .font(.system(size: 12.5))
        .foregroundStyle(AtlasPalette.ink.opacity(0.84))
        if summary.originalArchives > 0 {
          Text("包含 \(summary.originalArchives) 份完整聊天原档，其中可能有未选会话。")
            .font(.system(size: 12))
            .foregroundStyle(AtlasPalette.umber)
        }
      }
      HStack(spacing: 8) {
        Button("导出完整项目包…") { exportPackage() }.buttonStyle(PaperButton(primary: true))
        Button("从项目包恢复副本…") { importPackage() }.buttonStyle(PaperButton())
      }
      PaperRule().padding(.vertical, 2)
      Text("本机恢复点").font(AtlasTypeface.reading.font(15.5).weight(.medium))
      HStack(spacing: 8) {
        Button("更改位置…") { chooseRoot() }.buttonStyle(PaperButton(compact: true))
        Text(backupRoot?.path ?? "")
          .font(AtlasTypeface.code.font(11.5))
          .foregroundStyle(AtlasPalette.umber)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Stepper("保留最近 \(keep) 个有变更的日期", value: $keep, in: 1...365)
        .font(.system(size: 12.5))
        .onChange(of: keep) { _, n in
          defaults.set(n, forKey: RecoveryPolicy.keepKey)
        }
      HStack(spacing: 8) {
        Button("立即创建恢复点") { recovery() }.buttonStyle(PaperButton(compact: true))
        if let root = backupRoot {
          Button("在 Finder 中查看") { NSWorkspace.shared.open(root) }.buttonStyle(AtlasChipButtonStyle(emphasized: true))
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(points, id: \.self) { p in
            Button("恢复 " + p.lastPathComponent) { selectDestination(for: p) }
              .buttonStyle(AtlasChipButtonStyle(emphasized: true))
          }
        }
      }
    }
  }
  private var content: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("选择要导出的正式版本").font(AtlasTypeface.reading.font(15.5).weight(.medium))
      List(versions, selection: $selected) { v in
        Text(v.title + " · 版本 \(v.ordinal) · " + (v.isPDF ? "批注 PDF" : "Markdown"))
          .font(AtlasTypeface.reading.font(13.5))
          .tag(v.id)
      }
      .scrollContentBackground(.hidden)
      .background(AtlasPalette.paperInset.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(AtlasPalette.line.opacity(0.45), lineWidth: 0.75)
      }
      Text("PDF 副本保留页面和可见批注，批注的二次编辑取决于 PDF 阅读器。Markdown 导出包含所选正文和相关出处。")
        .font(.system(size: 11.5))
        .foregroundStyle(AtlasPalette.umber)
      Button("导出选定版本…") { exportSelection() }
        .buttonStyle(PaperButton(primary: true))
        .disabled(selected == nil)
    }
  }
  private var recycle: some View {
    VStack(alignment: .leading, spacing: 9) {
      Picker("范围", selection: $showTrash) {
        Text("已回收").tag(true)
        Text("项目中的对象").tag(false)
      }.pickerStyle(.segmented)
      ScrollView {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(objects.filter { $0.deleted == showTrash }) { item in
            HStack {
              Text(item.title).font(AtlasTypeface.reading.font(13.5)).lineLimit(2)
              Spacer()
              Button(item.deleted ? "恢复" : "移入回收站") {
                do {
                  try store.setRecycled(item, deleted: !item.deleted)
                  refresh()
                  onChanged()
                } catch { problem = error.localizedDescription }
              }
              .buttonStyle(PaperButton(compact: true))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AtlasPalette.paperInset.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(AtlasPalette.line.opacity(0.35), lineWidth: 0.7)
            }
          }
        }
      }
      Text("回收会隐藏这个对象。历史依据和原档仍保存在 Atlas 中。只想调整画布时，可使用图谱中的移除入口。")
        .font(.system(size: 11.5))
        .foregroundStyle(AtlasPalette.umber)
    }
  }
  private var purge: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("永久清除这个 Atlas").font(AtlasTypeface.reading.font(15.5).weight(.medium)).foregroundStyle(AtlasPalette.terracotta)
      Text("将清除项目数据库、受管资产、缓存及当前恢复点位置中的本项目备份。外部原件和独立导出的副本保留。")
        .font(.system(size: 12.5))
        .foregroundStyle(AtlasPalette.ink.opacity(0.84))
      VStack(alignment: .leading, spacing: 4) {
        Text(store.directory.path).font(AtlasTypeface.code.font(11.5)).foregroundStyle(AtlasPalette.umber).textSelection(.enabled)
        ForEach(knownRoots, id: \.self) { root in
          Text(root.appendingPathComponent(store.workspaceID).path)
            .font(AtlasTypeface.code.font(11.5))
            .foregroundStyle(AtlasPalette.umber)
            .textSelection(.enabled)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AtlasPalette.paperInset.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(AtlasPalette.line.opacity(0.42), lineWidth: 0.75)
      }
      TextField("输入完整项目名以确认", text: $typed)
        .textFieldStyle(.roundedBorder)
      Button("永久清除「" + (summary?.title ?? "") + "」", role: .destructive) {
        guard !knownRoots.isEmpty, let summary, typed == summary.title else { return }
        let alert = NSAlert()
        alert.messageText = "永久清除「" + summary.title + "」？"
        alert.informativeText = "此操作无法撤销。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "永久清除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
          try store.permanentlyErase(confirming: typed, recoveryRoots: knownRoots)
          dismiss()
          onPurge(store.directory)
        } catch { problem = error.localizedDescription }
      }
      .buttonStyle(PaperButton())
      .disabled(summary == nil || typed.isEmpty || typed != summary?.title)
    }
  }
  private func refresh() {
    do {
      summary = try store.projectArchiveSummary()
      objects = try store.recyclableObjects()
      versions = try store.exportVersions()
      let root = try RecoveryPolicy.root(store, defaults: defaults)
      backupRoot = root
      knownRoots = try RecoveryPolicy.roots(store, defaults: defaults)
      points = try store.recoveryPoints(at: root)
      keep = RecoveryPolicy.keep(defaults)
      problem = ""
    } catch { problem = error.localizedDescription }
  }
  private func chooseRoot() {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.canCreateDirectories = true
    guard p.runModal() == .OK, let url = p.url else { return }
    do {
      _ = try store.recoveryPoints(at: url)
      if let current = backupRoot { RecoveryPolicy.remember(current, store: store, defaults: defaults) }
      RecoveryPolicy.remember(url, store: store, defaults: defaults)
      defaults.set(url.path, forKey: RecoveryPolicy.rootKey)
      refresh()
    } catch { problem = error.localizedDescription }
  }
  private func performTask(
    _ op: @escaping @Sendable (@escaping @Sendable (String) throws -> Void) throws -> String,
    done: @escaping () -> Void = {}
  ) {
    problem = ""
    status = "准备中"
    busy = true
    let task = Task.detached { () -> String in
      try op { stage in
        try Task.checkCancellation()
        Task { @MainActor in status = stage }
      }
    }
    job = Task {
      do {
        status = try await withTaskCancellationHandler(
          operation: { try await task.value }, onCancel: { task.cancel() })
        refresh()
        done()
      } catch {
        problem = error is CancellationError ? "已取消，已有文件保留。" : error.localizedDescription
        status = ""
      }
      busy = false
      job = nil
    }
  }
  private func exportPackage() {
    let p = NSSavePanel()
    p.allowedContentTypes = [UTType(filenameExtension: "latlas") ?? .data]
    p.nameFieldStringValue = (summary?.title ?? "Atlas") + ".latlas"
    p.canCreateDirectories = true
    guard p.runModal() == .OK, let url = p.url else { return }
    let source = store
    performTask({ report in
      _ = try source.exportProject(to: url, replacing: true, progress: report)
      return "已导出：" + url.lastPathComponent
    })
  }
  private func importPackage() {
    let p = NSOpenPanel()
    p.allowedContentTypes = [UTType(filenameExtension: "latlas") ?? .data]
    guard p.runModal() == .OK, let file = p.url else { return }
    selectDestination(for: file)
  }
  private func selectDestination(for file: URL) {
    let p = NSSavePanel()
    p.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + " 恢复副本"
    p.canCreateDirectories = true
    guard p.runModal() == .OK, let dest = p.url else { return }
    performTask(
      { report in
        _ = try AtlasStore.restoreProject(from: file, to: dest, progress: report)
        return "副本已恢复"
      },
      done: {
        dismiss()
        onRestore(dest)
      })
  }
  private func recovery() {
    guard let root = backupRoot else { return }
    let source = store
    let n = keep
    performTask({ report in
      try report("正在创建恢复点")
      _ = try source.saveRecoveryPoint(at: root, keep: n, force: true, progress: report)
      return "恢复点已保存"
    })
  }
  private func exportSelection() {
    guard let v = versions.first(where: { $0.id == selected }) else { return }
    if v.isPDF {
      do {
        let f = try store.pdf(versionID: v.id)
        do { _ = try store.readablePDF(f) } catch PDFUnlockError.required {
          guard let password = promptPDFPassword(f.title) else { return }
          _ = try store.readablePDF(f, password: password)
        }
      } catch {
        problem = error.localizedDescription
        return
      }
    }
    let withImages: Bool
    do { withImages = try store.exportImageCount(v) > 0 } catch {
      problem = error.localizedDescription
      return
    }
    let p = NSSavePanel()
    p.nameFieldStringValue =
      String(v.title.prefix(48)).replacingOccurrences(of: "/", with: "-") + "-版本\(v.ordinal)."
      + (v.isPDF ? "pdf" : "md")
    if withImages {
      p.title = "导出到新的图文文件夹"
      p.nameFieldStringValue =
        String(v.title.prefix(48)).replacingOccurrences(of: "/", with: "-") + "-图文"
    }
    guard p.runModal() == .OK, let dest = p.url else { return }
    let source = store
    performTask({ report in
      try report("正在导出")
      if withImages {
        try source.exportMarkdownFolder(v, to: dest)
      } else {
        try source.exportContent(v, to: dest)
      }
      return "已导出：" + dest.lastPathComponent
    })
  }
}
