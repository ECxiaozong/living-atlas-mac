import AtlasCore
import SwiftUI

struct ExplorationPaper: View {
  @ObservedObject var s: Session
  let store: AtlasStore
  let move: (NSPoint, Bool) -> Void
  let reset: () -> Void
  @ViewState private var materialSettings = false
  @ViewState private var sourcePage: AnswerSourcePage?
  @ViewState private var editingFollowup = false
  @ViewState private var editorFocus: UUID?
  private var active: Bool { s.current.map { s.active.contains($0.id) } == true }
  private var writing: Bool {
    s.current == nil || (!active && (editingFollowup || !s.draft.isEmpty))
  }

  var body: some View {
    VStack(spacing: 0) {
      taskHead
      PaperRule()
      GeometryReader { proxy in
        VStack(alignment: .leading, spacing: 0) {
          if let run = s.current { answerBody(run, size: proxy.size) }
          if writing { questionEditor } else if let run = s.current { footer(run) }
        }
        .padding(.horizontal, 23).padding(.top, 20).padding(.bottom, 15)
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      }
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: s.current?.answer.isEmpty == true && !writing ? 452 : .infinity
    )
    .paperSheet()
    .frame(maxHeight: .infinity, alignment: .top)
    .sheet(item: $sourcePage) { page in AnswerSourcePanel(page: page, ask: { s.ask(excerpt: $0) }) }
    .onChange(of: s.selected) { _, _ in
      editingFollowup = false
      editorFocus = nil
    }
  }

  private var taskHead: some View {
    HStack(spacing: 12) {
      TaskCompanion(pose: active ? .working : (writing ? .exploring : .calm))
      VStack(alignment: .leading, spacing: 3) {
        SheetTitle(text: "继续探索", move: move, reset: reset)
        HStack(spacing: 6) {
          Circle().fill(active ? AtlasPalette.gold : AtlasPalette.line).frame(width: 5.5, height: 5.5)
          Text(s.current?.statusText ?? (s.anchor == nil ? "独立提问" : "选句追问"))
            .font(.system(size: 12)).foregroundStyle(AtlasPalette.umber)
        }
      }
      Spacer(minLength: 0)
      Button {
        materialSettings = true
      } label: {
        Image(systemName: "list.bullet.clipboard").foregroundStyle(AtlasPalette.umber)
      }
      .buttonStyle(AtlasChipButtonStyle()).accessibilityLabel("材料与范围").help(
        s.profile.map { $0.serviceLabel + " · " + $0.model } ?? "材料与范围"
      )
      .popover(isPresented: $materialSettings) { MaterialSettings(store: store, run: s.current) }
      if let run = s.current {
        if active {
          Button("停止生成") { s.stop(run) }.buttonStyle(PaperButton(compact: true))
        } else {
          Button("重试") { s.send(retry: run) }.buttonStyle(PaperButton(compact: true))
        }
      }
    }.padding(.horizontal, 16).frame(height: 62).background(AtlasPalette.paperHeader.opacity(0.62))
  }

