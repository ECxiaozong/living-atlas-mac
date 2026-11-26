import AtlasCore
import SwiftUI

typealias ViewState<Value> = SwiftUI.State<Value>

extension AtlasRun {
  var referenceLabel: String? {
    guard sourceReferenceID != nil else { return nil }
    if let sourceQuote, !sourceQuote.isEmpty { return sourceQuote }
    return "返回引用原件"
  }
  var statusText: String {
    switch status {
    case .preparing: return "准备上下文"
    case .queued: return "等待首段"
    case .streaming: return "生成中"
    case .completed: return "已完成"
    case .failed: return "生成失败"
    case .cancelled: return answer.isEmpty ? "已停止 · 尚无输出" : "已停止 · 保留未完成回答"
    case .interrupted: return "上次生成中断"
    }
  }
}

struct Workspace: View {
  @EnvironmentObject var s: Session
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var railNamespace
  @ViewState private var sourceSelection: PDFAnchor?
  enum Panel:String,Identifiable {case search, organize, protection, research, chat; var id:String{rawValue}}
  @ViewState private var panel:Panel?
  @ViewState private var canvasAction: CanvasAction?
  @ViewState private var canvasSearch = false
  @ViewState private var canvasOrganization = false
  @ViewState private var showTasks = false

  @ViewState private var pendingRelationVisit: RelationEntranceVisit?
  @ViewState private var requestedRelationVisit: RelationEntranceVisit?
  @ViewState private var requestedCanvasRun: String?

  private struct TaskRow: Identifiable {
    let run: AtlasRun
    let attempt: Int
    var id: String { run.id }
    var detail: String {
      let version = run.version.map { " · 版本 " + String($0) } ?? ""
      return "第 " + String(attempt) + " 次生成" + version + " · " + run.statusText
    }
  }
  private var taskRows: [TaskRow] {
    var attempts: [String: Int] = [:]
    return s.runs.reversed().map { run in
      attempts[run.turnID, default: 0] += 1
      return TaskRow(run: run, attempt: attempts[run.turnID, default: 1])
    }.reversed()
  }
  private func locateTask(_ run: AtlasRun) {
    requestedCanvasRun = run.id
    s.area = .overview
  }

