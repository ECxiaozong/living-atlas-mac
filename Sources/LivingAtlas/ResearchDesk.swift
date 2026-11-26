import AtlasCore
import SwiftUI

struct ResearchDesk: View {
  let store: AtlasStore
  let ask: (String) -> Void
  @Environment(\.dismiss) var dismiss
  @ViewState private var query = ""
  @ViewState private var address = ""
  @ViewState private var pasted = ""
  @ViewState private var selection: NSRange?
  @ViewState private var log: ResearchLog?
  @ViewState private var page: ResearchPage?
  @ViewState private var running: Task<Void, Never>?
  @ViewState private var issue = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        AtlasArt.compass.resizable().scaledToFit().frame(width: 19, height: 19).accessibilityHidden(true)
        Text("外部研究").font(AtlasTypeface.reading.font(21).weight(.medium)).foregroundStyle(AtlasPalette.ink)
        Spacer()
        Button("关闭") { dismiss() }.buttonStyle(PaperButton(compact: true))
      }
      PaperRule()
      TextField("搜索公开材料", text: $query).textFieldStyle(.roundedBorder)
      HStack(spacing: 8) {
        Button("搜索") { request(search: true, value: query) }
          .buttonStyle(PaperButton(primary: true, compact: true))
          .disabled(
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || query.unicodeScalars.count > 128 || busy || count("Search") >= 2)
        Text("DeepSeek · 搜索 \(count("Search"))/2 · 读取 \(count("Fetch"))/3")
          .font(.system(size: 11.5))
          .foregroundStyle(AtlasPalette.umber)
        Spacer()
        if running != nil { Button("取消研究") { cancel() }.buttonStyle(PaperButton(compact: true)) }
        Button("新研究") {
          act {
            cancel()
            log = try store.createResearch()
            page = nil
            query = ""
            pasted = ""
            address = ""
            issue = ""
          }
        }.buttonStyle(AtlasChipButtonStyle())
      }
      if let log {
        ForEach(log.candidates) { candidate in
          HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.title).font(AtlasTypeface.reading.font(14).weight(.medium)).lineLimit(1)
              Text(candidate.snippet).font(.system(size: 11.5)).foregroundStyle(AtlasPalette.umber).lineLimit(2)
            }
            Spacer()
            Button("读取网页") {
              address = candidate.url.absoluteString
              request(search: false, value: address)
            }
            .buttonStyle(PaperButton(compact: true))
            .disabled(busy || count("Fetch") >= 3)
          }
          .padding(9)
          .background(AtlasPalette.paperInset.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(AtlasPalette.line.opacity(0.35), lineWidth: 0.7)
          }
        }
        if !log.pages.isEmpty {
          Menu {
            ForEach(log.pages) { p in
              Button(p.title) {
                page = p
                selection = nil
              }
            }
          } label: {
            AtlasMenuPillLabel(title: "已读取的网页", icon: "globe", compact: true)
          }
          .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AtlasMenuButtonStyle(compact: true)).fixedSize()
        }
      }
      HStack(spacing: 8) {
        TextField("网页地址", text: $address).textFieldStyle(.roundedBorder)
        Button("读取") { request(search: false, value: address) }
          .buttonStyle(PaperButton(compact: true))
          .disabled(address.isEmpty || busy || count("Fetch") >= 3)
      }
      DisclosureGroup("手动粘贴正文") {
        VStack(alignment: .leading, spacing: 8) {
          TextEditor(text: $pasted)
            .font(AtlasTypeface.reading.font(13.5))
            .frame(height: 76)
            .padding(4)
            .background(AtlasPalette.paperInset.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
          Button("使用粘贴的正文") {
            act {
              page = try ExternalResearch.pasted(pasted, url: ExternalResearch.address(address))
              selection = nil
            }
          }.buttonStyle(PaperButton(compact: true))
        }
      }
      if let page {
        PaperRule()
        Text(page.title).font(AtlasTypeface.reading.font(16).weight(.medium))
        Text(page.url.absoluteString).font(AtlasTypeface.code.font(11.5)).foregroundStyle(AtlasPalette.umber).textSelection(.enabled)
        SourceText(bodyText: page.text, initial: nil, changed: { selection = $0 }).id(page.id)
        HStack(spacing: 8) {
          Button(selection?.length ?? 0 > 0 ? "用选段提问" : "用全文提问") { adopt(page, save: false) }
            .buttonStyle(PaperButton(primary: true))
          Button("收藏到图谱") { adopt(page, save: true) }
            .buttonStyle(PaperButton())
        }
      } else {
        Spacer()
      }
      if !issue.isEmpty {
        Text(issue).font(.system(size: 12.5)).foregroundStyle(AtlasPalette.umber).textSelection(.enabled)
      }
    }
    .padding(22)
    .frame(minWidth: 590, minHeight: 500)
    .background(AtlasPalette.paper)
    .foregroundStyle(AtlasPalette.ink)
      .onAppear {
        act {
          log = try store.latestResearch() ?? store.createResearch()
          page = log?.pages.last
        }
      }
      .onDisappear { if running != nil { cancel() } }
  }
  private var busy: Bool { running != nil || log?.cancelled == true }
  private func count(_ kind: String) -> Int { log?.attempts.filter { $0.kind == kind }.count ?? 0 }
  private func act(_ f: () throws -> Void) {
    do { try f() } catch { issue = error.localizedDescription }
  }
  private func cancel() {
    running?.cancel()
    running = nil
    if let log { act { self.log = try store.cancelResearch(log.id) } }
  }
  private func request(search: Bool, value: String) {
    guard let log, !busy else { return }
    act {
      if !search { _ = try ExternalResearch.address(value) }
      let credentials = try ProviderProfile(address: "https://api.deepseek.com", model: "research")
      guard let key = try Credentials.read(credentials), !key.isEmpty else {
        throw AtlasStoreError.invalid("请在设置中保存 DeepSeek 的 API 密钥。")
      }
      let a = try store.beginResearchAttempt(log.id, search: search, input: value)
      self.log = try store.latestResearch()
      let sourceQuery = log.candidates.first(where: { $0.url.absoluteString == value })?.query
      issue = search ? "正在搜索…" : "正在读取…"
      running = Task { @MainActor in
        do {
          let candidates = search ? try await ExternalResearch.search(value, key: key) : []
          let fetched =
            search
            ? nil
            : try await ExternalResearch.fetch(
              ExternalResearch.address(value), query: sourceQuery, key: key)
          try Task.checkCancellation()
          let saved = try store.finishResearchAttempt(
            log.id, attempt: a.id, candidates: candidates, page: fetched)
          guard self.log?.id == log.id, !saved.cancelled else { return }
          self.log = saved
          if let fetched {
            page = fetched
            selection = nil
          }
          issue = search ? "返回 \(candidates.count) 个候选。" : "已取得网页正文。"
        } catch {
          guard !Task.isCancelled else { return }
          let msg = error.localizedDescription
          act { self.log = try store.finishResearchAttempt(log.id, attempt: a.id, error: msg) }
          issue = msg
        }
        if self.log?.id == log.id { running = nil }
      }
    }
  }
  private func adopt(_ p: ResearchPage, save: Bool) {
    act {
      var quote = p.text
      var offset = 0
      if !save, let selection, selection.length > 0, let range = Range(selection, in: p.text) {
        quote = String(p.text[range])
        offset = p.text[..<range.lowerBound].unicodeScalars.count
      }
      let ref = try store.freezeWeb(p, quote: quote, offset: offset, save: save)
      if save {
        issue = "已收藏，可从图谱打开当时的正文。"
      } else {
        dismiss()
        ask(ref)
      }
    }
  }
}