  @ViewBuilder private func answerBody(_ run: AtlasRun, size: CGSize) -> some View {
    Text("当前问题").font(.system(size: 12)).foregroundStyle(AtlasPalette.blueInk)
    let question = Text(run.question)
      .font(AtlasTypeface.reading.font(size.width < 416 ? 20 : 22).weight(.medium))
      .lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    ViewThatFits(in: .vertical) {
      question
      ScrollView { question }
    }.frame(maxHeight: min(146, size.height * 0.28), alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true).padding(.top, 9).padding(.bottom, 15)
    if let quote = run.parentAnswer {
      Button {
        s.perform {
          if let ex = try store.parentExcerpt(of: run) {
            sourcePage = AnswerSourcePage(
              runID: ex.runID, body: ex.body, title: "历史回答", initial: ex.nativeRange,
              historical: true)
          }
        }
      } label: {
        Label(quote, systemImage: "arrow.uturn.backward").lineLimit(2)
      }.buttonStyle(.plain).help("回到提问时的父回答片段")
    }
    if run.extraCitationCount > 0 {
      Button("附加引用材料（" + String(run.extraCitationCount) + "）") { s.showCanvasCitations(run) }
    }
    if let id = run.sourceReferenceID, let quote = run.referenceLabel {
      Button {
        s.openReference(id)
      } label: {
        Label(quote, systemImage: "text.quote").lineLimit(2)
      }.buttonStyle(.plain)
    }
    if let anchor = run.anchor {
      FrozenCitation(anchor: anchor, store: store, follow: { s.follow(anchor) })
        .padding(.bottom, 13)
    }
    HStack(spacing: 10) {
      Text("回答").font(.system(size: 12)).foregroundStyle(AtlasPalette.umber)
      PaperRule()
      if !run.answer.isEmpty {
        Button("选段追问") {
          sourcePage = AnswerSourcePage(runID: run.id, body: run.answer, title: "从回答选句")
        }.buttonStyle(.plain).font(.caption)
      }
      if s.versions.count > 1 { versionMenu(run) }
    }.padding(.bottom, 6)
    if !run.answer.isEmpty {
      AnswerReader(
        text: run.answer, streaming: active,
        selectedSource: { body, range, _ in
          sourcePage = AnswerSourcePage(runID: run.id, body: body, title: "从回答选句", initial: range)
        }
      ).id(run.id)
    } else {
      Text(emptyAnswer(run)).font(.system(size: 15)).foregroundStyle(AtlasPalette.blueInk)
        .textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .topLeading)
    }
    if run.status == .failed, !run.answer.isEmpty, let reason = run.reason {
      Text(reason).font(.caption).lineLimit(3).textSelection(.enabled).padding(.vertical, 4)
    }
    PaperRule().padding(.vertical, 8)
  }

  private func versionMenu(_ run: AtlasRun) -> some View {
    let label: String = run.version.map { "版本 " + String($0) } ?? "此次尝试"
    return Menu(label) {
      ForEach(s.versions) { version in
        let number: String = version.version.map { "回答 " + String($0) } ?? "无输出"
        Button(number + " · " + version.statusText) {
          s.openQuestion(version, keepingReadingPlace: true)
        }
      }
    }.menuStyle(.borderlessButton).fixedSize().font(.caption)
  }

  @ViewBuilder private var questionEditor: some View {
    if let quote = s.excerpt?.quote ?? s.referenceID.flatMap({ try? store.referenceQuote($0) }) {
      Text(quote).font(AtlasTypeface.reading.font(14)).lineLimit(3).padding(.bottom, 6)
    }
    if let anchor = s.anchor {
      FrozenCitation(
        anchor: anchor, store: store, follow: { s.follow(anchor) },
        remove: { s.saveDraft(s.draft, anchor: nil) }
      ).padding(.bottom, 12)
    }
    Text(s.current == nil ? "你的问题" : "继续追问")
      .font(AtlasTypeface.reading.font(s.current == nil ? 21 : 15).weight(.medium))
      .padding(.bottom, 8)
    Composer(
      value: s.draft, focusRequest: editorFocus ?? s.composerFocus,
      changed: { s.saveDraft($0, anchor: s.anchor) }, send: { s.send() }
    )
    .frame(height: s.current == nil ? 100 : 56)
    .background(AtlasPalette.cream.opacity(0.78), in: RoundedRectangle(cornerRadius: 5))
    .overlay {
      RoundedRectangle(cornerRadius: 5).strokeBorder(
        AtlasPalette.line.opacity(0.54), lineWidth: 0.8)
    }
    HStack {
      if s.current != nil, s.draft.isEmpty {
        Button("收起") { editingFollowup = false }.buttonStyle(.plain)
      }
      Spacer()
      Button("提交问题") { s.send() }.buttonStyle(PaperButton(primary: true))
        .disabled(s.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }.padding(.top, 9)
    if s.current == nil { Spacer() }
  }

  private func footer(_ run: AtlasRun) -> some View {
    HStack(spacing: 8) {
      if run.anchor != nil {
        Text(run.answer.isEmpty ? "引文取自原件" : "引文取自原件 · 回答含延伸说明")
          .font(.system(size: 11)).foregroundStyle(AtlasPalette.umber)
      }
      Spacer(minLength: 0)
      if !active {
        Menu {
          Button("按当前范围重新回答") { s.send(retry: run, reusingContext: false) }
          Button("独立提问") { s.fresh(focus: true) }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多提问操作").menuStyle(.borderlessButton).fixedSize()
        Button(run.answer.isEmpty ? "独立提问" : "继续追问") {
          if run.answer.isEmpty {
            s.fresh(focus: true)
          } else {
            editingFollowup = true
            editorFocus = UUID()
          }
        }.buttonStyle(PaperButton())
      }
    }
  }

  private func emptyAnswer(_ run: AtlasRun) -> String {
    switch run.status {
    case .failed: return run.reason ?? "未能收到回答。可以重试这个问题。"
    case .cancelled: return "在收到首段前已停止，可以重试。"
    case .interrupted: return "上次生成中断，尚未收到回答。"
    case .completed: return "本次生成已结束，未返回正文。"
    default: return "正在等待首段回答…"
    }
  }
}

private struct FrozenCitation: View {
  let anchor: PDFAnchor
  let store: AtlasStore
  let follow: () -> Void
  var remove: (() -> Void)?
  @ViewState private var version: AtlasPDF?
  @ViewState private var missing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Button(action: follow) {
          HStack(spacing: 5) {
            Text(sourceLabel).lineLimit(2).multilineTextAlignment(.leading)
            Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
          }
        }.buttonStyle(.plain).foregroundStyle(AtlasPalette.blueInk)
          .help("回到引用的原文").accessibilityLabel("回到引用的原文，" + sourceLabel)
        Spacer(minLength: 0)
        if let remove {
          Button(action: remove) { Image(systemName: "xmark") }
            .buttonStyle(.plain).accessibilityLabel("移除引文")
        }
      }.font(.system(size: 12, weight: .medium))
      let quote = Text(anchor.quote).font(AtlasTypeface.reading.font(16))
        .lineSpacing(3).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true).frame(
          maxWidth: .infinity, alignment: .leading)
      ViewThatFits(in: .vertical) {
        quote
        ScrollView { quote }
      }.frame(maxHeight: 70, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
      PaperRule().padding(.top, 3)
    }
    .padding(.leading, 12).padding(.vertical, 3)
    .overlay(alignment: .leading) { Rectangle().fill(AtlasPalette.line).frame(width: 1.5) }
    .background(CitationPin(anchor: anchor))
    .task(id: anchor.versionID) {
      do {
        version = try store.pdfInfo(versionID: anchor.versionID)
        missing = false
      } catch {
        version = nil
        missing = true
      }
    }
  }

  private var sourceLabel: String {
    let pages = Set(anchor.segments.map { $0.pageIndex + 1 }).sorted().map(String.init).joined(
      separator: "、")
    let source =
      version.map { $0.title + "  ·  版本 " + String($0.ordinal) }
      ?? (missing ? "历史版本暂不可读" : "读取历史版本…")
    return source + "  ·  第 " + pages + " 页"
  }
}
