import AtlasCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct WritingDesk: View {
  let store: AtlasStore
  var initialReferenceID: String? = nil
  var onQuestion: ((String) -> Void)? = nil
  var canvasItemID: String? = nil
  var placementID: String? = nil
  var editorFocus: CanvasEditorFocus? = nil
  var addSelection: ((String,[WritingSelection]) -> Void)? = nil
  var onSelectText: (() -> Void)? = nil
  var onInteraction: ((Bool) -> Void)? = nil
  var onVisibleVersion: ((String?, String?) -> Void)? = nil
  @ViewState private var composing = false
  @ViewState private var selecting = false
  @ViewState private var editorActive = false
  @ViewState private var items = [WritingItem]()
  @ViewState private var current: WritingItem?
  @ViewState private var versions = [WritingVersion]()
  @ViewState private var history: WritingVersion?
  @ViewState private var source = ""
  @ViewState private var editing = true
  @ViewState private var page = WrittenPage(blocks: [])
  @ViewState private var selection = [WritingSelection]()
  @ViewState private var selectionWasRestored = false
  @ViewState private var allMarks = [AtlasTextMark]()
  @ViewState private var visibleMarks = [WritingPreview.Mark]()
  @ViewState private var target: [WritingSelection]?
  struct SelectedComment: Identifiable {
    let id = UUID()
    let version: String
    let selection: [WritingSelection]
  }
  @ViewState private var annotationTarget: SelectedComment?
  @ViewState private var comment = ""
  @ViewState private var editingMark: AtlasTextMark?
  @ViewState private var listingMarks = false
  @ViewState private var problem: String?
  @ViewState private var unsaved = false

  @ViewState private var previewWeb: WKWebView?
  @ViewState private var inkSheet: InkSurface?
  @ViewState private var imageLinks = [String: String]()
  @ViewState private var imageVersion: String?
  @ViewState private var surfaces = [InkSurface]()
  private var version: String? {
    history?.id ?? (current?.draft == nil ? current?.currentVersionID : nil)
  }
  var body: some View {
    HStack(spacing: 14) {
      if canvasItemID == nil {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("笔记").font(AtlasTypeface.reading.font(17).weight(.medium)).foregroundStyle(AtlasPalette.ink)
            Spacer()
            Menu {
              Button("新建灵感") { create(.idea) }
              Button("新建 Markdown") { create(.markdown) }
              Divider()
              Button("导入 Markdown…") { importDocument() }
            } label: {
              Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AtlasPalette.blueInk)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasChipButtonStyle(emphasized: true)).fixedSize()
            .accessibilityLabel("新建笔记")
          }
          PaperRule()
          ScrollView {
            VStack(alignment: .leading, spacing: 5) {
              ForEach(items) { item in
                Button {
                  run { try open(item) }
                } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle).font(AtlasTypeface.reading.font(13.5)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(
                      item.kind.label + (item.draft == nil ? "" : " · 草稿")
                    ).font(.system(size: 11)).foregroundStyle(AtlasPalette.umber)
                  }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                      item.id == current?.id ? AtlasPalette.blueInk.opacity(0.09) : .clear,
                      in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                      if item.id == current?.id {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                          .strokeBorder(AtlasPalette.blueInk.opacity(0.28), lineWidth: 0.75)
                      }
                    }
                }.buttonStyle(.plain)
              }
            }
          }
        }.padding(14).frame(width: 196).frame(maxHeight: .infinity).paperSheet()
      }
      VStack(alignment: .leading, spacing: placementID == nil ? 10 : 4) {
        if let current {
          if placementID == nil {
            HStack {
              Text(current.displayTitle).font(AtlasTypeface.reading.font(18).weight(.medium)).lineLimit(1)
              Spacer()
              versionMenu(current)
            }
          }
          HStack(spacing: placementID == nil ? 6 : 4) {
            if placementID != nil { versionMenu(current) }
            Button(editing ? "阅读预览" : (history == nil ? "编辑源码" : "查看源码")) {
              run {
                if editing {
                  try preview()
                } else {
                  editing = true
                  selection = []
                  target = nil
                }
                try remember()
              }
            }
            .buttonStyle(AtlasChipButtonStyle())
            if history == nil && (placementID == nil || current.draft != nil) {
              Button("保存为版本") { publish() }
                .buttonStyle(PaperButton(primary: true, compact: true))
                .disabled(
                  current.draft == nil
                    || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if current.kind == .markdown {
              if placementID != nil {
                Menu {
                  Button("文字批注（\(allMarks.count)）") { listingMarks.toggle() }
                  Divider()
                  inkChoices
                } label: {
                  AtlasMenuPillLabel(title: "批注", compact: true)
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
                .accessibilityLabel("批注")
              } else {
                Button("批注 \(allMarks.count)") { listingMarks.toggle() }
                  .buttonStyle(AtlasChipButtonStyle())
                Menu { inkChoices } label: {
                  AtlasMenuPillLabel(title: "手写", compact: true)
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
                .accessibilityLabel("手写")
              }
            }
            Spacer()
          }
          .opacity(placementID != nil && !editing ? 0.84 : 1.0)
          if placementID == nil { Divider() }
          if editing {
            if history != nil {
              ScrollView {
                Text(source).font(AtlasTypeface.code.font(14)).textSelection(.enabled).frame(
                  maxWidth: .infinity, alignment: .leading)
              }
            } else if let placementID {
              CanvasSourceEditor(
                text: source, store: store, placementID: placementID, focus: editorFocus,
                failure: { problem = $0 }, saveBeforeHiding: { text in
                  if text != source { saveDraft(text) }
                  if unsaved { run { try flush() } }
                  return !unsaved
                }, onEdit: saveDraft, onFocus: { editorActive = $0 },
                onComposition: { composing = $0 })
            } else {
              TextEditor(text: Binding(get: { source }, set: saveDraft)).font(
                AtlasTypeface.code.font(14)
              )
              .scrollContentBackground(.hidden).accessibilityLabel("Markdown 源码")
            }
          } else {
            WritingPreview(
              imageStore: store, imageVersion: imageVersion,
              readingVersion: version ?? (placementID == nil ? nil : "draft"),
              placementID: placementID,
              onFailure: { problem = $0 }, imageLinks: imageLinks, page: page, marks: visibleMarks,
              focus: target, onReady: { previewWeb = $0 }, onGesture: { selecting = $0 },
              onRestoreSelection: { selectionWasRestored = true; selection = $0 },
              onSelect: { next in
                selectionWasRestored = false
                selection = next
                if !next.isEmpty { onSelectText?() }
              }
            )
            .id((placementID ?? "") + (version ?? current.id + ".draft"))
            if version != nil && current.kind == .markdown {
              if placementID != nil {
                if !selection.isEmpty {
                  HStack(spacing: 6) {
                    Button(addSelection != nil ? "把 Markdown 选句加入本题" : "追问") { askSelected() }
                      .buttonStyle(PaperButton(primary: true, compact: true))
                    Menu {
                      Button("高亮") { add(.highlight) }
                      Button("划线") { add(.underline) }
                      Button("文字批注…") {
                        if let version {
                          comment = ""
                          annotationTarget = SelectedComment(version: version, selection: selection)
                        }
                      }
                    } label: {
                      AtlasMenuPillLabel(title: "添加批注", compact: true)
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
                    .accessibilityLabel("添加批注")
                    Spacer()
                  }
                }
              } else {
                HStack {
                  Button("高亮") { add(.highlight) }.disabled(selection.isEmpty)
                  Button("划线") { add(.underline) }.disabled(selection.isEmpty)
                  TextField("写下批注", text: $comment)
                  Button("添加批注") { add(.text) }.disabled(
                    selection.isEmpty
                      || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                  if onQuestion != nil {
                    Button(addSelection != nil ? "把 Markdown 选句加入本题" : "追问") { askSelected() }.disabled(selection.isEmpty)
                  }
                }.controlSize(.small)
              }
            }
          }
          if listingMarks { markList }
        } else {
          VStack(spacing: 14) {
            Text("从一条灵感或一篇文档开始").font(.title3)
            HStack {
              Button("新建灵感") { create(.idea) }
              Button("新建 Markdown") { create(.markdown) }
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
      }.padding(placementID == nil ? 18 : 0).frame(
        maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
      )
      .modifier(WritingPaper(standalone: placementID == nil))
    }.padding(placementID == nil ? 16 : 0).onAppear {
      run {
        if let canvasItemID, let placementID {
          try restoreEntrance(canvasItemID, placement: placementID)
          return
        }
        items = try store.writings()
        if let ref = initialReferenceID {
          try reveal(ref)
        } else if let last = try store.readViewState(String.self, key: "writing.item"),
          let remembered = items.first(where: { $0.id == last })
        {
          try open(remembered)
        } else if let first = items.first {
          try open(first)
        }
      }
    }
    .onChange(of: [current?.id, version], initial: true) { _, _ in onVisibleVersion?(current?.id, version) }
    .onReceive(
      NotificationCenter.default.publisher(for: .atlasWritingChanged).receive(on: RunLoop.main)
    ) { note in
      guard let idOfStore = note.object as? String, idOfStore == store.workspaceID,
        let id = note.userInfo?["itemID"] as? String, id == current?.id
      else { return }
      // The editing entrance already holds this committed draft. Other entrances
      // still receive updates, including publication or rollback without an edit serial.
      if let serial = note.userInfo?["editSerial"] as? Int, serial == current?.editSerial,
        note.userInfo?["versionID"] as? String == current?.currentVersionID { return }
      run {
        let next = try store.writing(id: id)
        guard next != current, !unsaved, !composing else { return }
        current = next
        versions = try store.writingVersions(next)
        if history == nil {
          source = next.draft ?? versions.first?.body ?? ""
          if !editing { page = try parseDisplayedSource() }
          selection = []
          target = nil
        }
        try reloadMarks()
      }
    }
    .onChange(
      of: editorActive || selecting || composing || (!selection.isEmpty && !selectionWasRestored) || inkSheet != nil
        || editingMark != nil || annotationTarget != nil
    ) {
      _, active in onInteraction?(active)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .atlasCanvasAnnotationChanged).receive(
        on: RunLoop.main)
    ) { note in
      if let changed = note.object as? AtlasStore, changed === store,
        let item = note.userInfo?["id"] as? String, item == current?.id
      {
        run { try reloadMarks() }
      }
    }
    .onDisappear { onInteraction?(false) }
    .onReceive(NotificationCenter.default.publisher(for: .atlasAgentCommitted)) { note in
      guard note.object as? AtlasStore === store else { return }
      run {
        items = try store.writings()
        if !unsaved, !editing, history == nil, let id = current?.id,
          let newer = items.first(where: { $0.id == id }),
          newer.currentVersionID != current?.currentVersionID
        {
          try open(newer)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .atlasLifecycleChanged)) { note in
      guard let changed = note.object as? AtlasStore, changed === store else { return }
      run {
        if let canvasItemID, let placementID {
          try restoreEntrance(canvasItemID, placement: placementID)
          return
        }
        items = try store.writings()
        if let next = items.first(where: { $0.id == current?.id }) ?? items.first {
          try open(next)
        } else {
          current = nil
          history = nil
          versions = []
          allMarks = []
        }
      }
    }
    .onChange(of: initialReferenceID) { _, ref in if let ref { run { try reveal(ref) } } }
    .sheet(item: $annotationTarget) { target in
      VStack(alignment: .leading, spacing: 10) {
        Text("文字批注").font(.headline)
        Text(target.selection.map(\.quote).joined(separator: " ")).lineLimit(3)
        TextEditor(text: $comment).frame(height: 100)
        HStack {
          Spacer()
          Button("取消") { annotationTarget = nil }
          Button("保存") {
            run {
              try store.markWriting(
                versionID: target.version, selection: target.selection, kind: .text, text: comment)
              annotationTarget = nil
              comment = ""
              try annotationsChanged()
            }
          }.disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding(18).frame(width: 380)
    }
    .sheet(item: $inkSheet) { InkDesk(store: store, surface: $0) }
    .sheet(item: $editingMark) { mark in
      EditWrittenComment(mark: mark) { text in
        try store.editComment(mark, text: text)
        try annotationsChanged()
        editingMark = nil
      }
    }
  }

  private func versionMenu(_ current: WritingItem) -> some View {
    let label =
      history.map { "历史 · 版本 \($0.ordinal)" }
      ?? (current.draft != nil
        ? (unsaved ? "草稿待保存" : "已存草稿") : "版本 \(versions.first?.ordinal ?? 0)")
    return Menu {
      Button("跟随当前版本") {
        run {
          try open(current)
          try remember()
        }
      }
      Divider()
      ForEach(versions) { v in
        Button("查看版本 \(v.ordinal)") {
          run {
            try show(v)
          }
        }
      }
    } label: {
      AtlasMenuPillLabel(title: label, compact: true)
    }
    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
    .accessibilityLabel(label)
  }
  @ViewBuilder private var inkChoices: some View {
    Button("标注当前可见版面") { freezeViewport() }.disabled(editing || version == nil || previewWeb == nil)
    ForEach(Array(surfaces.enumerated()), id: \.element.id) { i, s in
      Button("版本 \(s.version) · 版面 \(surfaces.count-i)") { inkSheet = s }
    }
  }

  private var markList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if allMarks.isEmpty { Text("还没有批注").foregroundStyle(.secondary) }
        ForEach(allMarks) { mark in
          HStack {
            VStack(alignment: .leading) {
              Text(mark.kind.label + " · 版本 \(mark.ordinal)").font(.caption)
              Text(mark.quote).lineLimit(2)
              if !mark.text.isEmpty { Text(mark.text).foregroundStyle(AtlasPalette.umber) }
            }
            Spacer()
            if mark.kind == .text { Button("修改") { editingMark = mark } }
            Button("当时原文") {
              run {
                guard let historical = versions.first(where: { $0.id == mark.versionID }) else {
                  throw AtlasStoreError.invalid("此历史版本不可用。")
                }
                try show(historical)
                target = try store.resolveWritingSource(mark.referenceID, in: historical.id)
              }
            }
            if let latest = current?.currentVersionID, latest != mark.versionID {
              if version == latest && !editing && !selection.isEmpty {
                Button("关联到所选文字") {
                  run {
                    try store.reanchorWritingSource(
                      mark.referenceID, to: latest, selection: selection)
                    try reloadMarks()
                  }
                }
              }
              Button("当前定位") {
                run {
                  guard let parts = try store.resolveWritingSource(mark.referenceID, in: latest),
                    let v = versions.first(where: { $0.id == latest })
                  else {
                    throw AtlasStoreError.invalid("当前版本待定位。可从「当时原文」查看原句。")
                  }
                  try show(v)
                  target = parts
                }
              }
            }
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.frame(maxHeight: 150)
  }

  private func run(_ action: () throws -> Void) {
    do {
      problem = nil
      try action()
    } catch { problem = error.localizedDescription }
  }
  private func importDocument() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    run {
      try flush()
      let bytes = try Data(contentsOf: url)
      guard let raw = String(data: bytes, encoding: .utf8) else {
        throw AtlasStoreError.invalid("请选择 UTF-8 Markdown 文档。")
      }
      let source = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
        of: "\r", with: "\n")
      let parsed = try WrittenMarkdown.parse(source)
      try open(
        store.importMarkdown(from: url, original: bytes, blocks: parsed.blocks.map(\.content)))
    }
  }
  private func create(_ kind: WritingKind) {
    run {
      try flush()
      try open(store.createWriting(kind))
    }
  }
  private func flush() throws {
    if unsaved, let current {
      self.current = try store.saveWritingDraft(current, body: source)
      unsaved = false
    }
  }
  private func reveal(_ ref: String) throws {
    guard let source = try store.writingSourceTarget(ref),
      let item = try store.writings().first(where: { $0.id == source.documentID })
    else { throw AtlasStoreError.invalid("找不到提问时的 Markdown 来源。") }
    try open(item)
    guard let v = versions.first(where: { $0.id == source.versionID }) else {
      throw AtlasStoreError.invalid("找不到这份材料的历史版本。")
    }
    try show(v)
    guard let exact = try store.resolveWritingSource(ref, in: v.id) else {
      throw AtlasStoreError.invalid("已打开历史版本，原句待定位。")
    }
    target = exact
  }
  private func restoreEntrance(_ itemID: String, placement: String) throws {
    let fresh = try store.writing(id: itemID)
    let stored = try store.readViewState(CanvasWritingState.self, key: CanvasWritingState.key(placement))
    if current == fresh, history?.id == stored?.pinnedVersion { return }
    if let pinned = stored?.pinnedVersion {
      guard let version = try store.writingVersions(fresh).first(where: { $0.id == pinned }) else {
        throw AtlasStoreError.invalid("此入口绑定的历史版本不可用。")
      }
      try open(fresh)
      try show(version, saveChoice: false)
    } else {
      try open(fresh)
      if let stored {
        if stored.editing { editing = true } else { try preview() }
      }
    }
  }

  private func open(_ item: WritingItem) throws {
    try flush()
    let fresh = try store.writing(id: item.id)
    if canvasItemID == nil {
      items = try store.writings()
      try store.saveViewState(item.id, key: "writing.item")
    }
    current = fresh
    versions = try store.writingVersions(fresh)
    history = nil
    editorActive = false
    composing = false
    selecting = false
    editing = fresh.draft != nil
    listingMarks = false
    selection = []
    target = nil
    previewWeb = nil
    comment = ""
    source = fresh.draft ?? versions.first?.body ?? ""
    if !editing { page = try parseDisplayedSource() }
    try reloadMarks()
  }
  private func remember() throws {
    guard let placementID else { return }
    try store.saveViewState(
      CanvasWritingState(pinnedVersion: history?.id, editing: editing),
      key: CanvasWritingState.key(placementID))
    if let item = current {
      NotificationCenter.default.post(name: .atlasWritingChanged, object: store.workspaceID,
        userInfo: ["itemID": item.id, "entranceVersionChanged": true])
    }
  }
  private func saveDraft(_ text: String) {
    guard let current, history == nil else { return }
    source = text
    unsaved = true
    run {
      let item = try store.saveWritingDraft(current, body: text)
      self.current = item
      unsaved = false
      if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
    }
  }
  private func parseDisplayedSource() throws -> WrittenPage {
    let published = history ?? (current?.draft == nil ? versions.first : nil)
    return try WrittenMarkdown.parse(source, callouts: published?.supportsCallouts ?? true)
  }
  private func preview() throws {
    try flush()
    page = try parseDisplayedSource()
    editorActive = false
    editing = false
    selection = []
    try reloadMarks()
  }
  private func publish() {
    run {
      try flush()
      guard let current else { return }
      let parsed = try WrittenMarkdown.parse(source)
      try open(store.publishWriting(current, blocks: parsed.blocks.map(\.content)))
      try remember()
    }
  }
  private func show(_ v: WritingVersion, saveChoice: Bool = true) throws {
    try flush()
    let parsed = try WrittenMarkdown.parse(v.body, callouts: v.supportsCallouts)
    source = v.body
    history = v
    page = parsed
    editorActive = false
    editing = false
    selection = []
    target = nil
    try reloadMarks()
    if saveChoice { try remember() }
  }
  private func reloadMarks() throws {
    guard let current, current.kind == .markdown else {
      allMarks = []
      visibleMarks = []
      surfaces = []
      imageLinks = [:]
      imageVersion = nil
      return
    }
    imageVersion = history?.id ?? current.currentVersionID
    imageLinks = try imageVersion.map { try store.writingImageLinks(version: $0) } ?? [:]
    surfaces = try store.inkSurfaces(document: current.id)
    allMarks = try store.textMarks(documentID: current.id)
    if let version {
      visibleMarks = try allMarks.compactMap { mark in
        guard let parts = try store.resolveWritingSource(mark.referenceID, in: version) else {
          return nil
        }
        return WritingPreview.Mark(kind: mark.kind.rawValue, parts: parts)
      }
    } else {
      visibleMarks = []
    }
  }

  private func freezeViewport() {
    guard let web = previewWeb, let version, !editing else { return }
    Task { @MainActor in
      do {
        let data = try await Self.snapshot(web)
        guard self.version == version, self.previewWeb === web, !self.editing else {
          throw AtlasStoreError.invalid("版面已切换，请重新标注。")
        }
        inkSheet = try store.markdownInkSurface(
          version: version, png: data.0, width: data.1.width, height: data.1.height,
          viewport: data.2)
        try reloadMarks()
      } catch { problem = error.localizedDescription }
    }
  }
  static func snapshot(_ web: WKWebView) async throws -> (Data, CGSize, InkViewport) {
    let probe = """
      const visible=[...document.querySelectorAll('article > section')].filter(e=>{
        const r=e.getBoundingClientRect();return r.bottom>0 && r.top<innerHeight;});
      return JSON.stringify({scrollX,scrollY,firstBlock:visible.length?Number(visible[0].dataset.block):null,
        lastBlock:visible.length?Number(visible[visible.length-1].dataset.block):null,
        textFont:getComputedStyle(document.body).font});
      """
    let bounds = web.bounds
    guard bounds.width > 0, bounds.height > 0,
      let before = try await web.callAsyncJavaScript(
        probe, arguments: [:], in: nil, contentWorld: .defaultClient) as? String
    else {
      throw AtlasStoreError.invalid("请先打开要标注的正文。")
    }
    let config = WKSnapshotConfiguration()
    config.rect = bounds
    let image = try await web.takeSnapshot(configuration: config)
    let after =
      try await web.callAsyncJavaScript(
        probe, arguments: [:], in: nil, contentWorld: .defaultClient) as? String
    guard after == before, web.bounds == bounds, let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      throw AtlasStoreError.invalid("截取期间版面发生变化，请再次打开手写。")
    }
    return (png, bounds.size, try JSONDecoder().decode(InkViewport.self, from: Data(before.utf8)))
  }
  private func askSelected() {
    run {
      if let version, let addSelection { addSelection(version, selection) }
      else if let version, let onQuestion {
        onQuestion(try store.captureWritingSource(versionID: version, selection: selection))
      }
    }
  }
  private func annotationsChanged() throws {
    try reloadMarks()
    if let current {
      NotificationCenter.default.post(
        name: .atlasCanvasAnnotationChanged, object: store, userInfo: ["id": current.id])
    }
  }
  private func add(_ kind: TextMarkKind) {
    run {
      guard let version else { return }
      try store.markWriting(versionID: version, selection: selection, kind: kind, text: comment)
      comment = ""
      try annotationsChanged()
    }
  }
}

struct EditWrittenComment: View {
  let mark: AtlasTextMark
  let save: (String) throws -> Void
  @ViewState private var bodyText = ""
  @ViewState private var problem: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("修改文字批注").font(.headline)
      Text(mark.quote).lineLimit(3)
      TextEditor(text: $bodyText).frame(minHeight: 90)
      if let problem { Text(problem).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") {
          do {
            try save(bodyText)
            dismiss()
          } catch { problem = error.localizedDescription }
        }
      }
    }.padding(18).frame(width: 420).onAppear { bodyText = mark.text }
  }
}

extension Notification.Name {
  fileprivate static let atlasCanvasAnnotationChanged = Notification.Name(
    "LivingAtlas.canvasAnnotationChanged")
}

private struct WritingPaper: ViewModifier {
  let standalone: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if standalone { content.paperSheet() } else { content }
  }
}