  private var desktop: some View {
    VStack(spacing: 0) {
      windowBar
      HStack(spacing: 0) {
        navigation
        ZStack {
          if s.store == nil || s.area != .overview {
            MapGround(prominentTerrain: s.store == nil)
          }
          if let store = s.store {
            if s.area == .overview {
              MapOverview(s: s, store: store, action: $canvasAction, importChat: { panel = .chat }, canvasSearch: $canvasSearch, canvasOrganization: $canvasOrganization, requestedRun: $requestedCanvasRun,
                relationVisit: $requestedRelationVisit).id(
                store.workspaceID)
            } else if s.area == .notes {
              WritingDesk(
                store: store, initialReferenceID: s.writingReference,
                onQuestion: { s.ask(reference: $0) },
                onVisibleVersion: { s.assistantNote = ($0, $1) }
              ).id(store.workspaceID)
            } else if s.area == .history {
              history
            } else {
              worktable(store).id(store.workspaceID)
            }
          } else {
            VStack(spacing: 18) {
              AtlasArt.compass.resizable().scaledToFit().frame(width: 34, height: 34)
              VStack(spacing: 6) {
                Text("我的 Atlas").font(AtlasTypeface.reading.font(26).weight(.medium))
                Text("从一个问题、一份资料或一段未解的困惑开始")
                  .font(.system(size: 13.5))
                  .foregroundStyle(AtlasPalette.umber)
              }
              PaperRule().frame(width: 180).padding(.vertical, 2)
              HStack(spacing: 12) {
                Button("新建 Atlas…") { s.choose(new: true) }.buttonStyle(PaperButton(primary: true))
                Button("打开已有项目…") { s.choose(new: false) }.buttonStyle(PaperButton())
              }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .paperSheet(cornerRadius: 16, elevated: true)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .foregroundStyle(AtlasPalette.ink)
  }
  var body:some View {desktop
    .task { s.openFirstAtlas() }
    .sheet(isPresented: $s.assistantShown) {
      if let store = s.store { AtlasAssistant(session: s, store: store).id(store.workspaceID) }
    }
    .sheet(isPresented: $s.canvasHelp) { CanvasGuide() }
    .onChange(of: s.store?.workspaceID) { _, _ in canvasOrganization = false; s.commandPalette = false; sourceSelection = nil; requestedCanvasRun = nil; pendingRelationVisit = nil; requestedRelationVisit = nil }
    .sheet(item: $s.citationList) { list in
      if let store = s.store { CanvasCitationPanel(store: store, citations: list.citations) }
    }
    .sheet(item: $s.relationSource, onDismiss: {
      if let pendingRelationVisit {
        requestedRelationVisit = pendingRelationVisit
        self.pendingRelationVisit = nil
      }
    }) { source in
      if let store = s.store {
        CanvasRelationPanel(source: source, store: store, locate: s.area == .overview ? { pendingRelationVisit = $0 } : nil)
      }
    }
    .sheet(item: $s.chatOriginList) { list in
      if let store = s.store {
        ChatOriginSheet(
          store: store, list: list,
          onQuestion: {
            s.chatOriginList = nil
            s.ask(reference: $0)
          })
      }
    }
    .sheet(item:$panel){id in if let store=s.store {tool(id,store:store)}}
    .sheet(item:$s.searchOrigin){item in
      VStack(alignment:.leading,spacing:12){
        HStack{
          Text(item.source.hit.title).font(.system(.title2, design: .serif))
          Spacer()
          Button("关闭"){s.searchOrigin=nil}.buttonStyle(PaperButton(compact: true))
        }
        PaperRule()
        SourceText(bodyText:item.source.fullText,initial:item.source.matchRange ?? item.source.range,changed:{_ in})
      }.padding(22).frame(minWidth:520,minHeight:390).background(AtlasPalette.paper)
    }
    .sheet(item:$s.webSource){page in
      VStack(alignment:.leading,spacing:10){
        HStack {
          Text(page.title).font(.system(.title2, design: .serif))
          Spacer()
          Button("关闭"){s.webSource=nil}.buttonStyle(PaperButton(compact: true))
        }
        Text(page.url+" · "+page.captured).font(.caption).foregroundStyle(AtlasPalette.umber).textSelection(.enabled)
        PaperRule()
        SourceText(bodyText:page.body,initial:page.selectedRange,changed:{_ in})
      }.padding(22).frame(minWidth:550,minHeight:420).background(AtlasPalette.paper)
    }
    .sheet(isPresented: $s.agentSettings) { if let store = s.store { AgentAccessPanel(store:store,service:s.agentAccess) } }
    .sheet(isPresented: $s.settings) { ModelSettings().environmentObject(s) }
    .alert(
      "这一步未完成", isPresented: Binding(get: { !s.error.isEmpty }, set: { if !$0 { s.error = "" } })
    ) {
      Button("好") { s.error = "" }
    } message: {
      Text(s.error)
    }
  }

  @ViewBuilder private func tool(_ id:Panel,store:AtlasStore)->some View {
    switch id {
    case .search:
      AtlasSearchPanel(store:store,profile:s.profile,onOpen:{ source in panel=nil;s.revealSearch(source)},onAsk:{ref in panel=nil;s.ask(reference:ref)}).environmentObject(s)
    case .organize:
      OrganizationDesk.workspace(s, store: store) { ref, _ in panel = nil; s.ask(reference: ref) }
    case .protection:
      ProjectProtectionPanel(store:store,defaults:s.defaults,onRestore:{url in s.perform{try s.open(url)}},onPurge:{s.didPurgeProject($0)},onChanged:{s.perform{try s.refreshAfterLifecycle(store)}})
    case .research:
      ResearchDesk(store:store,ask:{ref in panel=nil;s.ask(reference:ref)})
    case .chat:
      ChatArchiveImportView(store:store,onQuestion:{ref in panel=nil;s.ask(reference:ref)})
    }
  }

  private var windowBar: some View {
    GeometryReader { geometry in
      windowBar(width: geometry.size.width)
    }.frame(height: 50)
  }

  private func windowBar(width: CGFloat) -> some View {
    let compact = width < 1080
    let narrow = width < 890
    return HStack(spacing: narrow ? 6 : (compact ? 9 : 12)) {
      HStack(spacing: narrow ? 4 : 8) {
        AtlasArt.compass.resizable().scaledToFit().frame(width: 22, height: 22)
          .accessibilityHidden(true)
        Text("Living Atlas")
          .font(.custom("Georgia-Italic", size: narrow ? 16 : 20))
          .foregroundStyle(Color(red: 0.969, green: 0.945, blue: 0.894))
          .tracking(0.3).fixedSize()
      }
      Rectangle().fill(AtlasPalette.gold.opacity(0.32)).frame(width: 1, height: 18)
        .padding(.horizontal, 2)
      Menu {
        Button("新建 Atlas…") { s.choose(new: true) }
        Button("打开 Atlas…") { s.choose(new: false) }
        if s.store != nil {
          Divider()
          Button("本机 CLI 授权…") { s.agentSettings = true }
          Button("整理所选材料…") {
            if s.area == .overview { canvasOrganization = true } else { panel = .organize }
          }
          Button("备份、恢复与回收…") { panel = .protection }
          Button("外部研究…") { panel = .research }
          Button("导入旧聊天…") { panel = .chat }
        }
      } label: {
        AtlasMenuPillLabel(
          title: s.folder?.lastPathComponent ?? "我的图谱",
          icon: "folder",
          compact: false,
          dark: true
        ).frame(maxWidth: narrow ? 88 : (compact ? 126 : 175), alignment: .leading)
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(AtlasMenuButtonStyle(dark: true, compact: false))
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel(s.folder?.lastPathComponent ?? "我的图谱")

      if s.store != nil, s.area == .overview {
        Menu {
          Button("提问") { canvasAction = .ask }
          Button("放入资料…") { canvasAction = .material }
          Button("Markdown 文档") { canvasAction = .markdown }
          Button("灵感") { canvasAction = .idea }
          Divider()
          Button("主题地域…") { canvasAction = .region }
        } label: {
          AtlasMenuPillLabel(title: "新建", icon: "plus", compact: false, dark: true)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(AtlasMenuButtonStyle(dark: true, compact: false))
        .fixedSize()
        .accessibilityLabel("新建")
      }
      AtlasTitlebarDragArea()
        .frame(minWidth: narrow ? 8 : 16, maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
      if s.store != nil {
        Button {
          if s.area == .overview { canvasSearch = true } else { panel = .search }
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 11.5, weight: .medium))
              .foregroundStyle(AtlasPalette.umber)
            Text(compact ? "搜索" : "搜索此图谱…")
              .font(AtlasTypeface.reading.font(12.5))
              .foregroundStyle(AtlasPalette.umber.opacity(0.92))
            if !compact {
              Spacer(minLength: 8)
              Text("⇧⌘F")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AtlasPalette.umber.opacity(0.82))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(AtlasPalette.paperInset.opacity(0.9), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                  RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(AtlasPalette.line.opacity(0.55), lineWidth: 0.6)
                }
            }
          }
          .frame(width: compact ? nil : 206)
        }
        .buttonStyle(TopBarSearchPillStyle())
        .fixedSize()
        .accessibilityLabel("搜索")
        .keyboardShortcut("f", modifiers: [.command, .shift])

        Button { s.assistantShown = true } label: {
          HStack(spacing: 4) {
            AtlasArt.pupu.resizable().scaledToFit().frame(width: 21, height: 21)
            if !narrow { Text("噗噗").font(AtlasTypeface.reading.font(12)) }
          }
        }
        .buttonStyle(TopBarLightButtonStyle(active: s.assistantShown))
        .accessibilityLabel("噗噗助手").help("噗噗助手（⌥⌘K）")

        if s.area == .overview {
          Button {
            withAnimation(AtlasMotion.surface(reduceMotion)) { s.commandPalette.toggle() }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(AtlasPalette.gold)
              Text("⌘K")
                .font(.system(size: 11, weight: .medium, design: .rounded))
            }
          }
          .buttonStyle(TopBarLightButtonStyle(active: s.commandPalette))
          .accessibilityLabel("快速命令与跳转")
          .help("快速命令与跳转 (⌘K)")
        }
      }
      if !s.saving.isEmpty {
        HStack(spacing: 5) {
          Circle().fill(AtlasPalette.gold.opacity(0.88)).frame(width: 5, height: 5)
          Text(s.saving)
            .font(.system(size: 11.5))
            .foregroundStyle(AtlasPalette.umber)
        }
        .padding(.horizontal, 2)
      }
      if let store = s.store {
        if s.area == .graph || s.area == .library {
          Menu {
            ForEach([75, 100, 125, 150], id: \.self) { percent in
              Button(String(percent) + "%") { s.zoomCanvas(to: Double(percent) / 100) }
            }
          } label: {
            AtlasMenuPillLabel(
              title: String(Int(s.canvasZoom * 100)) + "%",
              icon: "magnifyingglass",
              compact: false,
              dark: false
            )
          }
          .menuStyle(.button)
          .menuIndicator(.hidden)
          .buttonStyle(AtlasMenuButtonStyle(dark: false, compact: false))
          .fixedSize()
          .accessibilityLabel("工作区缩放")
          .help("同时缩放原文与追问图版")

          Button {
            for key in ["library", "explore"] {
              NotificationCenter.default.post(
                name: .atlasResetSheet, object: nil,
                userInfo: ["project": store.workspaceID, "area": key])
            }
          } label: {
            if narrow { Image(systemName: "arrow.counterclockwise") } else { Text("图版归位") }
          }
          .buttonStyle(TopBarLightButtonStyle())
          .accessibilityLabel("图版归位")
          .help("将阅读和追问图版放回起始位置")
        }
        Button {
          showTasks.toggle()
        } label: {
          if narrow {
            HStack(spacing: 3) { Image(systemName: "list.bullet"); Text(String(s.active.count)) }
          } else { Label("任务（" + String(s.active.count) + "）", systemImage: "list.bullet") }
        }
        .accessibilityLabel("任务（" + String(s.active.count) + "）")
        .buttonStyle(TopBarLightButtonStyle(active: showTasks || !s.active.isEmpty))
        .popover(isPresented: $showTasks) {
          VStack(alignment: .leading, spacing: 12) {
            Text("本项目的任务").font(.system(size: 16, weight: .medium, design: .serif))
            PaperRule()
            if s.runs.isEmpty {
              Text("还没有提问").font(.callout).foregroundStyle(AtlasPalette.umber)
            }
            ScrollView {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(taskRows) { row in
                  Button {
                    if s.area == .overview { locateTask(row.run) } else { s.openQuestion(row.run) }
                    showTasks = false
                  } label: {
                    VStack(alignment: .leading, spacing: 3) {
                      Text(row.run.question)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(AtlasPalette.ink)
                        .lineLimit(2)
                      Text(row.detail).font(.caption).foregroundStyle(AtlasPalette.umber)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AtlasPalette.paperInset.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                  }.buttonStyle(.plain).accessibilityLabel(row.run.question + " · " + row.detail)
                }
              }
            }.frame(maxHeight: min(320, CGFloat(max(1, s.runs.count) * 58)))
          }.padding(16).frame(width: 360).background(AtlasPalette.paper)
        }
      }
    }
    .padding(.leading, 80)
    .padding(.trailing, narrow ? 10 : 18)
    .frame(width: width, height: 50)
    .background {
      ZStack(alignment: .bottom) {
        // Luminous ink-to-parchment watercolor skyline transition (deep maritime left anchor -> sunlit parchment right sky)
        LinearGradient(
          stops: [
            .init(color: AtlasPalette.navy, location: 0.00),
            .init(color: Color(red: 0.145, green: 0.212, blue: 0.275), location: 0.34),
            .init(color: Color(red: 0.355, green: 0.435, blue: 0.490), location: 0.48),
            .init(color: Color(red: 0.785, green: 0.775, blue: 0.735), location: 0.62),
            .init(color: Color(red: 0.933, green: 0.902, blue: 0.843), location: 0.76),
            .init(color: Color(red: 0.957, green: 0.929, blue: 0.875), location: 1.00),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
        AtlasTitlebarDragArea()
        // Soft hand-painted alpine ridge dissolving along the misty horizon
        GeometryReader { proxy in
          AtlasArt.topMountains
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: min(640, proxy.size.width * 0.56), height: 52, alignment: .bottom)
            .opacity(0.42)
            .blendMode(.multiply)
            .mask(
              LinearGradient(
                stops: [
                  .init(color: .clear, location: 0.0),
                  .init(color: .black, location: 0.24),
                  .init(color: .black, location: 0.80),
                  .init(color: .clear, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(x: 40)
            .clipped()
        }.allowsHitTesting(false)
        // Subtle binding hairline separating top skyline from parchment map
        LinearGradient(
          stops: [
            .init(color: AtlasPalette.gold.opacity(0.38), location: 0.0),
            .init(color: AtlasPalette.line.opacity(0.62), location: 0.55),
            .init(color: AtlasPalette.line.opacity(0.48), location: 1.0),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(height: 1)
      }
    }
  }

  private var navigation: some View {
    VStack(spacing: 6) {
      ForEach(Session.Area.allCases, id: \.self) { area in
        let icon = [
          Session.Area.overview: "map", Session.Area.graph: "text.book.closed",
          .library: "books.vertical", .notes: "square.and.pencil",
          .history: "clock",
        ][area]!
        Button {
          if area == .library { s.readingPane = .source }
          if area == .graph { s.readingPane = .task }
          withAnimation(AtlasMotion.surface(reduceMotion)) {
            s.area = area
          }
        } label: {
          RailNavItem(
            title: area == .graph ? "阅读" : area == .overview ? "图谱" : area.rawValue,
            icon: icon,
            active: s.area == area,
            indicatorNamespace: railNamespace
          )
        }
        .disabled(s.store == nil)
        .help(area == .overview ? "在同一张画布探索所有入口" : area.rawValue)
      }
      Spacer()
      PaperRule().opacity(0.25).padding(.horizontal, 14).padding(.bottom, 4)
      Button {
        s.settings = true
      } label: {
        RailNavItem(title: "设置", icon: "gearshape", active: s.settings)
      }
    }
    .padding(.vertical, 14)
    .frame(width: 72)
    .background {
      ZStack(alignment: .trailing) {
        AtlasPalette.rail
        Rectangle().fill(Color.black.opacity(0.28)).frame(width: 1)
      }
    }
    .buttonStyle(.plain)
  }

  private var history: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("问答历史").font(.system(.title2, design: .serif))
      PaperRule()
      if s.runs.isEmpty { Text("还没有已提交的问题。") }
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(taskRows) { row in
            Button {
              locateTask(row.run)
            } label: {
              HStack(alignment: .firstTextBaseline) {
                Text(row.run.question).frame(maxWidth: .infinity, alignment: .leading)
                Text(row.detail).font(.caption).foregroundStyle(AtlasPalette.umber)
              }.padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(row.run.question + " · " + row.detail)
            PaperRule()
          }
        }
      }
    }.padding(24).paperSheet().padding(30)
  }

  private func worktable(_ store: AtlasStore) -> some View {
    GeometryReader { proxy in
      let compact = proxy.size.width < 804
      let tight = proxy.size.width < 1030
      VStack(spacing: 0) {
        if compact {
          Picker("工作图版", selection: $s.readingPane) {
            Text("阅读原文").tag(Session.ReadingPane.source)
            Text("继续探索").tag(Session.ReadingPane.task)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 218).padding(.top, 10)
        }
        HStack(alignment: .top, spacing: tight ? 0 : 16) {
          if !compact || s.readingPane == .source {
            SheetCanvas(
              store: store, key: "library", target: s.shownPDF.map { .document($0.id) },
              zoom: s.canvasZoom, zoomChanged: s.zoomCanvas, failure: { s.error = $0 }
            ) { move, reset in
              ReadingPaper(
                s: s, store: store, selection: $sourceSelection, move: move, reset: reset)
            }
            .frame(
              width: compact
                ? nil : (tight ? (proxy.size.width - 4) * 0.53 : (proxy.size.width - 64) * 0.6)
            )
            .padding(.top, compact ? 0 : 8)
            .padding(.bottom, compact ? 0 : min(112, max(12, proxy.size.height - 600) * 0.43))
          }
          if !compact || s.readingPane == .task {
            SheetCanvas(
              store: store, key: "explore", target: s.current.map { .turn($0.turnID) },
              zoom: s.canvasZoom, zoomChanged: s.zoomCanvas, failure: { s.error = $0 }
            ) { move, reset in
              ExplorationPaper(s: s, store: store, move: move, reset: reset)
            }
            .padding(.bottom, compact ? 0 : min(34, max(0, proxy.size.height - 680) * 0.22))
          }
        }
        .padding(.horizontal, tight ? 2 : 14)
        .padding(.top, compact ? 0 : 7)
        .padding(.bottom, compact ? 3 : 12)
        .overlay {
          if !compact, let file = s.shownPDF, let anchor = s.displayedCitation,
            file.versionID == anchor.versionID
          {
            CitationThread(anchor: anchor).allowsHitTesting(false).accessibilityHidden(true)
          }
        }
      }
    }
  }
}

private struct RailNavItem: View {
  let title: String
  let icon: String
  let active: Bool
  var indicatorNamespace: Namespace.ID? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var hovering = false

  var body: some View {
    VStack(spacing: 4.5) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: active ? .medium : .regular))
      Text(title)
        .font(.system(size: 11, weight: active ? .semibold : .medium))
    }
    .foregroundStyle(
      active
        ? AtlasPalette.railActiveText
        : Color(red: 0.945, green: 0.922, blue: 0.875).opacity(hovering ? 0.92 : 0.64)
    )
    .frame(width: 54, height: 50)
    .background(
      active
        ? AtlasPalette.railActive.opacity(0.22)
        : (hovering ? Color.white.opacity(0.06) : .clear),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .overlay {
      if active {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(AtlasPalette.gold.opacity(0.32), lineWidth: 0.75)
      }
    }
    .overlay(alignment: .leading) {
      if active {
        if let ns = indicatorNamespace {
          RoundedRectangle(cornerRadius: 1.5)
            .fill(AtlasPalette.gold)
            .frame(width: 2.5, height: 22)
            .matchedGeometryEffect(id: "rail.active.bar", in: ns)
            .offset(x: -5)
        } else {
          RoundedRectangle(cornerRadius: 1.5)
            .fill(AtlasPalette.gold)
            .frame(width: 2.5, height: 22)
            .offset(x: -5)
        }
      }
    }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .animation(AtlasMotion.micro(reduceMotion), value: hovering)
  }
}

private struct ChatOriginSheet: View {
  let store: AtlasStore
  let list: Session.ChatOriginList
  let onQuestion: (String) -> Void
  @ViewState private var choice = 0
  var body: some View {
    VStack {
      if list.origins.count > 1 {
        Picker("原始消息", selection: $choice) {
          ForEach(list.origins.indices, id: \.self) { i in
            Text(String(list.origins[i].exact.prefix(35))).tag(i)
          }
        }.padding(.horizontal)
      }
      ChatArchiveImportView(
        store: store, sourceExcerpt: list.origins[choice], onQuestion: onQuestion
      ).id(choice)
    }
  }
}
